/**
 * Claude Discord Bridge — Main Entry Point
 *
 * Wraps `claude -p` CLI with streaming JSON output.
 * Manages slash commands, shared state, and client lifecycle.
 *
 * Message handling → lib/handlers.js
 * Session/rate/streaming → lib/session.js
 * Claude spawning/RAG → lib/claude-runner.js
 * Logging/ntfy → lib/claude-runner.js
 */

import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import {
  Client,
  GatewayIntentBits,
  EmbedBuilder,
  SlashCommandBuilder,
  REST,
  Routes,
} from 'discord.js';
import 'dotenv/config';

import { log, sendNtfy } from './lib/claude-runner.js';
import { SessionStore, RateTracker, Semaphore } from './lib/session.js';
import { handleMessage } from './lib/handlers.js';

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

// Load task IDs from tasks.json for autocomplete
function getTaskIds() {
  try {
    const tasksConfig = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'tasks.json'), 'utf-8'));
    return (tasksConfig.tasks || []).map(t => ({ name: `${t.id} — ${t.name}`, value: t.id }));
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Interaction handler (slash commands + button cancel)
// ---------------------------------------------------------------------------

async function handleInteraction(interaction) {
  // Cancel button handler
  if (interaction.isButton() && interaction.customId.startsWith('cancel_')) {
    const key = interaction.customId.replace('cancel_', '');
    const proc = activeProcesses.get(key);
    if (proc?.proc) {
      proc.proc.kill('SIGTERM');
      await interaction.reply({ content: '⏹️ 중단됨', ephemeral: true });
    } else {
      await interaction.reply({ content: '실행 중인 작업 없음', ephemeral: true });
    }
    return;
  }

  // Autocomplete for /run id field
  if (interaction.isAutocomplete()) {
    if (interaction.commandName === 'run') {
      const focused = interaction.options.getFocused().toLowerCase();
      const choices = getTaskIds()
        .filter(c => c.value.includes(focused) || c.name.toLowerCase().includes(focused))
        .slice(0, 25);
      await interaction.respond(choices);
    }
    return;
  }

  if (!interaction.isChatInputCommand()) return;

  // Owner-only guard for sensitive commands
  const OWNER_ID = process.env.OWNER_DISCORD_ID;
  const SENSITIVE = ['run', 'schedule', 'remember', 'alert', 'stop', 'clear'];
  if (OWNER_ID && SENSITIVE.includes(interaction.commandName) && interaction.user.id !== OWNER_ID) {
    await interaction.reply({ content: '⛔ 이 명령어는 봇 오너만 사용할 수 있습니다.', ephemeral: true });
    return;
  }

  const { commandName } = interaction;

  // Build session key: thread ID for threads, channel+user for channels
  const ch = interaction.channel;
  const sk = ch?.isThread()
    ? ch.id
    : `${ch?.id}-${interaction.user.id}`;

  if (commandName === 'clear') {
    sessions.delete(sk);
    await interaction.reply('Session cleared.');
    log('info', 'Session cleared', { sessionKey: sk });

  } else if (commandName === 'stop') {
    const active = activeProcesses.get(sk);
    if (active) {
      active.proc.kill('SIGTERM');
      setTimeout(() => { if (!active.proc.killed) active.proc.kill('SIGKILL'); }, 3000);
      await interaction.reply(`Stopping ${BOT_NAME} process...`);
      log('info', 'Process stopped via /stop', { sessionKey: sk });
    } else {
      await interaction.reply({ content: 'No active process.', ephemeral: true });
    }

  } else if (commandName === 'memory') {
    const memPath = join(BOT_HOME, 'rag', 'memory.md');
    const content = existsSync(memPath) ? readFileSync(memPath, 'utf8') : '메모리가 비어있습니다.';
    await interaction.reply({ content: content.slice(0, 1900) });

  } else if (commandName === 'remember') {
    const text = interaction.options.getString('content');
    const memPath = join(BOT_HOME, 'rag', 'memory.md');
    const timestamp = new Date().toISOString().slice(0, 10);
    appendFileSync(memPath, `\n- [${timestamp}] ${text}`);
    await interaction.reply({ content: `기억했습니다: ${text}` });
    log('info', 'Memory saved via /remember', { text: text.slice(0, 100) });

  } else if (commandName === 'search') {
    await interaction.deferReply();
    const query = interaction.options.getString('query');
    try {
      const { execFileSync } = await import('node:child_process');
      const result = execFileSync(
        'node', [join(BOT_HOME, 'lib', 'rag-query.mjs'), query],
        { timeout: 10000, encoding: 'utf-8' },
      );
      await interaction.editReply(result.slice(0, 1900) || '검색 결과가 없습니다.');
    } catch (err) {
      await interaction.editReply('RAG 검색 실패: ' + (err.message?.slice(0, 200) || 'Unknown error'));
    }

  } else if (commandName === 'threads') {
    const entries = Object.entries(sessions.data);
    if (entries.length === 0) {
      await interaction.reply({ content: '활성 세션이 없습니다.', ephemeral: true });
    } else {
      const list = entries
        .slice(0, 20)
        .map(([key, sid]) => `• \`${key}\` → \`${sid.id?.slice(0, 8) ?? sid.slice?.(0, 8)}…\``)
        .join('\n');
      await interaction.reply({
        content: `**활성 세션 (${entries.length}개)**\n${list}`,
        ephemeral: true,
      });
    }

  } else if (commandName === 'alert') {
    const msg = interaction.options.getString('message');
    await sendNtfy(`${BOT_NAME} Alert`, msg, 'high');
    await interaction.reply({ content: `ntfy 전송 완료: ${msg}`, ephemeral: true });

  } else if (commandName === 'status') {
    await interaction.deferReply({ ephemeral: true });
    const uptimeSec = Math.floor(process.uptime());
    const uptimeStr = `${Math.floor(uptimeSec / 3600)}h ${Math.floor((uptimeSec % 3600) / 60)}m`;
    const silenceSec = Math.floor((Date.now() - lastMessageAt) / 1000);
    const wsStatusNames = ['READY','CONNECTING','RECONNECTING','IDLE','NEARLY','DISCONNECTED','WAITING_FOR_GUILDS','IDENTIFYING','RESUMING'];
    const wsCode = client.ws.status ?? -1;
    const wsStatus = wsStatusNames[wsCode] ?? `UNKNOWN(${wsCode})`;
    const wsHealthy = wsCode === 0;
    const rate = rateTracker.check();
    const memMB = Math.round(process.memoryUsage().rss / 1024 / 1024);
    const pingMs = client.ws.ping;
    const embed = new EmbedBuilder()
      .setTitle(`${BOT_NAME} 시스템 상태`)
      .setColor(wsHealthy && !rate.warn ? 0x2ecc71 : rate.reject ? 0xe74c3c : 0xf39c12)
      .addFields(
        { name: '🔌 WebSocket', value: `\`${wsStatus}\`${pingMs >= 0 ? ` (${pingMs}ms)` : ''}`, inline: true },
        { name: '⏱️ 업타임', value: `\`${uptimeStr}\``, inline: true },
        { name: '🔇 마지막 이벤트', value: `\`${silenceSec}초 전\``, inline: true },
        { name: '📊 Rate limit', value: `\`${rate.count}/${rate.max}\` (${Math.round(rate.pct * 100)}%)`, inline: true },
        { name: '⚡ 활성 프로세스', value: `\`${activeProcesses.size}/${MAX_CONCURRENT}\``, inline: true },
        { name: '💬 세션', value: `\`${Object.keys(sessions.data).length}개\``, inline: true },
        { name: '💾 메모리', value: `\`${memMB}MB\``, inline: true },
      )
      .setTimestamp();
    await interaction.editReply({ embeds: [embed] });

  } else if (commandName === 'tasks') {
    await interaction.deferReply({ ephemeral: true });
    try {
      const { execSync } = await import('node:child_process');
      const logPath = join(BOT_HOME, 'logs', 'cron.log');
      const today = new Date().toISOString().slice(0, 10);
      const raw = execSync(`grep "${today}" "${logPath}" 2>/dev/null | tail -100`, { encoding: 'utf-8' });
      const taskStats = {};
      for (const line of raw.split('\n')) {
        const m = line.match(/\[([^\]]+)\] (SUCCESS|FAIL)/);
        if (!m) continue;
        const [, name, status] = m;
        if (!taskStats[name]) taskStats[name] = { ok: 0, fail: 0 };
        if (status === 'SUCCESS') taskStats[name].ok++;
        else taskStats[name].fail++;
      }
      if (Object.keys(taskStats).length === 0) {
        await interaction.editReply('오늘 실행된 크론 태스크가 없습니다.');
        return;
      }
      const lines = Object.entries(taskStats).map(([name, s]) =>
        `${s.fail > 0 ? '❌' : '✅'} \`${name}\`: ${s.ok}성공${s.fail > 0 ? ' ' + s.fail + '실패' : ''}`
      );
      await interaction.editReply(`**오늘 태스크 현황 (${today})**\n${lines.join('\n')}`.slice(0, 1900));
    } catch (err) {
      await interaction.editReply('태스크 로그 읽기 실패: ' + err.message?.slice(0, 200));
    }

  } else if (commandName === 'run') {
    const taskId = interaction.options.getString('id');
    const taskIds = getTaskIds().map(t => t.value);
    if (!taskIds.includes(taskId)) {
      await interaction.reply({ content: `❌ 태스크 ID \`${taskId}\` 를 찾을 수 없습니다.`, ephemeral: true });
      return;
    }
    await interaction.deferReply();
    try {
      const { execFileSync } = await import('node:child_process');
      const cronScript = join(BOT_HOME, 'bin', 'bot-cron.sh');
      log('info', 'Manual task run via /run', { taskId, user: interaction.user.tag });
      execFileSync('/bin/bash', [cronScript, taskId], {
        timeout: 300_000,
        encoding: 'utf-8',
        env: { ...process.env, HOME },
      });
      const embed = new EmbedBuilder()
        .setTitle(`✅ 태스크 완료: \`${taskId}\``)
        .setColor(0x2ecc71)
        .setDescription(`**${interaction.user.tag}** 님이 수동 실행했습니다.`)
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });
    } catch (err) {
      const embed = new EmbedBuilder()
        .setTitle(`❌ 태스크 실패: \`${taskId}\``)
        .setColor(0xe74c3c)
        .setDescription('```\n' + (err.message || 'Unknown error').slice(0, 500) + '\n```')
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });
      log('error', 'Manual task run failed', { taskId, error: err.message?.slice(0, 200) });
    }

  } else if (commandName === 'schedule') {
    const task = interaction.options.getString('task');
    const delay = interaction.options.getString('in');
    const delayMs = { '30m': 30, '1h': 60, '2h': 120, '4h': 240, '8h': 480 }[delay] * 60 * 1000;
    const scheduleAt = new Date(Date.now() + delayMs).toISOString();
    const queueDir = join(BOT_HOME, 'queue');
    mkdirSync(queueDir, { recursive: true });
    const fname = join(queueDir, `${Date.now()}_${Math.random().toString(36).slice(2)}.json`);
    const payload = { prompt: task, schedule_at: scheduleAt, created_by: interaction.user.tag, channel: interaction.channelId };
    writeFileSync(fname, JSON.stringify(payload, null, 2));
    await interaction.reply(`✅ **${delay}** 후 실행 예약됨\n> ${task}`);

  } else if (commandName === 'usage') {
    await interaction.deferReply();
    try {
      const cachePath = join(HOME, '.claude', 'usage-cache.json');
      const cfgPath   = join(HOME, '.claude', 'usage-config.json');
      const statsPath = join(HOME, '.claude', 'stats-cache.json');

      if (!existsSync(cachePath)) {
        await interaction.editReply('❌ 사용량 캐시 없음. Claude Code를 한 번 실행해주세요.');
        return;
      }

      const cache = JSON.parse(readFileSync(cachePath, 'utf-8'));
      const cfg   = existsSync(cfgPath) ? JSON.parse(readFileSync(cfgPath, 'utf-8')) : {};
      const limits = cfg.limits ?? {};

      const bar = (pct) => {
        const filled = Math.round(pct / 10);
        return '█'.repeat(filled) + '░'.repeat(10 - filled);
      };
      const color = (pct) => pct >= 90 ? 0xed4245 : pct >= 70 ? 0xfee75c : 0x57f287;

      const fiveH  = cache.fiveH  ?? {};
      const sevenD = cache.sevenD ?? {};
      const sonnet = cache.sonnet ?? {};
      const maxPct = Math.max(fiveH.pct ?? 0, sevenD.pct ?? 0, sonnet.pct ?? 0);
      const ts = cache.ts ? new Date(cache.ts) : null;
      const tsStr = ts ? ts.toLocaleString('ko-KR', { timeZone: cfg.timezone ?? 'Asia/Seoul', hour12: false }) : '알 수 없음';

      const embed = new EmbedBuilder()
        .setColor(color(maxPct))
        .setTitle('⚡ Claude Max 사용량')
        .addFields(
          {
            name: `5시간 한도 (${limits.fiveH?.toLocaleString() ?? '?'} msgs)`,
            value: `\`${bar(fiveH.pct ?? 0)}\` **${fiveH.pct ?? '?'}%** — ${fiveH.remain ?? '?'} 남음\n리셋: ${fiveH.reset ?? '?'} (${fiveH.resetIn ?? '?'} 후)`,
            inline: false,
          },
          {
            name: `7일 한도 (${limits.sevenD?.toLocaleString() ?? '?'} msgs)`,
            value: `\`${bar(sevenD.pct ?? 0)}\` **${sevenD.pct ?? '?'}%** — ${sevenD.remain ?? '?'} 남음\n리셋: ${sevenD.reset ?? '?'} (${sevenD.resetIn ?? '?'} 후)`,
            inline: false,
          },
          {
            name: `Sonnet 7일 (${limits.sonnet7D?.toLocaleString() ?? '?'} msgs)`,
            value: `\`${bar(sonnet.pct ?? 0)}\` **${sonnet.pct ?? '?'}%** — ${sonnet.remain ?? '?'} 남음\n리셋: ${sonnet.reset ?? '?'} (${sonnet.resetIn ?? '?'} 후)`,
            inline: false,
          },
        )
        .setFooter({ text: `캐시 기준: ${tsStr}` })
        .setTimestamp();

      if (existsSync(statsPath)) {
        try {
          const stats = JSON.parse(readFileSync(statsPath, 'utf-8'));
          const recent = (stats.dailyActivity ?? []).slice(-3).reverse();
          if (recent.length > 0) {
            const rows = recent.map(d => `\`${d.date}\` ${d.messageCount}msg / ${d.toolCallCount}tools`).join('\n');
            embed.addFields({ name: '최근 3일 활동', value: rows, inline: false });
          }
        } catch { /* stats 파싱 실패 무시 */ }
      }

      await interaction.editReply({ embeds: [embed] });
    } catch (err) {
      await interaction.editReply('❌ 사용량 조회 실패: ' + (err.message?.slice(0, 300) || 'Unknown error'));
      log('error', 'Usage command failed', { error: err.message?.slice(0, 200) });
    }
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
});

const handlerState = { sessions, rateTracker, semaphore, activeProcesses, client };

client.on('messageCreate', (message) => {
  lastMessageAt = Date.now();
  handleMessage(message, handlerState).catch((err) => {
    log('error', 'Unhandled error in handleMessage', { error: err.message, stack: err.stack });
  });
});

client.on('interactionCreate', (interaction) => {
  handleInteraction(interaction).catch((err) => {
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
