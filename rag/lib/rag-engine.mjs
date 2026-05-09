/**
 * RAG Engine - LanceDB BM25 + Local Embeddings (Ollama snowflake-arctic-embed2)
 *
 * Hybrid search: BM25 full-text (primary, free, local) + vector similarity (optional enrichment).
 * Local embeddings via Ollama snowflake-arctic-embed2 (1024-dim, multilingual incl. Korean).
 * Storage: LanceDB (local embedded, no server needed)
 * Path resolution via paths.mjs (JARVIS_RAG_HOME > BOT_HOME/rag > XDG default)
 */

import * as lancedb from '@lancedb/lancedb';
import * as arrow from 'apache-arrow';
import { readFile, readdir, stat, readFile as readFileAsync } from 'node:fs/promises';
import { join, extname, dirname } from 'node:path';
import { homedir } from 'node:os';
import { appendFileSync, mkdirSync, rmdirSync, statSync, readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { LANCEDB_PATH, RAG_LOCK_DIR, INFRA_HOME, ENTITY_GRAPH_PATH, ensureDirs } from './paths.mjs';

// ─────────────────────────────────────────────────────────────────────────────
// Owner companies — private/config/owner-companies.txt 에서 로드
// 공개 저장소에는 일반 플랫폼명만 두고, 오너 개인 회사명은 gitignored 파일로 분리.
// 형식: pipe(|) 구분 문자열. 예: "Company-A|Company-B|Company-C"
// 파일 없으면 빈 배열 → 공개 OSS 사용자는 자체 회사명 설정 가능.
// ─────────────────────────────────────────────────────────────────────────────
const __rag_engine_dir = dirname(fileURLToPath(import.meta.url));
const OWNER_COMPANIES_PATH = join(__rag_engine_dir, '..', '..', 'private', 'config', 'owner-companies.txt');
function loadOwnerCompanies() {
  try {
    if (!existsSync(OWNER_COMPANIES_PATH)) return [];
    const content = readFileSync(OWNER_COMPANIES_PATH, 'utf-8').trim();
    return content.split('|').map(s => s.trim()).filter(Boolean);
  } catch {
    return [];
  }
}
const OWNER_COMPANIES = loadOwnerCompanies();

const EMBEDDING_MODEL = 'snowflake-arctic-embed2';
const EMBEDDING_DIM = 1024;
const OLLAMA_EMBED_URL = 'http://localhost:11434/api/embed';
// 2026-05-07: batch 150 + 30s timeout 조합으로 timeout 폭주 발생 (Ollama가 150개 batch를 30초에 못 끝냄).
// 환경변수로 튜닝 가능하게 분리, default 50 (Ollama가 60s 안에 안정 처리).
const EMBED_BATCH_SIZE = Number(process.env.RAG_EMBED_BATCH_SIZE) || 50;
const CHUNK_MAX_CHARS = 2000; // ~512 tokens
const CHUNK_OVERLAP_LINES = 0.2; // 20% overlap
const TABLE_NAME = 'documents';

// --- Arrow record → plain JS object 변환 헬퍼 ---
// LanceDB query()가 반환하는 Arrow RecordBatch를 mergeInsert에 다시 넣으면
// vector.isValid 같은 Arrow 내부 메타데이터가 "field not in schema" 에러를 유발함.
// 명시적으로 스키마 필드만 plain 값으로 추출하여 안전한 object를 생성한다.
const _SCHEMA_FIELDS = ['id','text','vector','source','chunk_index','header_path','modified_at','importance','entities','topics','deleted','deleted_at','is_latest','expires_at','chunk_type'];

// ─────────────────────────────────────────────────────────────────────────────
// BM25 Hybrid Search — 순수 JS 구현 (외부 라이브러리 없음)
// Dense(벡터) 검색과 BM25 텍스트 검색을 RRF로 병합하여 검색 품질 향상.
// ─────────────────────────────────────────────────────────────────────────────

const BM25_K1 = 1.5;  // 단어 빈도 포화 상수 (term frequency saturation)
const BM25_B  = 0.75; // 문서 길이 정규화 계수

/**
 * 텍스트를 BM25 토큰 배열로 분리.
 * 영문 소문자 + 한글 유니코드 범위 유지, 기타 특수문자 제거.
 * 2자 미만 토큰 제거 (노이즈 방지).
 */
function _bm25Tokenize(text) {
  return text
    .toLowerCase()
    .replace(/[^\w\s가-힣]/g, ' ')
    .split(/\s+/)
    .filter(t => t.length > 1);
}

/**
 * IDF 맵 생성: 각 단어가 몇 개의 문서(청크)에 등장하는지 계산 후
 * IDF = log((N - df + 0.5) / (df + 0.5) + 1) 공식 적용.
 * @param {string[][]} tokenizedDocs  각 문서의 토큰 배열
 * @returns {Map<string, number>}
 */
function _buildIdfMap(tokenizedDocs) {
  const df = new Map();
  for (const tokens of tokenizedDocs) {
    for (const t of new Set(tokens)) {
      df.set(t, (df.get(t) || 0) + 1);
    }
  }
  const N = tokenizedDocs.length;
  const idf = new Map();
  for (const [term, freq] of df) {
    idf.set(term, Math.log((N - freq + 0.5) / (freq + 0.5) + 1));
  }
  return idf;
}

/**
 * BM25 스코어 계산: 쿼리 토큰의 가중합.
 * @param {string[]} queryTokens  쿼리 토큰 배열
 * @param {string[]} docTokens    문서 토큰 배열
 * @param {number}   avgDocLen    전체 문서 평균 길이
 * @param {Map}      idfMap       IDF 맵
 * @returns {number}
 */
function _bm25Score(queryTokens, docTokens, avgDocLen, idfMap) {
  const docLen = docTokens.length;
  if (docLen === 0 || avgDocLen === 0) return 0;
  const tfMap = new Map();
  for (const t of docTokens) tfMap.set(t, (tfMap.get(t) || 0) + 1);
  let score = 0;
  for (const qt of queryTokens) {
    const tf = tfMap.get(qt) || 0;
    if (tf === 0) continue;
    const idf = idfMap.get(qt) || 0;
    score += idf * (tf * (BM25_K1 + 1)) /
      (tf + BM25_K1 * (1 - BM25_B + BM25_B * docLen / avgDocLen));
  }
  return score;
}

/**
 * Reciprocal Rank Fusion — Dense 랭킹과 BM25 랭킹을 병합.
 * RRF 공식: score(d) = Σ 1/(k + rank(d))
 * k=60 은 표준 파라미터 (Cormack et al. 2009).
 * @param {Array}  denseRanks  Dense(벡터) 검색 결과 배열 (id/path 포함)
 * @param {Array}  bm25Ranks   BM25 검색 결과 배열 (id/path 포함)
 * @param {number} k           RRF 상수
 * @returns {string[]}  id 배열 (score 내림차순)
 */
function _rrfMerge(denseRanks, bm25Ranks, k = 60) {
  const scores = new Map();
  for (const [i, doc] of denseRanks.entries()) {
    const id = doc.id || doc.path;
    scores.set(id, (scores.get(id) || 0) + 1 / (k + i + 1));
  }
  for (const [i, doc] of bm25Ranks.entries()) {
    const id = doc.id || doc.path;
    scores.set(id, (scores.get(id) || 0) + 1 / (k + i + 1));
  }
  return [...scores.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([id]) => id);
}

/**
 * HyDE: 쿼리로 가상 답변 생성 후 그것을 임베딩으로 검색
 * LLM 호출 비용 있음 → useHyde: true 명시 시에만 동작
 */
async function generateHypotheticalDoc(query, llmClient) {
  if (!llmClient) return query; // fallback
  try {
    const resp = await llmClient.chat({
      model: 'llama3.2:latest',
      messages: [{
        role: 'user',
        content: `다음 질문에 대한 간결한 답변을 2-3문장으로 작성하세요. 답변만 출력하세요.\n\n질문: ${query}`
      }],
      max_tokens: 150,
      temperature: 0.3,
    });
    return resp?.choices?.[0]?.message?.content?.trim() || query;
  } catch {
    return query; // LLM 실패 시 원본 쿼리로 폴백
  }
}

// ── code-chunk: 파일 타입 → 언어 매핑 ──
const CODE_EXT_LANG = {
  '.js': 'js', '.mjs': 'js', '.cjs': 'js', '.jsx': 'js',
  '.ts': 'ts', '.tsx': 'ts',
  '.py': 'py',
  '.sh': 'sh', '.bash': 'sh', '.zsh': 'sh',
  '.java': 'java',
  '.go': 'go',
  '.rs': 'rs',
  '.c': 'c', '.cpp': 'cpp', '.cc': 'cpp', '.h': 'c', '.hpp': 'cpp',
  '.cs': 'cs',
  '.rb': 'rb',
  '.php': 'php',
};
const CODE_EXTENSIONS = new Set(Object.keys(CODE_EXT_LANG));
// 스키마 일치 사전 검증 — mergeInsert/table.add 전에 호출하여 LanceDB Rust 레이어 도달 전 차단
function _validateRecordSchema(records) {
  if (records.length === 0) return;
  const missing = _SCHEMA_FIELDS.filter(f => !(f in records[0]));
  if (missing.length > 0) {
    throw new Error(`[rag] Schema bug: record missing fields [${missing.join(', ')}]. All ${_SCHEMA_FIELDS.length} fields required.`);
  }
}

function _toPlainRecord(record, overrides = {}) {
  const out = {};
  for (const f of _SCHEMA_FIELDS) {
    if (!(f in record)) continue;
    const v = record[f];
    if (f === 'vector' && v != null) {
      // Float32Array로 명시 변환 — Array.from()은 LanceDB가 재직렬화 시
      // vector.isValid validity 비트를 붙여 "Found field not in schema" 에러 유발.
      // Float32Array는 non-nullable 타입드 배열이므로 isValid 없이 직렬화됨.
      out[f] = v instanceof Float32Array ? v : Float32Array.from(v);
    } else if (v != null && typeof v === 'object' && typeof v[Symbol.iterator] === 'function' && !Array.isArray(v)) {
      // Arrow FixedSizeList 등 기타 iterable → plain JS Array
      out[f] = Array.from(v);
    } else {
      out[f] = v;
    }
  }
  return { ...out, ...overrides };
}

// --- Per-file cross-process lock (mkdir-based, atomic on POSIX) ---

// RAG_LOCK_DIR imported from paths.mjs
const LOCK_STALE_MS = 30_000; // 30s stale lock auto-cleanup
const LOCK_WAIT_TIMEOUT_MS = 20_000; // 20s max wait (rag-index 대용량 파일 임베딩 완료 대기)
const LOCK_POLL_INTERVAL_MS = 50; // poll every 50ms

/** Hash filePath to safe directory name for lock. */
function _lockPath(filePath) {
  const hash = createHash('sha256').update(filePath).digest('hex').slice(0, 16);
  return join(RAG_LOCK_DIR, `idx-${hash}.lock`);
}

/** Try to acquire a per-file cross-process lock. Returns true on success. */
function _tryAcquireFileLock(filePath) {
  const lockDir = _lockPath(filePath);
  try {
    mkdirSync(lockDir, { recursive: false });
    return true;
  } catch (err) {
    if (err.code === 'EEXIST') {
      // Check for stale lock
      try {
        const st = statSync(lockDir);
        if (Date.now() - st.mtimeMs > LOCK_STALE_MS) {
          try { rmdirSync(lockDir); } catch { /* race ok */ }
          // Retry once after stale cleanup
          try {
            mkdirSync(lockDir, { recursive: false });
            return true;
          } catch { /* another process grabbed it */ }
        }
      } catch { /* stat failed, lock may have been released */ }
      return false;
    }
    // ENOENT on parent dir — create it and retry
    if (err.code === 'ENOENT') {
      try {
        mkdirSync(RAG_LOCK_DIR, { recursive: true });
        mkdirSync(lockDir, { recursive: false });
        return true;
      } catch { return false; }
    }
    return false;
  }
}

/** Release per-file cross-process lock. */
function _releaseFileLock(filePath) {
  try { rmdirSync(_lockPath(filePath)); } catch { /* ignore */ }
}

/** Await cross-process lock with timeout. Returns true if acquired. */
async function _awaitFileLock(filePath, timeoutMs = LOCK_WAIT_TIMEOUT_MS) {
  if (_tryAcquireFileLock(filePath)) return true;
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    await new Promise(r => setTimeout(r, LOCK_POLL_INTERVAL_MS + Math.floor(Math.random() * 20)));
    if (_tryAcquireFileLock(filePath)) return true;
  }
  return false;
}

// --- Ollama embedding (snowflake-arctic-embed2, batch) ---
// Ollama /api/embed supports multi-text batch in a single HTTP request.
// Batch size 50 gives ~18ms/text on M2, full reindex ~41min for 135k chunks.

export class RAGEngine {
  constructor(dbPath) {
    this.dbPath = dbPath || LANCEDB_PATH;
    this.db = null;
    this.table = null;
    // enrichDocument는 로컬 룰 기반으로 전환됨 (OpenAI 불필요)
    // Embeddings: @xenova/transformers (all-MiniLM-L6-v2, 로컬)
    this._indexLocks = new Map(); // filePath → Promise (in-memory per-file lock)
  }

  async init() {
    this.db = await lancedb.connect(this.dbPath);

    try {
      this.table = await this.db.openTable(TABLE_NAME);

      // ── 자동 스키마 마이그레이션 ──
      // 코드에 새 필드가 추가됐는데 기존 테이블에 없으면 자동으로 컬럼 추가.
      // "different schema" 에러 재발 방지 (deleted/deleted_at 사태 교훈).
      const currentFields = (await this.table.schema()).fields.map(f => f.name);
      const migrations = [];
      if (!currentFields.includes('deleted'))    migrations.push({ name: 'deleted',    valueSql: 'false' });
      if (!currentFields.includes('deleted_at')) migrations.push({ name: 'deleted_at', valueSql: '0.0' });
      // v2: 시간적 무효화 (isLatest + expiresAt)
      if (!currentFields.includes('is_latest'))  migrations.push({ name: 'is_latest',  valueSql: 'true' });
      if (!currentFields.includes('expires_at')) migrations.push({ name: 'expires_at', valueSql: '0.0' });
      // v2: 청킹 타입 (code-chunk 라우팅 기록)
      if (!currentFields.includes('chunk_type')) migrations.push({ name: 'chunk_type', valueSql: "'markdown'" });
      if (migrations.length > 0) {
        console.log(`[rag] Auto-migrating table: adding [${migrations.map(m => m.name).join(', ')}]`);
        await this.table.addColumns(migrations);
        // addColumns은 valueSql을 non-nullable로 추론 → 구 fragment에서 NULL fill-in 시 Rust 패닉.
        // alterColumns으로 nullable=true 전환: 구 fragment → NULL 허용, 신규 레코드 → 실제 값 저장.
        const newNames = migrations.map(m => m.name);
        const toNullable = newNames.filter(n => ['is_latest','expires_at','chunk_type'].includes(n));
        if (toNullable.length > 0) {
          try {
            await this.table.alterColumns(toNullable.map(n => ({ path: n, nullable: true })));
            console.log(`[rag] Migration: nullable=true set for [${toNullable.join(', ')}]`);
          } catch (alterErr) {
            console.warn(`[rag] alterColumns nullable failed (non-fatal): ${alterErr.message?.slice(0, 80)}`);
          }
        }
      }

      // 역량 플래그
      const finalFields = new Set([...currentFields, ...migrations.map(m => m.name)]);
      this._supportsDeleted   = finalFields.has('deleted');
      this._supportsIsLatest  = finalFields.has('is_latest');
      this._supportsExpiresAt = finalFields.has('expires_at');
    } catch (openErr) {
      // openTable 실패 시: 기존 데이터 폴더가 있으면 빈 테이블로 덮어쓰지 않음 (데이터 보호)
      const { existsSync: _exists } = await import('node:fs');
      const { join: _join } = await import('node:path');
      const lancePath = _join(this.dbPath, `${TABLE_NAME}.lance`);
      if (_exists(lancePath)) {
        console.error(`[rag] init: openTable failed but ${lancePath} exists — NOT creating empty table`);
        console.error(`[rag] init error: ${openErr?.message?.slice(0, 150)}`);
        throw new Error(`openTable failed with existing data: ${openErr?.message?.slice(0, 100)}`);
      }
      // documents.lance 폴더 없음 = 진짜 첫 실행 → 빈 테이블 생성
      console.log('[rag] init: no existing table — creating fresh empty table');
      const schema = new arrow.Schema([
        new arrow.Field('id', new arrow.Utf8()),
        new arrow.Field('text', new arrow.Utf8()),
        new arrow.Field('vector', new arrow.FixedSizeList(EMBEDDING_DIM, new arrow.Field('item', new arrow.Float32(), false))),
        new arrow.Field('source', new arrow.Utf8()),
        new arrow.Field('chunk_index', new arrow.Int32()),
        new arrow.Field('header_path', new arrow.Utf8()),
        new arrow.Field('modified_at', new arrow.Float64()),
        new arrow.Field('importance', new arrow.Float32()),
        new arrow.Field('entities', new arrow.Utf8()),
        new arrow.Field('topics', new arrow.Utf8()),
        new arrow.Field('deleted', new arrow.Bool()),
        new arrow.Field('deleted_at', new arrow.Float64()),
        new arrow.Field('is_latest', new arrow.Bool()),
        new arrow.Field('expires_at', new arrow.Float64()),
        new arrow.Field('chunk_type', new arrow.Utf8()),
      ]);
      this.table = await this.db.createEmptyTable(TABLE_NAME, schema);
      this._supportsDeleted   = true;
      this._supportsIsLatest  = true;
      this._supportsExpiresAt = true;
    }

    // 역량 플래그 미설정 안전망 (예외 경로에서 openTable 성공했으나 migration 실패한 경우)
    if (this._supportsDeleted === undefined) {
      try {
        const sampleRow = await this.table.query().limit(1).toArray();
        this._supportsDeleted = sampleRow.length === 0 || sampleRow[0].hasOwnProperty('deleted');
      } catch {
        this._supportsDeleted = false;
      }
    }
    if (this._supportsIsLatest  === undefined) this._supportsIsLatest  = false;
    if (this._supportsExpiresAt === undefined) this._supportsExpiresAt = false;

    // FTS index creation moved to compact() only — creating it in init() can trigger
    // internal data file rewrite (LanceDB 2.0.0) which causes "Not found" errors
    // when another process holds a stale manifest reference to the pre-rewrite file.
  }

  /**
   * 테이블 참조 갱신 — 다른 프로세스(rag-index)가 DB를 수정/compact한 후
   * stale manifest 참조를 방지하기 위해 테이블을 다시 열어 최신 버전 획득.
   */
  async refreshTable() {
    try {
      const newTable = await this.db.openTable(TABLE_NAME);
      this.table = newTable;
      // deleted 컬럼 지원 여부 확인
      try {
        const sampleRow = await this.table.query().limit(1).toArray();
        this._supportsDeleted = sampleRow.length === 0 || sampleRow[0].hasOwnProperty('deleted');
      } catch {
        this._supportsDeleted = false;
      }
      return true; // 성공
    } catch (openErr) {
      // openTable() 실패 → DB 커넥션 자체를 재생성하여 캐시 무효화 후 재시도
      console.warn(`[rag] refreshTable: openTable failed (${openErr.message?.slice(0, 80)}), attempting full reconnect…`);
      try {
        this.db = await lancedb.connect(this.dbPath);
        this.table = await this.db.openTable(TABLE_NAME);
        console.log('[rag] refreshTable: reconnected successfully');
        try {
          const sampleRow = await this.table.query().limit(1).toArray();
          this._supportsDeleted = sampleRow.length === 0 || sampleRow[0].hasOwnProperty('deleted');
        } catch {
          this._supportsDeleted = false;
        }
        return true; // 재연결 후 성공
      } catch (reconnErr) {
        // 재연결도 실패: this.table은 기존 값 유지 (호출자가 에러 처리)
        console.error(`[rag] refreshTable: reconnect failed: ${reconnErr.message?.slice(0, 100)}`);
        return false; // 실패 — 호출자가 !refreshOk 로 감지
      }
    }
  }

  /**
   * Stale manifest 복구: 손상된 documents.lance 디렉토리를 제거하고 빈 테이블로 재초기화.
   * rag-index가 _staleManifest=true를 감지했을 때만 호출. 데이터 손실 감수.
   * (어차피 stale manifest 상태에서는 기존 데이터에 접근 불가)
   */
  // ── 읽기 전용 모드 ──

  /**
   * 읽기 전용으로 DB를 열기. DB가 없으면 절대 생성하지 않고 throw.
   * 상태 확인 목적(getStats, search)에만 사용할 것.
   */
  async openReadOnly() {
    const { existsSync } = await import('node:fs');
    const { join } = await import('node:path');
    const lancePath = join(this.dbPath, `${TABLE_NAME}.lance`);
    if (!existsSync(lancePath)) {
      throw new Error(`[rag] openReadOnly: DB not found at ${lancePath} — refusing to create`);
    }
    const db = await lancedb.connect(this.dbPath);
    this.table = await db.openTable(TABLE_NAME);
    this._readOnly = true;
    // 역량 플래그 (migration 없이 샘플로만 판단)
    try {
      const sample = await this.table.query().limit(1).toArray();
      this._supportsDeleted   = sample.length === 0 || 'deleted'    in sample[0];
      this._supportsIsLatest  = sample.length === 0 || 'is_latest'  in sample[0];
      this._supportsExpiresAt = sample.length === 0 || 'expires_at' in sample[0];
    } catch {
      this._supportsDeleted   = false;
      this._supportsIsLatest  = false;
      this._supportsExpiresAt = false;
    }
  }

  /**
   * readOnly 모드에서 쓰기 메서드 호출 시 throw.
   * 쓰기 메서드 최상단에서 반드시 호출할 것.
   */
  _assertWritable() {
    if (this._readOnly) throw new Error('[rag] Operation not allowed in read-only mode');
  }

  async dropAndReinit() {
    this._assertWritable();
    const { rm } = await import('node:fs/promises');
    const { join } = await import('node:path');
    const tablePath = join(this.dbPath, 'documents.lance');
    try {
      await rm(tablePath, { recursive: true, force: true });
      console.log(`[rag] dropAndReinit: removed ${tablePath}`);
    } catch (rmErr) {
      console.warn(`[rag] dropAndReinit: rm failed (${rmErr.message?.slice(0, 80)}) — continuing`);
    }
    this.table = null;
    this.db = null;
    await this.init();
    console.log('[rag] dropAndReinit: fresh empty table created');
  }

  _withDeletedFilter(query) {
    // deleted 컬럼이 지원되는 경우에만 필터링 적용
    let q = this._supportsDeleted ? query.where('deleted IS NULL OR deleted = false') : query;
    // is_latest: false 인 청크는 더 최신 버전이 존재 → 검색 제외
    // nullable 컬럼이므로 NULL = 마이그레이션 전 기존 레코드 → 최신으로 간주
    if (this._supportsIsLatest)  q = q.where('is_latest IS NULL OR is_latest = true');
    // expires_at: NULL 또는 0 = 영구, >0 = TTL; 만료된 청크 제외
    if (this._supportsExpiresAt) q = q.where(`expires_at IS NULL OR expires_at = 0 OR expires_at > ${Date.now()}`);
    return q;
  }

  // --- Enrichment ---

  /**
   * 로컬 룰 기반 문서 분석: 중요도(importance), 엔티티(entities), 토픽(topics) 추출.
   * 외부 API 의존 없음 — 정규식·키워드 매칭으로 즉시 실행. 비용 0.
   */
  enrichDocument(text) {
    // --- Entity 사전 (긴 용어 우선 — 서브스트링 오탐 방지) ---
    const TECH_TERMS = [
      'Spring Boot', 'Spring Batch', 'Spring WebFlux', 'Spring Security', 'Spring',
      'JavaScript', 'TypeScript', 'Java', 'Kotlin', 'Python', 'Node.js',
      'Kafka', 'Redis', 'MySQL', 'PostgreSQL', 'MongoDB', 'LanceDB', 'SQLite',
      'GitHub Actions', 'AWS', 'EC2', 'S3', 'Lambda', 'ECS', 'RDS', 'CloudWatch', 'SQS',
      'Kubernetes', 'Docker', 'k8s', 'Terraform', 'Jenkins',
      'GraphQL', 'gRPC', 'WebSocket', 'REST',
      'QueryDSL', 'JPA', 'MyBatis', 'Hibernate',
      'Datadog', 'Grafana', 'Prometheus',
      'Next.js', 'React', 'Gatsby', 'Netlify', 'Vue',
      'Anthropic', 'OpenAI', 'Claude', 'GPT', 'LLM', 'RAG',
      'WebFlux', 'Reactor', 'RxJava',
    ];
    // NLP 엔티티 추출용 회사명 사전.
    // 공개 저장소엔 일반 플랫폼명만 유지. 오너 개인 근무 이력/관심 회사는
    // private/config/owner-companies.txt 로 분리 (gitignored).
    const COMPANY_TERMS = [
      'Discord', 'Slack', 'Teams',
      ...OWNER_COMPANIES,
    ];

    // --- Topic 매핑 (키워드 히트 수로 스코어링) ---
    const TOPIC_MAP = {
      '커리어':       ['면접', '이직', '이력서', '채용', '합격', '불합격', '연봉', '오퍼', '코딩테스트', '포트폴리오', '자기소개서', '지원'],
      '트러블슈팅':   ['오류', '에러', 'error', 'exception', '장애', '버그', 'bug', '수정', '해결', '원인', '디버그', 'NPE', 'timeout'],
      '인프라':       ['배포', 'deploy', 'AWS', 'Docker', '서버', 'Kubernetes', 'k8s', 'CI/CD', 'Jenkins', 'plist', 'launchd', 'cron'],
      '개발':         ['Spring', 'Kotlin', 'JPA', 'Kafka', 'Redis', 'gRPC', 'WebFlux', '쿼리', '트랜잭션', '리팩토링', 'QueryDSL'],
      '블로그':       ['포스팅', '블로그', '글 작성', 'SEO', 'Netlify', 'Gatsby', '초안', '발행'],
      'AI/자비스':    ['Jarvis', 'jarvis', 'RAG', 'LLM', 'Claude', '봇', 'bot', '크론', '자동화', '에이전트', 'embedding'],
      '금융/투자':    ['주식', '트레이딩', '레버리지', '투자', '수익률', 'ETF'],
    };

    // --- Importance 키워드 (히트 시 가중치) ---
    const HIGH_IMP_KWS = ['면접', '이직', '합격', '불합격', '장애', '원인', '해결', '배포', '성과', '개선', '수치', '오류'];

    const lower = text.toLowerCase();

    // entities: 매칭 후 서브스트링 중복 제거
    // ex) "Spring Boot"와 "Spring" 둘 다 매칭 → "Spring Boot"만 유지
    const rawEntities = [];
    for (const term of [...COMPANY_TERMS, ...TECH_TERMS]) {
      if (text.includes(term) && !rawEntities.includes(term)) rawEntities.push(term);
    }
    // 다른 엔티티의 서브스트링인 것 제거 (Java → JavaScript에 포함되므로 제거)
    const entities = rawEntities.filter(
      term => !rawEntities.some(other => other !== term && other.includes(term))
    );

    // topics: 스코어 상위 3개
    const topicScores = {};
    for (const [topic, kws] of Object.entries(TOPIC_MAP)) {
      let score = 0;
      for (const kw of kws) { if (lower.includes(kw.toLowerCase())) score++; }
      if (score > 0) topicScores[topic] = score;
    }
    const topics = Object.entries(topicScores)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 3)
      .map(([t]) => t);

    // importance: 기저 0.3 → 조건별 누적
    let importance = 0.3;
    if (text.length > 300)  importance += 0.05;
    if (text.length > 800)  importance += 0.05;
    if (text.length > 1500) importance += 0.05;
    if (/\d+/.test(text))   importance += 0.05;  // 수치 포함
    if (/```|`[^`]+`/.test(text)) importance += 0.05; // 코드 포함
    if (HIGH_IMP_KWS.some(kw => text.includes(kw))) importance += 0.1;
    if (entities.length >= 3) importance += 0.05; // 기술 컨텍스트 풍부
    if (topics.length >= 2)   importance += 0.05;
    importance = Math.min(1, importance);

    return { importance, entities: entities.slice(0, 12), topics };
  }

  // --- Embedding ---

  async embed(texts) {
    // Batches를 병렬로 Ollama에 전송 — 큰 파일(150청크 이상)에서만 효과 발생.
    // Ollama 서버의 NUM_PARALLEL(기본 auto=4)을 활용해 동시 embedding 처리.
    // 2026-04-20: 직렬 → 병렬 (CONCURRENCY=2) 전환. 파일 단위 병렬화와 조합됨.
    const batches = [];
    for (let i = 0; i < texts.length; i += EMBED_BATCH_SIZE) {
      batches.push(texts.slice(i, i + EMBED_BATCH_SIZE));
    }
    if (batches.length === 0) return [];
    if (batches.length === 1) {
      // 단일 batch는 병렬화 의미 없음 — 기존 경로로 처리
      return this._embedOneBatch(batches[0]);
    }

    const CONCURRENCY = Math.min(
      Number(process.env.RAG_EMBED_BATCH_CONCURRENCY) || 2,
      batches.length,
    );
    const results = new Array(batches.length);
    let next = 0;
    const workers = Array.from({ length: CONCURRENCY }, () => (async () => {
      while (true) {
        const idx = next++;
        if (idx >= batches.length) return;
        results[idx] = await this._embedOneBatch(batches[idx]);
      }
    })());
    await Promise.all(workers);
    return results.flat();
  }

  /**
   * Single batch embedding with retry (ECONNREFUSED/timeout만 재시도).
   * @param {string[]} batch - 최대 EMBED_BATCH_SIZE 텍스트
   * @returns {Promise<number[][]>} embeddings 배열
   */
  async _embedOneBatch(batch) {
    // Circuit breaker: 연속 실패 5회 → 30분 OPEN (추가 호출 즉시 차단, BM25 fallback 활성).
    // 복구: 30분 후 HALF-OPEN 1회 시도 → 성공 시 CLOSED, 실패 시 재 OPEN.
    if (!this._embedCircuit) this._embedCircuit = { state: 'closed', failCount: 0, openedAt: 0 };
    const EMBED_FAIL_THRESHOLD = 5;
    const EMBED_OPEN_DURATION_MS = 30 * 60 * 1000;
    const now = Date.now();
    if (this._embedCircuit.state === 'open') {
      if (now - this._embedCircuit.openedAt < EMBED_OPEN_DURATION_MS) {
        const remainMin = Math.max(1, Math.round((EMBED_OPEN_DURATION_MS - (now - this._embedCircuit.openedAt)) / 60000));
        throw new Error(`Embedding circuit OPEN (${this._embedCircuit.failCount} consecutive failures, cooling down ~${remainMin}min)`);
      }
      this._embedCircuit.state = 'half-open';
      console.warn('[rag] Embedding circuit HALF-OPEN — trial request');
    }

    const MAX_RETRIES = 2;
    let lastErr;
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        const res = await fetch(OLLAMA_EMBED_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: EMBEDDING_MODEL, input: batch }),
          // 2026-05-07: 30s → 60s 상향 (batch 50개 처리 안정 마진).
          signal: AbortSignal.timeout(Number(process.env.RAG_EMBED_TIMEOUT_MS) || 60_000),
        });
        if (!res.ok) {
          throw new Error(`Ollama embed HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
        }
        const data = await res.json();
        if (this._embedCircuit.state !== 'closed') {
          console.warn(`[rag] Embedding circuit CLOSED — recovered after ${this._embedCircuit.failCount} failures`);
          this._embedCircuit = { state: 'closed', failCount: 0, openedAt: 0 };
        }
        return data.embeddings;
      } catch (err) {
        lastErr = err;
        const msg = err.message || '';
        if ((msg.includes('timed out') || msg.includes('timeout') || msg.includes('ECONNREFUSED')) && attempt < MAX_RETRIES) {
          await new Promise(r => setTimeout(r, 3_000));
          continue;
        }
        this._embedCircuit.failCount++;
        // [DIAG 2026-05-02] catch 블록 raw 에러 로깅 (이전엔 미기록 → 6개월 silent 누적)
        // batch.length·err.name·err.message로 timeout vs HTTP error vs ECONNREFUSED 분류 가능.
        console.warn(`[rag] Embed batch fail #${this._embedCircuit.failCount} (batchLen=${batch.length}): ${err.name || 'Error'}: ${(err.message || '').slice(0, 200)}`);
        if (this._embedCircuit.state === 'half-open' || this._embedCircuit.failCount >= EMBED_FAIL_THRESHOLD) {
          this._embedCircuit.state = 'open';
          this._embedCircuit.openedAt = Date.now();
          console.warn(`[rag] Embedding circuit OPEN — ${this._embedCircuit.failCount} consecutive failures, cooling 30min`);
        }
        throw err;
      }
    }
    throw lastErr;
  }

  async _alertEmbeddingFailure(status, message) {
    // 쿨다운: 1시간에 1회만 알림
    const now = Date.now();
    if (this._lastEmbedAlert && now - this._lastEmbedAlert < 3600_000) return;
    this._lastEmbedAlert = now;

    const alertText = `🚨 RAG Embedding 장애 (Ollama snowflake-arctic-embed2)\n오류: ${message.slice(0, 200)}\nOllama 실행 여부 확인: curl http://localhost:11434/api/ps`;
    const botHome = INFRA_HOME;

    // monitoring.json에서 웹훅/ntfy 정보 읽기
    try {
      const monCfg = JSON.parse(await readFile(join(botHome, 'config', 'monitoring.json'), 'utf-8'));
      // Discord jarvis-system 웹훅
      const webhook = monCfg.webhooks?.['jarvis-system'];
      if (webhook) {
        await fetch(webhook, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ content: alertText }),
        }).catch(() => {});
      }
      // ntfy 모바일 푸시
      if (monCfg.ntfy?.enabled && monCfg.ntfy?.topic) {
        await fetch(`${monCfg.ntfy.server}/${monCfg.ntfy.topic}`, {
          method: 'POST',
          headers: { Title: 'RAG Embedding Alert', Priority: 'high', Tags: 'warning' },
          body: alertText,
        }).catch(() => {});
      }
    } catch { /* monitoring.json 읽기 실패 — 무시 */ }

    // 구조화 로그
    try {
      appendFileSync(
        join(botHome, 'logs', 'rag-errors.jsonl'),
        JSON.stringify({ ts: new Date().toISOString(), type: 'embedding_failure', status, message: message.slice(0, 200) }) + '\n',
      );
    } catch { /* 로그 실패 — 무시 */ }
  }

  // --- Indexing ---

  async indexFile(filePath, prevChunkCount = Infinity, opts = {}) {
    this._assertWritable();
    // --- Layer 1: In-memory per-file lock (same process) ---
    const inMemStart = Date.now();
    while (this._indexLocks.has(filePath)) {
      if (Date.now() - inMemStart > LOCK_WAIT_TIMEOUT_MS) {
        console.warn(`[rag] indexFile skipped (in-memory lock timeout): ${filePath}`);
        return 0;
      }
      await this._indexLocks.get(filePath);
    }

    let inMemResolve;
    const inMemPromise = new Promise((r) => { inMemResolve = r; });
    this._indexLocks.set(filePath, inMemPromise);

    // --- Layer 2: Cross-process per-file lock (mkdir-based) ---
    const gotProcessLock = await _awaitFileLock(filePath);
    if (!gotProcessLock) {
      this._indexLocks.delete(filePath);
      inMemResolve();
      console.warn(`[rag] indexFile skipped (cross-process lock timeout): ${filePath}`);
      return 0;
    }

    try {
      const content = await readFile(filePath, 'utf-8');
      if (!content.trim()) return 0;

      // code-chunk: 코드 파일은 함수/클래스 경계 기반 청킹, 나머지는 마크다운 헤딩 기반
      const fileExt = extname(filePath).toLowerCase();
      const isCode  = CODE_EXTENSIONS.has(fileExt);
      const chunks  = isCode ? splitCode(content, fileExt) : splitMarkdown(content);
      if (chunks.length === 0) return 0;

      // Enrich: 첫 번째 청크를 대표 텍스트로 사용 (ENABLE_RAG_ENRICHMENT=1 시만 API 호출)
      const enrichment = await this.enrichDocument(chunks[0].text);

      // Embed all chunks — degrade to zero vectors if OpenAI unavailable (BM25 still works)
      const texts = chunks.map((c) => c.text);
      let embeddings;
      try {
        embeddings = await this.embed(texts);
      } catch (embErr) {
        console.warn(`[rag] Embedding unavailable (${embErr.message.slice(0, 80)}), storing zero vectors — BM25 only`);
        embeddings = texts.map(() => new Array(EMBEDDING_DIM).fill(0));
        // 재시도 대기열에 기록 (429 Rate Limit 등 일시적 오류 시 추후 재인덱싱용)
        const retryQueuePath = join(INFRA_HOME, 'state', 'embedding-retry-queue.jsonl');
        try {
          appendFileSync(
            retryQueuePath,
            JSON.stringify({ ts: new Date().toISOString(), filePath, reason: embErr.message.slice(0, 100) }) + '\n'
          );
        } catch(_) {}
      }

      const safeSource = filePath.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
      const chunkType  = isCode ? `code-${CODE_EXT_LANG[fileExt] || 'unknown'}` : 'markdown';
      const expiresAt  = opts.ttlMs ? Date.now() + opts.ttlMs : 0;
      const records = chunks.map((chunk, i) => ({
        id: `${filePath}:${i}`,
        text: chunk.text,
        vector: embeddings[i],
        source: filePath,
        chunk_index: i,
        header_path: chunk.headerPath,
        modified_at: Date.now(),
        importance: enrichment.importance,
        entities: JSON.stringify(enrichment.entities),
        topics: JSON.stringify(enrichment.topics),
        deleted: false,
        deleted_at: 0,
        is_latest: true,
        expires_at: expiresAt,
        chunk_type: chunkType,
      }));

      _validateRecordSchema(records);

      // mergeInsert: delete() 대신 upsert 사용 → _deletions 파일 생성 방지
      // 업데이트(matched) + 신규 삽입(not matched) 모두 처리
      // mergeInsert retry — LanceDB issue #1597: commit conflict 발생 시 자동 재시도
      let _mergeAttempt = 0;
      while (true) {
        try {
          await this.table.mergeInsert('id')
            .whenMatchedUpdateAll()
            .whenNotMatchedInsertAll()
            .execute(records);
          break;
        } catch (mergeErr) {
          _mergeAttempt++;
          const isConflict = mergeErr.message?.includes('commit conflict') ||
            mergeErr.message?.includes('Commit conflict') ||
            mergeErr.message?.includes('preempted by concurrent');
          // "Not found: .lance" = stale manifest reference (e.g. after compact deleted old fragments)
          // refreshTable() fetches the latest manifest so the next attempt uses current fragment paths
          const isStaleManifest = mergeErr.message?.includes('Not found:') &&
            mergeErr.message?.includes('.lance');
          if ((isConflict || isStaleManifest) && _mergeAttempt < 4) {
            await new Promise(r => setTimeout(r, _mergeAttempt * 500));
            const refreshOk = await this.refreshTable();
            if (!refreshOk) {
              // refreshTable 실패 = table 자체가 없음 → 재시도 무의미
              console.error(`[rag] indexFile: refreshTable failed on attempt ${_mergeAttempt}, aborting merge`);
              throw mergeErr;
            }
            continue;
          }
          throw mergeErr;
        }
      }

      // stale 청크 제거: 이전 청크 수보다 줄었을 때만 실행 (드문 케이스)
      // table.update()는 0행 match여도 새 manifest version 생성 → fragment 누적 원인.
      // prevChunkCount를 호출자(rag-index.mjs)가 state에서 전달해 불필요한 호출 차단.
      if (records.length > 0 && prevChunkCount > records.length) {
        const staleTs = Date.now();
        await this.table.update({
          where: `source = '${safeSource}' AND chunk_index >= ${records.length}`,
          values: { deleted: true, deleted_at: staleTs, is_latest: false },
        }).catch(() => {}); // stale 청크 없으면 정상
      }

      return records.length;
    } finally {
      _releaseFileLock(filePath);
      this._indexLocks.delete(filePath);
      inMemResolve();
    }
  }

  /**
   * 파일 청킹 + 임베딩 + 레코드 준비. DB 쓰기 없음.
   * fresh rebuild 시 batched table.add()를 위해 사용.
   * @returns {Array<Object>} records (빈 파일/오류면 [])
   */
  async _prepareFileRecords(filePath) {
    try {
      let content = await readFile(filePath, 'utf-8');
      if (!content.trim()) return [];
      // code-chunk: 코드 파일은 함수/클래스 경계 기반 청킹, 나머지는 마크다운 헤딩 기반
      const fileExt = extname(filePath).toLowerCase();
      const isCode  = CODE_EXTENSIONS.has(fileExt);
      let chunks  = isCode ? splitCode(content, fileExt) : splitMarkdown(content);
      if (chunks.length === 0) return [];
      const enrichment = await this.enrichDocument(chunks[0].text);
      const texts = chunks.map((c) => c.text);
      let embeddings;
      try {
        embeddings = await this.embed(texts);
      } catch (embErr) {
        console.warn(`[rag] Embedding unavailable (${embErr.message.slice(0, 80)}), storing zero vectors — BM25 only`);
        embeddings = texts.map(() => new Array(EMBEDDING_DIM).fill(0));
        const retryQueuePath = join(INFRA_HOME, 'state', 'embedding-retry-queue.jsonl');
        try {
          appendFileSync(
            retryQueuePath,
            JSON.stringify({ ts: new Date().toISOString(), filePath, reason: embErr.message.slice(0, 100) }) + '\n'
          );
        } catch(_) {}
      }
      const chunkType = isCode ? `code-${CODE_EXT_LANG[fileExt] || 'unknown'}` : 'markdown';
      return chunks.map((chunk, i) => ({
        id: `${filePath}:${i}`,
        text: chunk.text,
        vector: embeddings[i],
        source: filePath,
        chunk_index: i,
        header_path: chunk.headerPath,
        modified_at: Date.now(),
        importance: enrichment.importance,
        entities: JSON.stringify(enrichment.entities),
        topics: JSON.stringify(enrichment.topics),
        deleted: false,
        deleted_at: 0,
        is_latest: true,
        expires_at: 0,
        chunk_type: chunkType,
      }));
    } catch (err) {
      console.warn(`[rag] _prepareFileRecords failed for ${filePath}: ${err.message.slice(0, 80)}`);
      return [];
    }
  }

  async indexDirectory(dirPath, opts = {}) {
    this._assertWritable();
    const { extensions = ['.md'], maxAgeDays = null } = opts;
    let totalChunks = 0;
    let entries;

    try {
      entries = await readdir(dirPath, { withFileTypes: true });
    } catch {
      return 0;
    }

    for (const entry of entries) {
      const fullPath = join(dirPath, entry.name);

      if (entry.isDirectory()) {
        totalChunks += await this.indexDirectory(fullPath, opts);
        continue;
      }

      if (!extensions.includes(extname(entry.name))) continue;

      // Check file age if maxAgeDays specified
      if (maxAgeDays !== null) {
        const fstat = await stat(fullPath);
        const ageDays = (Date.now() - fstat.mtimeMs) / (1000 * 60 * 60 * 24);
        if (ageDays > maxAgeDays) continue;
      }

      totalChunks += await this.indexFile(fullPath);
    }

    return totalChunks;
  }

  // --- Search ---

  /**
   * 한국어 조사/어미를 제거한 BM25 검색용 정규화 쿼리 생성.
   * LanceDB FTS는 공백 단위 토크나이징 → "destination-b에서" ≠ "destination-b" 미매치 방지.
   */
  _normalizeKoreanQuery(query) {
    // 명사 뒤에 오는 격조사/보조사만 제거 (공백 단위 BM25 토크나이저 보완)
    // 주의: 연결어미(고/며/나/아서/어서/므로/니까 등)는 제외 — "먹고" → "먹" 오탐 방지
    // 포함: 격조사(에서/에게/으로/를/이/가/의...) + 보조사(은/는/도/만/까지/부터...)
    // 복합조사(에서는/에서도 등)를 단순조사보다 먼저 나열해 최장 일치 우선 적용
    // 명확히 분리되는 장음절 조사만 처리 — 1-2자 조사(은/는/이/가/을/를/로 등)는
    // 동사 어미와 구분 불가("가는"→"가", "먹이"→"먹" 오탐)이므로 제외
    return query
      .replace(/([가-힣])(?:에게서|에서는|에서도|에서만|으로부터|로부터|한테서|에게|에서|으로부터|이랑|에는|에도|에만|한테|보다|처럼|만큼|마다|까지|부터|씩|랑)(?=\s|$)/g,
        '$1 ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /**
   * 하이브리드 검색: LanceDB FTS(BM25) + Dense(벡터) + 순수 JS BM25 → RRF 병합.
   *
   * @param {string} query    검색 쿼리
   * @param {number} limit    반환 결과 수 (기본 5) — 하위 호환 유지
   * @param {Object} opts     검색 옵션
   * @param {number}  [opts.topK]        limit 별칭 (limit보다 우선). 기본값: limit
   * @param {string}  [opts.domain]      도메인 필터: 'board'|'discord'|'rag'|'code'|null
   *                                     - 'discord' → discord-history 소스만
   *                                     - 'board'   → board 소스만
   *                                     - 'rag'     → .jarvis/rag 소스만
   *                                     - 'code'    → chunk_type이 code-* 인 청크만
   * @param {Date|string} [opts.since]   이 시각 이후 수정된 청크만 (modified_at 필터)
   * @param {boolean} [opts.useHybrid]   true(기본): Dense+BM25 RRF 병합 / false: 기존 FTS only
   * @param {number}  [opts.minScore]    RRF 최소 스코어 임계값 (기본 0.0, 실질적 컷오프 없음)
   * @param {string}  [opts.sourceFilter] 기존 하위 호환: 'episodic' → discord-history 우선
   * @param {boolean} [opts.useHyde]     HyDE: LLM으로 가상 답변 생성 후 임베딩 검색 (기본 false)
   * @param {object}  [opts.llmClient]   HyDE용 LLM 클라이언트 (Groq 등, chat() 메서드 필요)
   */
  async search(query, limit = 5, opts = {}) {
    if (!query.trim()) return [];

    // ── 옵션 파싱 ──────────────────────────────────────────────────────────────
    const {
      topK        = limit,          // topK가 있으면 limit보다 우선
      domain      = null,           // 도메인 필터 (신규)
      since       = null,           // 날짜 필터 (신규)
      useHybrid   = true,           // BM25+Dense RRF 병합 (신규, 기본 활성화)
      minScore    = 0.0,            // RRF 최소 스코어 (신규)
      sourceFilter = opts.sourceFilter, // 기존 하위 호환
      useHyde     = false,          // HyDE: LLM으로 가상 답변 생성 후 임베딩 검색
      llmClient   = null,           // HyDE용 LLM 클라이언트 (외부 주입)
    } = opts;
    const effectiveLimit = topK;

    // 한국어 조사 제거 전처리 (BM25 토크나이저 보완)
    const normalizedQuery = this._normalizeKoreanQuery(query);

    // ── 메타데이터 필터 조합 ────────────────────────────────────────────────────
    // domain 필터: 소스 경로 패턴 또는 chunk_type으로 판별
    let domainWhereClause = null;
    if (domain === 'discord') {
      domainWhereClause = "source LIKE '%discord-history%'";
    } else if (domain === 'board') {
      domainWhereClause = "source LIKE '%board%'";
    } else if (domain === 'rag') {
      // dual-pattern: 호환 심링크(~/.jarvis) 만료(2026-10-17) 후에도
      // 기존 인덱싱된 24,448개 문서가 검색되도록 옛/새 경로 둘 다 매칭. # ALLOW-DOTJARVIS
      domainWhereClause = "(source LIKE '%/.jarvis/rag%' OR source LIKE '%/jarvis/runtime/rag%')";
    } else if (domain === 'code') {
      domainWhereClause = "chunk_type LIKE 'code-%'";
    }

    // since 필터: modified_at (Unix ms) ≥ since 타임스탬프
    let sinceWhereClause = null;
    if (since != null) {
      const sinceMs = since instanceof Date ? since.getTime() : new Date(since).getTime();
      if (!isNaN(sinceMs)) {
        sinceWhereClause = `modified_at >= ${sinceMs}`;
      }
    }

    // sourceFilter: 'episodic' → discord-history 우선 (기존 하위 호환)
    const isEpisodic = sourceFilter === 'episodic';
    const episodicFilter = "source LIKE '%discord-history%'";

    // 모든 where 조건을 AND로 조합하는 헬퍼
    const _buildWhereFilter = (extra = null) => {
      const clauses = [];
      if (extra)             clauses.push(extra);
      if (domainWhereClause) clauses.push(domainWhereClause);
      if (sinceWhereClause)  clauses.push(sinceWhereClause);
      return clauses.length > 0 ? clauses.join(' AND ') : null;
    };

    // LanceDB query에 deleted/is_latest/expires_at + 추가 필터를 체이닝하는 헬퍼
    const _applyFilters = (q, extraWhere = null) => {
      q = this._withDeletedFilter(q);
      const where = _buildWhereFilter(extraWhere);
      return where ? q.where(where) : q;
    };

    // ── 1. LanceDB FTS (BM25 인덱스) ────────────────────────────────────────────
    // 기존 FTS 검색: LanceDB가 관리하는 인덱스 기반 → 빠름
    let ftsResults = [];
    try {
      const episodicExtra = isEpisodic ? episodicFilter : null;
      const [raw, normalized] = await Promise.allSettled([
        _applyFilters(
          this.table.query().fullTextSearch(query, { columns: ['text'] }),
          episodicExtra
        ).limit(effectiveLimit * 3).toArray(),
        normalizedQuery !== query
          ? _applyFilters(
              this.table.query().fullTextSearch(normalizedQuery, { columns: ['text'] }),
              episodicExtra
            ).limit(effectiveLimit * 3).toArray()
          : Promise.resolve([]),
      ]);
      const rawRes  = raw.status       === 'fulfilled' ? raw.value       : [];
      const normRes = normalized.status === 'fulfilled' ? normalized.value : [];
      const seen = new Set(rawRes.map(r => r.id));
      ftsResults = [...rawRes, ...normRes.filter(r => !seen.has(r.id))];

      // episodic 모드 부족 시 전체 fallback
      if (isEpisodic && ftsResults.length < effectiveLimit) {
        const [fallback] = await Promise.allSettled([
          _applyFilters(
            this.table.query().fullTextSearch(query, { columns: ['text'] })
          ).limit(effectiveLimit * 3).toArray(),
        ]);
        const fallbackRes = fallback.status === 'fulfilled' ? fallback.value : [];
        const seen2 = new Set(ftsResults.map(r => r.id));
        ftsResults = [...ftsResults, ...fallbackRes.filter(r => !seen2.has(r.id))];
      }
    } catch {
      // FTS 인덱스 미준비 또는 테이블 비어 있음 → 무시
    }

    // ── 2. Dense(벡터) 검색 ─────────────────────────────────────────────────────
    // HyDE 활성화 시: LLM으로 가상 답변을 생성하여 임베딩 쿼리 품질 향상
    const searchQuery = useHyde
      ? await generateHypotheticalDoc(query, llmClient)
      : query;

    let denseResults = [];
    try {
      const [queryVec] = await this.embed([searchQuery]);
      let vecQ = this._withDeletedFilter(this.table.search(queryVec)).limit(effectiveLimit * 3);
      const extraWhere = _buildWhereFilter(isEpisodic ? episodicFilter : null);
      if (extraWhere) vecQ = vecQ.where(extraWhere);
      denseResults = await vecQ.toArray();
      denseResults.sort((a, b) => (a._distance ?? 999) - (b._distance ?? 999));
    } catch {
      // 임베딩 모델 미준비 또는 오류 → Dense 없이 FTS만 사용
    }

    // ── 3. 순수 JS BM25 (useHybrid=true 시만 실행) ─────────────────────────────
    // LanceDB FTS + Dense 결과를 후보 풀로 삼아 BM25 스코어를 재계산.
    // 전체 DB 스캔 없이 후보 집합 내에서만 계산 → 성능 부담 없음.
    let bm25RankedResults = [];
    if (useHybrid && (ftsResults.length + denseResults.length) > 0) {
      // 후보 풀: FTS + Dense 합집합
      const candidateMap = new Map();
      for (const r of [...ftsResults, ...denseResults]) {
        if (!candidateMap.has(r.id)) candidateMap.set(r.id, r);
      }
      const candidates = [...candidateMap.values()];

      if (candidates.length > 0) {
        const tokenizedDocs = candidates.map(c => _bm25Tokenize(c.text || ''));
        const avgDocLen = tokenizedDocs.reduce((s, t) => s + t.length, 0) / tokenizedDocs.length;
        const idfMap = _buildIdfMap(tokenizedDocs);
        const queryTokens = _bm25Tokenize(query);

        bm25RankedResults = candidates
          .map((doc, i) => ({
            ...doc,
            _bm25Score: _bm25Score(queryTokens, tokenizedDocs[i], avgDocLen, idfMap),
          }))
          .sort((a, b) => b._bm25Score - a._bm25Score);
      }
    }

    // ── 4. 병합 전략 ────────────────────────────────────────────────────────────
    let results;
    if (useHybrid && bm25RankedResults.length > 0 && denseResults.length > 0) {
      // RRF 병합: Dense 랭킹 + 순수 BM25 랭킹 → id 순서 목록
      const rrfIds = _rrfMerge(denseResults, bm25RankedResults);

      // id → 실제 결과 객체 매핑
      const allById = new Map();
      for (const r of [...denseResults, ...bm25RankedResults, ...ftsResults]) {
        if (!allById.has(r.id)) allById.set(r.id, r);
      }

      // minScore 필터 적용 (RRF 스코어가 낮은 것 제거)
      // _rrfMerge는 순서만 반환하므로 스코어를 직접 재계산
      const rrfScores = new Map();
      const k = 60;
      for (const [i, doc] of denseResults.entries()) {
        const id = doc.id || doc.path;
        rrfScores.set(id, (rrfScores.get(id) || 0) + 1 / (k + i + 1));
      }
      for (const [i, doc] of bm25RankedResults.entries()) {
        const id = doc.id || doc.path;
        rrfScores.set(id, (rrfScores.get(id) || 0) + 1 / (k + i + 1));
      }

      results = rrfIds
        .filter(id => (rrfScores.get(id) || 0) >= minScore)
        .map(id => allById.get(id))
        .filter(Boolean);

      // RRF 결과에 없는 FTS 결과를 보조로 뒤에 추가
      const rrfIdSet = new Set(rrfIds);
      const ftsExtra = ftsResults.filter(r => !rrfIdSet.has(r.id));
      results = [...results, ...ftsExtra];
    } else if (useHybrid && bm25RankedResults.length > 0) {
      // Dense 실패 → FTS+BM25 재랭킹 결과만 사용
      results = bm25RankedResults;
    } else {
      // useHybrid=false (하위 호환): FTS 우선, Dense 보조
      const ftsIds = new Set(ftsResults.map(r => r.id));
      const vecOnly = denseResults.filter(r => !ftsIds.has(r.id));
      results = [...ftsResults, ...vecOnly];
    }

    // ── 5. GraphRAG 확장 ────────────────────────────────────────────────────────
    results = await this._graphExpand(query, results, effectiveLimit);

    // ── 6. Cross-encoder reranking (Jina API, 선택적) ──────────────────────────
    results = await this._rerank(query, results);

    const sliced = results.slice(0, effectiveLimit);

    // ── 7. Faithfulness 점수 ────────────────────────────────────────────────────
    const faithfulness = this._computeFaithfulness(query, sliced);

    return sliced.map((r) => ({
      text: r.text,
      source: r.source,
      headerPath: r.header_path,
      distance: r._distance,
      chunkIndex: r.chunk_index,
      importance: r.importance ?? 0.5,
      entities: r.entities ? (() => { try { return JSON.parse(r.entities); } catch { return []; } })() : [],
      topics: r.topics ? (() => { try { return JSON.parse(r.topics); } catch { return []; } })() : [],
      _faithfulness: faithfulness,
    }));
  }

  /**
   * Faithfulness 점수 계산 (0~1)
   * 쿼리 토큰 중 검색 결과 텍스트에 포함된 비율.
   * RAGAS Context Recall의 경량 근사치 — LLM 호출 없이 로컬 계산.
   * [2026-03-31] 신규 — logTelemetry에서 활용하여 RAG 품질 모니터링
   */
  _computeFaithfulness(query, results) {
    if (!results.length) return 0;
    // 쿼리를 2자 이상 토큰으로 분리 (한국어/영어 혼합 대응)
    const tokens = query
      .toLowerCase()
      .split(/[\s,\.\?!:;\"'()\[\]{}]+/)
      .filter(t => t.length >= 2);
    if (!tokens.length) return 1; // 토큰 없으면 측정 불가 → 1로 처리
    const combinedText = results.map(r => (r.text || '')).join(' ').toLowerCase();
    const matched = tokens.filter(t => combinedText.includes(t)).length;
    return Math.round((matched / tokens.length) * 100) / 100;
  }

  /**
   * GraphRAG 탐색: entity-graph.json에서 쿼리와 관련된 엔티티를 찾고
   * 해당 엔티티와 연결된 소스 문서를 추가 검색하여 결과를 보강.
   * entity-graph가 없거나 관련 엔티티가 없으면 원본 results 그대로 반환.
   */
  async _graphExpand(query, results, limit) {
    try {
      const { join } = await import('node:path');
      const { homedir } = await import('node:os');
      const { readFileSync } = await import('node:fs');
      const graphPath = ENTITY_GRAPH_PATH;
      let graph;
      try {
        graph = JSON.parse(readFileSync(graphPath, 'utf-8'));
      } catch {
        return results; // entity-graph 없으면 패스
      }
      if (!graph.nodes || Object.keys(graph.nodes).length === 0) return results;

      // 쿼리에서 graph.nodes 키와 매칭되는 엔티티 찾기 (단순 substring 매칭)
      const queryLower = query.toLowerCase();
      const matchedEntities = Object.keys(graph.nodes)
        .filter(e => queryLower.includes(e.toLowerCase()) || e.toLowerCase().includes(queryLower.slice(0, 4)))
        .slice(0, 5); // 최대 5개 엔티티

      if (matchedEntities.length === 0) return results;

      // 매칭된 엔티티와 연결된 관련 엔티티도 수집 (1-hop)
      const relatedEntities = new Set(matchedEntities);
      for (const e of matchedEntities) {
        const related = graph.nodes[e]?.topics ?? [];
        for (const r of related) relatedEntities.add(r);
        // edge에서 연결된 엔티티 수집
        for (const [edgeKey, edgeVal] of Object.entries(graph.edges ?? {})) {
          const [a, b] = edgeKey.split('|');
          if ((a === e || b === e) && edgeVal.weight >= 3) {
            relatedEntities.add(a === e ? b : a);
          }
        }
      }

      // 관련 엔티티의 소스 파일 수집
      const graphSources = new Set();
      for (const e of relatedEntities) {
        for (const src of graph.nodes[e]?.sources ?? []) graphSources.add(src);
      }

      if (graphSources.size === 0) return results;

      // 이미 있는 결과 소스 제외
      const existingSources = new Set(results.map(r => r.source));
      const newSources = [...graphSources].filter(s => !existingSources.has(s)).slice(0, 3);

      if (newSources.length === 0) return results;

      // 추가 소스에서 BM25 검색
      const extraResults = [];
      for (const src of newSources) {
        try {
          const srcRows = await this.table.query()
            .where(`source = '${src.replace(/'/g, "\\'")}'`)
            .limit(2)
            .toArray();
          extraResults.push(...srcRows);
        } catch { /* skip */ }
      }

      console.error(`[rag] GraphRAG: 엔티티 ${matchedEntities.join(',')} → ${extraResults.length}개 보강`);
      return [...results, ...extraResults];
    } catch {
      return results; // GraphRAG 실패는 비치명적
    }
  }

  async _rerank(query, results) {
    const apiKey = process.env.JINA_API_KEY;
    if (!apiKey || results.length === 0) return results;
    try {
      const resp = await fetch('https://api.jina.ai/v1/rerank', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: 'jina-reranker-v2-base-multilingual',
          query,
          documents: results.map(r => r.text),
          top_n: results.length
        })
      });
      if (!resp.ok) throw new Error(`Jina API ${resp.status}`);
      const data = await resp.json();
      const reranked = data.results
        .sort((a, b) => b.relevance_score - a.relevance_score)
        .map(r => results[r.index]);
      console.error('[rag] reranked with jina cross-encoder');
      return reranked;
    } catch (err) {
      console.error('[rag] rerank fallback:', err.message);
      return results;
    }
  }

  // --- Maintenance ---

  /**
   * Compact LanceDB storage and rebuild FTS index.
   * - Reclaims physical space from deleted rows (M2)
   * - Rebuilds FTS index so newly added data is searchable (M3)
   * Call from weekly cron via rag-compact.mjs.
   */
  async compact() {
    this._assertWritable();
    if (!this.table) throw new Error('Engine not initialized. Call init() first.');
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));

    // M3: FTS index rebuild FIRST — CreateIndex transaction must complete before
    // optimize() (Rewrite transaction) starts. Running them in the opposite order
    // causes "Retryable commit conflict: Rewrite preempted by CreateIndex".
    try {
      await this.table.createIndex('text', {
        config: lancedb.Index.fts(),
        replace: true,
      });
      console.log('[rag] compact: FTS index rebuilt');
    } catch (ftsErr) {
      console.warn(`[rag] compact: FTS rebuild failed (${ftsErr.message}), retrying without replace`);
      try {
        try { await this.table.dropIndex('text'); } catch { /* index may not exist */ }
        await this.table.createIndex('text', { config: lancedb.Index.fts() });
        console.log('[rag] compact: FTS index rebuilt (drop+create)');
      } catch (ftsErr2) {
        console.error(`[rag] compact: FTS rebuild failed: ${ftsErr2.message}`);
      }
    }

    // ⚠️ M1 (역사적 메모): table.delete()를 직접 호출하면 LanceDB 2.0.0 버그로 100%-deleted
    // fragment가 즉시 GC됨 → 동시 실행 중인 rag-index의 stale manifest 참조가 깨짐("Not found").
    // 단, rag-compact.mjs가 write lock(O_EXCL 원자적)을 획득한 상태에서 이 함수를 호출하므로
    // rag-index/rag-watch는 write lock을 얻을 수 없어 동시 실행이 불가능함.
    // 따라서 optimize() 완료 후 table.delete()는 안전 (M3 블록 참조).
    //
    // ❌ 잘못된 이전 설명: "optimize()의 Rewrite 트랜잭션이 deleted=true 행을 처리한다" — 틀림.
    // optimize()는 LanceDB deletion vector(실제 table.delete() 로 생성)만 처리하며,
    // deleted=true 컬럼 값(soft-delete)은 일반 boolean 컬럼이므로 전혀 인식하지 않음.
    // deleted=true 행은 반드시 명시적으로 table.delete()를 호출해야 정리됨 (M3 참조).

    // M2: Storage compaction — reclaim physical space from old fragments & manifest versions.
    // LanceDB labels optimize() conflicts as "Retryable" — honour that with backoff.
    let optimizeOk = false;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        const optStats = await this.table.optimize({ cleanupOlderThan: new Date(Date.now() - 14_400_000) }); // 4h 전 기준 — 2026-04-05 48h→4h 하향.
        // 이유: 매일 03:00 compact 기준, 전날 04:34 compact 파편은 22h 경과 → 48h 설정으로 미삭제 → 3일치 누적.
        // 4h: rag-index 최대 실행 3분 << 4h 버퍼 → 안전. 전날 파편(22h) > 4h → 즉시 정리.
        // 안전 근거:
        //   (1) rag-compact-safe.sh + rag-compact.mjs 이중 pgrep 체크로 rag-index 실행 중 compact 불가.
        //   (2) rag-index.mjs는 매 실행 시 refreshTable()로 최신 manifest 갱신 → stale 참조 없음.
        //   (3) REBUILD_SENTINEL 체크로 리빌드 중 compact 차단.
        // 과거 "Not found" 에러 원인: weekly 스케줄에서 48h 창 사용 → 7일 전 rebuild fragment가 orphan 판정 삭제됨.
        //   → 현재는 daily 스케줄이므로 48h 창 안전.
        console.log('[rag] compact: table.optimize() completed — fragments reclaimed');
        // ─── 진단 로깅 (2026-04-26 추가) ───
        // _versions/manifest 1,422개 누적 원인 진단용. cleanupOlderThan: Date 객체가 native binding에서
        // 정상 작동하는지, oldVersionsRemoved>0이 보고되는지 다음 03:00 compact에서 즉시 확인.
        try {
          const pruneVer  = optStats?.prune?.oldVersionsRemoved ?? 'n/a';
          const pruneByte = optStats?.prune?.bytesRemoved ?? 'n/a';
          const fragRem   = optStats?.compaction?.fragmentsRemoved ?? 'n/a';
          const fragAdd   = optStats?.compaction?.fragmentsAdded ?? 'n/a';
          console.log(`[rag] compact stats: prune=${pruneVer} versions / ${pruneByte} bytes · compaction=−${fragRem}/+${fragAdd} fragments`);
        } catch (_) { /* SDK 반환 구조 변경 시 silent — 진단 로깅이 메인 로직 깨뜨리지 않음 */ }
        optimizeOk = true;
        break;
      } catch (optErr) {
        const retryable = optErr.message.includes('Retryable');
        if (attempt < 3 && retryable) {
          console.warn(`[rag] compact: optimize attempt ${attempt} failed (retryable), retrying in ${attempt * 3}s…`);
          await sleep(attempt * 3000);
        } else {
          console.error(`[rag] compact: optimize failed after ${attempt} attempt(s): ${optErr.message}`);
        }
      }
    }
    if (!optimizeOk) {
      console.warn('[rag] compact: optimize skipped — fragments will accumulate until next run');
    }

    // M3: Soft-deleted row purge — table.delete('deleted = true')
    // optimize()는 deleted=true 컬럼 행을 제거하지 않음. 명시적으로 삭제해야 함.
    // 안전 근거: rag-compact.mjs가 O_EXCL write lock을 획득한 채 이 함수를 호출
    //   → rag-index/rag-watch는 동일 lock을 얻지 못해 LanceDB 쓰기 불가
    //   → GC 버그(동시 fragment 참조 소멸) 발생 조건 없음.
    // 단, 검색(read) 쿼리는 write lock과 무관하므로 table.delete() 중 In-flight 쿼리가
    // "Not found" 오류를 받을 수 있음. 해당 오류는 Discord 응답에서 캐치되어 non-fatal.
    // optimize() 성공 여부와 무관하게 독립 실행 — 누적된 soft-delete 행 정리.
    try {
      const deletedCount = await this.table.countRows('deleted = true');
      if (deletedCount > 0) {
        await this.table.delete('deleted = true');
        // delete() 이후 manifest가 변경되므로 table 참조 갱신
        await this.refreshTable().catch(e =>
          console.warn(`[rag] compact: refreshTable after purge failed: ${e.message?.slice(0, 80)}`)
        );
        console.log(`[rag] compact: purged ${deletedCount} soft-deleted rows`);
      } else {
        console.log('[rag] compact: no soft-deleted rows to purge');
      }
    } catch (purgeErr) {
      console.error(`[rag] compact: soft-delete purge failed: ${purgeErr.message}`);
    }
  }

  /**
   * DB 커넥션 해제 — 프로세스 종료 전 또는 장기 유휴 시 호출.
   * LanceDB는 명시적 close()가 없으므로 참조를 null로 해제하여 GC 유도.
   */
  close() {
    this.table = null;
    this.db = null;
  }

  async deleteBySource(source) {
    this._assertWritable();
    try {
      // Validate source is a safe filesystem path before query
      if (typeof source !== 'string' || source.length === 0) {
        throw new Error(`deleteBySource: invalid source path`);
      }
      // Escape single quotes and backticks for LanceDB filter
      const safeSource = source.replace(/\\/g, '\\\\').replace(/'/g, "\\'");

      // table.update()로 deleted 플래그만 업데이트 — 벡터 재직렬화 없이 안전
      // mergeInsert는 레코드 전체(벡터 포함)를 Arrow로 재직렬화하면서
      // vector.isValid 메타데이터 충돌이 발생하므로 사용하지 않음.
      let attempt = 0;
      while (true) {
        try {
          await this.table.update({
            where: `source = '${safeSource}'`,
            values: { deleted: true, deleted_at: Date.now() },
          });
          break; // 성공
        } catch (delErr) {
          attempt++;
          // 서킷브레이커: deletion manifest 파일 부재는 refreshTable로 복구 불가
          // (삭제할 청크 자체가 없거나, 테이블이 격리·리빌드된 상태). 즉시 noop.
          const isMissingDeletionFile = delErr.message?.includes('Not found:') &&
            delErr.message?.includes('_deletions/') &&
            delErr.message?.includes('.bi');
          if (isMissingDeletionFile) {
            console.warn(`[rag-engine] deleteBySource circuit-break: missing deletion file for ${source.split('/').pop()} — noop`);
            return;
          }
          const isStaleManifest = delErr.message?.includes('Not found:') &&
            delErr.message?.includes('.lance');
          if (isStaleManifest && attempt < 3) {
            // stale manifest — refreshTable() 후 재시도
            console.warn(`[rag-engine] deleteBySource stale manifest (attempt ${attempt}), refreshing table…`);
            await new Promise(r => setTimeout(r, attempt * 500));
            const refreshOk = await this.refreshTable();
            if (!refreshOk) {
              console.error(`[rag-engine] deleteBySource(${source.split('/').pop()}): refreshTable failed, aborting`);
              return; // table 자체 없음 — 삭제 불가, 조용히 종료
            }
            continue;
          }
          console.error(`[rag-engine] deleteBySource(${source.split('/').pop()}) soft-delete failed after ${attempt} attempt(s): ${delErr.message?.slice(0, 120)}`);
          return;
        }
      }
    } catch (outerErr) {
      // validation 에러 등 outer try-catch
      console.error(`[rag-engine] deleteBySource(${source}) error: ${outerErr.message?.slice(0, 120)}`);
    }
  }

  async getStats() {
    if (!this.table) return { totalChunks: 0, totalSources: 0 };
    // totalChunks는 독립적으로 획득 — totalSources 실패가 0으로 덮어쓰지 않도록 분리
    // deleted=true 레코드 제외하고 카운트 (컬럼 지원 시에만)
    let totalChunks = 0;
    for (let _statsAttempt = 1; _statsAttempt <= 2; _statsAttempt++) {
      try {
        if (this._supportsDeleted) {
          const activeRows = await this._withDeletedFilter(this.table.query()).toArray();
          totalChunks = activeRows.length;
        } else {
          totalChunks = await this.table.countRows();
        }
        break; // 성공
      } catch (e) {
        const isStale = e.message?.includes('Not found:') && e.message?.includes('.lance');
        if (isStale && _statsAttempt === 1) {
          // stale manifest → refreshTable() 후 1회 재시도
          // 이 실패를 0으로 해석하면 rag-index가 false fresh rebuild를 트리거함 (치명적)
          console.warn(`[rag] getStats: stale manifest detected, refreshing table before retry…`);
          await this.refreshTable();
          continue;
        }
        // 재시도 후에도 stale manifest 실패: 빈 DB가 아닌 손상된 DB
        // _staleManifest: true → rag-index가 false state 리셋을 건너뜀
        if (isStale) {
          console.error(`[rag] getStats: stale manifest persists after refresh — signaling _staleManifest`);
          return { totalChunks: 0, totalSources: 0, _staleManifest: true };
        }
        console.warn(`[rag] getStats: countRows failed (${e.message.slice(0, 80)})`);
        return { totalChunks: 0, totalSources: 0 };
      }
    }
    let totalSources = 0;
    try {
      // LanceDB 0.26.x: db.query() SQL 미지원 → table.query() 사용
      // deleted=true 레코드 제외하고 소스 카운트 (컬럼 지원 시에만)
      const sample = await this._withDeletedFilter(this.table.query())
        .select(['source']).limit(10000).toArray();
      totalSources = new Set(sample.map((r) => r.source)).size;
    } catch {
      // _deletions 파일 손상 등 query 실패 시 totalSources만 0으로 처리 (totalChunks 유지)
      totalSources = 0;
    }
    // deleted 행 수 및 비율 추적 — 폭증 조기 감지용
    let deletedChunks = 0;
    if (this._supportsDeleted) {
      try {
        deletedChunks = await this.table.countRows('deleted = true');
      } catch { /* non-critical */ }
    }
    const physicalChunks = totalChunks + deletedChunks;
    const deletedRatio = physicalChunks > 0 ? deletedChunks / physicalChunks : 0;

    return { totalChunks, totalSources, deletedChunks, deletedRatio };
  }
}

// --- Markdown Chunker ---

export function splitMarkdown(content) {
  const chunks = [];
  const lines = content.split('\n');
  let currentChunk = [];
  let currentHeaders = [];

  function flushChunk() {
    if (currentChunk.length === 0) return;
    const text = currentChunk.join('\n').trim();
    if (text.length < 30) return; // Skip tiny chunks
    chunks.push({
      text,
      headerPath: currentHeaders.filter(Boolean).join(' > '),
      index: chunks.length,
    });
    // Keep overlap (last 20% of lines)
    const overlapStart = Math.floor(currentChunk.length * (1 - CHUNK_OVERLAP_LINES));
    currentChunk = currentChunk.slice(overlapStart);
  }

  let inCodeBlock = false;

  for (const line of lines) {
    // Track code fences
    if (line.startsWith('```')) {
      inCodeBlock = !inCodeBlock;
      currentChunk.push(line);
      continue;
    }

    // Don't split inside code blocks
    if (inCodeBlock) {
      currentChunk.push(line);
      // Force split if chunk is too large even inside code block
      if (currentChunk.join('\n').length > CHUNK_MAX_CHARS * 1.5) {
        flushChunk();
      }
      continue;
    }

    const headerMatch = line.match(/^(#{1,6})\s+(.+)/);

    if (headerMatch) {
      // Flush current chunk before starting new section
      flushChunk();
      currentChunk = [];

      const level = headerMatch[1].length;
      // Update header hierarchy
      currentHeaders = currentHeaders.slice(0, level - 1);
      currentHeaders[level - 1] = headerMatch[2].trim();
    }

    currentChunk.push(line);

    // Split if chunk exceeds max size
    if (currentChunk.join('\n').length > CHUNK_MAX_CHARS) {
      flushChunk();
    }
  }

  // Flush remaining
  flushChunk();

  return chunks;
}

/**
 * splitCode — 코드 파일용 청킹 함수
 *
 * 전략: 언어별 최상위 선언(함수/클래스/export) 경계에서 청크를 나눈다.
 * CHUNK_MAX_CHARS 초과 시 강제 분할. 경계 인식 실패 시 splitMarkdown() 폴백.
 *
 * @param {string} content  파일 전체 내용
 * @param {string} ext      파일 확장자 (예: '.ts', '.py', '.sh')
 * @returns {{ text: string, headerPath: string, index: number }[]}
 */
export function splitCode(content, ext) {
  const lang = CODE_EXT_LANG[ext] || 'default';

  // ── 언어별 최상위 선언 경계 패턴 ──
  // 조건: 라인 시작(들여쓰기 없음 or 최소) + 선언 키워드
  const BOUNDARY = {
    js: /^(?:export\s+(?:default\s+)?(?:async\s+)?(?:function|class)|(?:async\s+)?function\s+\w|class\s+\w|const\s+\w+\s*=\s*(?:async\s+)?(?:function|\())/,
    ts: /^(?:export\s+(?:default\s+)?(?:async\s+)?(?:function|class|abstract\s+class)|(?:async\s+)?function\s+\w|class\s+\w|interface\s+\w|type\s+\w+\s*=|const\s+\w+\s*=\s*(?:async\s+)?(?:function|\())/,
    py: /^(?:(?:async\s+)?def\s+\w|class\s+\w)/,
    sh: /^(?:\w[\w-]*\s*\(\)|function\s+\w)/,
    java: /^(?:(?:public|private|protected|static|final|abstract|synchronized)\s+)*(?:class|interface|enum|(?:void|[\w<>\[\]]+)\s+\w+\s*\()/,
    go: /^func\s+(?:\([^)]+\)\s+)?\w/,
    rs: /^(?:pub\s+(?:async\s+)?fn|(?:async\s+)?fn|pub\s+struct|struct|pub\s+enum|enum|pub\s+impl|impl|pub\s+trait|trait)\s+\w/,
    default: /^(?:(?:async\s+)?function\s+\w|class\s+\w|def\s+\w)/,
  };

  const pattern = BOUNDARY[lang] || BOUNDARY.default;
  const lines   = content.split('\n');
  const chunks  = [];
  let current   = [];
  let header    = '';

  function flush() {
    if (current.length === 0) return;
    const text = current.join('\n').trim();
    if (text.length < 30) return;
    chunks.push({ text, headerPath: header, index: chunks.length });
    // overlap: 마지막 20% 라인 재사용
    const overlapStart = Math.floor(current.length * (1 - CHUNK_OVERLAP_LINES));
    current = current.slice(overlapStart);
  }

  for (const line of lines) {
    const trimmed = line.trimStart();
    // 현재 청크가 충분히 클 때만 경계로 인정 (단독 선언 1줄 청크 방지)
    if (pattern.test(trimmed) && current.join('\n').length > 100) {
      flush();
      header = trimmed.slice(0, 80).replace(/[{(].*$/, '').trim();
    }
    current.push(line);
    if (current.join('\n').length > CHUNK_MAX_CHARS) {
      flush();
    }
  }
  flush();

  // 청크가 너무 적으면 마크다운 폴백 (코드 경계 인식 실패)
  return chunks.length >= 2 ? chunks : splitMarkdown(content);
}
