#!/usr/bin/env node
/**
 * claude-cli-rag-sync.mjs
 * Claude CLI 세션(.jsonl) → RAG inbox 변환 싱크
 *
 * ~/.claude/projects/ 하위 .jsonl 파일에서 user/assistant 대화 추출 후
 * ~/jarvis/runtime/inbox/claude-cli-YYYYMMDD-{sessionId}.md 로 저장
 * → rag-watch.mjs가 감지해 LanceDB 자동 인덱싱
 *
 * 사용법: node claude-cli-rag-sync.mjs [--dry-run]
 * cron: 매 10분 실행 권장
 */

import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const CLAUDE_PROJECTS = join(HOME, '.claude', 'projects');
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');
const INBOX = join(BOT_HOME, 'inbox');
const STATE_FILE = join(BOT_HOME, 'state', 'cli-rag-sync.json');
const DRY_RUN = process.argv.includes('--dry-run');

const MIN_CONTENT_LEN = 30;   // 너무 짧은 메시지 스킵
const MAX_CONTENT_LEN = 2000; // 메시지당 최대 길이

function log(msg) {
  console.log(`[${new Date().toISOString()}] [cli-rag-sync] ${msg}`);
}

/** Python repr dict 문자열 → JS object (간단 파싱) */
function parsePyRepr(raw) {
  if (!raw || typeof raw !== 'string') return null;
  try {
    // Python repr → JSON 변환 시도: True/False/None 치환
    const jsonLike = raw
      .replace(/\bTrue\b/g, 'true')
      .replace(/\bFalse\b/g, 'false')
      .replace(/\bNone\b/g, 'null')
      // Python single-quote string: 단순 케이스만 처리
      .replace(/'/g, '"');
    return JSON.parse(jsonLike);
  } catch {
    return null;
  }
}

/** message 필드에서 텍스트 추출 */
function extractText(message) {
  if (!message) return null;

  // 이미 파싱된 객체
  if (typeof message === 'object') {
    const content = message.content;
    if (typeof content === 'string') return content.trim();
    if (Array.isArray(content)) {
      return content
        .filter(c => c?.type === 'text')
        .map(c => c.text)
        .join('\n')
        .trim();
    }
    return null;
  }

  // 문자열인 경우 Python repr 파싱 시도
  if (typeof message === 'string') {
    // JSON 시도
    try {
      const parsed = JSON.parse(message);
      return extractText(parsed);
    } catch { /* ignore */ }

    // Python repr 시도
    const parsed = parsePyRepr(message);
    if (parsed) return extractText(parsed);

    // role/content 패턴 직접 추출 (regex fallback)
    const contentMatch = message.match(/'content':\s*'((?:[^'\\]|\\.)*)'/);
    if (contentMatch) return contentMatch[1].replace(/\\n/g, '\n').replace(/\\'/g, "'").trim();

    // 더블쿼트 버전
    const contentMatch2 = message.match(/"content":\s*"((?:[^"\\]|\\.)*)"/);
    if (contentMatch2) return contentMatch2[1].replace(/\\n/g, '\n').replace(/\\"/g, '"').trim();
  }

  return null;
}

/** .jsonl 파일 파싱 → { sessionId, date, turns: [{role, text, ts}] } */
function parseSession(filePath) {
  const lines = readFileSync(filePath, 'utf-8').trim().split('\n');
  let sessionId = null;
  let cwd = null;
  const turns = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }

    if (!sessionId && entry.sessionId) sessionId = entry.sessionId;
    if (!cwd && entry.cwd) cwd = entry.cwd;

    const type = entry.type;
    if (type !== 'user' && type !== 'assistant') continue;

    const ts = entry.timestamp || '';
    const msgRaw = entry.message;
    if (!msgRaw) continue;

    const text = extractText(msgRaw);
    if (!text || text.length < MIN_CONTENT_LEN) continue;

    // 시스템 주입(긴 context prefix) 스킵 — user 메시지에서 RAG 등 주입된 데이터 제외
    // 실제 사용자 입력만 짧게 남김
    const trimmedText = text.slice(0, MAX_CONTENT_LEN);

    turns.push({ role: type, text: trimmedText, ts });
  }

  return { sessionId, cwd, turns };
}

/** 세션 → markdown 변환 */
function toMarkdown(session, fileDate) {
  const { sessionId, cwd, turns } = session;
  if (turns.length === 0) return null;

  const dateStr = fileDate;
  const shortId = (sessionId || 'unknown').slice(0, 8);
  const cwdLabel = cwd ? ` (cwd: ${cwd.replace(HOME, '~')})` : '';

  const lines = [
    `# Claude CLI 대화 — ${dateStr} [${shortId}]${cwdLabel}`,
    `_자동 수집: claude-cli-rag-sync.mjs_`,
    '',
  ];

  for (const turn of turns) {
    const timeStr = turn.ts ? turn.ts.slice(11, 16) : '';
    const roleLabel = turn.role === 'user' ? '**[사용자]**' : '**[Jarvis CLI]**';
    lines.push(`## ${roleLabel} ${timeStr}`);
    lines.push('');
    lines.push(turn.text);
    lines.push('');
    lines.push('---');
    lines.push('');
  }

  return lines.join('\n');
}

/** 상태 파일 로드/저장 */
function loadState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf-8'));
  } catch {
    return { processed: {} };
  }
}

function saveState(state) {
  mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

/** 메인 */
async function main() {
  if (!existsSync(CLAUDE_PROJECTS)) {
    log(`Claude projects dir not found: ${CLAUDE_PROJECTS}`);
    return;
  }
  mkdirSync(INBOX, { recursive: true });

  const state = loadState();
  let synced = 0;
  let skipped = 0;

  // 모든 project 디렉토리 순회
  const projectDirs = readdirSync(CLAUDE_PROJECTS).filter(d => {
    try { return statSync(join(CLAUDE_PROJECTS, d)).isDirectory(); } catch { return false; }
  });

  for (const projectDir of projectDirs) {
    const dir = join(CLAUDE_PROJECTS, projectDir);
    let files;
    try { files = readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { continue; }

    for (const file of files) {
      const filePath = join(dir, file);
      const stat = statSync(filePath);
      const mtime = stat.mtimeMs;
      const processedMtime = state.processed[filePath];

      // 이미 처리한 파일이고 수정 안 됐으면 스킵
      if (processedMtime && processedMtime >= mtime) {
        skipped++;
        continue;
      }

      // 너무 작은 파일 스킵 (1KB 미만)
      if (stat.size < 1024) {
        state.processed[filePath] = mtime;
        continue;
      }

      try {
        const session = parseSession(filePath);
        if (session.turns.length < 2) {
          state.processed[filePath] = mtime;
          continue;
        }

        // 날짜 추출: 파일 수정일 기준
        const fileDate = new Date(mtime).toISOString().slice(0, 10);
        const md = toMarkdown(session, fileDate);
        if (!md) {
          state.processed[filePath] = mtime;
          continue;
        }

        const shortId = (session.sessionId || file.replace('.jsonl', '')).slice(0, 8);
        const outFile = join(INBOX, `claude-cli-${fileDate}-${shortId}.md`);

        if (!DRY_RUN) {
          writeFileSync(outFile, md, 'utf-8');
        }
        log(`${DRY_RUN ? '[dry]' : 'saved'}: ${basename(outFile)} (${session.turns.length} turns)`);
        state.processed[filePath] = mtime;
        synced++;
      } catch (err) {
        log(`WARN: parse failed ${file}: ${err.message}`);
        state.processed[filePath] = mtime;
      }
    }
  }

  if (!DRY_RUN) saveState(state);
  log(`done — synced: ${synced}, skipped: ${skipped}`);
}

main().catch(err => {
  console.error('[cli-rag-sync] fatal:', err);
  process.exit(1);
});