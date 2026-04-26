#!/usr/bin/env node
/**
 * mistake-extractor.mjs — 오답노트 자동 추출기 (Compound Engineering Phase 2)
 *
 * 세션 요약 파일에서 오너의 지적/정정 패턴을 Haiku로 감지하여
 * ~/jarvis/runtime/wiki/meta/learned-mistakes.md 상단에 4필드 섹션으로 append.
 *
 * 크론 스케줄: 매일 03:15 KST (session-summarizer 03:00 이후 / wiki-ingest 03:30 이전)
 *
 * 흐름:
 *   1. session-summaries/*.md 중 mistakeExtractedUntil 이후 수정된 파일 수집
 *   2. Haiku 프롬프트로 JSON 배열 추출 [{pattern, actual, evidence, correction}]
 *   3. 중복 감지(기존 섹션 제목과 문자열 유사도 65% 이상 skip)
 *   4. 4필드 섹션 상단 삽입 + frontmatter last_updated 갱신
 *   5. state 갱신 + Discord 알림(동일한 출력 형식)
 *
 * CLI:
 *   node mistake-extractor.mjs           # 실 추출
 *   node mistake-extractor.mjs --dry-run # 추출 후보만 출력, 파일 쓰기 없음
 *
 * Log: ~/jarvis/runtime/logs/mistake-extractor.log
 */

import {
  readFileSync, writeFileSync, existsSync, readdirSync,
  statSync, mkdirSync, appendFileSync, renameSync,
  openSync, closeSync, unlinkSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

// ── 설정 ─────────────────────────────────────────────────────────────────────
const HOME          = homedir();
const BOT_HOME      = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');
const LOG_FILE      = join(BOT_HOME, 'logs', 'mistake-extractor.log');
const SUMMARIES_DIR = join(BOT_HOME, 'state', 'session-summaries');
const MISTAKES_FILE = join(BOT_HOME, 'wiki', 'meta', 'learned-mistakes.md');
const STATE_FILE    = join(BOT_HOME, 'state', 'mistake-extractor-state.json');

const CLAUDE_BIN       = process.env.CLAUDE_BINARY || join(HOME, '.local/bin/claude');
const MAX_FILES_PER_RUN = 5;     // 세션 파일 상한
const MAX_MISTAKES_PER_RUN = 5;  // 추출 건 상한
const MIN_FILE_BYTES   = 300;    // 이보다 작은 요약은 스킵
const DUPLICATE_THRESHOLD = 0.4; // 기존 패턴과 유사도 이상이면 skip (Verify P3 지적에 따라 0.65→0.4 하향)

const DRY_RUN = process.argv.includes('--dry-run');
// Stop 훅 전용 단일 파일 모드: --file <path> 로 특정 세션 .md 1건만 처리하고 state 갱신 skip
// (배치 흐름 state.mistakeExtractedUntil과 무관하게 호출 가능 — 세션 종료 직후 실시간 등재용)
const FILE_ARG_IDX = process.argv.indexOf('--file');
const SINGLE_FILE = FILE_ARG_IDX >= 0 && process.argv[FILE_ARG_IDX + 1]
  ? process.argv[FILE_ARG_IDX + 1]
  : null;

// 2026-04-22 추가: LLM 우회 폴백 모드
// 자기정정 신호가 명확하여 4필드를 호출자가 직접 구성한 경우, Haiku 호출 없이 즉시 등재.
// circuit OPEN 상태에서도 동작 (오답노트 자동 파이프라인 마비 시에도 핵심 실수는 누락되지 않도록).
// 사용: echo '[{"pattern":"...","actual":"...","evidence":"...","correction":"..."}]' | node mistake-extractor.mjs --direct-fact
const DIRECT_FACT_MODE = process.argv.includes('--direct-fact');

// ── 로거 (KST) ───────────────────────────────────────────────────────────────
function kstNow() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
}
function kstISO() {
  // 2026-04-20T18:35:00+09:00 형식
  const d = new Date(Date.now() + 9 * 3600_000);
  return d.toISOString().replace('Z', '+09:00');
}
function todayKST() {
  return kstNow().slice(0, 10);
}
function log(msg) {
  const line = `[${kstNow()}] mistake-extractor: ${msg}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    appendFileSync(LOG_FILE, line);
  } catch { /* best-effort */ }
  process.stderr.write(line);
}

// ── LLM 호출 (Claude CLI spawn) ──────────────────────────────────────────────
function callClaude(prompt) {
  const result = spawnSync(CLAUDE_BIN, [
    '--model', 'claude-haiku-4-5-20251001',
    '--max-turns', '3',
    '--tools', '',
    '-p', '-',
  ], {
    input: prompt,
    timeout: 90_000,
    maxBuffer: 1024 * 1024,
    encoding: 'utf-8',
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`claude exit ${result.status}: ${(result.stderr || '').slice(0, 300)}`);
  }
  return (result.stdout || '').trim();
}

// ── 원자적 파일 쓰기 ──────────────────────────────────────────────────────────
function atomicWrite(filePath, content) {
  const tmp = filePath + '.tmp.' + process.pid;
  writeFileSync(tmp, content, 'utf-8');
  renameSync(tmp, filePath);
}

// ── lockfile 기반 상호 배제 (Stop 훅 + 배치 동시 실행 경합 방지) ─────────────
// read-modify-write 시퀀스를 직렬화. stale lock(60초+)은 강제 해제.
function withLock(lockPath, fn) {
  const MAX_WAIT_MS  = 10_000;
  const STALE_MS     = 60_000;
  const POLL_MS      = 200;
  const start = Date.now();
  let fd = null;
  while (Date.now() - start < MAX_WAIT_MS) {
    try {
      fd = openSync(lockPath, 'wx');
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // stale 판정
      try {
        const st = statSync(lockPath);
        if (Date.now() - st.mtimeMs > STALE_MS) {
          log(`stale lock 제거: ${lockPath} (age ${Math.round((Date.now()-st.mtimeMs)/1000)}s)`);
          try { unlinkSync(lockPath); } catch {}
          continue;
        }
      } catch { /* 이미 사라짐 */ }
      // 짧은 busy-wait (CLI 스크립트라 허용)
      const until = Date.now() + POLL_MS;
      while (Date.now() < until) { /* wait */ }
    }
  }
  if (fd === null) {
    throw new Error(`lock acquire timeout (${MAX_WAIT_MS}ms): ${lockPath}`);
  }
  try {
    return fn();
  } finally {
    try { closeSync(fd); } catch {}
    try { unlinkSync(lockPath); } catch {}
  }
}

// ── 예산 강제 차단 (Verify 4회차 P0-2 — max_budget_usd 메타필드만은 무의미 해소) ──
// 오늘 누적 cost_usd >= BUDGET_DAILY_USD 면 callClaude 호출 자체 차단.
// 환경변수 MISTAKE_EXTRACTOR_BUDGET 로 override.
// 2026-04-26 상향: 0.10 → 0.50 (SINGLE_FILE 트리거가 자주 호출돼 어제·오늘 모두 16:22 이전 차단됨)
// Haiku-4.5 기준 일 50건+ 처리 가능 = 학습 흐름 정상화. env MISTAKE_EXTRACTOR_BUDGET로 추가 override 가능.
const BUDGET_DAILY_USD = Number(process.env.MISTAKE_EXTRACTOR_BUDGET || 0.50);
function budgetCheck() {
  try {
    const ledgerFile = join(homedir(), 'jarvis/runtime/state/token-ledger.jsonl');
    if (!existsSync(ledgerFile)) return { allow: true, today: 0 };
    const today = kstNow().slice(0, 10); // YYYY-MM-DD (KST)
    const raw = readFileSync(ledgerFile, 'utf-8');
    let totalCost = 0;
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      try {
        const o = JSON.parse(line);
        if (o.task === 'mistake-extractor' && o.ts && o.ts.startsWith(today)) {
          totalCost += Number(o.cost_usd || 0);
        }
      } catch { /* malformed line ignore */ }
    }
    if (totalCost >= BUDGET_DAILY_USD) {
      return {
        allow: false,
        reason: `오늘 누적 $${totalCost.toFixed(5)} ≥ 예산 $${BUDGET_DAILY_USD.toFixed(2)} — 내일 00:00 KST 자동 리셋`,
        today: totalCost,
      };
    }
    return { allow: true, today: totalCost };
  } catch (e) {
    log(`budget check 실패 (허용): ${e.message}`);
    return { allow: true, today: 0 };
  }
}

// ── 서킷브레이커 (Haiku 연속 실패 3회 → 단계적 백오프) ───────────────────────
// 비용 폭주 방지 + 일시 ETIMEDOUT 으로 24h 마비 방지.
// 2026-04-22 오답노트 등재: 단일 24h 쿨다운으로 자동 파이프라인이 24시간 멈춘 사고
// → 백오프를 5min → 30min → 2h → 24h 4단계로 변경. 일시적 timeout 은 5분 후 회복 가능.
// state: closed(정상) | open(차단) | half-open(쿨다운 후 1회 시도 허용 — 자동)
const CIRCUIT_FILE = join(homedir(), 'jarvis/runtime/state/mistake-extractor-circuit.json');
const CIRCUIT_FAIL_THRESHOLD = 3;
// 실패 횟수별 쿨다운(ms) — 1·2회는 즉시 재시도, 3회=5min, 4회=30min, 5회=2h, 6회+=24h
const CIRCUIT_BACKOFF_MS = [
  0,                         // fail 0 (placeholder)
  0,                         // fail 1 — 즉시 재시도
  0,                         // fail 2 — 즉시 재시도
  5 * 60 * 1000,             // fail 3 — 5분
  30 * 60 * 1000,            // fail 4 — 30분
  2 * 3600 * 1000,           // fail 5 — 2시간
  24 * 3600 * 1000,          // fail 6+ — 24시간
];

function loadCircuit() {
  try { return JSON.parse(readFileSync(CIRCUIT_FILE, 'utf-8')); }
  catch { return { consecutiveFails: 0, lastFailTs: 0, state: 'closed', nextRetryTs: 0 }; }
}
function saveCircuit(c) {
  try {
    mkdirSync(dirname(CIRCUIT_FILE), { recursive: true });
    atomicWrite(CIRCUIT_FILE, JSON.stringify(c, null, 2));
  } catch (e) { log(`circuit 저장 실패 (무시): ${e.message}`); }
}
function circuitCheck() {
  const c = loadCircuit();
  if (c.state === 'open' && Date.now() < c.nextRetryTs) {
    const remMin = Math.round((c.nextRetryTs - Date.now()) / 60000);
    return { allow: false, reason: `circuit OPEN (재시도까지 ${remMin}분, 연속실패 ${c.consecutiveFails}회, lastFail=${new Date(c.lastFailTs).toISOString()})` };
  }
  return { allow: true };
}
function circuitOnSuccess() {
  const c = loadCircuit();
  if (c.consecutiveFails > 0 || c.state !== 'closed') {
    saveCircuit({ consecutiveFails: 0, lastFailTs: 0, state: 'closed', nextRetryTs: 0 });
    log('circuit closed (회복)');
  }
}
function circuitOnFailure(errMsg) {
  const c = loadCircuit();
  c.consecutiveFails = (c.consecutiveFails || 0) + 1;
  c.lastFailTs = Date.now();
  if (c.consecutiveFails >= CIRCUIT_FAIL_THRESHOLD) {
    const idx = Math.min(c.consecutiveFails, CIRCUIT_BACKOFF_MS.length - 1);
    const cooldownMs = CIRCUIT_BACKOFF_MS[idx];
    const cooldownLabel = cooldownMs >= 3600000 ? `${Math.round(cooldownMs / 3600000)}h`
                       : cooldownMs >= 60000 ? `${Math.round(cooldownMs / 60000)}min`
                       : `${Math.round(cooldownMs / 1000)}s`;
    c.state = 'open';
    c.nextRetryTs = Date.now() + cooldownMs;
    log(`circuit OPEN (연속 ${c.consecutiveFails}회 실패, ${cooldownLabel} 쿨다운): ${errMsg?.slice(0, 120)}`);
  } else {
    log(`circuit fail ${c.consecutiveFails}/${CIRCUIT_FAIL_THRESHOLD}: ${errMsg?.slice(0, 120)}`);
  }
  saveCircuit(c);
  return c;
}

// ── state 로드/저장 ──────────────────────────────────────────────────────────
function loadState() {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf-8')); }
  catch { return { mistakeExtractedUntil: 0, lastRun: null, totalExtracted: 0 }; }
}
function saveState(state) {
  try {
    mkdirSync(dirname(STATE_FILE), { recursive: true });
    atomicWrite(STATE_FILE, JSON.stringify(state, null, 2));
  } catch (e) {
    log(`state 저장 실패: ${e.message}`);
  }
}

// ── 세션 파일 수집 ───────────────────────────────────────────────────────────
function collectSessionFiles(sinceMs) {
  if (!existsSync(SUMMARIES_DIR)) return [];
  const entries = readdirSync(SUMMARIES_DIR);
  const targets = [];
  for (const name of entries) {
    if (!name.endsWith('.md') || name.endsWith('.bak')) continue;
    const fpath = join(SUMMARIES_DIR, name);
    try {
      const st = statSync(fpath);
      if (st.mtimeMs <= sinceMs) continue;
      if (st.size < MIN_FILE_BYTES) continue;
      targets.push({ path: fpath, mtime: st.mtimeMs, size: st.size });
    } catch { /* ignore */ }
  }
  targets.sort((a, b) => b.mtime - a.mtime);
  return targets.slice(0, MAX_FILES_PER_RUN);
}

// ── 기존 오답노트 패턴 수집 (중복 감지용) ────────────────────────────────────
function loadExistingPatterns() {
  if (!existsSync(MISTAKES_FILE)) return [];
  const body = readFileSync(MISTAKES_FILE, 'utf-8');
  // ## YYYY-MM-DD — <제목>  + 바로 아래 `- **패턴**: ...` 라인 추출
  const patterns = [];
  const lines = body.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^## \d{4}-\d{2}-\d{2} — (.+)$/);
    if (!m) continue;
    const title = m[1].trim();
    let patternLine = '';
    for (let j = i + 1; j < Math.min(i + 8, lines.length); j++) {
      const pm = lines[j].match(/^- \*\*패턴\*\*: (.+)$/);
      if (pm) { patternLine = pm[1].trim(); break; }
    }
    patterns.push({ title, patternLine });
  }
  return patterns;
}

// 간단한 Jaccard 기반 토큰 유사도 (한글/영문 혼합용)
function similarity(a, b) {
  if (!a || !b) return 0;
  const norm = s => s.toLowerCase().replace(/[^\w가-힣]+/g, ' ').trim().split(/\s+/).filter(t => t.length >= 2);
  const sa = new Set(norm(a));
  const sb = new Set(norm(b));
  if (sa.size === 0 || sb.size === 0) return 0;
  let inter = 0;
  for (const t of sa) if (sb.has(t)) inter++;
  const union = sa.size + sb.size - inter;
  return union === 0 ? 0 : inter / union;
}

// ── Haiku 프롬프트 빌드 ──────────────────────────────────────────────────────
function buildPrompt(sessionBodies) {
  const conjoined = sessionBodies
    .map((b, i) => `### 세션 ${i + 1}\n${b.slice(0, 6000)}`)
    .join('\n\n');

  // 오너 이름은 OSS 누출 방지 위해 env 로 주입 (blocklist rule: korean-owner-name).
  const ownerName = process.env.OWNER_NAME || 'Owner';

  return `다음은 AI 집사(Jarvis)와 오너(${ownerName} 대표)의 최근 Discord 대화 세션 요약입니다.
오너가 **Jarvis의 응답·판단·조치를 지적/정정**한 부분만 JSON 배열로 추출하세요.

## 추출 대상 (반드시 포함)
- 오너가 "틀렸다 / 잘못했다 / 그게 아니다 / 다시 해 / 제대로 해"처럼 명시적 지적
- 오너가 대안을 제시하며 수정을 요구
- Jarvis가 "죄송합니다 / 잘못 보고 / 확인 못했다"처럼 자체 정정한 경우
- **Jarvis 자기검열 실패 사례**: "단언했/실측 없이/검증 전 OK 선언/추정을 사실처럼 보고" — Iron Law 6 (VERIFY BEFORE DECLARE) 위반
- **SSoT 위반**: 기존 파일 미탐색 + 신규 중복 생성 ("~/.claude/commands/와 ~/.jarvis/ # ALLOW-DOTJARVISskills/ 양쪽에 같은 이름")
- **자동화 파이프라인 마비 미인지**: circuit OPEN, 추출 0건, 24h 무감지 등 메타 시스템 결함을 Jarvis 본인이 놓친 경우
- **할루시네이션 / 편향**: 파일 미열람 상태에서 코드 단언, 첫 응답 단언 편향, 가정을 사실처럼 진술

## 제외 대상
- 오너 본인의 실수·회한
- 단순 방향 전환("이거 말고 저거 보자") — 지적 아님
- Jarvis 정상 보고를 오너가 승인·확인한 경우
- 이미 해결되어 원인이 명확하지 않은 일반 잡담

## 출력 형식 (JSON 배열, 다른 텍스트 금지)
\`\`\`json
[
  {
    "pattern": "패턴 (~30자, 재발 방지용 한 줄 요약. 예: '크론 등록 파이프라인 부분 실행 후 완료 선언')",
    "actual": "실제 어떤 일이 벌어졌는지 (~100자)",
    "evidence": "대화 발췌 또는 명령 출력 (~100자, 원문 인용)",
    "correction": "다음부터 어떻게 해야 하는지 (~100자, 행동 지침)"
  }
]
\`\`\`

지적이 없으면 \`[]\` 출력. **JSON 외 텍스트 금지** (\`\`\`json 펜스는 OK).

## 대화 데이터
${conjoined}
`;
}

// ── JSON 응답 파싱 ───────────────────────────────────────────────────────────
function parseLLMResponse(text) {
  if (!text) return [];
  // ```json 펜스 제거
  let cleaned = text.trim()
    .replace(/^```(?:json)?\s*/m, '')
    .replace(/```\s*$/m, '')
    .trim();
  try {
    const parsed = JSON.parse(cleaned);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(item =>
      item && typeof item === 'object' &&
      typeof item.pattern === 'string' && item.pattern.length >= 5 &&
      typeof item.actual === 'string' &&
      typeof item.evidence === 'string' &&
      typeof item.correction === 'string'
    );
  } catch (e) {
    log(`JSON 파싱 실패: ${e.message} | 응답 앞부분: ${cleaned.slice(0, 200)}`);
    return [];
  }
}

// ── 중복 필터링 ──────────────────────────────────────────────────────────────
function filterDuplicates(candidates, existingPatterns) {
  const kept = [];
  for (const c of candidates) {
    let maxSim = 0;
    let dupTitle = '';
    for (const e of existingPatterns) {
      const s = Math.max(
        similarity(c.pattern, e.title),
        similarity(c.pattern, e.patternLine)
      );
      if (s > maxSim) { maxSim = s; dupTitle = e.title; }
    }
    if (maxSim >= DUPLICATE_THRESHOLD) {
      log(`중복 skip: "${c.pattern.slice(0, 40)}" ↔ "${dupTitle}" (sim=${maxSim.toFixed(2)})`);
      continue;
    }
    kept.push(c);
  }
  return kept;
}

// ── learned-mistakes.md에 append (flock으로 read-modify-write 직렬화) ────────
function appendMistakes(mistakes) {
  if (!existsSync(MISTAKES_FILE)) {
    throw new Error(`${MISTAKES_FILE} 부재 — 최초 수동 생성 필요`);
  }
  return withLock(MISTAKES_FILE + '.lock', () => _appendMistakesUnsafe(mistakes));
}

function _appendMistakesUnsafe(mistakes) {
  const body = readFileSync(MISTAKES_FILE, 'utf-8');

  // frontmatter / 헤더 분리
  const fmMatch = body.match(/^---\n([\s\S]*?)\n---\n/);
  if (!fmMatch) throw new Error('frontmatter 누락');
  const fmEnd = fmMatch[0].length;
  const afterFm = body.slice(fmEnd);

  // last_updated 갱신
  const newFm = fmMatch[1].replace(/^last_updated: .*$/m, `last_updated: ${kstISO()}`);

  // "> 새 항목 추가 시" 안내문 찾고 그 다음 `---` 바로 뒤 삽입
  const insertAnchor = afterFm.search(/\n---\n\n## \d{4}-\d{2}-\d{2}/);
  if (insertAnchor === -1) throw new Error('삽입 지점(첫 `---` + `## YYYY-MM-DD`) 감지 실패');

  const before = afterFm.slice(0, insertAnchor + 5); // \n---\n 까지 포함
  const after = afterFm.slice(insertAnchor + 5);

  const today = todayKST();
  const newSections = mistakes.map(m => {
    // pattern이 너무 길면 제목 30자로 자름
    const title = m.pattern.length > 40 ? m.pattern.slice(0, 40).replace(/\s+$/, '') + '…' : m.pattern;
    return `\n## ${today} — ${title}\n\n- **패턴**: ${m.pattern}\n- **실제**: ${m.actual}\n- **증거**: ${m.evidence}\n- **대응**: ${m.correction}\n\n---\n`;
  }).join('');

  const newBody = `---\n${newFm}\n---\n${before}${newSections}${after}`;
  atomicWrite(MISTAKES_FILE, newBody);
}

// ── Discord 출력용 요약 (stdout으로 내보내면 크론 러너가 Discord 전송) ──────
function buildStdoutSummary(added, skipped, duration) {
  if (added.length === 0) {
    return `🤖 오답노트 자동 추출 — 신규 항목 없음\n- 세션 파일 스캔: ${skipped.filesScanned}개\n- 중복/필터 제외: ${skipped.duplicates}건\n- 소요: ${duration}초`;
  }
  const lines = [`🤖 오답노트 자동 추출 — **${added.length}건 추가**`];
  for (const m of added) {
    lines.push(`- **${m.pattern.slice(0, 60)}**`);
  }
  lines.push(`\n📊 세션 ${skipped.filesScanned}개 스캔, 중복 ${skipped.duplicates}건 skip, ${duration}초`);
  lines.push(`📁 ${MISTAKES_FILE.replace(HOME, '~')}`);
  return lines.join('\n');
}

// ── LLM 우회 폴백 모드 — stdin 4필드 JSON 직접 등재 ────────────────────────
// circuit OPEN/budget 차단 우회. 호출자가 자기정정 신호를 명확히 인식했을 때만 사용.
// 자동화 파이프라인 마비 시 핵심 실수가 누락되지 않도록 보장하는 안전망.
async function runDirectFact() {
  const t0 = Date.now();
  log(`=== mistake-extractor 시작 (DIRECT-FACT) ===`);

  // stdin 읽기 (Node.js 동기)
  let stdinBuf = '';
  try {
    stdinBuf = readFileSync(0, 'utf-8');
  } catch (e) {
    log(`stdin 읽기 실패: ${e.message}`);
    console.log(`❌ direct-fact: stdin 읽기 실패 — ${e.message}`);
    process.exit(1);
  }

  let mistakes;
  try {
    const parsed = JSON.parse(stdinBuf.trim());
    if (!Array.isArray(parsed)) throw new Error('JSON 배열이 아님');
    mistakes = parsed.filter(item =>
      item && typeof item === 'object' &&
      typeof item.pattern === 'string' && item.pattern.length >= 5 &&
      typeof item.actual === 'string' &&
      typeof item.evidence === 'string' &&
      typeof item.correction === 'string'
    );
  } catch (e) {
    log(`JSON 파싱 실패: ${e.message}`);
    console.log(`❌ direct-fact: JSON 파싱 실패 — ${e.message}`);
    process.exit(1);
  }

  if (mistakes.length === 0) {
    log('direct-fact: 유효 4필드 0건 — 종료');
    console.log('🤖 direct-fact: 유효 4필드 0건');
    return;
  }

  // 중복 필터링은 그대로 적용 (악의적 스팸/중복 방지)
  const existingPatterns = loadExistingPatterns();
  log(`direct-fact: 기존 패턴 ${existingPatterns.length}개 로드`);
  const filtered = filterDuplicates(mistakes, existingPatterns);
  const final = filtered.slice(0, MAX_MISTAKES_PER_RUN);

  if (final.length === 0) {
    log(`direct-fact: 모두 중복으로 skip (${mistakes.length}건)`);
    console.log(`🤖 direct-fact: 모두 중복으로 skip (${mistakes.length}건)`);
    return;
  }

  try {
    appendMistakes(final);
    log(`direct-fact: learned-mistakes.md에 ${final.length}건 append 완료`);
  } catch (e) {
    log(`direct-fact: append 실패: ${e.message}`);
    console.log(`❌ direct-fact: append 실패 — ${e.message}`);
    process.exit(1);
  }

  // ledger append (source: direct-fact — manual-direct-edit과 구분되는 신규 진입점)
  try {
    const ledgerFile = join(BOT_HOME, 'state', 'mistake-ledger.jsonl');
    const ledgerLine = JSON.stringify({
      ts: kstISO(),
      source: 'direct-fact',
      count: final.length,
      titles: final.map(m => (m.pattern || '(untitled)').slice(0, 80)),
      session_file: null,
      duration_s: Number(((Date.now() - t0) / 1000).toFixed(1)),
      circuit_bypassed: true,
      llm_bypassed: true,
    }) + '\n';
    appendFileSync(ledgerFile, ledgerLine);
    log(`direct-fact: ledger append: ${ledgerFile}`);
  } catch (e) {
    log(`direct-fact: ledger append 실패 (무시): ${e.message}`);
  }

  const summary = [
    `🧠 오답노트 직접 등재 — **${final.length}건 추가** (LLM 우회)`,
    ...final.map(m => `- **${m.pattern.slice(0, 60)}**`),
    `\n📊 입력 ${mistakes.length}건, 중복 ${mistakes.length - final.length}건 skip, ${((Date.now() - t0)/1000).toFixed(1)}초`,
  ];
  console.log(summary.join('\n'));
}

// ── 메인 ─────────────────────────────────────────────────────────────────────
async function main() {
  // LLM 우회 폴백 모드 — circuit/budget 우회하여 즉시 등재
  if (DIRECT_FACT_MODE) {
    return await runDirectFact();
  }

  const t0 = Date.now();
  log(`=== mistake-extractor 시작${DRY_RUN ? ' (DRY-RUN)' : ''}${SINGLE_FILE ? ' (SINGLE_FILE)' : ''} ===`);

  // 서킷브레이커 — Haiku 연속 실패 시 단계적 백오프 (DRY_RUN은 무시)
  if (!DRY_RUN) {
    const gate = circuitCheck();
    if (!gate.allow) {
      log(`차단: ${gate.reason}`);
      console.log(`🛑 오답노트 자동 추출 — ${gate.reason}`);
      return;
    }
  }

  // 예산 차단 (DRY_RUN은 제외, 일일 누적 Haiku 비용 $0.10 기본)
  if (!DRY_RUN) {
    const budget = budgetCheck();
    if (!budget.allow) {
      log(`예산 차단: ${budget.reason}`);
      console.log(`💰 오답노트 자동 추출 — 예산 차단: ${budget.reason}`);
      return;
    }
    if (budget.today > BUDGET_DAILY_USD * 0.8) {
      log(`예산 경고: 오늘 누적 $${budget.today.toFixed(5)} (${(budget.today/BUDGET_DAILY_USD*100).toFixed(0)}%)`);
    }
  }

  const state = loadState();
  const sinceMs = state.mistakeExtractedUntil || (Date.now() - 48 * 3600_000); // 초회 48h
  log(`state.mistakeExtractedUntil=${new Date(sinceMs).toISOString()}`);

  let sessionFiles;
  if (SINGLE_FILE) {
    if (!existsSync(SINGLE_FILE)) {
      log(`--file 대상 없음: ${SINGLE_FILE}`);
      console.log('🤖 오답노트 자동 추출 — 세션 파일 없음');
      return;
    }
    const st = statSync(SINGLE_FILE);
    if (st.size < MIN_FILE_BYTES) {
      log(`--file 너무 작음 (${st.size} < ${MIN_FILE_BYTES}): ${SINGLE_FILE}`);
      console.log('🤖 오답노트 자동 추출 — 세션 분량 부족');
      return;
    }
    sessionFiles = [{ path: SINGLE_FILE, mtime: st.mtimeMs, size: st.size }];
    log(`--file 단일 파일 모드: ${SINGLE_FILE}`);
  } else {
    sessionFiles = collectSessionFiles(sinceMs);
  }
  if (sessionFiles.length === 0) {
    log('신규 세션 요약 없음 — 종료');
    console.log('🤖 오답노트 자동 추출 — 신규 세션 요약 없음');
    return;
  }
  log(`대상 세션 파일 ${sessionFiles.length}개 (최신 ${new Date(sessionFiles[0].mtime).toISOString()})`);

  const bodies = sessionFiles.map(f => readFileSync(f.path, 'utf-8'));
  const prompt = buildPrompt(bodies);
  log(`Haiku 호출 (프롬프트 ${prompt.length}자)`);

  // Token-ledger append 헬퍼 (Verify 재감사 B1 지적 — Haiku 호출 회계 누락 해소)
  // 기존 token-ledger.jsonl 스키마와 동일 구조. 한글 bytes/3 로 토큰 근사 (정확 tokenizer 없음).
  const tokenLedgerFile = join(BOT_HOME, 'state', 'token-ledger.jsonl');
  const appendTokenLedger = (status, resultBytes, errMsg) => {
    try {
      const inputTok = Math.round(prompt.length / 3);
      const outputTok = Math.round(resultBytes / 3);
      // Haiku-4-5 실비: input $0.80/MTok, output $4/MTok
      const costUsd = Number((inputTok * 0.80 / 1e6 + outputTok * 4 / 1e6).toFixed(5));
      const entry = {
        ts: new Date().toISOString(),
        task: 'mistake-extractor',
        model: 'claude-haiku-4-5-20251001',
        status,
        input: inputTok,
        output: outputTok,
        cost_usd: costUsd,
        duration_ms: Math.round(Date.now() - t0),
        result_bytes: resultBytes,
        source: SINGLE_FILE ? 'stop-hook' : 'batch-daily',
        max_budget_usd: 0.10,
      };
      if (errMsg) entry.error = errMsg.slice(0, 120);
      appendFileSync(tokenLedgerFile, JSON.stringify(entry) + '\n');
      log(`token-ledger append: ${status} ${inputTok}in/${outputTok}out $${costUsd.toFixed(5)}`);
    } catch (e) {
      log(`token-ledger append 실패 (무시): ${e.message}`);
    }
  };

  let raw;
  try {
    raw = callClaude(prompt);
    circuitOnSuccess();
    appendTokenLedger('success', raw.length, null);
  } catch (e) {
    log(`Haiku 호출 실패: ${e.message}`);
    if (!DRY_RUN) circuitOnFailure(e.message);
    appendTokenLedger('failed', 0, e.message);
    console.log(`❌ 오답노트 추출 실패 — LLM 호출 오류: ${e.message}`);
    process.exit(1);
  }

  const candidates = parseLLMResponse(raw);
  log(`LLM 응답 파싱 완료 — 후보 ${candidates.length}건`);
  if (candidates.length === 0) {
    log('신규 지적 패턴 없음');
    console.log('🤖 오답노트 자동 추출 — 신규 지적 패턴 없음');
    if (!DRY_RUN && !SINGLE_FILE) {
      state.mistakeExtractedUntil = Date.now();
      state.lastRun = kstISO();
      saveState(state);
    }
    return;
  }

  const existingPatterns = loadExistingPatterns();
  log(`기존 오답노트 패턴 ${existingPatterns.length}개 로드`);
  const filtered = filterDuplicates(candidates, existingPatterns);
  const final = filtered.slice(0, MAX_MISTAKES_PER_RUN);
  const skipped = {
    filesScanned: sessionFiles.length,
    duplicates: candidates.length - filtered.length,
  };

  if (DRY_RUN) {
    console.log('=== DRY-RUN 결과 ===');
    console.log(JSON.stringify({ candidates, filtered, final }, null, 2));
    log(`=== DRY-RUN 완료 (${final.length}건 append 예정) ===`);
    return;
  }

  if (final.length > 0) {
    try {
      appendMistakes(final);
      log(`learned-mistakes.md에 ${final.length}건 append 완료`);
    } catch (e) {
      log(`append 실패: ${e.message}`);
      console.log(`❌ append 실패: ${e.message}`);
      process.exit(1);
    }

    // Ledger append (SSoT: 배치/Stop훅/oops 세 진입점 공통 감사 트레일)
    // append-only JSONL — 주간 감사가 이 원장을 읽어 "반복 패턴"·"진입점별 정확도" 분석
    try {
      const ledgerFile = join(BOT_HOME, 'state', 'mistake-ledger.jsonl');
      const ledgerLine = JSON.stringify({
        ts: kstISO(),
        source: SINGLE_FILE ? 'stop-hook' : 'batch-daily',
        count: final.length,
        titles: final.map(m => (m.pattern || m.title || '(untitled)').slice(0, 80)),
        session_file: SINGLE_FILE || null,
        duration_s: Number(((Date.now() - t0) / 1000).toFixed(1)),
      }) + '\n';
      appendFileSync(ledgerFile, ledgerLine);
      log(`ledger append: ${ledgerFile}`);
    } catch (e) {
      log(`ledger append 실패 (무시): ${e.message}`);
    }
  }

  if (!SINGLE_FILE) {
    state.mistakeExtractedUntil = Date.now();
    state.lastRun = kstISO();
    state.totalExtracted = (state.totalExtracted || 0) + final.length;
    saveState(state);
  }

  const dur = ((Date.now() - t0) / 1000).toFixed(1);
  log(`=== mistake-extractor 완료: +${final.length}건, ${dur}초 ===`);
  console.log(buildStdoutSummary(final, skipped, dur));
}

main().catch(err => {
  log(`치명적 오류: ${err.stack || err.message}`);
  console.log(`❌ 오답노트 추출 치명적 오류: ${err.message}`);
  process.exit(1);
});
