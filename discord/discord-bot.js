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
import {
  Client,
  GatewayIntentBits,
  SlashCommandBuilder,
  REST,
  Routes,
} from 'discord.js';
import 'dotenv/config';

import { log, sendNtfy } from './lib/claude-runner.js';
import { SessionStore, RateTracker, Semaphore } from './lib/session.js';
import { handleMessage } from './lib/handlers.js';
import { handleInteraction } from './lib/commands.js';
import { handleApprovalInteraction, pollL3Requests } from './lib/approval.js';
import { t } from './lib/i18n.js';
import { initAlertBatcher, botAlerts } from './lib/alert-batcher.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const BOT_HOME = join(process.env.BOT_HOME || join(HOME, '.jarvis'));
const SESSIONS_PATH = join(BOT_HOME, 'state', 'sessions.json');
const RATE_TRACKER_PATH = join(BOT_HOME, 'state', 'rate-tracker.json');
const MAX_CONCURRENT = 2;
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
          )
      ),
  ];

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
});

let lastMessageAt = Date.now();

client.once('clientReady', async () => {
  log('info', `Logged in as ${client.user.tag}`, { id: client.user.id });

  const guildId = process.env.GUILD_ID;
  if (guildId) {
    await registerSlashCommands(client.user.id, guildId);
  }

  // Init alert batcher — send batched alerts to first allowed channel
  const firstChannelId = (process.env.CHANNEL_IDS || '').split(',')[0]?.trim();
  if (firstChannelId) {
    const alertCh = client.channels.cache.get(firstChannelId) || await client.channels.fetch(firstChannelId).catch(() => null);
    if (alertCh) initAlertBatcher(alertCh);
  }

  // 10-minute heartbeat (shorter than bot-watchdog.sh 15-min threshold)
  setInterval(() => {
    const wsStatus = client.ws?.status ?? -1;
    const uptimeSec = Math.floor(process.uptime());
    const silenceSec = Math.floor((Date.now() - lastMessageAt) / 1000);
    const memMB = Math.round(process.memoryUsage().rss / 1024 / 1024);
    log('info', 'Heartbeat: alive', {
      wsStatus, uptimeSec, silenceSec,
      guilds: client.guilds?.cache?.size ?? 0, memMB,
    });
    if (wsStatus !== 0) {
      log('warn', `WebSocket not READY (status=${wsStatus}). discord.js should auto-reconnect.`);
    }
  }, 600_000);

  // L3 request polling (pick up bash-originated approval requests every 10s)
  setInterval(() => pollL3Requests(client), 10_000);

  // QW2: WebSocket self-ping every 2 hours — detect zombie connections
  setInterval(() => {
    const wsStatus = client.ws?.status ?? -1;
    if (wsStatus !== 0) {
      log('warn', `WS self-ping: status=${wsStatus}, not READY. Attempting destroy+login cycle.`);
      sendNtfy(`${BOT_NAME} WS Unhealthy`, `WebSocket status=${wsStatus}. Restarting connection.`, 'high').catch(() => {});
      client.destroy();
      client.login(process.env.DISCORD_TOKEN).catch((err) => {
        log('error', 'WS self-ping: re-login failed', { error: err.message });
        process.exit(1);
      });
    } else {
      log('info', 'WS self-ping: healthy', { ping: client.ws.ping });
    }
  }, 2 * 60 * 60 * 1000);
});

const handlerState = { sessions, rateTracker, semaphore, activeProcesses, client };

client.on('messageCreate', (message) => {
  lastMessageAt = Date.now();
  handleMessage(message, handlerState).catch((err) => {
    log('error', 'Unhandled error in handleMessage', { error: err.message, stack: err.stack });
  });
});

const interactionDeps = {
  sessions, activeProcesses, rateTracker, client,
  BOT_HOME, BOT_NAME, HOME,
  get lastMessageAt() { return lastMessageAt; },
  maxConcurrent: MAX_CONCURRENT,
};

client.on('interactionCreate', async (interaction) => {
  try {
    // L3 approval buttons — check before slash commands
    if (await handleApprovalInteraction(interaction)) return;

    await handleInteraction(interaction, interactionDeps);
  } catch (err) {
    log('error', 'Unhandled error in interactionCreate', { error: err.message });
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
});

client.on('shardError', (err, shardId) => {
  log('error', `Shard ${shardId} error`, { error: err.message });
  botAlerts.push({ title: `${BOT_NAME} Shard Error`, message: `Shard ${shardId}: ${err.message}`, level: 'high' });
});

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

async function shutdown(signal) {
  log('info', `Received ${signal}, shutting down`);
  // 활성 세션 사용자에게 재시작 안내 메시지 전송
  for (const [threadId, entry] of activeProcesses) {
    try {
      const channel = await client.channels.fetch(threadId).catch(() => null);
      if (channel) {
        await channel.send('⚠️ 봇이 재시작됩니다. 잠시 후 다시 시도해주세요.').catch(() => {});
      }
    } catch { /* best effort */ }
    log('info', 'Killing active process', { threadId });
    clearTimeout(entry.timeout);
    if (entry.typingInterval) clearInterval(entry.typingInterval);
    entry.proc.kill('SIGTERM');
  }
  activeProcesses.clear();
  await botAlerts.shutdown();
  sessions.save();
  client.destroy();
  log('info', 'Shutdown complete');
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// QW5: Catch uncaught exceptions — log, notify, then exit for launchd restart
process.on('uncaughtException', (err) => {
  log('error', '[fatal] uncaughtException', {
    error: err.message,
    stack: err.stack,
  });
  try {
    sendNtfy(`${BOT_NAME} uncaughtException`, err.message, 'urgent');
  } catch { /* best effort */ }
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  log('error', 'Unhandled rejection', {
    error: reason instanceof Error ? reason.message : String(reason),
  });
  const code = reason?.code;
  const msg = reason instanceof Error ? reason.message : String(reason);
  if (code === 'TokenInvalid' || msg.includes('TokenInvalid') || msg.includes('invalid token')) {
    log('error', 'TokenInvalid detected, exiting for launchd restart');
    process.exit(1);
  }
  sendNtfy(`${BOT_NAME} Crash`, msg, 'urgent');
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const token = process.env.DISCORD_TOKEN;
if (!token) {
  console.error('DISCORD_TOKEN not set in .env');
  process.exit(1);
}

client.login(token);
