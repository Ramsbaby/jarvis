/**
 * RAG Engine - LanceDB BM25 + OpenAI Embeddings
 *
 * Hybrid search: BM25 full-text (primary, free, local) + vector similarity (optional enrichment).
 * OpenAI embeddings are a supplement — BM25 is always the backbone.
 * Storage: ~/.jarvis/rag/lancedb/ (local embedded, no server needed)
 */

import * as lancedb from '@lancedb/lancedb';
import * as arrow from 'apache-arrow';
import OpenAI from 'openai';
import { readFile, readdir, stat, readFile as readFileAsync } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';
import { appendFileSync, mkdirSync, rmdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';

const EMBEDDING_MODEL = 'text-embedding-3-small';
const EMBEDDING_DIM = 1536;
const CHUNK_MAX_CHARS = 2000; // ~512 tokens
const CHUNK_OVERLAP_LINES = 0.2; // 20% overlap
const TABLE_NAME = 'documents';

// --- Per-file cross-process lock (mkdir-based, atomic on POSIX) ---

const RAG_LOCK_DIR = join(process.env.BOT_HOME || join(homedir(), '.jarvis'), 'state', 'rag-locks');
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

export class RAGEngine {
  constructor(dbPath) {
    this.dbPath = dbPath || join(process.env.BOT_HOME || join(homedir(), '.jarvis'), 'rag', 'lancedb');
    this.db = null;
    this.table = null;
    try {
      this.openai = new OpenAI();
    } catch {
      // API key not available (e.g., cron environment) — BM25-only mode
      this.openai = null;
    }
    this._indexLocks = new Map(); // filePath → Promise (in-memory per-file lock)
  }

  async init() {
    this.db = await lancedb.connect(this.dbPath);

    try {
      this.table = await this.db.openTable(TABLE_NAME);
    } catch {
      // Create table with initial schema (includes enrichment columns with defaults)
      this.table = await this.db.createTable(TABLE_NAME, [
        {
          id: '__init__',
          text: '',
          vector: new Array(EMBEDDING_DIM).fill(0),
          source: '',
          chunk_index: 0,
          header_path: '',
          modified_at: 0,
          importance: 0.5,
          entities: '[]',
          topics: '[]',
        },
      ]);
      // Remove the init row
      await this.table.delete("id = '__init__'");
    }

    // Create FTS index for hybrid search (idempotent — errors if exists)
    try {
      await this.table.createIndex('text', { config: lancedb.Index.fts() });
    } catch {
      // Index already exists
    }
  }

  // --- Enrichment ---

  /**
   * LLM 기반 문서 분석: 중요도(importance), 엔티티(entities), 토픽(topics) 추출.
   * ENABLE_RAG_ENRICHMENT=1 환경변수가 설정된 경우에만 실제 API 호출.
   * 실패 시 항상 기본값 반환 (절대 throw 안 함).
   */
  async enrichDocument(text) {
    const DEFAULT = { importance: 0.5, entities: [], topics: [] };

    if (process.env.ENABLE_RAG_ENRICHMENT !== '1') return DEFAULT;
    if (!this.openai) return DEFAULT;

    const truncated = text.slice(0, 2000);
    try {
      const response = await this.openai.chat.completions.create(
        {
          model: 'gpt-4o-mini',
          messages: [
            {
              role: 'system',
              content: 'You are a document analyzer. Respond only with valid JSON.',
            },
            {
              role: 'user',
              content: `Analyze this text and return JSON: {"importance": 0.0-1.0, "entities": ["list of key names/orgs/concepts"], "topics": ["2-4 topic tags"]}\n\nText: ${truncated}`,
            },
          ],
          temperature: 0,
          max_tokens: 200,
        },
        { signal: AbortSignal.timeout(10_000) },
      );

      const raw = response.choices[0]?.message?.content?.trim() ?? '';
      // JSON 블록 추출 (마크다운 코드 펜스 대응)
      const jsonStr = raw.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
      const parsed = JSON.parse(jsonStr);

      return {
        importance: typeof parsed.importance === 'number'
          ? Math.min(1, Math.max(0, parsed.importance))
          : DEFAULT.importance,
        entities: Array.isArray(parsed.entities) ? parsed.entities : DEFAULT.entities,
        topics: Array.isArray(parsed.topics) ? parsed.topics : DEFAULT.topics,
      };
    } catch {
      // API 오류, 파싱 오류, 타임아웃 — 기본값으로 폴백
      return DEFAULT;
    }
  }

  // --- Embedding ---

  async embed(texts) {
    if (!this.openai) throw new Error('OpenAI client not available (no API key)');
    const MAX_RETRIES = 2;
    let lastErr;
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        const response = await this.openai.embeddings.create(
          { model: EMBEDDING_MODEL, input: texts },
          { signal: AbortSignal.timeout(30_000) },
        );
        return response.data.map((d) => Array.from(d.embedding));
      } catch (err) {
        lastErr = err;
        const msg = err.message || '';
        const status = err.status || 0;
        // 결제/계정 비활성 또는 인증 실패 시 즉시 알림 (재시도 없이 throw)
        if (status === 401 || status === 403 || msg.includes('account not active')) {
          await this._alertEmbeddingFailure(status, msg);
          throw err;
        }
        // Rate limit: 1분 대기 후 1회 재시도
        if (status === 429 && attempt < MAX_RETRIES) {
          await this._alertEmbeddingFailure(status, msg);
          await new Promise(r => setTimeout(r, 60_000));
          continue;
        }
        // Timeout: 3초 대기 후 1회 재시도
        if ((msg.includes('timed out') || msg.includes('timeout') || msg.includes('AbortError')) && attempt < MAX_RETRIES) {
          await new Promise(r => setTimeout(r, 3_000));
          continue;
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

    const alertText = `🚨 RAG Embedding API 장애\nHTTP ${status}: ${message.slice(0, 200)}\n즉시 결제/API 키 확인 필요`;
    const botHome = process.env.BOT_HOME || join(homedir(), '.jarvis');

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

  async indexFile(filePath) {
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

      const chunks = splitMarkdown(content);
      if (chunks.length === 0) return 0;

      // Delete old chunks from this source
      await this.deleteBySource(filePath);

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
      }

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
      }));

      await this.table.add(records);
      return records.length;
    } finally {
      _releaseFileLock(filePath);
      this._indexLocks.delete(filePath);
      inMemResolve();
    }
  }

  async indexDirectory(dirPath, opts = {}) {
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
   * LanceDB FTS는 공백 단위 토크나이징 → "삿포로에서" ≠ "삿포로" 미매치 방지.
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

  async search(query, limit = 5) {
    if (!query.trim()) return [];

    // 한국어 조사 제거 전처리 (BM25 토크나이저 보완)
    const normalizedQuery = this._normalizeKoreanQuery(query);

    // 1. BM25 FTS — primary search, always runs, free (local LanceDB index)
    let bm25Results = [];
    try {
      // 원본 쿼리와 정규화 쿼리 모두 시도, 더 많은 결과 확보
      const [raw, normalized] = await Promise.allSettled([
        this.table.query().fullTextSearch(query, { columns: ['text'] }).limit(limit * 2).toArray(),
        normalizedQuery !== query
          ? this.table.query().fullTextSearch(normalizedQuery, { columns: ['text'] }).limit(limit * 2).toArray()
          : Promise.resolve([]),
      ]);
      const rawRes = raw.status === 'fulfilled' ? raw.value : [];
      const normRes = normalized.status === 'fulfilled' ? normalized.value : [];
      // 중복 제거 후 합산 (id 기준)
      const seen = new Set(rawRes.map(r => r.id));
      bm25Results = [...rawRes, ...normRes.filter(r => !seen.has(r.id))];
    } catch {
      // FTS index not ready or table empty
    }

    // 2. Vector search — optional enrichment only (costs OpenAI tokens, may be unavailable)
    const bm25Ids = new Set(bm25Results.map((r) => r.id));
    let vecOnlyResults = [];
    try {
      const [queryVec] = await this.embed([query]);
      const vecResults = await this.table
        .search(queryVec)
        .limit(limit * 2)
        .toArray();
      // Only keep results not already found by BM25 (avoid duplicates)
      vecOnlyResults = vecResults.filter((r) => !bm25Ids.has(r.id));
      vecOnlyResults.sort((a, b) => (a._distance ?? 999) - (b._distance ?? 999));
    } catch {
      // OpenAI unavailable or budget exhausted — BM25 results are sufficient
    }

    // 3. Merge: BM25 results first (by relevance order), then vector-only supplements
    let results = [...bm25Results, ...vecOnlyResults];

    // 4. Cross-encoder reranking via Jina API (if available)
    results = await this._rerank(query, results);

    return results.slice(0, limit).map((r) => ({
      text: r.text,
      source: r.source,
      headerPath: r.header_path,
      distance: r._distance,
      chunkIndex: r.chunk_index,
    }));
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
    if (!this.table) throw new Error('Engine not initialized. Call init() first.');

    // M2: LanceDB storage compaction — reclaim deleted row space
    try {
      // cleanupOlderThan: Date(0) = 모든 구버전 파일 즉시 제거 (올바른 LanceDB 0.26.x API)
      await this.table.optimize({ cleanupOlderThan: new Date(0) });
      console.log('[rag] compact: table.optimize() completed — deleted rows reclaimed');
    } catch (optErr) {
      console.warn(`[rag] compact: optimize failed (${optErr.message}), trying cleanup`);
      // Fallback: try cleanup separately if optimize signature differs
      try {
        await this.table.optimize();
        console.log('[rag] compact: table.optimize() (no args) completed');
      } catch (optErr2) {
        console.error(`[rag] compact: optimize fallback also failed: ${optErr2.message}`);
      }
    }

    // M3: Rebuild FTS index for newly added data
    try {
      // LanceDB createIndex with replace=true rebuilds the index
      await this.table.createIndex('text', {
        config: lancedb.Index.fts(),
        replace: true,
      });
      console.log('[rag] compact: FTS index rebuilt');
    } catch (ftsErr) {
      console.warn(`[rag] compact: FTS rebuild failed (${ftsErr.message}), retrying without replace`);
      // Some LanceDB versions may not support replace — drop and recreate
      try {
        try { await this.table.dropIndex('text'); } catch { /* index may not exist */ }
        await this.table.createIndex('text', { config: lancedb.Index.fts() });
        console.log('[rag] compact: FTS index rebuilt (drop+create)');
      } catch (ftsErr2) {
        console.error(`[rag] compact: FTS rebuild failed: ${ftsErr2.message}`);
      }
    }
  }

  async deleteBySource(source) {
    try {
      // Validate source is a safe filesystem path before query
      if (typeof source !== 'string' || source.length === 0) {
        throw new Error(`deleteBySource: invalid source path`);
      }
      // Escape single quotes and backticks for LanceDB filter
      const safeSource = source.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
      await this.table.delete(`source = '${safeSource}'`);
    } catch {
      // Table might be empty
    }
  }

  async getStats() {
    if (!this.table) return { totalChunks: 0, totalSources: 0 };
    try {
      const totalChunks = await this.table.countRows();
      // Arrow 버퍼 누수 방지: 전체 row 로딩 대신 SQL aggregate 사용
      let totalSources = 0;
      try {
        const result = await this.db.query(
          `SELECT COUNT(DISTINCT source) as cnt FROM ${TABLE_NAME}`
        );
        const rows = await result.toArray();
        totalSources = Number(rows[0]?.cnt ?? 0);
      } catch {
        // LanceDB 버전에 따라 SQL 미지원 시 fallback — 단, 청크 수 제한으로 메모리 절약
        const sample = await this.table.query().select(['source']).limit(10000).toArray();
        totalSources = new Set(sample.map((r) => r.source)).size;
      }
      return { totalChunks, totalSources };
    } catch {
      return { totalChunks: 0, totalSources: 0 };
    }
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
