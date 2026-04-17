/**
 * Slash command and interaction handler — extracted from discord-bot.js.
 *
 * Exports: handleInteraction(interaction, deps)
 *   deps = { sessions, activeProcesses, rateTracker, client, BOT_HOME, BOT_NAME, HOME }
 */

import { readFileSync, existsSync, appendFileSync, writeFileSync, mkdirSync, readdirSync, renameSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import discordPkg from 'discord.js';
const { EmbedBuilder, MessageFlags } = discordPkg;
import { log, sendNtfy } from './claude-runner.js';
import { lastQueryStore } from './streaming.js';
import { rerunQuery, clearProcessedId } from './handlers.js';
import { userMemory } from '../../lib/user-memory.mjs';
import { t } from './i18n.js';
import { getActivities } from './lounge.js';

// Cross-platform: launchctl은 macOS 전용
const IS_MACOS = process.platform === 'darwin';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Load task IDs from tasks.json for autocomplete */
function getTaskIds(botHome) {
  try {
    const tasksConfig = JSON.parse(readFileSync(join(botHome, 'config', 'tasks.json'), 'utf-8'));
    return (tasksConfig.tasks || []).map(t => ({ name: `${t.id} — ${t.name}`, value: t.id }));
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// handleInteraction
// ---------------------------------------------------------------------------

/**
 * @param {import('discord.js').Interaction} interaction
 * @param {object} deps
 * @param {import('./session.js').SessionStore} deps.sessions
 * @param {Map} deps.activeProcesses
 * @param {import('./session.js').RateTracker} deps.rateTracker
 * @param {import('discord.js').Client} deps.client
 * @param {string} deps.BOT_HOME
 * @param {string} deps.BOT_NAME
 * @param {string} deps.HOME
 * @param {number} deps.lastMessageAt
 */
export async function handleInteraction(interaction, deps) {
  const { sessions, activeProcesses, rateTracker, client, BOT_HOME, BOT_NAME, HOME } = deps;

  // Cancel button handler
  if (interaction.isButton() && interaction.customId.startsWith('cancel_')) {
    const key = interaction.customId.replace('cancel_', '');
    const proc = activeProcesses.get(key);
    if (proc?.proc) {
      proc.proc.kill('manual'); // 'manual': 사용자 수동 중단 — auto-resume 차단용
      await interaction.reply({ content: t('cmd.cancel.stopped'), flags: MessageFlags.Ephemeral });
    } else {
      await interaction.reply({ content: t('cmd.cancel.noProcess'), flags: MessageFlags.Ephemeral });
    }
    return;
  }

  // Regen button — 저장된 쿼리로 Claude 재실행
  if (interaction.isButton() && interaction.customId.startsWith('regen_')) {
    const key = interaction.customId.replace('regen_', '');
    log('info', 'Regen button clicked', { key, channelId: interaction.channelId });
    if (activeProcesses.has(key)) {
      await interaction.reply({ content: '⚠️ 이미 처리 중입니다. 완료 후 다시 시도해주세요.', flags: MessageFlags.Ephemeral });
      return;
    }
    const query = lastQueryStore.get(key);
    if (!query) {
      await interaction.reply({ content: '⚠️ 봇 재시작으로 쿼리가 초기화됐습니다. 다시 질문해주세요.', flags: MessageFlags.Ephemeral });
      return;
    }
    // interaction.channel이 partial/null이면 fetch
    const channel = interaction.channel ?? await interaction.client.channels.fetch(interaction.channelId).catch(() => null);
    if (!channel) {
      await interaction.reply({ content: '⚠️ 채널을 찾을 수 없습니다.', flags: MessageFlags.Ephemeral });
      return;
    }
    await interaction.deferUpdate().catch(() => {});
    rerunQuery(channel, query, key, { sessions, activeProcesses }).catch((err) => {
      log('error', 'rerunQuery (regen button) failed', { key, error: err.message });
    });
    return;
  }

  // Summarize button — 직전 응답 요약 요청
  if (interaction.isButton() && interaction.customId.startsWith('summarize_')) {
    const key = interaction.customId.replace('summarize_', '');
    log('info', 'Summarize button clicked', { key, channelId: interaction.channelId });
    if (activeProcesses.has(key)) {
      await interaction.reply({ content: '⚠️ 이미 처리 중입니다. 완료 후 다시 시도해주세요.', flags: MessageFlags.Ephemeral });
      return;
    }
    const summarizeQuery = '바로 직전 응답의 핵심 포인트를 3-5줄로 간결하게 요약해줘.';
    const channel = interaction.channel ?? await interaction.client.channels.fetch(interaction.channelId).catch(() => null);
    if (!channel) {
      await interaction.reply({ content: '⚠️ 채널을 찾을 수 없습니다.', flags: MessageFlags.Ephemeral });
      return;
    }
    await interaction.deferUpdate().catch(() => {});
    rerunQuery(channel, summarizeQuery, key, { sessions, activeProcesses }, { contextLabel: '📝 요약 중...' }).catch((err) => {
      log('error', 'rerunQuery (summarize button) failed', { key, error: err.message });
    });
    return;
  }

  // Autocomplete for /run id field
  if (interaction.isAutocomplete()) {
    if (interaction.commandName === 'run') {
      const focused = interaction.options.getFocused().toLowerCase();
      const choices = getTaskIds(BOT_HOME)
        .filter(c => c.value.includes(focused) || c.name.toLowerCase().includes(focused))
        .slice(0, 25);
      await interaction.respond(choices);
    }
    return;
  }

  if (!interaction.isChatInputCommand()) return;

  // Owner-only guard for sensitive commands
  const OWNER_ID = process.env.OWNER_DISCORD_ID;
  const SENSITIVE = ['run', 'schedule', 'remember', 'alert', 'stop', 'clear', 'doctor', 'approve', 'commitments'];
  if (OWNER_ID && SENSITIVE.includes(interaction.commandName) && interaction.user.id !== OWNER_ID) {
    await interaction.reply({ content: t('error.ownerOnly'), flags: MessageFlags.Ephemeral });
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
    await interaction.reply(t('cmd.clear.done'));
    log('info', 'Session cleared', { sessionKey: sk });

  } else if (commandName === 'stop') {
    const active = activeProcesses.get(sk);
    if (active) {
      active.proc.kill();
      // AbortController는 이진(abort or not) — SIGKILL 에스컬레이션 불필요
      await interaction.reply(t('cmd.stop.stopping', { botName: BOT_NAME }));
      log('info', 'Process stopped via /stop', { sessionKey: sk });
    } else {
      await interaction.reply({ content: t('cmd.stop.noProcess'), flags: MessageFlags.Ephemeral });
    }

  } else if (commandName === 'memory') {
    const memPath = join(BOT_HOME, 'rag', 'memory.md');
    const content = existsSync(memPath) ? readFileSync(memPath, 'utf8') : t('cmd.memory.empty');
    await interaction.reply({ content: content.slice(0, 1900) });

  } else if (commandName === 'remember') {
    const text = interaction.options.getString('content');
    const memPath = join(BOT_HOME, 'rag', 'memory.md');
    const timestamp = new Date().toISOString().slice(0, 10);
    appendFileSync(memPath, `\n- [${timestamp}] ${text}`);
    userMemory.addFact(interaction.user.id, text, 'discord-slash-remember');
    await interaction.reply({ content: t('cmd.remember.done', { content: text }) });
    log('info', 'Memory saved via /remember', { userId: interaction.user.id, text: text.slice(0, 100) });

  } else if (commandName === 'search') {
    await interaction.deferReply();
    const query = interaction.options.getString('query');
    try {
      const { execFileSync } = await import('node:child_process');
      const result = execFileSync(
        'node', [join(BOT_HOME, 'lib', 'rag-query.mjs'), query],
        { timeout: 10000, encoding: 'utf-8' },
      );
      if (!result.trim()) {
        await interaction.editReply(t('cmd.search.noResult'));
      } else {
        const embed = new EmbedBuilder()
          .setColor(0x5865f2)
          .setTitle(`\ud83d\udd0d ${query.slice(0, 250)}`)
          .setDescription(result.slice(0, 4000))
          .setTimestamp();
        await interaction.editReply({ embeds: [embed] });
      }
    } catch (err) {
      await interaction.editReply(t('cmd.search.error', { error: err.message?.slice(0, 200) || 'Unknown error' }));
    }

  } else if (commandName === 'threads') {
    const entries = Object.entries(sessions.data);
    if (entries.length === 0) {
      await interaction.reply({ content: t('cmd.threads.empty'), flags: MessageFlags.Ephemeral });
    } else {
      const list = entries
        .slice(0, 20)
        .map(([key, sid]) => `\u2022 \`${key}\` \u2192 \`${sid.id?.slice(0, 8) ?? sid.slice?.(0, 8)}\u2026\``)
        .join('\n');
      const embed = new EmbedBuilder()
        .setColor(0x5865f2)
        .setTitle(t('cmd.threads.title', { count: entries.length }))
        .setDescription(list)
        .setTimestamp();
      await interaction.reply({ embeds: [embed], flags: MessageFlags.Ephemeral });
    }

  } else if (commandName === 'alert') {
    const msg = interaction.options.getString('message');
    await sendNtfy(`${BOT_NAME} Alert`, msg, 'high');
    await interaction.reply({ content: t('cmd.alert.done', { message: msg }), flags: MessageFlags.Ephemeral });

  } else if (commandName === 'status') {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const uptimeSec = Math.floor(process.uptime());
    const uptimeStr = `${Math.floor(uptimeSec / 3600)}h ${Math.floor((uptimeSec % 3600) / 60)}m`;
    const lastMessageAt = deps.lastMessageAt ?? Date.now();
    const silenceSec = Math.floor((Date.now() - lastMessageAt) / 1000);
    const wsStatusNames = ['READY','CONNECTING','RECONNECTING','IDLE','NEARLY','DISCONNECTED','WAITING_FOR_GUILDS','IDENTIFYING','RESUMING'];
    const wsCode = client.ws.status ?? -1;
    const wsStatus = wsStatusNames[wsCode] ?? `UNKNOWN(${wsCode})`;
    const wsHealthy = wsCode === 0;
    const rate = rateTracker.check();
    const memMB = Math.round(process.memoryUsage().rss / 1024 / 1024);
    const pingMs = client.ws.ping;
    // Context usage from Claude's cache
    let ctxValue = '-';
    try {
      const cachePath = join(HOME, '.claude', 'usage-cache.json');
      if (existsSync(cachePath)) {
        const uc = JSON.parse(readFileSync(cachePath, 'utf-8'));
        ctxValue = t('status.context.value', { fiveH: uc.fiveH?.pct ?? '?', sevenD: uc.sevenD?.pct ?? '?' });
      }
    } catch { /* best effort */ }
    const embed = new EmbedBuilder()
      .setTitle(t('status.title', { botName: BOT_NAME }))
      .setColor(wsHealthy && !rate.warn ? 0x2ecc71 : rate.reject ? 0xe74c3c : 0xf39c12)
      .addFields(
        { name: t('status.ws'), value: `\`${wsStatus}\`${pingMs >= 0 ? ` (${pingMs}ms)` : ''}`, inline: true },
        { name: t('status.uptime'), value: `\`${uptimeStr}\``, inline: true },
        { name: t('status.lastEvent'), value: `\`${t('status.lastEvent.value', { seconds: silenceSec })}\``, inline: true },
        { name: t('status.rateLimit'), value: `\`${rate.count}/${rate.max}\` (${Math.round(rate.pct * 100)}%)`, inline: true },
        { name: t('status.activeProcs'), value: `\`${activeProcesses.size}/${deps.maxConcurrent ?? 2}\``, inline: true },
        { name: t('status.sessions'), value: `\`${t('status.sessions.value', { count: Object.keys(sessions.data).length })}\``, inline: true },
        { name: t('status.memory'), value: `\`${memMB}MB\``, inline: true },
        { name: t('status.context'), value: `\`${ctxValue}\``, inline: true },
      )
      .setTimestamp();
    await interaction.editReply({ embeds: [embed] });

  } else if (commandName === 'tasks') {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const { execFileSync } = await import('node:child_process');
      const logPath = join(BOT_HOME, 'logs', 'cron.log');
      const today = new Date().toISOString().slice(0, 10);
      let raw = '';
      try {
        const grepOut = execFileSync('grep', [today, logPath], { encoding: 'utf-8', maxBuffer: 512 * 1024 });
        raw = grepOut.split('\n').slice(-100).join('\n');
      } catch { /* grep exit 1 = no match */ }
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
        await interaction.editReply(t('cmd.tasks.noTasks'));
        return;
      }
      const lines = Object.entries(taskStats).map(([name, s]) =>
        `${s.fail > 0 ? '\u274c' : '\u2705'} \`${name}\`: ${t('cmd.tasks.success', { count: s.ok })}${s.fail > 0 ? t('cmd.tasks.fail', { count: s.fail }) : ''}`
      );
      const totalOk = Object.values(taskStats).reduce((a, s) => a + s.ok, 0);
      const totalFail = Object.values(taskStats).reduce((a, s) => a + s.fail, 0);
      const color = totalFail > 0 ? 0xfee75c : 0x57f287;
      const embed = new EmbedBuilder()
        .setColor(color)
        .setTitle(t('cmd.tasks.title', { date: today }))
        .setDescription(lines.join('\n').slice(0, 4000))
        .setFooter({ text: `\u2705 ${totalOk} \u00b7 \u274c ${totalFail}` })
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });
    } catch (err) {
      await interaction.editReply(t('cmd.tasks.error', { error: err.message?.slice(0, 200) }));
    }

  } else if (commandName === 'run') {
    const taskId = interaction.options.getString('id');
    const taskIds = getTaskIds(BOT_HOME).map(t => t.value);
    if (!taskIds.includes(taskId)) {
      await interaction.reply({ content: t('cmd.run.notFound', { taskId }), flags: MessageFlags.Ephemeral });
      return;
    }
    await interaction.deferReply();
    try {
      const { spawn } = await import('node:child_process');
      const cronScript = join(BOT_HOME, 'bin', 'bot-cron.sh');
      log('info', 'Manual task run via /run', { taskId, user: interaction.user.tag });

      const proc = spawn('/bin/bash', [cronScript, taskId], {
        env: { ...process.env, HOME },
        stdio: ['ignore', 'pipe', 'pipe'],
      });

      let stdout = '';
      let stderr = '';
      proc.stdout.on('data', (chunk) => { stdout += chunk.toString('utf-8'); });
      proc.stderr.on('data', (chunk) => { stderr += chunk.toString('utf-8'); });

      const timeout = setTimeout(() => {
        proc.kill('SIGTERM');
      }, 300_000); // 5분 timeout

      proc.on('close', async (code) => {
        clearTimeout(timeout);
        if (code === 0) {
          const embed = new EmbedBuilder()
            .setTitle(t('cmd.run.done', { taskId }))
            .setColor(0x2ecc71)
            .setDescription(t('cmd.run.doneDesc', { user: interaction.user.tag }))
            .setTimestamp();
          await interaction.editReply({ embeds: [embed] });
        } else {
          const embed = new EmbedBuilder()
            .setTitle(t('cmd.run.fail', { taskId }))
            .setColor(0xe74c3c)
            .setDescription('```\n' + (stderr || stdout || `Exit code: ${code}`).slice(0, 500) + '\n```')
            .setTimestamp();
          await interaction.editReply({ embeds: [embed] });
          log('error', 'Manual task run failed', { taskId, code, stderr: stderr.slice(0, 200) });
        }
      });
    } catch (err) {
      const embed = new EmbedBuilder()
        .setTitle(t('cmd.run.fail', { taskId }))
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
    await interaction.reply(t('cmd.schedule.done', { delay, task }));

  } else if (commandName === 'usage') {
    await interaction.deferReply();
    try {
      const cachePath = join(HOME, '.claude', 'usage-cache.json');
      const cfgPath   = join(HOME, '.claude', 'usage-config.json');
      const statsPath = join(HOME, '.claude', 'stats-cache.json');

      if (!existsSync(cachePath)) {
        await interaction.editReply(t('cmd.usage.noCache'));
        return;
      }

      const cache = JSON.parse(readFileSync(cachePath, 'utf-8'));
      const cfg   = existsSync(cfgPath) ? JSON.parse(readFileSync(cfgPath, 'utf-8')) : {};
      const limits = cfg.limits ?? {};

      const bar = (pct) => {
        const filled = Math.round(pct / 10);
        return '\u2588'.repeat(filled) + '\u2591'.repeat(10 - filled);
      };
      const color = (pct) => pct >= 90 ? 0xed4245 : pct >= 70 ? 0xfee75c : 0x57f287;

      const fiveH  = cache.fiveH  ?? {};
      const sevenD = cache.sevenD ?? {};
      const sonnet = cache.sonnet ?? {};
      const maxPct = Math.max(fiveH.pct ?? 0, sevenD.pct ?? 0, sonnet.pct ?? 0);
      const ts = cache.ts ? new Date(cache.ts) : null;
      const tsStr = ts ? ts.toLocaleString('ko-KR', { timeZone: cfg.timezone ?? 'Asia/Seoul', hour12: false }) : t('cmd.usage.unknown');

      const usageVal = (tier) => t('cmd.usage.value', {
        bar: bar(tier.pct ?? 0),
        pct: tier.pct ?? '?',
        remain: tier.remain ?? '?',
        reset: tier.reset ?? '?',
        resetIn: tier.resetIn ?? '?',
      });

      const embed = new EmbedBuilder()
        .setColor(color(maxPct))
        .setTitle(t('cmd.usage.title'))
        .addFields(
          {
            name: t('cmd.usage.fiveH', { limit: limits.fiveH?.toLocaleString() ?? '?' }),
            value: usageVal(fiveH),
            inline: false,
          },
          {
            name: t('cmd.usage.sevenD', { limit: limits.sevenD?.toLocaleString() ?? '?' }),
            value: usageVal(sevenD),
            inline: false,
          },
          {
            name: t('cmd.usage.sonnet7D', { limit: limits.sonnet7D?.toLocaleString() ?? '?' }),
            value: usageVal(sonnet),
            inline: false,
          },
        )
        .setFooter({ text: t('cmd.usage.cacheFooter', { time: tsStr }) })
        .setTimestamp();

      if (existsSync(statsPath)) {
        try {
          const stats = JSON.parse(readFileSync(statsPath, 'utf-8'));
          const recent = (stats.dailyActivity ?? []).slice(-3).reverse();
          if (recent.length > 0) {
            const rows = recent.map(d => `\`${d.date}\` ${d.messageCount}msg / ${d.toolCallCount}tools`).join('\n');
            embed.addFields({ name: t('cmd.usage.recentActivity'), value: rows, inline: false });
          }
        } catch { /* stats parsing failure ignored */ }
      }

      await interaction.editReply({ embeds: [embed] });
    } catch (err) {
      await interaction.editReply(t('cmd.usage.error', { error: err.message?.slice(0, 300) || 'Unknown error' }));
      log('error', 'Usage command failed', { error: err.message?.slice(0, 200) });
    }

  } else if (commandName === 'lounge') {
    const activities = getActivities();
    if (activities.length === 0) {
      await interaction.reply({ content: t('cmd.lounge.empty'), flags: MessageFlags.Ephemeral });
    } else {
      const list = activities
        .map(a => {
          const ago = Math.floor((Date.now() - a.ts) / 1000);
          return `\u2022 **${a.taskId}** \u2014 ${a.activity} (${ago}s ago)`;
        })
        .join('\n');
      const embed = new EmbedBuilder()
        .setTitle(t('cmd.lounge.title', { count: activities.length }))
        .setColor(0x5865f2)
        .setDescription(list)
        .setTimestamp();
      await interaction.reply({ embeds: [embed], flags: MessageFlags.Ephemeral });
    }

  } else if (commandName === 'doctor') {
    await interaction.deferReply();
    try {
      const { spawnSync, spawn } = await import('node:child_process');
      const fixes = [];
      const rows = [];

      const kstNow = new Date(Date.now() + 9 * 3600_000);
      const timestamp = kstNow.toISOString().slice(0, 16).replace('T', ' ');

      // 1. LaunchAgents
      let agentStatus;
      if (IS_MACOS) {
        const launchOut = spawnSync('launchctl', ['list'], { encoding: 'utf-8' });
        const launchLines = (launchOut.stdout || '').split('\n').filter(l => /jarvis/.test(l));
        const requiredAgents = ['ai.jarvis.discord-bot', 'ai.jarvis.watchdog', 'ai.jarvis.rag-watcher'];
        const runningAgents = launchLines.map(l => (l.split('\t')[2] || '').trim());
        const missingAgents = requiredAgents.filter(a => !runningAgents.some(r => r === a));
        for (const agent of missingAgents) {
          const plistPath = `${HOME}/Library/LaunchAgents/${agent}.plist`;
          spawnSync('launchctl', ['load', plistPath], { encoding: 'utf-8' });
          fixes.push(`${agent} 재등록`);
        }
        agentStatus = missingAgents.length === 0
          ? `✅ ${launchLines.length}개 실행 중`
          : `⚠️ ${missingAgents.length}개 재등록됨`;
      } else {
        const pm2Out = spawnSync('pm2', ['list', '--no-color'], { encoding: 'utf-8' });
        const jarvisRunning = /jarvis/.test(pm2Out.stdout || '');
        agentStatus = jarvisRunning ? '✅ pm2 실행 중' : '⚠️ pm2 프로세스 없음 (비macOS)';
      }
      rows.push(['LaunchAgents', agentStatus]);

      // 2. Discord bot process
      const botProc = spawnSync('pgrep', ['-fl', 'discord-bot.js'], { encoding: 'utf-8' });
      const botPid = (botProc.stdout || '').trim().split('\n')[0]?.split(' ')[0];
      rows.push(['Discord 봇', botPid ? `✅ PID ${botPid}` : '❌ 프로세스 없음']);

      // 3. RAG / LanceDB
      let ragStatus = '';
      const ldbNodeModules = join(BOT_HOME, 'discord', 'node_modules');
      const ldbImport = `${ldbNodeModules}/@lancedb/lancedb/dist/index.js`;
      const checkScript = [
        `import ldb from '${ldbImport}';`,
        `const db = await ldb.connect('${BOT_HOME}/rag/lancedb');`,
        `try {`,
        `  const t = await db.openTable('documents');`,
        `  const n = await t.countRows();`,
        `  const ftsTest = await t.search("jarvis").limit(1).toArray().catch(()=>null);`,
        `  console.log(JSON.stringify({chunks:n,queryOk:ftsTest!==null && ftsTest.length>0}));`,
        `} catch(e) { console.log(JSON.stringify({error:e.message.slice(0,80)})); }`,
      ].join('\n');
      const ragOut = spawnSync('node', ['--input-type=module'], {
        input: checkScript,
        encoding: 'utf-8',
        timeout: 15000,
        env: { ...process.env, NODE_PATH: ldbNodeModules, HOME },
      });
      let ragResult = {};
      try { ragResult = JSON.parse((ragOut.stdout || '').trim()); } catch { ragResult = { error: 'parse fail' }; }
      if (ragResult.error || ragResult.chunks === 0) {
        // Safe delegated rebuild via cron-safe-wrapper (no direct dropTable)
        const rebuildProc = spawn('/bin/bash', [
          join(BOT_HOME, 'bin', 'cron-safe-wrapper.sh'),
          'rag-index', '2700',
          'bash', join(BOT_HOME, 'bin', 'rag-index-safe.sh'),
        ], {
          env: { ...process.env, HOME, BOT_HOME, OMP_NUM_THREADS: '2', ORT_NUM_THREADS: '2' },
          detached: true, stdio: 'ignore',
        });
        rebuildProc.unref();
        fixes.push('LanceDB 재인덱싱 시작');
        ragStatus = `⚠️ 오류 감지 → 재인덱싱 중`;
      } else if (!ragResult.queryOk) {
        ragStatus = `❌ ${ragResult.chunks}청크, 쿼리 실패`;
      } else {
        const n = ragResult.chunks;
        ragStatus = n >= 1000 ? `✅ ${n}청크, 쿼리 OK` : `⚠️ ${n}청크 (인덱싱 부족)`;
      }
      rows.push(['RAG / LanceDB', ragStatus]);

      // 4. Cron errors (last 100 lines)
      let cronStatus = '✅ 에러 없음';
      const cronOut = spawnSync('bash', ['-c',
        `tail -100 "${BOT_HOME}/logs/cron.log" 2>/dev/null | grep -iE "error|fail|timeout|CRITICAL" | tail -5`],
        { encoding: 'utf-8' });
      const cronErrors = (cronOut.stdout || '').trim();
      if (/CRITICAL/i.test(cronErrors)) cronStatus = '❌ CRITICAL 발견';
      else if (cronErrors) cronStatus = '⚠️ 최근 에러 있음';
      rows.push(['크론', cronStatus]);

      // 5. Glances
      let glancesStatus = '';
      const gOut = spawnSync('curl', ['-sf', '--max-time', '3', 'http://localhost:61208/api/4/cpu'],
        { encoding: 'utf-8' });
      if (gOut.status !== 0) {
        if (IS_MACOS) {
          spawnSync('launchctl', ['load', `${HOME}/Library/LaunchAgents/ai.jarvis.glances.plist`], { encoding: 'utf-8' });
          fixes.push('Glances 재시작');
          glancesStatus = '⚠️ 재시작됨';
        } else {
          // Linux/Docker: glances는 pm2 관리 대상 아님 (선택적 모니터링 도구)
          glancesStatus = '⚠️ 응답 없음';
        }
      } else {
        try {
          const cpu = JSON.parse(gOut.stdout || '{}');
          glancesStatus = `✅ CPU ${cpu.total ?? '?'}%`;
        } catch {
          glancesStatus = '✅ 응답 OK';
        }
      }
      rows.push(['Glances', glancesStatus]);

      // 6. Weekly usage stats
      let weeklyMsgs = '?';
      try {
        const usageOut = spawnSync('bash', [join(BOT_HOME, 'scripts', 'usage-stats.sh'), '7'], {
          encoding: 'utf-8', timeout: 5000,
          env: { ...process.env, HOME, BOT_HOME },
        });
        const match = (usageOut.stdout || '').match(/총 대화: (\d+)건/);
        if (match) weeklyMsgs = match[1];
      } catch { /* skip */ }
      rows.push(['주간 대화', `${weeklyMsgs}건`]);

      // Build embed
      const hasErrors = rows.some(([, s]) => s.startsWith('❌'));
      const hasWarns = rows.some(([, s]) => s.startsWith('⚠️'));
      const color = hasErrors ? 0xed4245 : hasWarns ? 0xfee75c : 0x57f287;
      const tableLines = rows.map(([name, status]) => `\`${name.padEnd(12)}\` ${status}`);
      const fixSection = fixes.length > 0 ? `\n\n**자동 수정**: ${fixes.join(', ')}` : '';
      const embed = new EmbedBuilder()
        .setColor(color)
        .setTitle(`🏥 Jarvis 점검 — ${timestamp} KST`)
        .setDescription(tableLines.join('\n') + fixSection)
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });
      log('info', '/doctor completed', { fixes: fixes.length, user: interaction.user.tag });
    } catch (err) {
      await interaction.editReply(`❌ 점검 실패: ${err.message?.slice(0, 200)}`);
      log('error', '/doctor failed', { error: err.message?.slice(0, 200) });
    }

  } else if (commandName === 'team') {
    const teamName = interaction.options.getString('name');
    const TEAM_LABELS = {
      council: '\ud83d\udd0d 감사팀', infra: '\u2699\ufe0f 인프라팀', record: '\ud83d\uddc4\ufe0f 기록팀',
      brand: '\ud83d\udce3 브랜드팀', career: '\ud83d\ude80 성장팀', academy: '\ud83d\udcda 학습팀', trend: '\ud83d\udce1 정보팀',
      recon: '\ud83d\udd2d 정보탐험대',
    };
    // 보고서 파일 경로 (company-agent.mjs의 TEAMS 정의와 동기화)
    const reportsDir = join(BOT_HOME, 'rag', 'teams', 'reports');
    const kstDate = new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
    const kstWeek = (() => {
      const d = new Date(Date.now() + 9 * 3600_000);
      d.setUTCHours(0, 0, 0, 0);
      d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
      const y = d.getUTCFullYear();
      const w = Math.ceil((((d - new Date(Date.UTC(y, 0, 1))) / 86400_000) + 1) / 7);
      return `${y}-W${String(w).padStart(2, '0')}`;
    })();
    const REPORT_PATHS = {
      council: join(reportsDir, `council-${kstDate}.md`),
      infra: join(reportsDir, `infra-${kstDate}.md`),
      record: join(reportsDir, `record-${kstDate}.md`),
      trend: join(reportsDir, `trend-${kstDate}.md`),
      brand: join(reportsDir, `brand-${kstWeek}.md`),
      career: join(reportsDir, `career-${kstWeek}.md`),
      academy: join(reportsDir, `academy-${kstWeek}.md`),
      recon: join(reportsDir, `recon-${kstDate}.md`),
    };

    await interaction.deferReply();
    try {
      const { execFile } = await import('node:child_process');
      const { promisify } = await import('node:util');
      const execFileAsync = promisify(execFile);
      const agentPath = join(BOT_HOME, 'discord', 'lib', 'company-agent.mjs');

      log('info', `Team summoned via /team`, { team: teamName, user: interaction.user.tag });

      // 요청 채널로 결과 전송 (webhook key = Discord channel name)
      const requestChannel = interaction.channel?.name ?? null;
      const agentArgs = ['--team', teamName];
      if (requestChannel) agentArgs.push('--channel', requestChannel);

      await execFileAsync(
        process.execPath, [agentPath, ...agentArgs],
        { timeout: 300_000, env: { ...process.env, HOME }, cwd: BOT_HOME },
      );

      // 보고서 파일에서 결과 읽기 (stdout은 로그만 포함)
      const reportPath = REPORT_PATHS[teamName];
      let result = '';
      if (reportPath && existsSync(reportPath)) {
        result = readFileSync(reportPath, 'utf-8').trim();
      }

      if (result.length > 0) {
        const headerEmbed = new EmbedBuilder()
          .setColor(0x2ecc71)
          .setTitle(`${TEAM_LABELS[teamName]} 보고서`)
          .setFooter({ text: `${interaction.user.tag}` })
          .setTimestamp();
        const firstChunk = result.slice(0, 1900);
        await interaction.editReply({ embeds: [headerEmbed], content: firstChunk });
        for (let i = 1900; i < result.length; i += 1900) {
          await interaction.followUp(result.slice(i, i + 1900));
        }
      } else {
        const embed = new EmbedBuilder()
          .setColor(0xfee75c)
          .setDescription(`${TEAM_LABELS[teamName]} 실행 완료 (보고서 파일 없음)`);
        await interaction.editReply({ embeds: [embed] });
      }
    } catch (err) {
      const errMsg = err.stderr?.slice(0, 500) || err.message?.slice(0, 500) || 'Unknown error';
      const embed = new EmbedBuilder()
        .setColor(0xed4245)
        .setTitle(`${TEAM_LABELS[teamName]} 실행 실패`)
        .setDescription('```\n' + errMsg + '\n```')
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });
      log('error', 'Team command failed', { team: teamName, error: errMsg.slice(0, 200) });
    }

  // -------------------------------------------------------------------------
  } else if (commandName === 'approve') {
    // 오너 전용: doc-draft 승인 → 대상 문서에 적용 (SENSITIVE 가드로 이미 검증됨)
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const draftArg = interaction.options.getString('draft');
      const draftsDir = resolve(join(BOT_HOME, 'rag', 'teams', 'reports'));

      let draftFiles = [];
      try {
        draftFiles = readdirSync(draftsDir).filter(f => f.startsWith('doc-draft-') && f.endsWith('.md'));
      } catch { /* 디렉토리 없으면 빈 배열 */ }

      // 목록 표시 모드
      if (!draftArg) {
        if (draftFiles.length === 0) {
          await interaction.editReply('📭 승인 대기 중인 doc-draft 파일이 없습니다.');
          return;
        }
        const list = draftFiles.map((f, i) => `\`${i + 1}.\` ${f}`).join('\n');
        const embed = new EmbedBuilder()
          .setColor(0x5865f2)
          .setTitle('📋 승인 대기 중인 Doc-Draft')
          .setDescription(list + '\n\n> `/approve draft:<파일명>` 으로 적용')
          .setTimestamp();
        await interaction.editReply({ embeds: [embed] });
        return;
      }

      // 번호 선택 → 파일명으로 해소
      let resolvedName = draftArg;
      const numIdx = parseInt(draftArg, 10) - 1;
      if (!isNaN(numIdx) && draftFiles[numIdx]) {
        resolvedName = draftFiles[numIdx];
      }

      const draftName = resolvedName.endsWith('.md') ? resolvedName : `${resolvedName}.md`;

      // 경로 트래버설 방지: draftsDir 밖이면 거부
      const draftPath = resolve(join(draftsDir, draftName));
      if (!draftPath.startsWith(draftsDir + '/') && draftPath !== draftsDir) {
        await interaction.editReply('❌ 잘못된 경로입니다.');
        return;
      }

      if (!existsSync(draftPath)) {
        await interaction.editReply(`❌ 파일 없음: \`${draftName}\``);
        return;
      }

      const draftContent = readFileSync(draftPath, 'utf-8');

      // 프론트매터에서 target: 경로 추출
      const targetMatch = draftContent.match(/^---[\s\S]*?target:\s*(.+?)[\s\S]*?---/m);
      if (!targetMatch) {
        await interaction.editReply(`❌ \`${draftName}\` 에 \`target:\` 프론트매터가 없습니다.`);
        return;
      }

      const targetRel = targetMatch[1].trim();
      const targetPath = targetRel.startsWith('/') ? targetRel : join(BOT_HOME, targetRel);

      // 프론트매터 제거 후 본문만 추출
      const bodyContent = draftContent.replace(/^---[\s\S]*?---\n?/, '').trim();

      mkdirSync(dirname(targetPath), { recursive: true });
      writeFileSync(targetPath, bodyContent + '\n', 'utf-8');

      // draft 파일은 .applied.md 확장으로 보존
      renameSync(draftPath, draftPath.replace(/\.md$/, '.applied.md'));

      log('info', '/approve applied doc-draft', { draft: draftName, target: targetPath, user: interaction.user.tag });

      const embed = new EmbedBuilder()
        .setColor(0x57f287)
        .setTitle('✅ Doc-Draft 적용 완료')
        .addFields(
          { name: 'Draft', value: `\`${draftName}\``, inline: true },
          { name: 'Target', value: `\`${targetRel}\``, inline: true },
        )
        .setFooter({ text: `적용자: ${interaction.user.tag}` })
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });

    } catch (err) {
      await interaction.editReply(`❌ approve 실패: ${err.message?.slice(0, 300)}`);
      log('error', '/approve failed', { error: err.message?.slice(0, 200) });
    }

  // -------------------------------------------------------------------------
  } else if (commandName === 'commitments') {
    // 오너 전용: commitments.jsonl에서 open 항목 조회
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const commitFile = join(BOT_HOME, 'state', 'commitments.jsonl');
      const now = Date.now();

      if (!existsSync(commitFile)) {
        await interaction.editReply('📭 `state/commitments.jsonl` 파일이 없습니다. 아직 기록된 약속이 없습니다.');
        return;
      }

      const lines = readFileSync(commitFile, 'utf-8')
        .split('\n')
        .filter(l => l.trim());

      const open = [];
      for (const line of lines) {
        try {
          const item = JSON.parse(line);
          if (item.status === 'open') open.push(item);
        } catch { /* 깨진 라인 스킵 */ }
      }

      if (open.length === 0) {
        const embed = new EmbedBuilder()
          .setColor(0x57f287)
          .setTitle('✅ 미이행 약속 없음')
          .setDescription('모든 약속이 이행됐습니다.')
          .setTimestamp();
        await interaction.editReply({ embeds: [embed] });
        return;
      }

      const OVERDUE_MS = 24 * 60 * 60 * 1000;
      const lines2 = open.map(item => {
        const createdAt = item.created_at ? new Date(item.created_at).getTime() : 0;
        const age = now - createdAt;
        const ageH = Math.floor(age / 3600_000);
        const overdue = age > OVERDUE_MS;
        const badge = overdue ? '🔴' : '🟡';
        const timeStr = item.created_at ? `${ageH}h 전` : '시간 불명';
        const text = item.text || item.commitment || item.content || JSON.stringify(item);
        return `${badge} \`${timeStr}\` — ${text.slice(0, 120)}`;
      });

      const embed = new EmbedBuilder()
        .setColor(open.some(i => {
          const age = now - (i.created_at ? new Date(i.created_at).getTime() : now);
          return age > OVERDUE_MS;
        }) ? 0xed4245 : 0xfee75c)
        .setTitle(`📋 미이행 약속 ${open.length}건`)
        .setDescription(lines2.join('\n').slice(0, 2000))
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });

      log('info', '/commitments queried', { open: open.length, user: interaction.user.tag });
    } catch (err) {
      await interaction.editReply(`❌ 조회 실패: ${err.message?.slice(0, 300)}`);
      log('error', '/commitments failed', { error: err.message?.slice(0, 200) });
    }
  }
}
