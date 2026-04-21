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

// ── 서킷브레이커 (Haiku 연속 실패 3회 → 24h open) ────────────────────────────
// 비용 폭주 방지: LLM 호출 반복 실패 상황에서 extractor 자체를 24h 비활성화.
// state: closed(정상) | open(차단) | half-open(쿨다운 후 1회 시도 허용 — 자동)
const CIRCUIT_FILE = join(homedir(), 'jarvis/runtime/state/mistake-extractor-circuit.json');
const CIRCUIT_FAIL_THRESHOLD = 3;
const CIRCUIT_COOLDOWN_MS = 24 * 3600 * 1000;

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
    c.state = 'open';
    c.nextRetryTs = Date.now() + CIRCUIT_COOLDOWN_MS;
    log(`circuit OPEN (연속 ${c.consecutiveFails}회 실패, 24h 쿨다운): ${errMsg?.slice(0, 120)}`);
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

// ── 메인 ─────────────────────────────────────────────────────────────────────
async function main() {
  const t0 = Date.now();
  log(`=== mistake-extractor 시작${DRY_RUN ? ' (DRY-RUN)' : ''}${SINGLE_FILE ? ' (SINGLE_FILE)' : ''} ===`);

  // 서킷브레이커 — Haiku 연속 실패 시 24h 차단 (DRY_RUN은 무시)
  if (!DRY_RUN) {
    const gate = circuitCheck();
    if (!gate.allow) {
      log(`차단: ${gate.reason}`);
      console.log(`🛑 오답노트 자동 추출 — ${gate.reason}`);
      return;
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

  let raw;
  try {
    raw = callClaude(prompt);
    circuitOnSuccess();
  } catch (e) {
    log(`Haiku 호출 실패: ${e.message}`);
    if (!DRY_RUN) circuitOnFailure(e.message);
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
