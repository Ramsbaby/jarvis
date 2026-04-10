#!/usr/bin/env node
/**
 * rag-watch.mjs — RAG Watcher daemon (Queue Writer mode)
 *
 * Watches Vault, discord-history, inbox for .md changes and
 * appends them to state/rag-write-queue.jsonl.
 * rag-index.mjs (cron, 매시간 :30) 가 유일한 LanceDB writer.
 *
 * Runs as a persistent LaunchAgent (ai.jarvis.rag-watcher).
 * Path resolution via paths.mjs
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { existsSync, mkdirSync } from 'node:fs';
import { readFile, appendFile, unlink } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { config } from 'dotenv';
import chokidar from 'chokidar';
import { INFRA_HOME, STATE_DIR, ensureDirs } from './paths.mjs';

ensureDirs();

// ─── Config ───────────────────────────────────────────────────────────────────

const BOT_HOME             = INFRA_HOME;
const VAULT_PATH           = process.env.VAULT_DIR || join(homedir(), 'vault');
const DISCORD_HISTORY_PATH = join(BOT_HOME, 'context', 'discord-history');
const INBOX_PATH           = join(BOT_HOME, 'inbox');
const EVENT_BUS_PATH       = join(STATE_DIR, 'events');
const ENV_PATH             = join(BOT_HOME, 'discord', '.env');

// 큐 파일: rag-index.mjs가 읽어서 소비
const QUEUE_FILE = join(STATE_DIR, 'rag-write-queue.jsonl');

// Debounce: 같은 파일 5초 내 중복 큐잉 방지
const DEBOUNCE_MS = 5000;

// ─── Queue Writer ──────────────────────────────────────────────────────────────

async function appendQueue(action, filePath) {
  const entry = JSON.stringify({ action, path: filePath, ts: Date.now() }) + '\n';
  await appendFile(QUEUE_FILE, entry, 'utf-8');
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function ts()          { return new Date().toISOString(); }
function log(msg)  { console.log(`[${ts()}] [rag-watch] ${msg}`); }
function warn(msg) { console.warn(`[${ts()}] [rag-watch] WARN: ${msg}`); }
function err(msg)  { console.error(`[${ts()}] [rag-watch] ERROR: ${msg}`); }

// ─── Bootstrap ────────────────────────────────────────────────────────────────

config({ path: ENV_PATH });

if (!process.env.OPENAI_API_KEY) {
  err(`OPENAI_API_KEY not set. Check ${ENV_PATH}`);
  process.exit(1);
}

if (!existsSync(VAULT_PATH)) {
  err(`Vault directory not found: ${VAULT_PATH}`);
  err('Create Vault directory first (set VAULT_DIR or create ~/vault/), then restart this daemon.');
  process.exit(1);
}

if (!existsSync(DISCORD_HISTORY_PATH)) {
  mkdirSync(DISCORD_HISTORY_PATH, { recursive: true });
  log(`discord-history created: ${DISCORD_HISTORY_PATH}`);
}

if (!existsSync(INBOX_PATH)) {
  mkdirSync(INBOX_PATH, { recursive: true });
  log(`inbox created: ${INBOX_PATH}`);
}

if (!existsSync(EVENT_BUS_PATH)) {
  mkdirSync(EVENT_BUS_PATH, { recursive: true });
  log(`event-bus created: ${EVENT_BUS_PATH}`);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  log('Starting — queue writer mode (LanceDB writes delegated to rag-index.mjs)');
  log(`Queue file: ${QUEUE_FILE}`);

  // ── Event-bus trigger 설정 ──────────────────────────────────────────────────
  const tasksRaw  = readFileSync(join(BOT_HOME, 'config', 'tasks.json'), 'utf-8');
  const triggerMap = {};
  for (const t of (JSON.parse(tasksRaw).tasks || [])) {
    if (t.event_trigger) triggerMap[t.event_trigger] = { id: t.id, debounce_s: t.event_trigger_debounce_s ?? 300 };
  }
  const ALLOWED_EVENTS = new Set(Object.keys(triggerMap));
  const eventDebounce  = new Map();
  log(`Event triggers loaded: ${ALLOWED_EVENTS.size} events`);

  // rag-index.mjs가 inbox/ 디렉토리를 직접 스캔하므로 warm-up 큐잉 불필요.
  // rag-watch는 실시간 'add' 이벤트만 처리 (ignoreInitial: true).

  // Debounce map: filePath → last queue timestamp
  const lastProcessed = new Map();

  // ─── File change handler ──────────────────────────────────────────────────

  async function handleChange(event, filePath) {
    const now  = Date.now();
    const last = lastProcessed.get(filePath) || 0;
    if (now - last < DEBOUNCE_MS) {
      log(`Debounce skip (${event}): ${filePath.split('/').pop()}`);
      return;
    }
    lastProcessed.set(filePath, now);
    try {
      await appendQueue('index', filePath);
      log(`Queued (${event}): ${filePath.split('/').pop()}`);
    } catch (e) {
      err(`Queue write failed: ${filePath.split('/').pop()} — ${e.message}`);
    }
  }

  // ─── Event-bus handler ────────────────────────────────────────────────────

  async function handleEventFile(filePath) {
    try {
      const raw = await readFile(filePath, 'utf-8');
      const { event } = JSON.parse(raw);
      if (!ALLOWED_EVENTS.has(event)) {
        warn(`Rejected unknown event: ${event} (whitelist: ${[...ALLOWED_EVENTS].join(', ')})`);
        return;
      }
      const task = triggerMap[event];
      const now  = Date.now();
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
      await unlink(filePath).catch(() => {});
    }
  }

  // ─── Exclusion filter (mirrors rag-index.mjs exclusions) ─────────────────

  const RAG_EXCLUDED_DIRS  = new Set(['adr', 'architecture', 'board']);
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
    const parts    = filePath.split('/');
    const basename = parts[parts.length - 1];
    if (RAG_EXCLUDED_FILES.has(basename)) return true;
    if (filePath.includes('/adr/') && basename.startsWith('ADR-')) return true;
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

  // ─── Chokidar watcher ────────────────────────────────────────────────────

  const watchTargets = [VAULT_PATH, DISCORD_HISTORY_PATH, INBOX_PATH, EVENT_BUS_PATH];
  const watcher = chokidar.watch(watchTargets, {
    ignored: (filePath) => {
      const basename = filePath.split('/').pop();
      return basename.startsWith('.') && basename !== '.jarvis';
    },
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: 500,
      pollInterval: 100,
    },
  });

  watcher
    .on('add', (filePath) => {
      if (filePath.startsWith(EVENT_BUS_PATH + '/') && filePath.endsWith('.json')) {
        handleEventFile(filePath);
        return;
      }
      if (!filePath.endsWith('.md')) return;
      onlyMd((fp) => handleChange('add', fp))(filePath);
    })
    .on('change', (filePath) => {
      if (!filePath.endsWith('.md')) return;
      onlyMd((fp) => handleChange('change', fp))(filePath);
    })
    .on('unlink', onlyMd(async (filePath) => {
      try {
        await appendQueue('delete', filePath);
        log(`Queued delete: ${filePath.split('/').pop()}`);
      } catch (e) {
        warn(`Queue delete failed: ${filePath.split('/').pop()} — ${e.message}`);
      }
    }))
    .on('error', (watchErr) => {
      err(`Watcher error: ${watchErr.message}`);
    })
    .on('ready', () => {
      log(`Watcher ready — watching: ${watchTargets.join(', ')}`);
    });

  // ─── Graceful shutdown ────────────────────────────────────────────────────

  async function shutdown(signal) {
    log(`Received ${signal} — shutting down gracefully`);
    await watcher.close();
    log('Watcher closed. Goodbye.');
    process.exit(0);
  }

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT',  () => shutdown('SIGINT'));

  // ─── Memory watchdog ──────────────────────────────────────────────────────
  // LanceDB 제거로 메모리 사용량 대폭 감소. 200MB 초과 시 자가 재시작.
  const MEM_LIMIT_MB        = 200;
  const MEM_CHECK_INTERVAL  = 60_000;

  setInterval(() => {
    const heapMB = process.memoryUsage().rss / 1024 / 1024;
    if (heapMB > MEM_LIMIT_MB) {
      log(`메모리 한도 초과 (${heapMB.toFixed(0)}MB > ${MEM_LIMIT_MB}MB) — 자가 재시작`);
      watcher.close().finally(() => process.exit(0));
    }
  }, MEM_CHECK_INTERVAL);
}

main().catch((fatalErr) => {
  err(`Fatal: ${fatalErr.message}`);
  err(fatalErr.stack);
  process.exit(1);
});
