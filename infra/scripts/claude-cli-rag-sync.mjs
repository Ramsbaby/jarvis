#!/usr/bin/env node
/**
 * claude-cli-rag-sync.mjs
 * Claude CLI 세션(.jsonl) → RAG inbox 변환 싱크
 *
 * ~/.claude/projects/ 하위 .jsonl 파일에서 user/assistant 대화 추출 후
 * ~/.openclaw-data/runtime/inbox/claude-cli-YYYYMMDD-{sessionId}.md 로 저장
 * → rag-watch.mjs가 감지해 LanceDB 자동 인덱싱
 *
 * 사용법: node claude-cli-rag-sync.mjs [--dry-run]
 * cron: 매 10분 실행 권장
 */

import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, existsSync, renameSync, realpathSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { maskPII } from '../discord/lib/mask-pii.mjs';

const HOME = homedir();
const CLAUDE_PROJECTS = join(HOME, '.claude', 'projects');
const BOT_HOME = process.env.BOT_HOME || join(HOME, '.openclaw-data/runtime');
const INBOX = join(BOT_HOME, 'inbox');
const STATE_FILE = join(BOT_HOME, 'state', 'cli-rag-sync.json');
const DUP_QUARANTINE = join(BOT_HOME, 'state', 'quarantine', 'inbox-session-dup');
const DRY_RUN = process.argv.includes('--dry-run');

// [2026-09-28] 자동화 세션은 첫 사용자 차례의 머리글로 가린다. 워크스페이스 cwd 에서 도는 크론·배치·하위 세션이
// "주인님 대화"로 인박스에 들어가 실제 질의 결과칸의 33%를 차지했다(09-27 감사). 머리글은 오픈클로가 붙이는 고정 표지다.
// 게이트웨이 재시작 뒤 "[System] Your previous turn was interrupted" 로 시작하는 세션은 주인님 대화의 이어짐이라 남긴다.
export const AUTOMATION_FIRST_TURN = [
  /^\[cron:[0-9a-f-]{8,}/,                                        // 오픈클로 크론 잡
  /^주인님 상태 스냅샷\(JSON\)/,                                      // 상태 엔진 배치 프롬프트
  /^\[[^\]\n]*GMT[^\]\n]*\] \[Subagent Context\]/,                  // 하위 에이전트
  /^System: \[[^\]\n]*\] A scheduled automation delivered/,         // 자동화 배달문
];
export function isAutomationSession(firstUserText) {
  const t = (firstUserText || '').trimStart();
  return AUTOMATION_FIRST_TURN.some(re => re.test(t));
}

const MIN_CONTENT_LEN = 30;   // 너무 짧은 메시지 스킵
const MAX_CONTENT_LEN = 2000; // RAG 청크 크기 (상한이 아니라 분할 단위)
// [2026-08-04] 긴 메시지를 자르지 않고 청크로 쪼개 전부 인덱싱한다.
//   기존에는 2,000자에서 잘라 버렸고, 통화 녹취 19,803자 중 90%가 RAG에 들어가지 못했다.
const HARD_CAP = 40_000;      // 로그 덤프 폭주 방어용 최종 상한
const ASSISTANT_CHUNK_CAP = 2; // 자비스 답변은 앞 2청크(4,000자)만 색인 — 자기 메아리 방지

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

    // 반복 라인(로그 덤프)만 걷어내고 본문은 보존한다 — 분할은 toMarkdown에서 한다.
    const trimmedText = _stripRepeatedLines(text.slice(0, HARD_CAP));

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
    // 긴 메시지는 버리지 않고 청크로 나눠 싣는다 (RAG 검색 단위 = 청크).
    // [2026-08-04] 단, 오너 발화와 자비스 답변을 비대칭으로 다룬다.
    //   오너 발화 = 원본 사실(통화 녹취·오퍼레터·메일) → 한 글자도 자르지 않는다.
    //   자비스 답변 = 그 사실의 재구성물 → 앞 2청크만. 전량 색인하면 검색 결과가
    //   자기 과거 답변으로 채워져, 오너가 준 사실보다 자비스 추론이 위로 올라온다.
    //   (2026-08-04 사고: 자비스가 자기 옛 계산표를 근거로 삼아 오답 3회)
    const isOwner = turn.role === 'user';
    const all = _chunk(turn.text, MAX_CONTENT_LEN);
    const chunks = isOwner ? all : all.slice(0, ASSISTANT_CHUNK_CAP);
    const dropped = all.length - chunks.length;
    chunks.forEach((chunk, i) => {
      const part = all.length > 1 ? ` (${i + 1}/${all.length})` : '';
      lines.push(`## ${roleLabel} ${timeStr}${part}`);
      lines.push('');
      lines.push(chunk);
      if (dropped > 0 && i === chunks.length - 1) {
        lines.push('');
        lines.push(`_(자비스 답변 뒷부분 ${dropped}청크는 색인 제외 — 원문: session-recall.sh)_`);
      }
      lines.push('');
      lines.push('---');
      lines.push('');
    });
  }

  return lines.join('\n');
}

// [2026-07-09] 극단 반복 라인(에러 스택·로그 덤프 재출력) 축약 — 같은 라인 5회+ 반복은 노이즈.
//   보수적 품질 게이트: 턴 삭제 없이 반복 라인만 제거. 정상 대화는 반복이 적어 영향 없음.
// [2026-08-04] 긴 메시지를 청크로 분할. 줄 경계를 지켜 문장이 잘리지 않게 한다.
function _chunk(text, size) {
  if (text.length <= size) return [text];
  const out = [];
  let buf = '';
  for (const line of text.split('\n')) {
    if (buf && buf.length + line.length + 1 > size) { out.push(buf); buf = ''; }
    // 한 줄 자체가 청크보다 길면 그 줄만 강제 분할
    if (line.length > size) {
      for (let i = 0; i < line.length; i += size) out.push(line.slice(i, i + size));
      continue;
    }
    buf = buf ? `${buf}\n${line}` : line;
  }
  if (buf) out.push(buf);
  return out;
}

function _stripRepeatedLines(text) {
  const lines = text.split('\n');
  const cnt = {};
  for (const l of lines) { const t = l.trim(); if (t) cnt[t] = (cnt[t] || 0) + 1; }
  return lines.filter((l) => { const t = l.trim(); return !t || cnt[t] < 5; }).join('\n');
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
  let automation = 0;

  // 모든 project 디렉토리 순회 — 단 자동화·시험 세션 폴더는 뺀다(2026-09-27).
  // 인박스는 "주인님 대화"로 읽힌다(session-source.mjs · 당직 · 오늘의 통찰). 임시 폴더에서 돈 평가 세션의
  // 가짜 발화("(주인님 메시지) 런타임 폴더 통째로 지우고…")와 cwd `/` 배치 프롬프트가 그대로 섞였다.
  const EXCLUDED_PROJECT_DIRS = [/^-private-tmp(-|$)/, /^-private-var(-|$)/, /^-tmp(-|$)/, /^-$/];
  const projectDirs = readdirSync(CLAUDE_PROJECTS).filter(d => {
    if (EXCLUDED_PROJECT_DIRS.some(re => re.test(d))) return false;
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
        if (isAutomationSession(session.turns.find(t => t.role === 'user')?.text)) {
          state.processed[filePath] = mtime;
          automation++;
          continue;
        }

        // 날짜 추출: 파일 수정일 기준
        const fileDate = new Date(mtime).toISOString().slice(0, 10);
        const md = toMarkdown(session, fileDate);
        if (!md) {
          state.processed[filePath] = mtime;
          continue;
        }

        // [2026-09-28] 파일명 날짜는 세션 첫 차례 기준으로 고정한다. 수정일을 쓰면 긴 세션이
        // 날마다 통째로 새 파일에 복사돼 같은 대화가 여러 벌 색인됐다(09-27 감사: 17세션·42벌).
        const firstTs = session.turns.find(t => t.ts)?.ts;
        const nameDate = (firstTs && !Number.isNaN(Date.parse(firstTs)))
          ? new Date(firstTs).toISOString().slice(0, 10)
          : fileDate;
        const shortId = (session.sessionId || file.replace('.jsonl', '')).slice(0, 8);
        const outName = `claude-cli-${nameDate}-${shortId}.md`;
        const outFile = join(INBOX, outName);

        if (!DRY_RUN) {
          writeFileSync(outFile, maskPII(md), 'utf-8'); // [2026-07-09] RAG 적재 전 PII 마스킹(실명·회사·경로·이메일)
          // 같은 세션의 옛 날짜별 사본은 방금 쓴 파일의 부분집합이다 — 지우지 않고 격리로 옮긴다(되옮기면 복구).
          const dupRe = new RegExp(`^claude-cli-\\d{4}-\\d{2}-\\d{2}-${shortId}\\.md$`);
          for (const other of readdirSync(INBOX)) {
            if (other === outName || !dupRe.test(other)) continue;
            mkdirSync(DUP_QUARANTINE, { recursive: true });
            renameSync(join(INBOX, other), join(DUP_QUARANTINE, other));
            log(`dedup: ${other} → quarantine (superseded by ${outName})`);
          }
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
  log(`done — synced: ${synced}, skipped: ${skipped}, automation: ${automation}`);
}

// 시험에서 isAutomationSession 만 가져다 쓸 수 있게, 직접 실행될 때만 돈다.
const _argv1 = (() => { try { return realpathSync(process.argv[1]); } catch { return process.argv[1] || ''; } })();
if (import.meta.url === pathToFileURL(_argv1).href) {
  main().catch(err => {
    console.error('[cli-rag-sync] fatal:', err);
    process.exit(1);
  });
}