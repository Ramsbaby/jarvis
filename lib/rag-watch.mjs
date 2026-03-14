#!/usr/bin/env node
/**
 * rag-watch.mjs — RAG Watcher daemon
 *
 * Real-time Jarvis-Vault + discord-history → LanceDB sync.
 * Watches ~/Jarvis-Vault/ and ~/.jarvis/context/discord-history/ for .md changes
 * → immediate RAGEngine.indexFile()
 *
 * Runs as a persistent LaunchAgent (ai.jarvis.rag-watcher).
 * Loads OPENAI_API_KEY from ~/.jarvis/discord/.env
 */

import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { existsSync, mkdirSync } from 'node:fs';
import { readFile, writeFile, rename, stat as fsStat, unlink, open as fsOpen } from 'node:fs/promises';
import { existsSync as fsExistsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { config } from 'dotenv';
import chokidar from 'chokidar';
import { RAGEngine } from './rag-engine.mjs';

const require = createRequire(import.meta.url);

// ─── Config ───────────────────────────────────────────────────────────────────

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const VAULT_PATH = join(homedir(), 'Jarvis-Vault');
const DISCORD_HISTORY_PATH = join(BOT_HOME, 'context', 'discord-history');
const INBOX_PATH = join(BOT_HOME, 'inbox');
const EVENT_BUS_PATH = join(BOT_HOME, 'state', 'events');
const ENV_PATH = join(BOT_HOME, 'discord', '.env');
const DB_PATH = join(BOT_HOME, 'rag', 'lancedb');
const PROCESSED_DB_PATH = join(BOT_HOME, 'state', 'rag-processed.db');

// Debounce: skip same-file re-index within 5 seconds
const DEBOUNCE_MS = 5000;
// rag-index 실행 중 충돌 회피: PID 파일 확인 후 재시도 대기
const INDEX_BUSY_RETRY_MS = 35_000; // rag-index가 끝날 때까지 대기 후 재시도

// index-state.json: shared with rag-index.mjs to prevent duplicate indexing
const STATE_FILE = join(BOT_HOME, 'rag', 'index-state.json');
// rag-index PID 센티넬: 실행 중이면 충돌 회피
const RAG_INDEX_PID_FILE = join(BOT_HOME, 'state', 'rag-index.pid');
// rag-watch 인덱싱 lock: rag-index.mjs가 동시 쓰기를 감지하는 데 사용 (레거시)
const RAG_WATCH_LOCK = join(BOT_HOME, 'state', 'rag-watch-indexing.lock');
import { writeFileSync, unlinkSync } from 'node:fs';
function setWatchLock() { try { writeFileSync(RAG_WATCH_LOCK, String(Date.now())); } catch {} }
function clearWatchLock() { try { unlinkSync(RAG_WATCH_LOCK); } catch {} }

// ─── Global RAG write mutex (/tmp/jarvis-rag-write.lock) ──────────────────────
// Shared with rag-index.mjs. Prevents concurrent LanceDB writes.
// rag-watch holds the lock only for the duration of a single indexFile() call.
const RAG_WRITE_LOCK       = '/tmp/jarvis-rag-write.lock';
const WRITE_LOCK_WAIT_MS   = 30_000; // 30s max wait before skip + warn
const WRITE_LOCK_POLL_MS   = 200;    // poll interval
const WRITE_LOCK_STALE_MS  = 120_000; // 2min stale auto-cleanup

let _writeLockFd = null; // currently held FileHandle (null = not held)

async function _tryAcquireGlobalWriteLock() {
  // Stale lock cleanup (handles crash without cleanup)
  try {
    const st = await fsStat(RAG_WRITE_LOCK);
    if (Date.now() - st.mtimeMs > WRITE_LOCK_STALE_MS) {
      try { await unlink(RAG_WRITE_LOCK); } catch { /* race ok */ }
    }
  } catch { /* file doesn't exist — OK */ }

  try {
    // O_EXCL: atomic on POSIX, fails with EEXIST if already locked
    _writeLockFd = await fsOpen(RAG_WRITE_LOCK, 'wx');
    await _writeLockFd.writeFile(`${process.pid}\n`);
    return true;
  } catch (e) {
    if (e.code === 'EEXIST') return false;
    throw e;
  }
}

async function acquireGlobalWriteLock() {
  const deadline = Date.now() + WRITE_LOCK_WAIT_MS;
  while (Date.now() < deadline) {
    if (await _tryAcquireGlobalWriteLock()) return true;
    await new Promise(r => setTimeout(r, WRITE_LOCK_POLL_MS));
  }
  return false; // timeout
}

function releaseGlobalWriteLock() {
  try {
    if (_writeLockFd) { _writeLockFd.close().catch(() => {}); _writeLockFd = null; }
  } catch {}
  try { unlinkSync(RAG_WRITE_LOCK); } catch {}
}

// Best-effort cleanup on process exit (LaunchAgent will restart)
process.on('exit', releaseGlobalWriteLock);

let _tmpSeq = 0; // unique suffix per concurrent updateIndexState call

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Update index-state.json with the file's current mtime.
 * Uses atomic write (tmp + rename) to avoid corruption.
 */
async function updateIndexState(filePath) {
  let state = {};
  try {
    const raw = await readFile(STATE_FILE, 'utf-8');
    state = JSON.parse(raw);
  } catch {
    // File doesn't exist or is corrupt — start fresh
  }

  try {
    const s = await fsStat(filePath);
    state[filePath] = s.mtimeMs;
  } catch {
    // File was deleted between indexing and state update — skip
    return;
  }

  const tmpFile = STATE_FILE + `.tmp.${process.pid}.${_tmpSeq++}`;
  await writeFile(tmpFile, JSON.stringify(state, null, 2));
  await rename(tmpFile, STATE_FILE);
}

/**
 * Initialize SQLite DB for inbox processed-file tracking.
 * Returns an object with isProcessed(path) and markDone(path) / markError(path, msg).
 * Uses better-sqlite3 (CommonJS) via createRequire.
 */
function initProcessedDb() {
  const BetterSqlite3 = require(
    join(BOT_HOME, 'discord', 'node_modules', 'better-sqlite3')
  );
  const db = new BetterSqlite3(PROCESSED_DB_PATH);
  db.exec(`
    CREATE TABLE IF NOT EXISTS processed_files (
      path         TEXT PRIMARY KEY,
      processed_at TEXT NOT NULL,
      status       TEXT NOT NULL CHECK(status IN ('done', 'error')),
      error_msg    TEXT
    )
  `);

  const stmtGet    = db.prepare('SELECT status FROM processed_files WHERE path = ?');
  const stmtUpsert = db.prepare(`
    INSERT INTO processed_files (path, processed_at, status, error_msg)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
      processed_at = excluded.processed_at,
      status       = excluded.status,
      error_msg    = excluded.error_msg
  `);

  return {
    isProcessed(filePath) {
      const row = stmtGet.get(filePath);
      return row?.status === 'done';
    },
    markDone(filePath) {
      stmtUpsert.run(filePath, new Date().toISOString(), 'done', null);
    },
    markError(filePath, errorMsg) {
      stmtUpsert.run(filePath, new Date().toISOString(), 'error', String(errorMsg));
    },
  };
}

function ts() {
  return new Date().toISOString();
}

function log(msg) {
  console.log(`[${ts()}] [rag-watch] ${msg}`);
}

function warn(msg) {
  console.warn(`[${ts()}] [rag-watch] WARN: ${msg}`);
}

function err(msg) {
  console.error(`[${ts()}] [rag-watch] ERROR: ${msg}`);
}

// ─── Bootstrap ────────────────────────────────────────────────────────────────

// Load .env before anything touches process.env
config({ path: ENV_PATH });

if (!process.env.OPENAI_API_KEY) {
  err(`OPENAI_API_KEY not set. Check ${ENV_PATH}`);
  process.exit(1);
}

if (!existsSync(VAULT_PATH)) {
  err(`Vault directory not found: ${VAULT_PATH}`);
  err('Create ~/Jarvis-Vault/ first, then restart this daemon.');
  process.exit(1);
}

// discord-history 디렉토리: 없으면 직접 생성 (첫 대화 전 시작 시 감시 누락 방지)
if (!existsSync(DISCORD_HISTORY_PATH)) {
  mkdirSync(DISCORD_HISTORY_PATH, { recursive: true });
  log(`discord-history created: ${DISCORD_HISTORY_PATH}`);
}

// inbox 디렉토리: 없으면 생성 (watcher 시작 전 보장)
if (!existsSync(INBOX_PATH)) {
  mkdirSync(INBOX_PATH, { recursive: true });
  log(`inbox created: ${INBOX_PATH}`);
}

// event-bus 디렉토리: 없으면 생성 (이벤트 감시 전 보장)
if (!existsSync(EVENT_BUS_PATH)) {
  mkdirSync(EVENT_BUS_PATH, { recursive: true });
  log(`event-bus created: ${EVENT_BUS_PATH}`);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  log(`Starting — vault: ${VAULT_PATH}`);
  log(`Starting — discord-history: ${DISCORD_HISTORY_PATH}`);
  log(`Starting — inbox: ${INBOX_PATH}`);

  const engine = new RAGEngine(DB_PATH);
  await engine.init();

  // ── Event-bus trigger 설정 ──────────────────────────────────────────────────
  const tasksRaw = readFileSync(join(BOT_HOME, 'config', 'tasks.json'), 'utf-8');
  const triggerMap = {}; // { eventName: { id, debounce_s } }
  for (const t of (JSON.parse(tasksRaw).tasks || [])) {
    if (t.event_trigger) triggerMap[t.event_trigger] = { id: t.id, debounce_s: t.event_trigger_debounce_s ?? 300 };
  }
  const ALLOWED_EVENTS = new Set(Object.keys(triggerMap));
  const eventDebounce = new Map(); // eventName → lastTriggeredMs
  log(`Event triggers loaded: ${ALLOWED_EVENTS.size} events`);

  // SQLite DB for inbox processed-file tracking
  const processedDb = initProcessedDb();
  log(`Processed-files DB ready: ${PROCESSED_DB_PATH}`);

  const stats = await engine.getStats();
  log(`RAG DB ready — ${stats.totalChunks} chunks from ${stats.totalSources} sources`);

  // Warm-up: user-memory-*.md 파일은 ignoreInitial=true로 인해 시작 시 스킵됨
  // 재시작(메모리 500MB 자가 재시작 포함) 후에도 최신 user-memory를 즉시 인덱싱
  try {
    const { readdir } = await import('node:fs/promises');
    const files = await readdir(DISCORD_HISTORY_PATH);
    const userMemFiles = files.filter(f => f.startsWith('user-memory-') && f.endsWith('.md'));
    if (userMemFiles.length > 0) {
      log(`Warm-up: indexing ${userMemFiles.length} user-memory file(s)`);
      for (const f of userMemFiles) {
        const fp = join(DISCORD_HISTORY_PATH, f);
        try {
          const gotLock = await acquireGlobalWriteLock();
          if (!gotLock) {
            warn(`Warm-up: write lock timeout (30s) — skipping ${f}`);
            continue;
          }
          setWatchLock();
          try {
            const chunks = await engine.indexFile(fp);
            log(`Warm-up indexed: ${f} → ${chunks} chunks`);
          } finally {
            clearWatchLock();
            releaseGlobalWriteLock();
          }
        } catch (e) {
          warn(`Warm-up failed: ${f} — ${e.message}`);
        }
      }
    }
  } catch (e) {
    warn(`Warm-up scan failed: ${e.message}`);
  }

  // Debounce map: filePath → timestamp of last indexing start
  const lastProcessed = new Map();

  // ─── File event handler ───────────────────────────────────────────────────

  /** rag-index.mjs가 실행 중인지 확인 (PID 파일 기반) */
  function _isRagIndexRunning() {
    if (!fsExistsSync(RAG_INDEX_PID_FILE)) return false;
    try {
      const pid = parseInt(readFileSync(RAG_INDEX_PID_FILE, 'utf-8').trim(), 10);
      if (!pid) return false;
      process.kill(pid, 0); // 프로세스 존재 확인 (0 = no-op signal)
      return true;
    } catch {
      return false; // ESRCH: 프로세스 없음 (stale PID 파일) → not running
    }
  }

  async function handleChange(event, filePath) {
    const now = Date.now();
    const last = lastProcessed.get(filePath) || 0;

    if (now - last < DEBOUNCE_MS) {
      log(`Debounce skip (${event}): ${filePath}`);
      return;
    }

    // rag-index 실행 중이면 락 충돌 회피: INDEX_BUSY_RETRY_MS 후 재시도
    if (_isRagIndexRunning()) {
      log(`rag-index busy — deferring ${filePath.split('/').pop()} by ${INDEX_BUSY_RETRY_MS / 1000}s`);
      setTimeout(() => handleChange(event, filePath), INDEX_BUSY_RETRY_MS);
      return;
    }

    lastProcessed.set(filePath, now);

    // Acquire global write lock — wait up to 30s (rag-index may be mid-run)
    const gotLock = await acquireGlobalWriteLock();
    if (!gotLock) {
      warn(`Write lock timeout (30s) — skipping ${filePath.split('/').pop()} (${event})`);
      return;
    }

    setWatchLock();
    try {
      const chunks = await engine.indexFile(filePath);
      log(`Indexed (${event}): ${filePath} → ${chunks} chunks`);
      // Update index-state.json so rag-index cron skips this file (M1: dedup)
      await updateIndexState(filePath).catch((stateErr) =>
        warn(`index-state update failed: ${filePath} — ${stateErr.message}`)
      );
    } catch (indexErr) {
      err(`Failed to index (${event}): ${filePath} — ${indexErr.message}`);
    } finally {
      clearWatchLock();
      releaseGlobalWriteLock();
    }
  }

  async function handleEventFile(filePath) {
    try {
      const raw = await readFile(filePath, 'utf-8');
      const { event } = JSON.parse(raw);
      if (!ALLOWED_EVENTS.has(event)) {
        warn(`Rejected unknown event: ${event} (whitelist: ${[...ALLOWED_EVENTS].join(', ')})`);
        return;
      }
      const task = triggerMap[event];
      const now = Date.now();
      const last = eventDebounce.get(event) ?? 0;
      if (now - last < task.debounce_s * 1000) {
        log(`Event debounced: ${event} → ${task.id} (${Math.round((task.debounce_s * 1000 - (now - last)) / 1000)}s remaining)`);
        return;
      }
      eventDebounce.set(event, now);
      spawn('/bin/bash', [join(BOT_HOME, 'bin', 'bot-cron.sh'), task.id], {
        detached: true,
        stdio: 'ignore',
        env: { ...process.env, HOME: process.env.HOME || homedir() },
      }).unref();
      log(`Event triggered: ${event} → ${task.id}`);
    } catch (e) {
      err(`Event file error: ${filePath.split('/').pop()} — ${e.message}`);
    } finally {
      // 처리 완료(성공/실패 무관) 후 파일 삭제 (중복 처리 방지)
      await unlink(filePath).catch(() => {});
    }
  }

  // ─── Chokidar watcher ────────────────────────────────────────────────────

  // ─── Inbox file handler (SQLite-tracked, no mtime) ───────────────────────

  /**
   * Handles add/change events for inbox/ files.
   * Skips if already recorded as 'done' in processed_files DB.
   * Records result (done/error) after indexing.
   */
  async function handleInboxFile(event, filePath) {
    if (processedDb.isProcessed(filePath)) {
      log(`Inbox skip (already done): ${filePath.split('/').pop()}`);
      return;
    }

    // rag-index 실행 중이면 동일하게 락 회피
    if (_isRagIndexRunning()) {
      log(`rag-index busy — deferring inbox ${filePath.split('/').pop()} by ${INDEX_BUSY_RETRY_MS / 1000}s`);
      setTimeout(() => handleInboxFile(event, filePath), INDEX_BUSY_RETRY_MS);
      return;
    }

    // Acquire global write lock — wait up to 30s (rag-index may be mid-run)
    const gotLock = await acquireGlobalWriteLock();
    if (!gotLock) {
      warn(`Write lock timeout (30s) — skipping inbox ${filePath.split('/').pop()} (${event})`);
      return;
    }

    setWatchLock();
    try {
      const chunks = await engine.indexFile(filePath);
      processedDb.markDone(filePath);
      log(`Inbox indexed (${event}): ${filePath.split('/').pop()} → ${chunks} chunks`);
    } catch (indexErr) {
      processedDb.markError(filePath, indexErr.message);
      err(`Inbox index failed (${event}): ${filePath.split('/').pop()} — ${indexErr.message}`);
    } finally {
      clearWatchLock();
      releaseGlobalWriteLock();
    }
  }

  // Note: chokidar v5 does not resolve '**' globs against an absolute base path.
  // Watch the directory directly and filter .md in handlers.
  // DISCORD_HISTORY_PATH는 위에서 없으면 생성하므로 filter 불필요
  const watchTargets = [VAULT_PATH, DISCORD_HISTORY_PATH, INBOX_PATH, EVENT_BUS_PATH];
  const watcher = chokidar.watch(watchTargets, {
    // dotfile 필터: 파일/폴더 이름만 검사 (전체 경로의 .jarvis 등은 무시 안 함)
    ignored: (filePath) => {
      const basename = filePath.split('/').pop();
      return basename.startsWith('.') && basename !== '.jarvis';
    },
    persistent: true,
    ignoreInitial: true,            // skip initial scan (cron handles full index)
    awaitWriteFinish: {
      stabilityThreshold: 500,
      pollInterval: 100,
    },
  });

  // ─── Exclusion filter (mirrors rag-index.mjs exclusions) ────────────────────
  // Vault 내 개발/아키텍처 문서는 실시간 인덱싱에서도 제외해 DB 오염 방지.
  const RAG_EXCLUDED_DIRS = new Set(['adr', 'architecture']);
  const RAG_EXCLUDED_FILES = new Set([
    'ARCHITECTURE.md',
    'upgrade-roadmap-v2.md',
    'docdd-roadmap.md',
    'obsidian-enhancement-plan.md',
    'PKM-Obsidian-Research.md',
    'session-changelog.md',
    'ADR-INDEX.md',
  ]);

  function isExcluded(filePath) {
    const parts = filePath.split('/');
    const basename = parts[parts.length - 1];
    // 파일명 직접 제외
    if (RAG_EXCLUDED_FILES.has(basename)) return true;
    // ADR- 접두사는 adr/ 디렉토리 내에서만 제외 (전역 오탐 방지)
    if (filePath.includes('/adr/') && basename.startsWith('ADR-')) return true;
    // 제외 디렉토리 포함 여부 (경로 세그먼트 단위 검사)
    return parts.some((seg) => RAG_EXCLUDED_DIRS.has(seg));
  }

  const onlyMd = (handler) => (filePath) => {
    if (!filePath.endsWith('.md')) return;
    if (isExcluded(filePath)) {
      log(`Skip excluded: ${filePath.split('/').pop()}`);
      return;
    }
    handler(filePath);
  };

  /**
   * Determine whether a file path belongs to inbox/.
   * inbox files use SQLite tracking, not mtime.
   */
  function isInboxFile(filePath) {
    return filePath.startsWith(INBOX_PATH + '/') || filePath === INBOX_PATH;
  }

  watcher
    .on('add', (filePath) => {
      if (filePath.startsWith(EVENT_BUS_PATH + '/') && filePath.endsWith('.json')) {
        handleEventFile(filePath);
        return;
      }
      if (!filePath.endsWith('.md')) return;
      if (isInboxFile(filePath)) {
        handleInboxFile('add', filePath);
      } else {
        onlyMd((fp) => handleChange('add', fp))(filePath);
      }
    })
    .on('change', (filePath) => {
      if (!filePath.endsWith('.md')) return;
      if (isInboxFile(filePath)) {
        handleInboxFile('change', filePath);
      } else {
        onlyMd((fp) => handleChange('change', fp))(filePath);
      }
    })
    .on('unlink', onlyMd(async (filePath) => {
      try {
        await engine.deleteBySource(filePath);
        log(`File deleted: ${filePath} — removed from index`);
      } catch (e) {
        warn(`File deleted: ${filePath} — index removal failed: ${e.message}`);
      }
    }))
    .on('error', (watchErr) => {
      err(`Watcher error: ${watchErr.message}`);
    })
    .on('ready', () => {
      log(`Watcher ready — watching: ${watchTargets.join(', ')}`);
    });

  // ─── Graceful shutdown ───────────────────────────────────────────────────

  async function shutdown(signal) {
    log(`Received ${signal} — shutting down gracefully`);
    await watcher.close();
    log('Watcher closed. Goodbye.');
    process.exit(0);
  }

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  // ─── 메모리 자가 감시 (Arrow native 메모리 누수 대응) ─────────────────────
  // LanceDB Arrow 버퍼는 Node.js GC 밖에서 할당되어 자연 회수 안 됨.
  // 500MB 초과 시 자가 종료 → LaunchAgent가 즉시 재시작.
  const MEM_LIMIT_MB = 500;
  const MEM_CHECK_INTERVAL_MS = 60_000; // 1분마다 체크

  setInterval(() => {
    const heapMB = process.memoryUsage().rss / 1024 / 1024;
    if (heapMB > MEM_LIMIT_MB) {
      log(`메모리 한도 초과 (${heapMB.toFixed(0)}MB > ${MEM_LIMIT_MB}MB) — 자가 재시작`);
      watcher.close().finally(() => process.exit(0));
    }
  }, MEM_CHECK_INTERVAL_MS);
}

main().catch((fatalErr) => {
  err(`Fatal: ${fatalErr.message}`);
  err(fatalErr.stack);
  process.exit(1);
});
