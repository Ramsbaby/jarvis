/**
 * Jarvis Orchestrator — SQLite Event Bus daemon
 *
 * Polls messages.db every ORCHESTRATOR_POLL_MS (default 5000ms),
 * routes by channel, performs Two-Phase validate→execute, records KPIs.
 *
 * Usage: node orchestrator.mjs
 */

import { createRequire } from 'node:module';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { URL } from 'node:url';

// ---------------------------------------------------------------------------
// Bootstrap: dotenv (require-based since dotenv ships as CJS)
// ---------------------------------------------------------------------------

const require = createRequire(import.meta.url);

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const DISCORD_DIR = join(BOT_HOME, '..', '.jarvis', 'discord'); // normalizes fine via join
const ENV_PATH = join(homedir(), '.jarvis', 'discord', '.env');

// Minimal dotenv parser — no external dep needed for key=value files
function loadDotenv(path) {
  if (!existsSync(path)) return;
  try {
    const lines = readFileSync(path, 'utf-8').split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx === -1) continue;
      const key = trimmed.slice(0, eqIdx).trim();
      const val = trimmed.slice(eqIdx + 1).trim().replace(/^["']|["']$/g, '');
      if (key && !(key in process.env)) process.env[key] = val;
    }
  } catch (e) {
    log('warn', `dotenv load failed: ${e.message}`);
  }
}

loadDotenv(ENV_PATH);

// ---------------------------------------------------------------------------
// Paths & Config
// ---------------------------------------------------------------------------

const LOG_DIR     = join(BOT_HOME, 'logs');
const RESULTS_DIR = join(BOT_HOME, 'results', 'orchestrator');
const STATE_DIR   = join(BOT_HOME, 'state');

mkdirSync(LOG_DIR,     { recursive: true });
mkdirSync(RESULTS_DIR, { recursive: true });
mkdirSync(STATE_DIR,   { recursive: true });

const POLL_MS      = parseInt(process.env.ORCHESTRATOR_POLL_MS || '5000', 10);
const MAX_PER_POLL = 10;
const KPI_FLUSH_MS = 60_000;

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

function log(level, msg) {
  const line = `[${new Date().toISOString()}] [orchestrator] [${level.toUpperCase()}] ${msg}`;
  process.stdout.write(line + '\n');
}

// ---------------------------------------------------------------------------
// Config: monitoring.json
// ---------------------------------------------------------------------------

function loadJSON(filePath) {
  try { return JSON.parse(readFileSync(filePath, 'utf-8')); } catch { return {}; }
}

const monitoring = loadJSON(join(BOT_HOME, 'config', 'monitoring.json'));
const WEBHOOKS   = monitoring.webhooks ?? {};
const NTFY_CFG   = monitoring.ntfy ?? {};

// ---------------------------------------------------------------------------
// Discord webhook sender (raw HTTPS, no discord.js)
// ---------------------------------------------------------------------------

async function sendWebhook(webhookUrl, content) {
  if (!webhookUrl || !content) return;
  content = content.replace(/https?:\/\/[^ )>\n]+/g, '');
  // Discord 2000-char limit: chunk if needed
  for (let i = 0; i < content.length; i += 1990) {
    const chunk = content.slice(i, i + 1990);
    try {
      await fetch(webhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content: chunk }),
      });
      if (i + 1990 < content.length) {
        await new Promise((r) => setTimeout(r, 500));
      }
    } catch (e) {
      log('warn', `webhook POST failed: ${e.message}`);
    }
  }
}

// ---------------------------------------------------------------------------
// ntfy push notification
// ---------------------------------------------------------------------------

async function sendNtfy(title, message, priority = 'default') {
  if (!NTFY_CFG.enabled || !NTFY_CFG.topic) return;
  const url = `${NTFY_CFG.server || 'https://ntfy.sh'}/${NTFY_CFG.topic}`;
  try {
    await fetch(url, {
      method: 'POST',
      headers: {
        'Title': title,
        'Priority': priority,
        'Content-Type': 'text/plain',
      },
      body: message,
    });
  } catch (e) {
    log('warn', `ntfy push failed: ${e.message}`);
  }
}

// ---------------------------------------------------------------------------
// Market event significance check
// Phase 1 validation for 'market' channel
// ---------------------------------------------------------------------------

function isSignificantMarketEvent(payload) {
  const { changePercent, rsi, symbol } = payload;
  if (typeof changePercent === 'number' && Math.abs(changePercent) >= 3) return true;
  if (typeof rsi === 'number' && (rsi >= 70 || rsi <= 30)) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Channel handlers (Phase 2 execute)
// ---------------------------------------------------------------------------

async function handleAlert(msg, payload) {
  const level    = payload.level ?? 'info';
  const message  = payload.message ?? JSON.stringify(payload);
  const hookKey  = level === 'critical' ? 'jarvis-system' : 'jarvis';
  const hookUrl  = WEBHOOKS[hookKey];
  const ntfyPrio = level === 'critical' ? 'high' : 'default';

  const content = `🚨 **Jarvis Alert** [${level.toUpperCase()}]\n${message}`;
  log('info', `alert → Discord(${hookKey}): ${message.slice(0, 80)}`);
  await sendWebhook(hookUrl, content);
  await sendNtfy(`Jarvis Alert [${level}]`, message, ntfyPrio);
}

async function handleMarket(msg, payload) {
  // Phase 1: validate
  if (!isSignificantMarketEvent(payload)) {
    log('debug', `market msg ${msg.id} below threshold — skipped`);
    return;
  }
  // Phase 2: execute
  const { symbol, price, changePercent, rsi } = payload;
  const lines = [`📈 **시장 이벤트** — ${symbol ?? 'UNKNOWN'}`];
  if (price != null)         lines.push(`가격: $${price}`);
  if (changePercent != null) lines.push(`변동: ${changePercent > 0 ? '+' : ''}${changePercent.toFixed(2)}%`);
  if (rsi != null)           lines.push(`RSI: ${rsi}`);

  const content = lines.join('\n');
  log('info', `market → Discord(jarvis-market): ${symbol} ${changePercent}%`);
  await sendWebhook(WEBHOOKS['jarvis-market'], content);
}

async function handleSystem(msg, payload) {
  // Phase 1: validate — only act on degraded/critical
  const status = payload.status ?? '';
  if (status !== 'degraded' && status !== 'critical') {
    log('debug', `system msg ${msg.id} status=${status} — skipped`);
    return;
  }
  // Phase 2: execute
  const reason  = payload.reason ?? payload.message ?? JSON.stringify(payload);
  const emoji   = status === 'critical' ? '🔴' : '🟡';
  const content = `${emoji} **시스템 ${status.toUpperCase()}**\n${reason}`;

  // discord_sent=true: sender already notified Discord — skip re-send (prevent duplicate)
  if (payload.discord_sent) {
    log('info', `system msg ${msg.id} already Discord-notified — SQLite audit only`);
  } else {
    log('info', `system → Discord(jarvis-system): ${status} — ${reason.slice(0, 80)}`);
    await sendWebhook(WEBHOOKS['jarvis-system'], content);
  }

  if (status === 'critical') {
    await sendNtfy(`Jarvis System CRITICAL`, reason, 'urgent');
  }
}

async function handleKpi(msg, payload) {
  // Aggregate KPI data into daily JSON
  const date    = new Date().toISOString().slice(0, 10);
  const kpiFile = join(RESULTS_DIR, `${date}.json`);

  let existing = {};
  if (existsSync(kpiFile)) {
    try { existing = JSON.parse(readFileSync(kpiFile, 'utf-8')); } catch { /* start fresh */ }
  }

  // Merge incoming KPI fields
  for (const [k, v] of Object.entries(payload)) {
    if (typeof v === 'number') {
      existing[k] = (existing[k] ?? 0) + v;
    } else {
      existing[k] = v;
    }
  }
  existing._lastUpdated = new Date().toISOString();

  writeFileSync(kpiFile, JSON.stringify(existing, null, 2), 'utf-8');
  log('info', `kpi aggregated → ${kpiFile}`);
}

async function handleGeneral(msg, payload) {
  log('info', `general msg ${msg.id} from ${msg.sender}: ${JSON.stringify(payload).slice(0, 100)}`);
  // No action — just acknowledge (caller acks after this returns)
}

// ---------------------------------------------------------------------------
// Message router
// ---------------------------------------------------------------------------

async function processMessage(msg) {
  // payload is already parsed by message-queue.mjs receive()
  const payload = typeof msg.payload === 'string'
    ? (() => { try { return JSON.parse(msg.payload); } catch { return { raw: msg.payload }; } })()
    : (msg.payload ?? {});

  switch (msg.channel) {
    case 'alert':   await handleAlert(msg, payload);   break;
    case 'market':  await handleMarket(msg, payload);  break;
    case 'system':  await handleSystem(msg, payload);  break;
    case 'kpi':     await handleKpi(msg, payload);     break;
    default:        await handleGeneral(msg, payload); break;
  }
}

// ---------------------------------------------------------------------------
// In-memory KPI counter (flushed every KPI_FLUSH_MS)
// ---------------------------------------------------------------------------

const counter = { processed: 0, errors: 0, totalLatencyMs: 0, cycles: 0 };

function flushOwnKpi(mq) {
  if (counter.cycles === 0) return;
  const avgLatencyMs = counter.processed > 0
    ? Math.round(counter.totalLatencyMs / counter.processed)
    : 0;

  const payload = {
    processed:    counter.processed,
    errors:       counter.errors,
    avgLatencyMs,
    source:       'orchestrator',
  };

  try {
    mq.send('orchestrator', 'kpi', payload, { priority: 'normal', ttl: 3600 });
  } catch (e) {
    log('warn', `own kpi send failed: ${e.message}`);
  }

  // Reset counters
  counter.processed = 0;
  counter.errors    = 0;
  counter.totalLatencyMs = 0;
  counter.cycles    = 0;
}

// ---------------------------------------------------------------------------
// Poll loop
// ---------------------------------------------------------------------------

async function pollOnce(mq) {
  counter.cycles++;
  let msgs;
  try {
    msgs = mq.receive('orchestrator', { limit: MAX_PER_POLL });
  } catch (e) {
    log('error', `receive() failed: ${e.message}`);
    return;
  }

  if (msgs.length === 0) return;
  log('info', `poll: ${msgs.length} message(s) received`);

  for (const msg of msgs) {
    const t0 = Date.now();
    try {
      await processMessage(msg);
      mq.ack(msg.id);
      counter.processed++;
      counter.totalLatencyMs += Date.now() - t0;
    } catch (e) {
      log('error', `msg ${msg.id} failed: ${e.message}`);
      mq.fail(msg.id, e.message);
      counter.errors++;
    }
  }
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

async function main() {
  log('info', `Starting — poll interval ${POLL_MS}ms, max ${MAX_PER_POLL} msgs/cycle`);
  log('info', `BOT_HOME: ${BOT_HOME}`);

  // Dynamically import message-queue.mjs (relative to this file)
  const mqPath = new URL('../../../.jarvis/lib/message-queue.mjs', import.meta.url);
  let mq;
  try {
    mq = await import(mqPath.href);
    mq.init();
    log('info', `MessageQueue ready — db: ${join(BOT_HOME, 'state', 'messages.db')}`);
  } catch (e) {
    log('error', `Failed to init MessageQueue: ${e.message}`);
    process.exit(1);
  }

  // Print startup stats
  try {
    const s = mq.stats();
    log('info', `Queue stats — pending:${s.pending} processing:${s.processing} done:${s.done} failed:${s.failed}`);
  } catch { /* non-fatal */ }

  let running = true;

  // Graceful shutdown
  function shutdown(signal) {
    log('info', `${signal} received — finishing current cycle then exiting`);
    running = false;
  }
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT',  () => shutdown('SIGINT'));

  // KPI flush timer
  const kpiTimer = setInterval(() => {
    try { flushOwnKpi(mq); } catch (e) { log('warn', `kpi flush error: ${e.message}`); }
  }, KPI_FLUSH_MS);

  // Periodic cleanup (every 6 hours)
  const cleanupTimer = setInterval(() => {
    try {
      const result = mq.cleanup();
      if (result.changes > 0) log('info', `cleanup: removed ${result.changes} old messages`);
    } catch (e) { log('warn', `cleanup error: ${e.message}`); }
  }, 6 * 3600_000);

  // Claude CLI → RAG 싱크 (매 10분): CLI 대화를 inbox에 저장 → rag-watch 자동 인덱싱
  const cliRagSyncScript = join(BOT_HOME, 'scripts', 'claude-cli-rag-sync.mjs');
  const cliRagSyncTimer = setInterval(async () => {
    try {
      const { execFile } = await import('node:child_process');
      execFile(process.execPath, [cliRagSyncScript], { timeout: 30000 }, (err, stdout, stderr) => {
        if (err) { log('warn', `cli-rag-sync error: ${err.message}`); return; }
        const lastLine = stdout.trim().split('\n').pop() || '';
        if (lastLine.includes('synced: 0')) return; // 변경 없으면 로그 생략
        log('info', `cli-rag-sync: ${lastLine}`);
      });
    } catch (e) { log('warn', `cli-rag-sync launch error: ${e.message}`); }
  }, 10 * 60_000);

  log('info', 'Orchestrator ready — entering poll loop');

  // Main poll loop
  while (running) {
    await pollOnce(mq);
    if (running) {
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  }

  // Final flush before exit
  clearInterval(kpiTimer);
  clearInterval(cleanupTimer);
  clearInterval(cliRagSyncTimer);
  try { flushOwnKpi(mq); } catch { /* best effort */ }
  try { mq.close(); } catch { /* best effort */ }

  log('info', 'Orchestrator shut down cleanly');
  process.exit(0);
}

main().catch((e) => {
  process.stderr.write(`[${new Date().toISOString()}] [orchestrator] [FATAL] ${e.message}\n`);
  process.exit(1);
});
