#!/usr/bin/env node
/**
 * wiki-ingest-claude-app.mjs — Claude macOS 앱 export zip → 위키 주입
 *
 * 사용자가 claude.ai > Settings > Privacy > Export data로 받은 zip을
 * ~/Downloads/ 에서 감지하여 conversations.json 파싱 → Haiku로 facts 추출
 * → addFactToWiki(source: 'claude-app')로 위키 주입.
 *
 * Surface Memory Boundary 정책의 macOS 앱 자동 쓰기 경로 보완.
 *
 * Usage:
 *   node wiki-ingest-claude-app.mjs                     # ~/Downloads 자동 감지
 *   node wiki-ingest-claude-app.mjs <zip-path>          # 특정 zip 지정
 *   JARVIS_INGEST_DRYRUN=1 node wiki-ingest-claude-app.mjs  # 추출만, 위키 미주입
 *
 * Output (stdout, JSON):
 *   { status: 'ok',      zipFile, conversations, factsExtracted, factsWritten }
 *   { status: 'skipped', reason }
 *   { status: 'error',   error }
 *
 * Exit codes: 항상 0.
 * Log: ~/jarvis/runtime/logs/wiki-ingest-claude-app.log
 */

import {
  readFileSync, existsSync, readdirSync, statSync,
  appendFileSync, mkdirSync, writeFileSync, renameSync,
} from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { addFactToWiki } from '../discord/lib/wiki-engine.mjs';

const HOME              = homedir();
const BOT_HOME          = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');
const DOWNLOADS_DIR     = process.env.CLAUDE_EXPORT_DIR || join(HOME, 'Downloads');
const PROCESSED_DIR     = join(DOWNLOADS_DIR, 'claude-export-processed');
const LOG_FILE          = join(BOT_HOME, 'logs', 'wiki-ingest-claude-app.log');
const COOLDOWN_FILE     = join(BOT_HOME, 'state', 'wiki-ingest-claude-app-cooldown.json');

const CLAUDE_BIN        = process.env.CLAUDE_BINARY || join(HOME, '.local/bin/claude');
const MODEL             = 'claude-haiku-4-5-20251001';
const HAIKU_TIMEOUT_MS  = 60_000;
const MAX_INPUT_CHARS   = 12_000;
const MAX_CONVERSATIONS = parseInt(process.env.MAX_CONVERSATIONS || '50', 10);
const DRYRUN            = process.env.JARVIS_INGEST_DRYRUN === '1';

// PII 마스킹 패턴 (import 전 본문 정화)
const PII_PATTERNS = [
  { re: /sk-ant-[a-zA-Z0-9_-]{20,}/g,   sub: 'sk-ant-***' },
  { re: /sk-[a-zA-Z0-9]{20,}/g,         sub: 'sk-***' },
  { re: /\b\d{3}-\d{4}-\d{4}\b/g,        sub: '010-****-****' },
  { re: /[\w.+-]+@[\w-]+\.[\w.-]+/g,     sub: (m) => m.replace(/^(.).+?(@.+)$/, '$1***$2') },
];

function kstTimestamp() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
}

function log(level, msg, meta = {}) {
  const ts = kstTimestamp();
  const metaStr = Object.keys(meta).length ? ' ' + JSON.stringify(meta) : '';
  const line = `[${ts} KST] [wiki-ingest-app] [${level.toUpperCase()}] ${msg}${metaStr}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    appendFileSync(LOG_FILE, line);
  } catch {}
  if (level === 'error' || process.env.DEBUG) process.stderr.write(line);
}

function maskPII(text) {
  let out = text;
  for (const { re, sub } of PII_PATTERNS) {
    out = out.replace(re, sub);
  }
  return out;
}

function findExportZip() {
  if (!existsSync(DOWNLOADS_DIR)) return null;
  const files = readdirSync(DOWNLOADS_DIR)
    .filter((f) => /^data-\d{4}-\d{2}-\d{2}.*\.zip$/i.test(f) || /claude.*export.*\.zip$/i.test(f))
    .map((f) => ({ name: f, path: join(DOWNLOADS_DIR, f), mtime: statSync(join(DOWNLOADS_DIR, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  return files[0]?.path || null;
}

function unzipToTmp(zipPath) {
  const tmpDir = join(tmpdir(), `claude-export-${Date.now()}`);
  mkdirSync(tmpDir, { recursive: true });
  const r = spawnSync('unzip', ['-q', '-o', zipPath, '-d', tmpDir]);
  if (r.status !== 0) throw new Error(`unzip failed: ${r.stderr?.toString() || 'unknown'}`);
  return tmpDir;
}

function findConversationsJson(dir) {
  const entries = readdirSync(dir, { withFileTypes: true });
  for (const e of entries) {
    if (e.isFile() && e.name === 'conversations.json') return join(dir, e.name);
    if (e.isDirectory()) {
      const sub = findConversationsJson(join(dir, e.name));
      if (sub) return sub;
    }
  }
  return null;
}

function flattenConversation(conv) {
  const title = conv.name || conv.title || '(untitled)';
  const messages = conv.chat_messages || conv.messages || [];
  const lines = [`# ${title}`];
  for (const m of messages) {
    const role = m.sender || m.role || 'unknown';
    const content = typeof m.text === 'string'
      ? m.text
      : Array.isArray(m.content)
        ? m.content.map((c) => c?.text || '').join('\n')
        : String(m.content || '');
    if (content.trim()) lines.push(`\n**${role}**: ${content.trim()}`);
  }
  return lines.join('\n');
}

function extractFactsWithHaiku(text) {
  const truncated = text.length > MAX_INPUT_CHARS ? text.slice(-MAX_INPUT_CHARS) : text;
  const prompt = `다음은 Claude macOS 앱에서 주인님과 Claude가 나눈 대화입니다.
이 대화에서 미래 세션이 알아야 할 **확정된 사실·결정·선호**만 한 줄씩 추출해주세요.

규칙:
- 추측·가설·일반 지식 제외. 주인님이 명시한 사실/결정/선호만.
- 한 줄 한 사실. 6~160자. 한국어.
- 도메인 prefix: [career] [family] [health] [knowledge] [meta] [ops] 중 하나.
- 코드·로그·임시 디버깅 출력 제외.
- 결과는 JSON 배열만: [{"domain":"career","fact":"..."}]

대화:
${truncated}

JSON 배열만:`;

  const r = spawnSync(CLAUDE_BIN, ['--print', '--model', MODEL, '--bare'], {
    input: prompt,
    timeout: HAIKU_TIMEOUT_MS,
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    log('warn', 'haiku failed', { stderr: r.stderr?.slice(0, 200) });
    return [];
  }
  const out = r.stdout?.trim() || '';
  const match = out.match(/\[[\s\S]*\]/);
  if (!match) return [];
  try {
    const arr = JSON.parse(match[0]);
    return Array.isArray(arr) ? arr.filter((x) => x?.domain && x?.fact) : [];
  } catch {
    return [];
  }
}

async function main() {
  const zipPath = process.argv[2] || findExportZip();
  if (!zipPath) {
    console.log(JSON.stringify({ status: 'skipped', reason: 'no export zip found' }));
    return;
  }
  if (!existsSync(zipPath)) {
    console.log(JSON.stringify({ status: 'error', error: `zip not found: ${zipPath}` }));
    return;
  }

  log('info', 'start', { zipPath, dryrun: DRYRUN });

  let tmpDir;
  try {
    tmpDir = unzipToTmp(zipPath);
  } catch (e) {
    log('error', 'unzip failed', { err: e.message });
    console.log(JSON.stringify({ status: 'error', error: e.message }));
    return;
  }

  const convPath = findConversationsJson(tmpDir);
  if (!convPath) {
    log('warn', 'no conversations.json in zip');
    console.log(JSON.stringify({ status: 'skipped', reason: 'no conversations.json' }));
    return;
  }

  let conversations;
  try {
    conversations = JSON.parse(readFileSync(convPath, 'utf8'));
  } catch (e) {
    log('error', 'parse conversations.json failed', { err: e.message });
    console.log(JSON.stringify({ status: 'error', error: 'parse failed: ' + e.message }));
    return;
  }

  if (!Array.isArray(conversations)) {
    log('warn', 'conversations.json not array');
    console.log(JSON.stringify({ status: 'skipped', reason: 'invalid format' }));
    return;
  }

  const recent = conversations
    .filter((c) => c.chat_messages?.length || c.messages?.length)
    .sort((a, b) => new Date(b.updated_at || 0) - new Date(a.updated_at || 0))
    .slice(0, MAX_CONVERSATIONS);

  log('info', 'processing', { totalConvs: conversations.length, processing: recent.length });

  let factsExtracted = 0, factsWritten = 0;
  for (const conv of recent) {
    const flat = maskPII(flattenConversation(conv));
    const facts = extractFactsWithHaiku(flat);
    factsExtracted += facts.length;
    for (const { domain, fact } of facts) {
      if (DRYRUN) continue;
      try {
        const r = await addFactToWiki({ domain, fact, source: 'claude-app' });
        if (r?.written) factsWritten++;
      } catch (e) {
        log('warn', 'addFactToWiki failed', { err: e.message, fact: fact.slice(0, 60) });
      }
    }
  }

  // 처리 완료 zip은 별도 디렉토리로 이동 (중복 import 차단)
  if (!DRYRUN) {
    try {
      mkdirSync(PROCESSED_DIR, { recursive: true });
      const dst = join(PROCESSED_DIR, basename(zipPath));
      renameSync(zipPath, dst);
      log('info', 'moved processed zip', { dst });
    } catch (e) {
      log('warn', 'move failed', { err: e.message });
    }
  }

  log('info', 'done', { factsExtracted, factsWritten, dryrun: DRYRUN });
  console.log(JSON.stringify({
    status: 'ok',
    zipFile: basename(zipPath),
    conversations: recent.length,
    factsExtracted,
    factsWritten,
    dryrun: DRYRUN,
  }));
}

main().catch((e) => {
  log('error', 'fatal', { err: e.message, stack: e.stack?.split('\n').slice(0, 3).join(' | ') });
  console.log(JSON.stringify({ status: 'error', error: e.message }));
  process.exit(0); // 항상 0 (cron 보호)
});
