/**
 * Jarvis — Main Entry Point
 *
 * Wraps `claude -p` CLI with streaming JSON output.
 * Manages slash commands, shared state, and client lifecycle.
 *
 * Message handling → lib/handlers.js
 * Session/rate/streaming → lib/session.js
 * Claude spawning/RAG → lib/claude-runner.js
 * Slash commands → lib/commands.js
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync, rmSync, renameSync } from 'node:fs';
import {
  Client,
  GatewayIntentBits,
  SlashCommandBuilder,
  REST,
  Routes,
} from 'discord.js';
import { config as loadEnv } from 'dotenv';
loadEnv({ path: join(process.env.JARVIS_HOME || join(homedir(), 'jarvis'), 'runtime/discord/.env') });

import { log, sendNtfy, getSessionHistoryFile } from './lib/claude-runner.js';
import { SessionStore, RateTracker, Semaphore } from './lib/session.js';
import { handleMessage } from './lib/handlers.js';
import { handleInteraction } from './lib/commands.js';
import { handleApprovalInteraction, pollL3Requests } from './lib/approval.js';
import { t } from './lib/i18n.js';
import { initAlertBatcher, botAlerts } from './lib/alert-batcher.js';
import { recordError, sendRecoveryApologies } from './lib/error-tracker.js';
import { _loadPlaceholders, _savePlaceholders, cleanupOrphanPlaceholders } from './lib/streaming.js';
import { closeRagEngine } from './lib/rag-helper.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const BOT_HOME = join(process.env.BOT_HOME || join(HOME, 'jarvis/runtime'));
const SESSIONS_PATH = join(BOT_HOME, 'state', 'sessions.json');
const RATE_TRACKER_PATH = join(BOT_HOME, 'state', 'rate-tracker.json');
const MAX_CONCURRENT = 3;
const BOT_NAME = process.env.BOT_NAME || 'Claude Bot';

// ---------------------------------------------------------------------------
// Shared state (created here, passed to handlers)
// ---------------------------------------------------------------------------

const sessions = new SessionStore(SESSIONS_PATH);
const rateTracker = new RateTracker(RATE_TRACKER_PATH);
const semaphore = new Semaphore(MAX_CONCURRENT);

/** @type {Map<string, { proc: import('child_process').ChildProcess, timeout: NodeJS.Timeout, typingInterval: NodeJS.Timeout | null }>} */
const activeProcesses = new Map();

// ---------------------------------------------------------------------------
// Slash command registration
// ---------------------------------------------------------------------------

async function registerSlashCommands(clientId, guildId) {
  const bn = { botName: BOT_NAME };
  const commands = [
    new SlashCommandBuilder()
      .setName('clear')
      .setDescription(t('cmd.clear.desc', bn)),
    new SlashCommandBuilder()
      .setName('stop')
      .setDescription(t('cmd.stop.desc', bn)),
    new SlashCommandBuilder()
      .setName('memory')
      .setDescription(t('cmd.memory.desc', bn)),
    new SlashCommandBuilder()
      .setName('remember')
      .setDescription(t('cmd.remember.desc'))
      .addStringOption(opt => opt.setName('content').setDescription(t('cmd.remember.opt.content')).setRequired(true)),
    new SlashCommandBuilder()
      .setName('search')
      .setDescription(t('cmd.search.desc'))
      .addStringOption(opt => opt.setName('query').setDescription(t('cmd.search.opt.query')).setRequired(true)),
    new SlashCommandBuilder()
      .setName('threads')
      .setDescription(t('cmd.threads.desc', bn)),
    new SlashCommandBuilder()
      .setName('alert')
      .setDescription(t('cmd.alert.desc'))
      .addStringOption(opt => opt.setName('message').setDescription(t('cmd.alert.opt.message')).setRequired(true)),
    new SlashCommandBuilder()
      .setName('status')
      .setDescription(t('cmd.status.desc')),
    new SlashCommandBuilder()
      .setName('tasks')
      .setDescription(t('cmd.tasks.desc')),
    new SlashCommandBuilder()
      .setName('run')
      .setDescription(t('cmd.run.desc'))
      .addStringOption(opt =>
        opt.setName('id').setDescription(t('cmd.run.opt.id')).setRequired(true).setAutocomplete(true)
      ),
    new SlashCommandBuilder()
      .setName('schedule')
      .setDescription(t('cmd.schedule.desc'))
      .addStringOption(opt => opt.setName('task').setDescription(t('cmd.schedule.opt.task')).setRequired(true))
      .addStringOption(opt => opt.setName('in').setDescription(t('cmd.schedule.opt.in')).setRequired(true)
        .addChoices(
          { name: t('cmd.schedule.choice.30m'), value: '30m' },
          { name: t('cmd.schedule.choice.1h'), value: '1h' },
          { name: t('cmd.schedule.choice.2h'), value: '2h' },
          { name: t('cmd.schedule.choice.4h'), value: '4h' },
          { name: t('cmd.schedule.choice.8h'), value: '8h' },
        )),
    new SlashCommandBuilder()
      .setName('usage')
      .setDescription(t('cmd.usage.desc')),
    new SlashCommandBuilder()
      .setName('lounge')
      .setDescription(t('cmd.lounge.desc')),
    new SlashCommandBuilder()
      .setName('doctor')
      .setDescription('Jarvis 시스템 점검 + 자동 수정 (오너 전용)'),
    new SlashCommandBuilder()
      .setName('team')
      .setDescription('자비스 컴퍼니 팀장을 소환합니다')
      .addStringOption(opt =>
        opt.setName('name').setDescription('팀 이름').setRequired(true)
          .addChoices(
            { name: '감사팀 (Council)', value: 'council' },
            { name: '인프라팀 (Infra)', value: 'infra' },
            { name: '기록팀 (Record)', value: 'record' },
            { name: '브랜드팀 (Brand)', value: 'brand' },
            { name: '성장팀 (Career)', value: 'career' },
            { name: '학습팀 (Academy)', value: 'academy' },
            { name: '정보팀 (Trend)', value: 'trend' },
            { name: '🔭 정보탐험대 (Recon)', value: 'recon' },
          )
      ),
    new SlashCommandBuilder()
      .setName('approve')
      .setDescription('doc-draft 승인 → 실제 문서에 자동 적용 (오너 전용)')
      .addStringOption(opt =>
        opt.setName('draft').setDescription('적용할 draft 파일명 (미입력 시 목록 표시)').setRequired(false)
      ),
    new SlashCommandBuilder()
      .setName('commitments')
      .setDescription('미이행 약속 목록 조회 (오너 전용)'),
    new SlashCommandBuilder()
      .setName('skill')
      .setDescription('Claude Code 스킬 직접 실행 — SSoT 이름 제약 없이 모든 스킬 호출 가능')
      .addStringOption(opt =>
        opt.setName('input')
          .setDescription('스킬명 [인자] (예: anal-stock 삼성전자 / investigate / health)')
          .setRequired(true)
      ),
  ];

  // ---------------------------------------------------------------------------
  // SSoT 스킬 자동 등록 — ~/jarvis/runtime/skills/*.md 를 Discord 슬래시 커맨드로 승격
  // CLI의 `/mock-interview 삼성물산` 경험을 디스코드에서 그대로 재현.
  // 중복 이름은 기존 하드코딩 커맨드가 우선 (스킬 무시).
  // ---------------------------------------------------------------------------
  try {
    const { loadSkills } = await import('./lib/skill-loader.js');
    const skills = loadSkills();
    const existingNames = new Set(commands.map((c) => c.name));
    let added = 0;
    for (const s of skills) {
      if (existingNames.has(s.name)) continue;
      // Discord 제약: 이름은 소문자+하이픈만, 32자 이내
      if (!/^[a-z0-9-]{1,32}$/.test(s.name)) continue;
      const desc = (s.description || `${s.name} 스킬`).slice(0, 100);
      commands.push(
        new SlashCommandBuilder()
          .setName(s.name)
          .setDescription(desc)
          .addStringOption((opt) =>
            opt.setName('target').setDescription('회사명·주제·세부 지시 (선택)').setRequired(false)
          )
      );
      added++;
    }
    log('info', 'SSoT skills registered as slash commands', { added, total: skills.length });
  } catch (err) {
    log('warn', 'SSoT skill auto-registration failed (non-critical)', { error: err.message });
  }

  const rest = new REST({ version: '10' }).setToken(process.env.DISCORD_TOKEN);
  try {
    await rest.put(Routes.applicationGuildCommands(clientId, guildId), {
      body: commands.map((c) => c.toJSON()),
    });
    log('info', 'Slash commands registered', { guildId });
  } catch (err) {
    log('error', 'Failed to register slash commands', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// Discord client setup
// ---------------------------------------------------------------------------

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
    GatewayIntentBits.GuildMessageReactions,
  ],
  allowedMentions: { repliedUser: false },
});

let lastMessageAt = Date.now();
let healthMonitorInterval = null;
let l3PollInterval = null;

client.once('clientReady', async () => {
  log('info', `Logged in as ${client.user.tag}`, { id: client.user.id });
  try { rmSync('/tmp/jarvis-token-backoff', { force: true }); } catch {} // Reset token backoff on success

  const guildId = process.env.GUILD_ID;
  if (guildId) {
    await registerSlashCommands(client.user.id, guildId);
  }

  // Cleanup orphan placeholders from previous crash
  cleanupOrphanPlaceholders(client).catch((e) => log('warn', 'Orphan placeholder cleanup failed', { error: e.message }));

  // Init alert batcher — send batched alerts to system channel (jarvis-system)
  const systemAlertChannelId = process.env.SYSTEM_ALERT_CHANNEL_ID
    || (process.env.CHANNEL_IDS || '').split(',')[0]?.trim();
  if (systemAlertChannelId) {
    const alertCh = client.channels.cache.get(systemAlertChannelId) || await client.channels.fetch(systemAlertChannelId).catch(() => null);
    if (alertCh) initAlertBatcher(alertCh);
  }

  // 2026-04-20 제거: 이 블록은 streaming.js의 cleanupOrphanPlaceholders(219줄 호출)와
  // 중복이며, 훨씬 더 위험했음 — placeholder 목록에 있는 모든 메시지를 시간·내용 무관
  // 전량 msg.delete() 처리.
  //
  // 실제 버그 (07:03~07:04 KST 사례):
  //   1. 답변 본문 1652자가 split되어 첫번째 메시지(1381자) + 두번째(347자)로 finalize
  //   2. split 후 첫번째 메시지의 _unregisterPlaceholder 누락 (this.currentMessage가
  //      두번째 메시지로 덮어써지면서 첫번째 ID가 finalize 경로에서 unregister 안 됨)
  //   3. 봇 재시작 → 이 블록이 "finalized 본문이지만 placeholder 목록에 남아있는" 첫번째
  //      메시지까지 msg.delete() → Discord UI에서 본문 전반부 소실
  //
  // 안전 로직인 streaming.js의 cleanupOrphanPlaceholders(219줄에서 호출)만 유지:
  //   - 1시간 이내: survivor로 유지 (절대 건드리지 않음)
  //   - 1시간 초과: 메시지 content는 그대로, components/embeds만 제거 (delete 아님)

  // 재시작 알림: 종료 사유 포함
  try {
    const notifyPath = join(BOT_HOME, 'state', 'restart-notify.json');
    const heartbeatFile = join(BOT_HOME, 'state', 'bot-heartbeat');
    let reason = null;
    let notifyChannels = [];

    try {
      const notifyRaw = readFileSync(notifyPath, 'utf-8');
      rmSync(notifyPath, { force: true });
      const data = JSON.parse(notifyRaw);
      // 5분 이내만 유효
      if (Date.now() - data.ts < 300_000) {
        reason = data.reason || 'unknown';
        if (data.requestedRestart) reason = 'requested';
        // 재시작 알림은 jarvis 메인 채널로만
        notifyChannels = [process.env.OWNER_ALERT_CHANNEL_ID || '1468386844621144065'];
      }
    } catch {
      // restart-notify.json 없음 → heartbeat로 비정상 종료 추정
      try {
        const hbRaw = readFileSync(heartbeatFile, 'utf-8').trim();
        const lastHb = parseInt(hbRaw, 10);
        // heartbeat가 15분 이내면 → 갑자기 죽은 것 (watchdog kill 또는 OOM 등)
        if (Number.isFinite(lastHb) && Date.now() - lastHb < 900_000) {
          reason = 'unexpected shutdown (no graceful exit)';
        }
      } catch { /* no heartbeat = first boot */ }
    }

    // 재시작 알림 쿨다운: 60초 이내 연속 재시작(개발자 배포 루프)은 알림 억제
    const APOLOGY_COOLDOWN_MS = 60_000;
    const apologyCooldownFile = join(BOT_HOME, 'state', 'restart-apology-ts');
    let suppressApology = false;
    try {
      const lastTs = parseInt(readFileSync(apologyCooldownFile, 'utf-8').trim(), 10);
      if (Number.isFinite(lastTs) && Date.now() - lastTs < APOLOGY_COOLDOWN_MS) {
        suppressApology = true;
      }
    } catch { /* 파일 없으면 첫 재시작 */ }

    if (reason) {
      const isCrash = reason.startsWith('crash:');
      const isGraceful = reason.startsWith('graceful') || reason === 'requested';
      const reasonLabel = isCrash ? `크래시: ${reason.slice(7)}`
        : reason === 'requested' ? '요청됨'
        : reason.startsWith('graceful') ? '정상 종료'
        : reason;

      // 활성 세션 채널에 알림 (graceful shutdown: 진행 중이던 채널만)
      if (notifyChannels.length > 0 && !suppressApology) {
        const isRequestedRestart = isGraceful;
        const restartMsg = isRequestedRestart
          ? '-# ✅ 재시작됐습니다.'
          : `🔄 재시작됐습니다. 이전 응답이 중단되었으니 다시 말씀해 주세요.\n> ⚠️ 사유: ${reasonLabel}`;
        const quietIds = (process.env.QUIET_CHANNEL_IDS || '').split(',').map(s => s.trim()).filter(Boolean);
        for (const chId of notifyChannels.filter(id => !quietIds.includes(id))) {
          const ch = client.channels.cache.get(chId) || await client.channels.fetch(chId).catch(() => null);
          if (ch) {
            await ch.send(restartMsg).catch(() => {});
          }
        }
        try { writeFileSync(apologyCooldownFile, String(Date.now())); } catch { /* best effort */ }
      }

      // 비정상 종료(크래시/watchdog kill)이고 활성 채널이 없을 때 → 메인채널에 알림
      if (!isGraceful && notifyChannels.length === 0 && !suppressApology) {
        try {
          const ownerAlertId = process.env.OWNER_ALERT_CHANNEL_ID || '1468386844621144065';
          const ch = client.channels.cache.get(ownerAlertId) || await client.channels.fetch(ownerAlertId).catch(() => null);
          if (ch?.isTextBased()) {
            await ch.send(`-# 🔄 재시작됨 — 이전 대화 맥락은 세션 요약으로 복구됩니다. (${reasonLabel})`).catch(() => {});
          }
          try { writeFileSync(apologyCooldownFile, String(Date.now())); } catch { /* best effort */ }
        } catch { /* best effort */ }
      }

      if (suppressApology) {
        log('info', 'Bot restarted (apology suppressed — cooldown active)', { reason });
      } else {
        log('info', 'Bot restarted', { reason, notifiedChannels: notifyChannels.length });
      }
    }
  } catch { /* clean start, skip */ }

  // ---------------------------------------------------------------------------
  // Unified Health Monitor (replaces heartbeat + WS self-ping)
  // - 5분마다 실행
  // - heartbeat 파일 기록 (외부 watchdog용)
  // - WS 상태 + 이벤트 흐름 + API 생존 확인
  // - 좀비 세션 감지 시 자동 재연결
  // ---------------------------------------------------------------------------
  const HEALTH_INTERVAL = 300_000;      // 5분
  const SILENCE_THRESHOLD = 600_000;    // 10분 무메시지 → 의심
  const FORCE_RECONNECT_CHECKS = 144;   // API OK 상태로 144회(12시간) 이상 침묵 → 강제 재연결
  const heartbeatFile = join(BOT_HOME, 'state', 'bot-heartbeat');
  const writeHeartbeat = () => {
    try { writeFileSync(heartbeatFile, String(Date.now())); } catch { /* best effort */ }
  };
  writeHeartbeat();

  let _healthRunning = false;
  let _silentApiOkCount = 0; // API OK인데 이벤트 없는 연속 횟수
  healthMonitorInterval = setInterval(async () => {
    if (_healthRunning) return; // 이전 체크가 아직 실행 중이면 스킵
    _healthRunning = true;
    try {
    const wsStatus = client.ws?.status ?? -1;
    const wsPing = client.ws?.ping ?? -1;
    const silenceMs = Date.now() - lastMessageAt;
    const uptimeSec = Math.floor(process.uptime());
    const memMB = Math.round(process.memoryUsage().rss / 1024 / 1024);

    log('info', 'Health check', {
      wsStatus, wsPing,
      silenceSec: Math.floor(silenceMs / 1000),
      uptimeSec, memMB,
      guilds: client.guilds?.cache?.size ?? 0,
    });

    // OOM 사전 차단 (v4.44 2026-04-27 주인님 면접 중 938MB OOM 재시작 사고 — cap 정렬):
    // 이전 800MB cap → watchdog 정책(WARN 900 / SOFT 1100 / CRITICAL 1400)과 충돌.
    // 정상 운용(LanceDB 인덱스 + RAG 컨텍스트 + Claude 세션) 합산 800~1100MB에 쉽게 도달 → 면접 중 자가 재시작 = 흐름 절단.
    // 신규 1300MB: watchdog SOFT(1100) 위 + CRITICAL(1400) 아래. watchdog SOFT 재시작이 우선 발동(조용한 재시작), 이 cap은 watchdog 실패 시 마지막 안전망.
    const MEM_LIMIT_MB = 1300;
    if (memMB > MEM_LIMIT_MB) {
      log('error', `OOM threshold exceeded (${memMB}MB > ${MEM_LIMIT_MB}MB) — restarting cleanly`, { memMB });
      sendNtfy(`${BOT_NAME} OOM restart`, `메모리 ${memMB}MB 초과, 재시작`, 'high');
      // restart-notify.json 기록 → 재시작 후 Discord에 proper reason 표시
      try {
        writeFileSync(join(BOT_HOME, 'state', 'restart-notify.json'),
          JSON.stringify({ channels: [], ts: Date.now(), reason: `OOM restart (${memMB}MB > ${MEM_LIMIT_MB}MB)`, requestedRestart: false }));
      } catch { /* best effort */ }
      setTimeout(() => process.exit(1), 1000);
      return;
    }

    // Case 1: WS explicitly not ready → discord.js auto-reconnect에 맡기되 경고
    // heartbeat 안 씀 → watchdog이 15분 후 외부에서 강제 재시작
    if (wsStatus !== 0) {
      log('warn', `WS not READY (status=${wsStatus}). Skipping heartbeat.`);
      return;
    }

    // Case 2: WS "정상"인데 10분 이상 이벤트 없음 → 좀비 의심, API로 확인
    if (silenceMs > SILENCE_THRESHOLD) {
      log('warn', `No events for ${Math.floor(silenceMs / 1000)}s — verifying session via API`);
      try {
        await client.user.fetch(true);
        _silentApiOkCount++;
        log('info', `API liveness OK — session alive, just quiet (silent_ok_count=${_silentApiOkCount})`);

        // HTTP는 OK지만 Gateway가 이벤트를 안 보내는 상태 감지:
        // 12시간(144회) 이상 API-OK + 침묵 → Gateway 좀비 → 강제 재연결
        // 단, wsPing < 3000ms 이면 WebSocket 헬스 정상 → 단순 idle로 판단, 스킵
        const wsPingNow = client.ws.ping;
        if (_silentApiOkCount >= FORCE_RECONNECT_CHECKS && wsPingNow >= 3000) {
          log('warn', `Gateway silent for ${_silentApiOkCount} checks — forcing reconnect`);
          botAlerts.push({
            title: `${BOT_NAME} Gateway 침묵 감지`,
            message: `API OK지만 ${_silentApiOkCount * 5}분 이상 이벤트 없음. Gateway 강제 재연결.`,
            level: 'high',
          });
          _silentApiOkCount = 0;
          log('warn', 'Gateway forced reconnect: exiting for launchd clean restart');
          process.exit(1);
        }

        writeHeartbeat(); // API 성공 → 진짜 살아있음 → heartbeat 갱신
      } catch (err) {
        // API 실패 → 좀비 확정. heartbeat 안 씀 → watchdog이 백업으로 감지
        _silentApiOkCount = 0;
        log('error', 'API liveness FAILED — zombie session detected', { error: err.message });
        botAlerts.push({
          title: `${BOT_NAME} 좀비 세션 감지`,
          message: `WS status=0이지만 API 실패: ${err.message}. 재연결 시도.`,
          level: 'high',
        });
        log('error', 'Zombie recovery: exiting for launchd clean restart');
        process.exit(1);
      }
      return;
    }

    // Case 3: 정상 — 이벤트 흐름 있고 WS 연결 정상
    _silentApiOkCount = 0; // 이벤트 왔으면 카운터 리셋
    writeHeartbeat();

    // Write active-session indicator for watchdog
    const activeSessionFile = join(BOT_HOME, 'state', 'active-session');
    try {
      const activeCount = activeProcesses?.size ?? 0;
      if (activeCount > 0) {
        writeFileSync(activeSessionFile, String(Date.now()));
      } else {
        try { rmSync(activeSessionFile, { force: true }); } catch { /* ok */ }
      }
    } catch { /* best effort */ }
    } finally { _healthRunning = false; }
  }, HEALTH_INTERVAL);

  // L3 request polling (pick up bash-originated approval requests every 10s)
  l3PollInterval = setInterval(() => pollL3Requests(client), 10_000);
});

const handlerState = { sessions, rateTracker, semaphore, activeProcesses, client };

client.on('messageCreate', (message) => {
  if (isShuttingDown) return; // 종료 중 신규 세션 생성 차단 — orphan 방지
  lastMessageAt = Date.now();
  handleMessage(message, handlerState).catch(async (err) => {
    log('error', 'Unhandled error in handleMessage', { error: err.message, stack: err.stack });
    try {
      const { appendFileSync } = await import('node:fs');
      appendFileSync('/tmp/jarvis-guard-debug.log',
        `\n[${new Date().toISOString()}] HANDLER ERROR\n  msg: ${err.message}\n  stack: ${err.stack?.slice(0,1000)}\n`
      );
    } catch {}
  });
});

const interactionDeps = {
  sessions, activeProcesses, rateTracker, client,
  BOT_HOME, BOT_NAME, HOME,
  get lastMessageAt() { return lastMessageAt; },
  maxConcurrent: MAX_CONCURRENT,
};

client.on('interactionCreate', async (interaction) => {
  log('debug', 'interactionCreate received', {
    type: interaction.type,
    isButton: interaction.isButton?.(),
    customId: interaction.customId ?? null,
    channelId: interaction.channelId ?? null,
  });
  try {
    // L3 approval buttons — check before slash commands
    if (await handleApprovalInteraction(interaction)) return;

    await handleInteraction(interaction, interactionDeps);
  } catch (err) {
    log('error', 'Unhandled error in interactionCreate', { error: err.message, stack: err.stack?.slice(0, 300) });
  }
});

client.on('error', (err) => {
  log('error', 'Discord client error', { error: err.message });
});

client.on('warn', (msg) => {
  log('warn', `Discord warning: ${msg}`);
});

client.on('shardDisconnect', (event, shardId) => {
  log('warn', 'Discord disconnected', { code: event.code, shardId });
  botAlerts.push({ title: `${BOT_NAME} 연결 끊김`, message: `Shard ${shardId} disconnected (code: ${event.code})`, level: 'default' });
});

client.on('shardReconnecting', (shardId) => {
  log('info', 'Discord reconnecting', { shardId });
});

client.on('shardResume', (shardId, replayedEvents) => {
  log('info', 'Discord resumed', { shardId, replayedEvents });
  // Recovery apologies disabled
});

client.on('shardError', (err, shardId) => {
  log('error', `Shard ${shardId} error`, { error: err.message });
  botAlerts.push({ title: `${BOT_NAME} Shard Error`, message: `Shard ${shardId}: ${err.message}`, level: 'high' });
});

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

let isShuttingDown = false;

async function shutdown(signal) {
  isShuttingDown = true; // 즉시 플래그 — messageCreate 핸들러가 신규 세션 생성 차단
  log('info', `Received ${signal}, shutting down`);

  // Hard exit timeout — prevent hanging shutdown
  setTimeout(() => process.exit(1), 10000);

  // Clear all intervals
  if (healthMonitorInterval) clearInterval(healthMonitorInterval);
  if (l3PollInterval) clearInterval(l3PollInterval);

  // 활성 세션 채널 기록 → 재시작 후 알림용
  const activeChannels = [];
  const streamerFinalizations = [];
  for (const [threadId, entry] of activeProcesses) {
    // sessionKey는 "channelId-userId" 또는 threadId 형식 — 채널 ID만 추출
    const channelId = threadId.includes('-') ? threadId.split('-')[0] : threadId;
    activeChannels.push(channelId);
    log('info', 'Killing active process', { threadId });
    clearTimeout(entry.timeout);
    if (entry.typingInterval) clearInterval(entry.typingInterval);
    // Save pending task so user can resume with "계속"
    if (entry.originalPrompt && entry.sessionKey) {
      try {
        const pendingPath = join(BOT_HOME, 'state', 'pending-tasks.json');
        let tasks = {};
        if (existsSync(pendingPath)) {
          try { tasks = JSON.parse(readFileSync(pendingPath, 'utf-8')); } catch { tasks = {}; }
        }
        tasks[entry.sessionKey] = { prompt: entry.originalPrompt, savedAt: Date.now(), checkpoints: [] };
        const pendingTmp = `${pendingPath}.tmp`;
        writeFileSync(pendingTmp, JSON.stringify(tasks));
        renameSync(pendingTmp, pendingPath);
        log('info', 'Pending task saved on SIGTERM', { sessionKey: entry.sessionKey });
      } catch (e) {
        log('warn', 'Failed to save pending task on SIGTERM', { error: e.message });
      }
    }
    entry.proc.kill('SIGTERM');
    // 진행 중인 스트리머 finalize — client.destroy() 전에 Discord에 마지막 청크 전송
    if (entry.streamer && !entry.streamer.finalized) {
      streamerFinalizations.push(
        entry.streamer.finalize().catch(err => log('warn', 'Streamer finalize on shutdown failed', { error: err.message }))
      );
    }
  }
  // 활성 채널 없으면 마지막 활성 채널을 폴백으로 사용 (사용자 요청 재시작 알림용)
  let requestedRestart = false;
  if (activeChannels.length === 0) {
    try {
      const lastCh = readFileSync(join(BOT_HOME, 'state', 'last-active-channel'), 'utf-8').trim();
      if (lastCh) { activeChannels.push(lastCh); requestedRestart = true; }
    } catch { /* 파일 없으면 skip */ }
  }
  // 종료 사유 + 활성 채널 기록 → 재시작 후 알림용
  try {
    writeFileSync(join(BOT_HOME, 'state', 'restart-notify.json'),
      JSON.stringify({ channels: activeChannels, ts: Date.now(), reason: `graceful (${signal})`, requestedRestart }));
  } catch { /* best effort */ }
  activeProcesses.clear();
  // SDK ProcessTransport.close()가 2s 타이머(.unref())로 SIGTERM을 예약함.
  // 활성 프로세스가 있었다면 최소 2.5s 대기해야 타이머가 실행돼 자식 claude가 정리됨.
  // 스트리머 finalize도 함께 대기 (최대 8초 — hard exit timeout 10초보다 짧게)
  const hadActiveProcesses = activeChannels.length > 0;
  if (streamerFinalizations.length > 0 || hadActiveProcesses) {
    const waitMs = streamerFinalizations.length > 0 ? 8000 : 2500;
    if (streamerFinalizations.length > 0) {
      log('info', `Waiting for ${streamerFinalizations.length} streamer(s) to finalize`);
    } else {
      log('info', 'Waiting 2.5s for SDK child process cleanup');
    }
    await Promise.race([
      Promise.allSettled(streamerFinalizations.length > 0 ? streamerFinalizations : [Promise.resolve()]),
      new Promise(resolve => setTimeout(resolve, waitMs)),
    ]);
  }
  // Release all semaphore slots before exit
  while (semaphore.current > 0) {
    await semaphore.release();
  }
  await botAlerts.shutdown();
  closeRagEngine();
  sessions.save();
  // SESSION_END marker → session-sync cron이 context-bus 즉시 갱신에 사용
  // getSessionHistoryFile()로 현재 세션 파일에 기록 (세션 단위 파일 분리 아키텍처)
  try {
    const kst = new Date(Date.now() + 9 * 3600 * 1000);
    const dateStr = kst.toISOString().slice(0, 10);
    const timeStr = kst.toISOString().slice(11, 16);
    const marker = `\n## [${dateStr} ${timeStr} KST] SESSION_END\n\n봇 종료 (${signal}). session-sync가 context-bus를 갱신합니다.\n\n---\n`;
    appendFileSync(getSessionHistoryFile(), marker, 'utf-8');
  } catch { /* best effort — 실패해도 종료는 진행 */ }
  client.destroy();
  log('info', 'Shutdown complete');
  process.exit(0);
}

process.on('SIGTERM', () => { shutdown('SIGTERM').catch(err => { log('error', 'Shutdown error', { error: err.message }); process.exit(1); }); });
process.on('SIGINT', () => { shutdown('SIGINT').catch(err => { log('error', 'Shutdown error', { error: err.message }); process.exit(1); }); });

// QW5: Catch uncaught exceptions — log, notify, then exit for launchd restart
process.on('uncaughtException', (err) => {
  log('error', '[fatal] uncaughtException', {
    error: err.message,
    stack: err.stack,
  });
  // 크래시 시 진행 중인 작업 pending-tasks.json에 동기 저장 (사용자가 "계속"으로 복구 가능)
  try {
    const pendingPath = join(BOT_HOME, 'state', 'pending-tasks.json');
    let tasks = {};
    if (existsSync(pendingPath)) {
      try { tasks = JSON.parse(readFileSync(pendingPath, 'utf-8')); } catch { tasks = {}; }
    }
    for (const [, entry] of activeProcesses) {
      if (entry.originalPrompt && entry.sessionKey) {
        tasks[entry.sessionKey] = { prompt: entry.originalPrompt, savedAt: Date.now(), checkpoints: [] };
      }
    }
    if (Object.keys(tasks).length > 0) {
      const pendingTmp = `${pendingPath}.tmp`;
      writeFileSync(pendingTmp, JSON.stringify(tasks));
      renameSync(pendingTmp, pendingPath);
    }
  } catch { /* best effort — 크래시 핸들러에서 추가 실패 무시 */ }
  try {
    writeFileSync(join(BOT_HOME, 'state', 'restart-notify.json'),
      JSON.stringify({ channels: [], ts: Date.now(), reason: `crash: ${err.message.slice(0, 100)}` }));
  } catch { /* best effort */ }
  try {
    sendNtfy(`${BOT_NAME} uncaughtException`, err.message, 'urgent');
  } catch { /* best effort */ }
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  const code = reason?.code;
  const msg = reason instanceof Error ? reason.message : String(reason);

  // 무시해도 안전한 노이즈성 에러 (discord.js 내부 rate-limit, 네트워크 일시 오류)
  const BENIGN_PATTERNS = [
    'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND',
    'DiscordAPIError[10008]',  // Unknown Message (삭제된 메시지 편집 시도)
    'DiscordAPIError[10062]',  // Unknown interaction (timeout)
    'DiscordAPIError[40060]',  // Interaction already acknowledged
    'Missing Permissions',
    'Cannot send messages to this user',
  ];
  const isBenign = BENIGN_PATTERNS.some(p => msg.includes(p));
  // compactSession 백그라운드 작업 실패 — 봇 재시작 불필요
  const isCompactFailure = reason instanceof Error &&
    reason.stack?.includes('compactSessionWithAI');

  if (isBenign) {
    log('warn', 'Unhandled rejection (benign, ignored)', { error: msg });
    return;
  }

  if (isCompactFailure) {
    log('warn', 'Unhandled rejection (compactSession, ignored)', { error: msg });
    return;
  }

  log('error', 'Unhandled rejection', {
    error: msg,
    stack: reason instanceof Error ? reason.stack : undefined,
  });

  if (code === 'TokenInvalid' || msg.includes('TokenInvalid') || msg.includes('invalid token')) {
    const backoffFile = '/tmp/jarvis-token-backoff';
    let count = 0;
    try { count = parseInt(readFileSync(backoffFile, 'utf-8'), 10) || 0; } catch {}
    count++;
    writeFileSync(backoffFile, String(count));
    const delaySec = Math.min(count * 30, 300);
    log('error', `TokenInvalid #${count}, waiting ${delaySec}s before exit`);
    setTimeout(() => process.exit(1), delaySec * 1000);
    return;
  }

  // 알 수 없는 치명적 rejection → ntfy 후 3초 뒤 종료 (launchd 재시작)
  sendNtfy(`${BOT_NAME} Crash`, msg, 'urgent');
  setTimeout(() => process.exit(1), 3000);
});

// ---------------------------------------------------------------------------
// Singleton guard — 중복 프로세스 방지
// ---------------------------------------------------------------------------

const PID_FILE = join(BOT_HOME, 'state', 'bot.pid');

(function enforceSingleton() {
  if (existsSync(PID_FILE)) {
    const oldPid = parseInt(readFileSync(PID_FILE, 'utf8').trim(), 10);
    if (oldPid && oldPid !== process.pid) {
      try {
        process.kill(oldPid, 0); // 생존 확인
        log('warn', `[Singleton] 기존 프로세스 감지 (PID ${oldPid}) → 종료합니다`);
        process.kill(oldPid, 'SIGTERM');
        // SIGTERM 후 300ms 대기 후 SIGKILL fallback
        const killDeadline = Date.now() + 300;
        while (Date.now() < killDeadline) {
          try { process.kill(oldPid, 0); } catch { break; }
        }
        try { process.kill(oldPid, 'SIGKILL'); } catch { /* 이미 종료됨 */ }
      } catch {
        // oldPid 프로세스 없음 — stale PID 파일 (비정상 종료)
        // 다음 startup 알림이 proper reason을 보여줄 수 있도록 restart-notify.json 기록
        try {
          const notifyPath = join(BOT_HOME, 'state', 'restart-notify.json');
          if (!existsSync(notifyPath)) {
            writeFileSync(notifyPath, JSON.stringify({ channels: [], ts: Date.now(), reason: 'unexpected shutdown (stale PID)', requestedRestart: false }));
          }
        } catch { /* best effort */ }
        log('warn', `[Singleton] 스테일 PID 감지 (PID ${oldPid} 없음) — 비정상 종료 추정`);
      }
    }
  }
  writeFileSync(PID_FILE, String(process.pid), 'utf8');
  log('info', `[Singleton] PID ${process.pid} 등록 완료`);
})();

// 종료 시 PID 파일 정리
const _cleanupPid = () => { try { rmSync(PID_FILE); } catch { /* ignore */ } };
process.on('exit', _cleanupPid);

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const token = process.env.DISCORD_TOKEN;
if (!token) {
  console.error('DISCORD_TOKEN not set in .env');
  process.exit(1);
}

client.login(token);