/**
 * ErrorTracker — records user-facing errors and sends recovery apologies on restart.
 *
 * State file: ~/.jarvis/state/error-tracker.json
 * Schema: { errors: [{ channelId, userId, errorMessage, timestamp }], lastApology: { channelId: timestamp } }
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { EmbedBuilder } from 'discord.js';
import { log } from './claude-runner.js';
import { t } from './i18n.js';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const STATE_FILE = join(BOT_HOME, 'state', 'error-tracker.json');
const MAX_ERRORS = 50;
const APOLOGY_COOLDOWN_MS = 30 * 60 * 1000; // 30 minutes
const PRUNE_AGE_MS = 24 * 60 * 60 * 1000;   // 24 hours

// ---------------------------------------------------------------------------
// State persistence
// ---------------------------------------------------------------------------

function loadState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf-8'));
  } catch {
    return { errors: [], lastApology: {} };
  }
}

function saveState(state) {
  mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// ---------------------------------------------------------------------------
// Record an error (called from handlers.js catch block)
// ---------------------------------------------------------------------------

export function recordError(channelId, userId, errorMessage) {
  try {
    const state = loadState();
    state.errors.push({
      channelId,
      userId,
      errorMessage: (errorMessage || 'Unknown error').slice(0, 200),
      timestamp: Date.now(),
    });
    // Cap at MAX_ERRORS
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

export async function sendRecoveryApologies(client) {
  const state = loadState();
  if (state.errors.length === 0) return;

  const now = Date.now();

  // Group errors by channelId
  const byChannel = new Map();
  for (const entry of state.errors) {
    if (!byChannel.has(entry.channelId)) {
      byChannel.set(entry.channelId, []);
    }
    byChannel.get(entry.channelId).push(entry);
  }

  let sentCount = 0;

  for (const [channelId, entries] of byChannel) {
    // Cooldown check — skip if apology was sent recently
    const lastSent = state.lastApology[channelId] || 0;
    if (now - lastSent < APOLOGY_COOLDOWN_MS) {
      log('debug', 'Skipping apology (cooldown)', { channelId });
      continue;
    }

    // Collect unique user IDs
    const userIds = [...new Set(entries.map((e) => e.userId))];

    // Fetch channel
    const channel = client.channels.cache.get(channelId)
      || await client.channels.fetch(channelId).catch(() => null);
    if (!channel) {
      log('warn', 'Recovery apology: channel not found', { channelId });
      continue;
    }

    // Build apology embed
    const mentions = userIds.map((id) => `<@${id}>`).join(', ');
    const description = userIds.length > 0
      ? t('recovery.desc.single', { mentions })
      : t('recovery.desc.general');

    const embed = new EmbedBuilder()
      .setColor(0x5865f2)
      .setTitle(t('recovery.title'))
      .setDescription(description)
      .setFooter({ text: t('recovery.footer') })
      .setTimestamp();

    try {
      await channel.send({ embeds: [embed] });
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
