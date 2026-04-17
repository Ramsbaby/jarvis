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
 */

import {
  readFileSync, existsSync, readdirSync, statSync,
  appendFileSync, mkdirSync,
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
const MAX_AGE_SEC     = 3 * 60 * 60; // 3시간 이내 세션만 (너무 오래된 파일 재처리 방지)

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
      ['--model', MODEL, '--output-format', 'text', '--max-turns', '1', '--tools', '', '--dangerously-skip-permissions'],
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
      if (code === 0) resolve(out.trim());
      else reject(new Error(`haiku exit ${code}: ${err.slice(0, 200)}`));
    });
    proc.on('error', reject);
  });
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
  if (stat.size < 120) {
    const result = { status: 'skipped', reason: 'file too small', sessionFile, size: stat.size };
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

  const content = readFileSync(sessionFile, 'utf-8');
  log('info', 'ingesting', { sessionFile, size: stat.size });

  let rawResponse;
  try {
    rawResponse = await callHaiku(buildExtractionPrompt(content));
  } catch (err) {
    const result = { status: 'error', error: err.message, sessionFile };
    log('error', 'haiku call failed', result);
    console.log(JSON.stringify(result));
    return;
  }

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
  };
  log('info', 'done', result);
  console.log(JSON.stringify(result));
}

main().catch((err) => {
  const result = { status: 'error', error: err?.message || String(err) };
  log('error', 'main crashed', result);
  console.log(JSON.stringify(result));
  // 항상 exit 0 — 세션 저장 파이프라인 차단 금지
});