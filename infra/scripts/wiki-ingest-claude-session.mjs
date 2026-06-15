#!/usr/bin/env node
/**
 * wiki-ingest-claude-session.mjs — Claude Code CLI 세션 → 위키 실시간 주입
 *
 * stop-session-save.sh가 생성한 세션 마크다운 1개를 읽어
 * Haiku로 facts를 추출한 뒤 wiki-engine.addFactToWiki(source: 'claude-code-cli')로 주입한다.
 *
 * 디스코드 파이프라인의 autoExtractMemory → wikiAddFact 와 동등한 역할을
 * Claude Code CLI 표면에서 수행하는 진입점.
 *
 * Usage:
 *   node wiki-ingest-claude-session.mjs <session.md path>
 *   node wiki-ingest-claude-session.mjs --latest [project-slug]
 *
 * Output (stdout, JSON):
 *   { status: 'ok',      sessionFile, factsExtracted, factsWritten, domains }
 *   { status: 'skipped', reason, sessionFile? }
 *   { status: 'error',   error, sessionFile? }
 *
 * Exit codes: 항상 0. 세션 저장 파이프라인을 절대 차단하지 않음.
 *
 * Log: ~/jarvis/runtime/logs/wiki-ingest-claude.log
 *
 * ═══════════════════════════════════════════════════════════════
 * CONCEPT: SESSION FILE vs CONTEXT TOKEN
 * ═══════════════════════════════════════════════════════════════
 * SESSION FILE = Persistent context storage (disk-based)
 *   - Input: sessionFile (markdown from ~/.jarvis/context/claude-code-sessions/)
 *   - Purpose: Archive user conversations, extract facts
 *   - Lifetime: Persistent on disk
 *   - Related to API tokens? NO (file on disk)
 *
 * CONTEXT TOKEN = Ephemeral API input (for Claude API calls)
 *   - Created when: facts are sent to Haiku for extraction
 *   - Consumed by: Claude API tokenizer
 *   - Lifetime: Duration of single API call only
 *   - Related to billing? YES (tokens consumed = credits used)
 *
 * This script:
 *   1. Reads SESSION FILE from disk (no token cost)
 *   2. Sends partial content to Claude API → CONTEXT TOKENS consumed
 *   3. Writes extracted facts back to wiki (SESSION FILE update)
 *
 * Cost control:
 *   - MIN_SESSION_BYTES: Pre-filter to avoid sending tiny files
 *   - MAX_INPUT_CHARS: Cap token consumption per call
 *   - DAILY_CAP_USD: Global daily limit (billing safety)
 * ═══════════════════════════════════════════════════════════════
 */

import {
  readFileSync, existsSync, readdirSync, statSync,
  appendFileSync, mkdirSync, writeFileSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';
import { addFactToWiki } from '../discord/lib/wiki-engine.mjs';

// ── 설정 ─────────────────────────────────────────────────────────────────────
const HOME         = homedir();
const BOT_HOME     = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');
const SESSIONS_DIR = join(BOT_HOME, 'context', 'claude-code-sessions');
const LOG_FILE     = join(BOT_HOME, 'logs', 'wiki-ingest-claude.log');

const CLAUDE_BIN      = process.env.CLAUDE_BINARY || join(HOME, '.local/bin/claude');
const MODEL           = 'claude-haiku-4-5-20251001';
const HAIKU_TIMEOUT   = 60_000;
const MIN_FACT_LEN    = 6;
const MAX_FACT_LEN    = 160;
const MAX_INPUT_CHARS = 12_000;
const MAX_AGE_SEC     = 3 * 60 * 60;

// 2026-04-26 누수 가드 (Agent 감사 결과 — 월 $17.78 추정 누수 차단):
//   - 세션 .md 최소 크기 강화: 120 bytes → 2000 bytes (잡음 추출 차단)
//   - per-cwd 쿨다운 5분 (워크트리 16개 중복 트리거 방지)
//   - 일일 비용 캡 $1.00 (글로벌)
//   - token-ledger 적재 (Discord 봇 동일 ledger 통합)
const MIN_SESSION_BYTES = 2000;
const COOLDOWN_SEC      = 300;
const DAILY_CAP_USD     = 1.00;
const LEDGER_FILE       = join(BOT_HOME, 'state', 'token-ledger.jsonl');
const COOLDOWN_DIR      = join(BOT_HOME, 'state', 'wiki-ingest-cooldown');
const DAILY_COST_FILE   = join(BOT_HOME, 'state', 'wiki-ingest-daily-cost.json');

// 추출 금지 패턴 — autoExtractMemory의 FAMILY_JUNK_RE 에서 일반화
const JUNK_RE = /(^compacted at|^사용자 의도|^완료된 작업|^미완 작업|^핵심 참조|^\[20\d\d-\d\d-\d\d \d\d:\d\d:\d\d\])/i;

// ── 로거 (KST) ───────────────────────────────────────────────────────────────
function kstTimestamp() {
  // sv-SE 로케일은 ISO 유사 포맷 "YYYY-MM-DD HH:MM:SS" 를 돌려줌 → timeZone 옵션과 결합하면 KST 시각 획득
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
}

function log(level, msg, meta = {}) {
  const ts = kstTimestamp();
  const metaStr = Object.keys(meta).length ? ' ' + JSON.stringify(meta) : '';
  const line = `[${ts} KST] [wiki-ingest-claude] [${level.toUpperCase()}] ${msg}${metaStr}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    appendFileSync(LOG_FILE, line);
  } catch { /* log 실패는 무시 */ }
  if (level === 'error' || process.env.DEBUG) process.stderr.write(line);
}

// ── 최신 세션 탐색 ───────────────────────────────────────────────────────────
function findLatestSession(projectSlug = null) {
  if (!existsSync(SESSIONS_DIR)) return null;

  const candidates = [];
  let projects;
  try {
    projects = projectSlug ? [projectSlug] : readdirSync(SESSIONS_DIR);
  } catch {
    return null;
  }

  for (const p of projects) {
    const dir = join(SESSIONS_DIR, p);
    let dirStat;
    try { dirStat = statSync(dir); } catch { continue; }
    if (!dirStat.isDirectory()) continue;

    let files;
    try { files = readdirSync(dir); } catch { continue; }
    for (const f of files) {
      if (!f.endsWith('.md')) continue;
      const full = join(dir, f);
      try {
        const st = statSync(full);
        candidates.push({ path: full, mtime: st.mtimeMs });
      } catch { /* ignore */ }
    }
  }

  if (!candidates.length) return null;
  candidates.sort((a, b) => b.mtime - a.mtime);
  return candidates[0].path;
}

// ── LLM 추출 프롬프트 ────────────────────────────────────────────────────────
function buildExtractionPrompt(sessionContent) {
  const trimmed = sessionContent.length > MAX_INPUT_CHARS
    ? '...(앞부분 생략)\n' + sessionContent.slice(-MAX_INPUT_CHARS)
    : sessionContent;

  return [
    '다음은 오너와 Claude Code CLI 간의 개발/운영 세션 대화입니다.',
    '이 대화에서 **미래 세션에 유용한 사실·결정·선호**만 JSON 배열로 추출해주세요.',
    '',
    '## 추출 대상',
    '- 구체적 기술 결정 (무엇을 왜 그렇게 선택했는가)',
    '- 프로젝트 구조·파이프라인에 대한 확정 사실',
    '- 오너의 선호·규칙·금지사항 (피드백 성격)',
    '- 진행 중인 작업의 중요 맥락 (관련 시스템·파일·결정 배경)',
    '- 발견한 제약·버그·주의사항 (재발 방지용)',
    '',
    '## 추출 금지',
    '- 일반 상식·프로그래밍 기초·자명한 사실',
    '- 특정 코드 라인 / diff 내용 (git log이 다룸, 중복)',
    '- "무엇을 했다" 식 행동 요약 (사실이 아닌 서사)',
    '- 임시 디버깅 출력·스택트레이스·컴파일 에러 원문',
    '- 150자 이상 긴 문장 (짧고 검색 가능한 단위로)',
    '- 특정 시각/날짜에만 유효한 수치 (크론 실행 시각 등)',
    '',
    '## 세션 내용',
    trimmed,
    '',
    '## 출력 형식',
    '마지막 줄에 JSON 배열 1개만. 다른 텍스트 금지.',
    '추출할 사실이 없으면 []',
    '예: ["자비스맵 team-registry.ts가 SSoT로 구축됨", "오너는 땜질식 대처를 금지함"]',
  ].join('\n');
}

// ── Haiku 호출 ───────────────────────────────────────────────────────────────
function callHaiku(prompt, timeoutMs = HAIKU_TIMEOUT) {
  return new Promise((resolve, reject) => {
    const proc = spawn(
      CLAUDE_BIN,
      ['--model', MODEL, '--output-format', 'json', '--max-turns', '1', '--tools', '', '--dangerously-skip-permissions'],
      {
        timeout: timeoutMs,
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env },
      },
    );
    let out = '';
    let err = '';
    proc.stdout.on('data', (d) => { out += d; });
    proc.stderr.on('data', (d) => { err += d; });
    proc.stdin.write(prompt, 'utf-8');
    proc.stdin.end();
    proc.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`haiku exit ${code}: ${err.slice(0, 200)}`));
        return;
      }
      try {
        const json = JSON.parse(out.trim());
        resolve({
          text: (json.result || '').trim(),
          input: json.usage?.input_tokens || 0,
          output: json.usage?.output_tokens || 0,
          cost: json.total_cost_usd || json.cost_usd || 0,
          duration_ms: json.duration_ms || 0,
        });
      } catch (e) {
        reject(new Error(`json parse fail: ${e.message}`));
      }
    });
    proc.on('error', reject);
  });
}

// ── 가드 1: 일일 비용 캡 (글로벌) ──────────────────────────────────────────────
function loadDailyCost() {
  try {
    const raw = JSON.parse(readFileSync(DAILY_COST_FILE, 'utf-8'));
    const today = new Date().toISOString().slice(0, 10);
    if (raw.date === today) return raw.cost_usd || 0;
  } catch { /* 파일 없음/손상 */ }
  return 0;
}
function saveDailyCost(cost) {
  try {
    mkdirSync(dirname(DAILY_COST_FILE), { recursive: true });
    const today = new Date().toISOString().slice(0, 10);
    writeFileSync(DAILY_COST_FILE, JSON.stringify({ date: today, cost_usd: cost }));
  } catch { /* ignore */ }
}

// ── 가드 2: per-cwd 쿨다운 (워크트리 중복 차단) ───────────────────────────────
function checkCooldown(sessionFile) {
  try {
    mkdirSync(COOLDOWN_DIR, { recursive: true });
    // sessionFile path 기반 hash (워크트리별로 다른 .md여도 같은 cwd면 같은 슬러그)
    const slug = sessionFile.replace(/[^a-z0-9]/gi, '_').slice(-100);
    const f = join(COOLDOWN_DIR, slug + '.ts');
    if (existsSync(f)) {
      const last = parseInt(readFileSync(f, 'utf-8').trim(), 10);
      if (Date.now() - last < COOLDOWN_SEC * 1000) return true;
    }
    writeFileSync(f, Date.now().toString());
    return false;
  } catch { return false; }
}

// ── 가드 3: token-ledger 적재 (Discord 봇 동일 ledger 통합) ──────────────────
function appendLedger(sessionFile, usage, status, factsWritten = 0) {
  try {
    mkdirSync(dirname(LEDGER_FILE), { recursive: true });
    const entry = {
      ts: new Date().toISOString(),
      task: 'wiki-ingest-claude',
      model: MODEL,
      status,
      input: usage.input || 0,
      output: usage.output || 0,
      cost_usd: usage.cost || 0,
      duration_ms: usage.duration_ms || 0,
      result_bytes: factsWritten,
      source: 'stop-hook',
      session_file: sessionFile,
    };
    appendFileSync(LEDGER_FILE, JSON.stringify(entry) + '\n');
  } catch { /* 적재 실패는 무시 */ }
}

// ── 응답에서 JSON 배열 파싱 ──────────────────────────────────────────────────
function parseFactsFromResponse(raw) {
  const trimmed = raw.trim();
  let cursor = trimmed.length - 1;
  while (cursor >= 0) {
    const closeIdx = trimmed.lastIndexOf(']', cursor);
    if (closeIdx === -1) break;
    // bracket matching (중첩 [] 안전)
    let depth = 0;
    let openIdx = -1;
    for (let j = closeIdx; j >= 0; j--) {
      const ch = trimmed[j];
      if (ch === ']') depth++;
      else if (ch === '[') {
        depth--;
        if (depth === 0) { openIdx = j; break; }
      }
    }
    if (openIdx === -1) { cursor = closeIdx - 1; continue; }
    try {
      const parsed = JSON.parse(trimmed.slice(openIdx, closeIdx + 1));
      if (Array.isArray(parsed) && parsed.every(x => typeof x === 'string')) return parsed;
    } catch { /* 다음 후보 시도 */ }
    cursor = openIdx - 1;
  }
  return null;
}

// ── 사실 1개 유효성 ──────────────────────────────────────────────────────────
function isValidFact(fact) {
  if (typeof fact !== 'string') return false;
  const t = fact.trim();
  if (t.length < MIN_FACT_LEN || t.length > MAX_FACT_LEN) return false;
  if (JUNK_RE.test(t)) return false;
  return true;
}

// ── 메인 ─────────────────────────────────────────────────────────────────────
async function main() {
  const args = process.argv.slice(2);
  let sessionFile = null;

  if (args.includes('--latest')) {
    const idx = args.indexOf('--latest');
    const next = args[idx + 1];
    const project = next && !next.startsWith('--') ? next : null;
    sessionFile = findLatestSession(project);
    if (!sessionFile) {
      const result = { status: 'skipped', reason: 'no session file found', project };
      log('info', 'skipped', result);
      console.log(JSON.stringify(result));
      return;
    }
  } else if (args[0] && !args[0].startsWith('--')) {
    sessionFile = args[0];
  } else {
    console.error(JSON.stringify({
      error: 'Usage: wiki-ingest-claude-session.mjs <session.md path> | --latest [project-slug]',
    }));
    return; // exit 0 여전히 (훅 안전)
  }

  if (!existsSync(sessionFile)) {
    const result = { status: 'skipped', reason: 'file not found', sessionFile };
    log('warn', 'skipped', result);
    console.log(JSON.stringify(result));
    return;
  }

  const stat = statSync(sessionFile);
  if (stat.size < MIN_SESSION_BYTES) {
    const result = { status: 'skipped', reason: 'file too small', sessionFile, size: stat.size, threshold: MIN_SESSION_BYTES };
    log('info', 'skipped', result);
    console.log(JSON.stringify(result));
    return;
  }

  // 오래된 세션 재처리 방지
  const ageSec = (Date.now() - stat.mtimeMs) / 1000;
  if (ageSec > MAX_AGE_SEC) {
    const result = { status: 'skipped', reason: 'too old', sessionFile, ageSec: Math.round(ageSec) };
    log('info', 'skipped', result);
    console.log(JSON.stringify(result));
    return;
  }

  // 가드 1: 일일 비용 캡 ($1.00)
  const todayCost = loadDailyCost();
  if (todayCost >= DAILY_CAP_USD) {
    const result = { status: 'skipped', reason: 'daily cost cap reached', sessionFile, today_cost_usd: todayCost, cap_usd: DAILY_CAP_USD };
    log('warn', 'cap reached', result);
    appendLedger(sessionFile, { input: 0, output: 0, cost: 0, duration_ms: 0 }, 'skipped_cap');
    console.log(JSON.stringify(result));
    return;
  }

  // 가드 2: per-cwd 쿨다운 (5분)
  if (checkCooldown(sessionFile)) {
    const result = { status: 'skipped', reason: 'cooldown active (5min)', sessionFile };
    log('info', 'cooldown', result);
    console.log(JSON.stringify(result));
    return;
  }

  const content = readFileSync(sessionFile, 'utf-8');
  log('info', 'ingesting', { sessionFile, size: stat.size });

  let rawResponse;
  let usage = { input: 0, output: 0, cost: 0, duration_ms: 0 };
  try {
    const r = await callHaiku(buildExtractionPrompt(content));
    rawResponse = r.text;
    usage = { input: r.input, output: r.output, cost: r.cost, duration_ms: r.duration_ms };
  } catch (err) {
    const result = { status: 'error', error: err.message, sessionFile };
    log('error', 'haiku call failed', result);
    appendLedger(sessionFile, usage, 'error');
    console.log(JSON.stringify(result));
    return;
  }

  // 일일 비용 누적 갱신
  saveDailyCost(loadDailyCost() + (usage.cost || 0));

  const facts = parseFactsFromResponse(rawResponse);
  if (!facts) {
    const result = { status: 'skipped', reason: 'no valid JSON array in response', sessionFile };
    log('warn', 'no facts', { ...result, raw: rawResponse.slice(-200) });
    console.log(JSON.stringify(result));
    return;
  }

  const valid = facts.filter(isValidFact);
  const domainCounts = {};
  let written = 0;

  for (const fact of valid) {
    try {
      const domain = addFactToWiki(null, fact.trim(), { source: 'claude-code-cli' });
      domainCounts[domain] = (domainCounts[domain] ?? 0) + 1;
      written++;
      log('info', 'fact written', { domain, fact: fact.slice(0, 80) });
    } catch (err) {
      log('warn', 'addFactToWiki failed', { error: err.message, fact: fact.slice(0, 80) });
    }
  }

  const result = {
    status: 'ok',
    sessionFile,
    factsExtracted: facts.length,
    factsFiltered: facts.length - valid.length,
    factsWritten: written,
    domains: domainCounts,
    usage,
  };
  log('info', 'done', result);
  appendLedger(sessionFile, usage, 'success', written);
  console.log(JSON.stringify(result));
}

main().catch((err) => {
  const result = { status: 'error', error: err?.message || String(err) };
  log('error', 'main crashed', result);
  console.log(JSON.stringify(result));
  // 항상 exit 0 — 세션 저장 파이프라인 차단 금지
});