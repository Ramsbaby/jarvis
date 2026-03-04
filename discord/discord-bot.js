/**
 * Claude Discord Bridge — Main Entry Point
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

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const BOT_HOME = join(process.env.BOT_HOME || join(HOME, '.claude-discord-bridge'));
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
  const commands = [
    new SlashCommandBuilder()
      .setName('clear')
      .setDescription(`Clear the ${BOT_NAME} session for this channel`),
    new SlashCommandBuilder()
      .setName('stop')
      .setDescription(`Stop the active ${BOT_NAME} process`),
    new SlashCommandBuilder()
      .setName('memory')
      .setDescription(`${BOT_NAME} 장기 기억 내용 보기`),
    new SlashCommandBuilder()
      .setName('remember')
      .setDescription('정보를 기억에 저장')
      .addStringOption(opt => opt.setName('content').setDescription('기억할 내용').setRequired(true)),
    new SlashCommandBuilder()
      .setName('search')
      .setDescription('RAG 시맨틱 검색')
      .addStringOption(opt => opt.setName('query').setDescription('검색할 내용').setRequired(true)),
    new SlashCommandBuilder()
      .setName('threads')
      .setDescription(`활성 ${BOT_NAME} 세션/스레드 목록`),
    new SlashCommandBuilder()
      .setName('alert')
      .setDescription('Galaxy 푸시 알림 전송')
      .addStringOption(opt => opt.setName('message').setDescription('알림 내용').setRequired(true)),
    new SlashCommandBuilder()
      .setName('status')
      .setDescription('봇 상태 대시보드 (WebSocket, rate limit, uptime)'),
    new SlashCommandBuilder()
      .setName('tasks')
      .setDescription('오늘 크론 태스크 실행 현황'),
    new SlashCommandBuilder()
      .setName('run')
      .setDescription('크론 태스크 수동 실행')
      .addStringOption(opt =>
        opt.setName('id').setDescription('태스크 ID').setRequired(true).setAutocomplete(true)
      ),
    new SlashCommandBuilder()
      .setName('schedule')
      .setDescription('나중에 실행할 태스크 예약')
      .addStringOption(opt => opt.setName('task').setDescription('실행할 내용').setRequired(true))
      .addStringOption(opt => opt.setName('in').setDescription('지연 시간').setRequired(true)
        .addChoices(
          { name: '30분', value: '30m' }, { name: '1시간', value: '1h' }, { name: '2시간', value: '2h' },
          { name: '4시간', value: '4h' }, { name: '8시간', value: '8h' },
        )),
    new SlashCommandBuilder()
      .setName('usage')
      .setDescription('Claude Code API 사용량 조회'),
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

client.on('interactionCreate', (interaction) => {
  handleInteraction(interaction, interactionDeps).catch((err) => {
    log('error', 'Unhandled error in handleInteraction', { error: err.message });
  });
});

client.on('error', (err) => {
  log('error', 'Discord client error', { error: err.message });
});

client.on('warn', (msg) => {
  log('warn', `Discord warning: ${msg}`);
});

client.on('shardDisconnect', (event, shardId) => {
  log('warn', 'Discord disconnected', { code: event.code, shardId });
  sendNtfy(`${BOT_NAME} 연결 끊김`, `Shard ${shardId} disconnected (code: ${event.code})`, 'default').catch(() => {});
});

client.on('shardReconnecting', (shardId) => {
  log('info', 'Discord reconnecting', { shardId });
});

client.on('shardResume', (shardId, replayedEvents) => {
  log('info', 'Discord resumed', { shardId, replayedEvents });
});

client.on('shardError', (err, shardId) => {
  log('error', `Shard ${shardId} error`, { error: err.message });
  sendNtfy(`${BOT_NAME} Shard Error`, `Shard ${shardId}: ${err.message}`, 'high').catch(() => {});
});

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

async function shutdown(signal) {
  log('info', `Received ${signal}, shutting down`);
  for (const [threadId, entry] of activeProcesses) {
    log('info', 'Killing active process', { threadId });
    clearTimeout(entry.timeout);
    if (entry.typingInterval) clearInterval(entry.typingInterval);
    entry.proc.kill('SIGTERM');
  }
  activeProcesses.clear();
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
