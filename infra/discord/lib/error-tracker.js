/**
 * ErrorTracker — records user-facing errors and sends recovery apologies on restart.
 *
 * State file: ~/jarvis/runtime/state/error-tracker.json
 * Schema: { errors: [{ channelId, userId, errorMessage, timestamp }], lastApology: { channelId: timestamp } }
 */

import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import discordPkg from 'discord.js';
const { EmbedBuilder } = discordPkg;
import { log } from './claude-runner.js';
import { t } from './i18n.js';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const STATE_DIR = join(BOT_HOME, 'state');
const STATE_FILE = join(STATE_DIR, 'error-tracker.json');
const MAX_ERRORS = 50;
const APOLOGY_COOLDOWN_MS = 2 * 60 * 60 * 1000; // 2 hours — 재시작 반복 시 스팸 방지
const PRUNE_AGE_MS = 24 * 60 * 60 * 1000;   // 24 hours
const RECOVERY_TIMEOUT_MS = 8_000;            // 8s max for startup recovery

// Ensure state directory exists once at module load
try { mkdirSync(STATE_DIR, { recursive: true }); } catch { /* ignore */ }

// ---------------------------------------------------------------------------
// State persistence (atomic write via tmp + rename)
// ---------------------------------------------------------------------------

function loadState() {
  try {
    const raw = JSON.parse(readFileSync(STATE_FILE, 'utf-8'));
    // Defensive: ensure shape
    if (!Array.isArray(raw.errors)) raw.errors = [];
    if (!raw.lastApology || typeof raw.lastApology !== 'object') raw.lastApology = {};
    return raw;
  } catch {
    return { errors: [], lastApology: {} };
  }
}

function saveState(state) {
  const tmp = STATE_FILE + '.tmp.' + process.pid;
  writeFileSync(tmp, JSON.stringify(state, null, 2));
  renameSync(tmp, STATE_FILE);
}

// ---------------------------------------------------------------------------
// Record an error (called from handlers.js catch block)
// ---------------------------------------------------------------------------

export function recordError(channelId, userId, errorMessage) {
  if (!channelId || typeof channelId !== 'string') return;
  if (!userId || typeof userId !== 'string') return;

  // Parse sessionKey format "channelId-userId": if channelId contains '-'
  // and both sides are numeric (Discord snowflakes), extract the channelId part.
  if (channelId.includes('-')) {
    const parts = channelId.split('-');
    if (parts.length === 2 && /^\d+$/.test(parts[0]) && /^\d+$/.test(parts[1])) {
      channelId = parts[0];
    }
  }

  try {
    const state = loadState();
    state.errors.push({
      channelId,
      userId,
      errorMessage: (errorMessage || 'Unknown error').slice(0, 200),
      timestamp: Date.now(),
    });
    while (state.errors.length > MAX_ERRORS) state.errors.shift();
    saveState(state);
    log('debug', 'Error recorded for recovery', { channelId, userId });
  } catch (err) {
    log('error', 'recordError failed', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// Send recovery apologies (called on bot startup / shard resume)
// ---------------------------------------------------------------------------

async function _sendApologies(client) {
  const state = loadState();
  if (state.errors.length === 0) return;

  const now = Date.now();

  // Group errors by channelId
  const byChannel = new Map();
  for (const entry of state.errors) {
    if (!entry.channelId) continue;
    if (!byChannel.has(entry.channelId)) {
      byChannel.set(entry.channelId, []);
    }
    byChannel.get(entry.channelId).push(entry);
  }

  let sentCount = 0;

  for (const [channelId, entries] of byChannel) {
    // Cooldown: skip only if ALL errors are older than last apology
    const lastSent = state.lastApology[channelId] || 0;
    const newestError = Math.max(...entries.map((e) => e.timestamp));
    if (lastSent > 0 && newestError <= lastSent && now - lastSent < APOLOGY_COOLDOWN_MS) {
      log('debug', 'Skipping apology (cooldown, no new errors)', { channelId });
      continue;
    }

    const userIds = [...new Set(entries.map((e) => e.userId))];

    // Fetch channel (works for both channels and threads in discord.js v14)
    const channel = client.channels.cache.get(channelId)
      || await client.channels.fetch(channelId).catch(() => null);
    if (!channel) {
      log('warn', 'Recovery apology: channel not found', { channelId });
      continue;
    }

    // Build apology embed — NO @mentions to avoid pinging users at odd hours
    const userNames = userIds.length > 0
      ? userIds.map((id) => `<@${id}>`).join(', ')
      : '';
    const description = userNames
      ? t('recovery.desc.single', { mentions: userNames })
      : t('recovery.desc.general');

    const embed = new EmbedBuilder()
      .setColor(0x5865f2)
      .setTitle(t('recovery.title'))
      .setDescription(description)
      .setFooter({ text: t('recovery.footer') })
      .setTimestamp();

    try {
      // allowedMentions: empty → suppress all pings
      await channel.send({ embeds: [embed], allowedMentions: { parse: [] } });
      state.lastApology[channelId] = now;
      sentCount++;
      log('info', 'Recovery apology sent', { channelId, users: userIds.length });
    } catch (err) {
      log('error', 'Recovery apology send failed', { channelId, error: err.message });
    }
  }

  // Clear errors and prune old lastApology entries
  state.errors = [];
  for (const [chId, ts] of Object.entries(state.lastApology)) {
    if (now - ts > PRUNE_AGE_MS) delete state.lastApology[chId];
  }
  saveState(state);

  if (sentCount > 0) {
    log('info', `Recovery apologies complete: ${sentCount} channel(s)`);
  }
}

// Public: wraps _sendApologies with a timeout to never block bot startup
// DISABLED: recovery apology messages are not useful and annoying on restart
export async function sendRecoveryApologies(_client) {
  return; // disabled
}