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

export function recordError(channelId, userId, errorMessage, messageId, messageChannelId) {
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
      messageId: typeof messageId === 'string' ? messageId : null, // 재생(replay)용 원본 메시지 ID
      messageChannelId: typeof messageChannelId === 'string' ? messageChannelId : null, // 원본 메시지가 사는 채널 (스레드 응답 시 channelId와 다를 수 있음)
      errorMessage: (errorMessage || 'Unknown error').slice(0, 200),
      timestamp: Date.now(),
    });
    while (state.errors.length > MAX_ERRORS) state.errors.shift();
    saveState(state);
    log('debug', 'Error recorded for recovery', { channelId, userId, messageId });
  } catch (err) {
    log('error', 'recordError failed', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// Failed-request auto-replay (2026-07-17 — Discord typing 500 사건 후속)
// 장애로 죽은 요청을 복구 후 자동 재처리한다. 봇 기동 45초 후 + 5분 주기.
// ---------------------------------------------------------------------------

const REPLAY_INITIAL_DELAY_MS = 45_000;
const REPLAY_INTERVAL_MS = 5 * 60_000;
const REPLAY_MAX_ATTEMPTS = 4;          // 초과 시 폐기 (영구 장애 무한 재시도 방지)
const REPLAY_MAX_AGE_MS = 12 * 60 * 60 * 1000; // 12시간 지난 요청은 재생 무의미
const REPLAY_BATCH = 3;                 // tick당 최대 재생 수 (burst 방지)

let _replayRunning = false;

function _rewriteQueue(mutator) {
  const state = loadState();
  state.errors = mutator(state.errors);
  saveState(state);
}

export function startErrorReplayer(client, handleMessageFn, handlerState, isShuttingDownFn) {
  const tick = () =>
    _replayTick(client, handleMessageFn, handlerState, isShuttingDownFn).catch((err) =>
      log('error', 'Error replay tick failed', { error: err.message }),
    );
  setTimeout(tick, REPLAY_INITIAL_DELAY_MS);
  setInterval(tick, REPLAY_INTERVAL_MS);
  log('info', 'Error replayer armed — failed requests will be auto-replayed');
}

// 봇의 "실질 응답" 판정 — 재생 안내(⏳)·세션 푸터(-#)·짧은 오류 알림 제외.
// ⚠️ 25자 미만 초단답은 실질 응답으로 감지 못해 최대 attempts 캡까지 중복 발송될 수 있음 (알려진 한계).
function _isSubstantiveBotReply(m, botUserId) {
  if (m.author?.id !== botUserId) return false;
  const c = m.content || '';
  if (c.startsWith('⏳') || c.startsWith('-#')) return false;
  return c.length >= 25 || (m.attachments?.size ?? 0) > 0;
}

async function _replayTick(client, handleMessageFn, handlerState, isShuttingDownFn) {
  if (_replayRunning) return; // 이전 tick 미완료 시 중첩 금지
  _replayRunning = true;
  try {
    if (!client.isReady()) return;
    if (isShuttingDownFn?.()) return; // 종료 중 신규 세션 생성 금지 (orphan 방지)
    const now = Date.now();
    const state = loadState();
    if (state.errors.length === 0) return;

    // 대상 선별: messageId 있는 항목만 (구 스키마·만료·시도초과는 폐기).
    // 같은 messageId 중복(재생 실패 시 recordError가 attempts 없는 새 항목을 재적재)은
    // attempts=최댓값·timestamp=최솟값(최초 실패 시각)으로 병합 → 캡·만료가 물리적으로 보장됨.
    const byMsg = new Map();
    for (const e of state.errors) {
      if (!e.messageId) continue;
      const prev = byMsg.get(e.messageId);
      if (prev) {
        prev.attempts = Math.max(prev.attempts || 0, e.attempts || 0);
        prev.timestamp = Math.min(prev.timestamp, e.timestamp);
      } else {
        byMsg.set(e.messageId, { ...e });
      }
    }
    const byUser = new Map();
    for (const e of byMsg.values()) {
      if (now - e.timestamp > REPLAY_MAX_AGE_MS) continue;
      if ((e.attempts || 0) >= REPLAY_MAX_ATTEMPTS) continue;
      const key = `${e.channelId}:${e.userId}`;
      const prev = byUser.get(key);
      if (!prev || e.timestamp > prev.timestamp) byUser.set(key, e);
    }
    const candidates = [...byUser.values()].sort((a, b) => a.timestamp - b.timestamp);
    _rewriteQueue(() => candidates); // 폐기 반영된 큐로 재작성

    let dispatched = 0;
    for (const entry of candidates) {
      if (dispatched >= REPLAY_BATCH) break;
      if (isShuttingDownFn?.()) break;

      const fetchChannelId = entry.messageChannelId || entry.channelId;
      const channel =
        client.channels.cache.get(fetchChannelId) ||
        (await client.channels.fetch(fetchChannelId).catch(() => null));
      if (!channel?.messages) continue; // fail-closed: 채널 fetch 실패는 폐기 아닌 보류 (API 장애 중 오폐기 방지)

      // 실패 시점 이후의 채널 흐름 조회 — 실패하면 이번 tick 보류 (fail-closed)
      const after = await channel.messages
        .fetch({ after: entry.messageId, limit: 100 })
        .catch(() => undefined);
      if (after === undefined) continue;
      const laterMsgs = [...after.values()];

      // 완결 확인 ①: 봇의 실질 응답이 이미 존재 → 성공(이전 재생 포함) → 큐 제거
      if (laterMsgs.some((m) => _isSubstantiveBotReply(m, client.user.id))) {
        log('info', 'Replay resolved — substantive bot reply found', { channelId: entry.channelId, messageId: entry.messageId });
        _rewriteQueue((q) => q.filter((e) => e.messageId !== entry.messageId));
        continue;
      }
      // 완결 확인 ②: 같은 사용자가 이미 다시 물었으면 재생 포기 (중복 응답 방지)
      if (laterMsgs.some((m) => m.author?.id === entry.userId)) {
        log('info', 'Replay skipped — user already re-asked', { channelId: entry.channelId, messageId: entry.messageId });
        _rewriteQueue((q) => q.filter((e) => e.messageId !== entry.messageId));
        continue;
      }

      const failedMsg = await channel.messages.fetch(entry.messageId).catch((err) => err);
      if (failedMsg instanceof Error || !failedMsg?.id) {
        // 10008(Unknown Message)/10003(Unknown Channel)만 폐기 — 그 외(일시 오류)는 보류
        if (failedMsg?.code === 10008 || failedMsg?.code === 10003) {
          _rewriteQueue((q) => q.filter((e) => e.messageId !== entry.messageId));
        }
        continue;
      }

      // 시도 횟수 선기록 — 발송 중 크래시해도 캡이 유지되도록 발송 전에 영속화.
      // 큐 제거는 여기서 하지 않는다: handleMessage는 즉시 resolve되는 대기열 게이트라
      // "발송 성공 ≠ 처리 성공". 완결 판정은 다음 tick의 실질 응답 확인 ①이 담당.
      entry.attempts = (entry.attempts || 0) + 1;
      _rewriteQueue((q) =>
        q.map((e) => (e.messageId === entry.messageId ? { ...e, attempts: entry.attempts } : e)),
      );

      dispatched++;
      log('info', 'Replaying failed request', {
        channelId: entry.channelId, messageId: entry.messageId, attempt: entry.attempts,
      });
      try {
        if (entry.attempts === 1) {
          await channel.send({ content: '⏳ 앞서 일시 장애로 처리하지 못한 요청을 이어서 처리합니다.' }).catch(() => {});
        }
        await handleMessageFn(failedMsg, handlerState);
        log('info', 'Replay dispatched — completion will be verified next tick', {
          channelId: entry.channelId, messageId: entry.messageId,
        });
      } catch (err) {
        log('warn', 'Replay dispatch failed — will retry next tick', {
          channelId: entry.channelId, messageId: entry.messageId,
          attempt: entry.attempts, error: err.message,
        });
      }
    }
  } finally {
    _replayRunning = false;
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