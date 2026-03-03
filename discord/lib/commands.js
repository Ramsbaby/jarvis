/**
 * Slash command and interaction handler — extracted from discord-bot.js.
 *
 * Exports: handleInteraction(interaction, deps)
 *   deps = { sessions, activeProcesses, rateTracker, client, BOT_HOME, BOT_NAME, HOME }
 */

import { readFileSync, existsSync, appendFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { EmbedBuilder } from 'discord.js';
import { log, sendNtfy } from './claude-runner.js';
import { userMemory } from './user-memory.js';

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
      proc.proc.kill('SIGTERM');
      await interaction.reply({ content: '\u23f9\ufe0f \uc911\ub2e8\ub428', ephemeral: true });
    } else {
      await interaction.reply({ content: '\uc2e4\ud589 \uc911\uc778 \uc791\uc5c5 \uc5c6\uc74c', ephemeral: true });
    }
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
  const SENSITIVE = ['run', 'schedule', 'remember', 'alert', 'stop', 'clear'];
  if (OWNER_ID && SENSITIVE.includes(interaction.commandName) && interaction.user.id !== OWNER_ID) {
    await interaction.reply({ content: '\u26d4 \uc774 \uba85\ub839\uc5b4\ub294 \ubd07 \uc624\ub108\ub9cc \uc0ac\uc6a9\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.', ephemeral: true });
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
    const content = existsSync(memPath) ? readFileSync(memPath, 'utf8') : '\uba54\ubaa8\ub9ac\uac00 \ube44\uc5b4\uc788\uc2b5\ub2c8\ub2e4.';
    await interaction.reply({ content: content.slice(0, 1900) });

  } else if (commandName === 'remember') {
    const text = interaction.options.getString('content');
    const memPath = join(BOT_HOME, 'rag', 'memory.md');
    const timestamp = new Date().toISOString().slice(0, 10);
    appendFileSync(memPath, `\n- [${timestamp}] ${text}`);
    userMemory.addFact(interaction.user.id, text);
    await interaction.reply({ content: `기억했습니다 🧠 ${text}` });
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
      await interaction.editReply(result.slice(0, 1900) || '\uac80\uc0c9 \uacb0\uacfc\uac00 \uc5c6\uc2b5\ub2c8\ub2e4.');
    } catch (err) {
      await interaction.editReply('RAG \uac80\uc0c9 \uc2e4\ud328: ' + (err.message?.slice(0, 200) || 'Unknown error'));
    }

  } else if (commandName === 'threads') {
    const entries = Object.entries(sessions.data);
    if (entries.length === 0) {
      await interaction.reply({ content: '\ud65c\uc131 \uc138\uc158\uc774 \uc5c6\uc2b5\ub2c8\ub2e4.', ephemeral: true });
    } else {
      const list = entries
        .slice(0, 20)
        .map(([key, sid]) => `\u2022 \`${key}\` \u2192 \`${sid.id?.slice(0, 8) ?? sid.slice?.(0, 8)}\u2026\``)
        .join('\n');
      await interaction.reply({
        content: `**\ud65c\uc131 \uc138\uc158 (${entries.length}\uac1c)**\n${list}`,
        ephemeral: true,
      });
    }

  } else if (commandName === 'alert') {
    const msg = interaction.options.getString('message');
    await sendNtfy(`${BOT_NAME} Alert`, msg, 'high');
    await interaction.reply({ content: `ntfy \uc804\uc1a1 \uc644\ub8cc: ${msg}`, ephemeral: true });

  } else if (commandName === 'status') {
    await interaction.deferReply({ ephemeral: true });
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
    const embed = new EmbedBuilder()
      .setTitle(`${BOT_NAME} \uc2dc\uc2a4\ud15c \uc0c1\ud0dc`)
      .setColor(wsHealthy && !rate.warn ? 0x2ecc71 : rate.reject ? 0xe74c3c : 0xf39c12)
      .addFields(
        { name: '\ud83d\udd0c WebSocket', value: `\`${wsStatus}\`${pingMs >= 0 ? ` (${pingMs}ms)` : ''}`, inline: true },
        { name: '\u23f1\ufe0f \uc5c5\ud0c0\uc784', value: `\`${uptimeStr}\``, inline: true },
        { name: '\ud83d\udd07 \ub9c8\uc9c0\ub9c9 \uc774\ubca4\ud2b8', value: `\`${silenceSec}\ucd08 \uc804\``, inline: true },
        { name: '\ud83d\udcca Rate limit', value: `\`${rate.count}/${rate.max}\` (${Math.round(rate.pct * 100)}%)`, inline: true },
        { name: '\u26a1 \ud65c\uc131 \ud504\ub85c\uc138\uc2a4', value: `\`${activeProcesses.size}/${deps.maxConcurrent ?? 2}\``, inline: true },
        { name: '\ud83d\udcac \uc138\uc158', value: `\`${Object.keys(sessions.data).length}\uac1c\``, inline: true },
        { name: '\ud83d\udcbe \uba54\ubaa8\ub9ac', value: `\`${memMB}MB\``, inline: true },
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
        await interaction.editReply('\uc624\ub298 \uc2e4\ud589\ub41c \ud06c\ub860 \ud0dc\uc2a4\ud06c\uac00 \uc5c6\uc2b5\ub2c8\ub2e4.');
        return;
      }
      const lines = Object.entries(taskStats).map(([name, s]) =>
        `${s.fail > 0 ? '\u274c' : '\u2705'} \`${name}\`: ${s.ok}\uc131\uacf5${s.fail > 0 ? ' ' + s.fail + '\uc2e4\ud328' : ''}`
      );
      await interaction.editReply(`**\uc624\ub298 \ud0dc\uc2a4\ud06c \ud604\ud669 (${today})**\n${lines.join('\n')}`.slice(0, 1900));
    } catch (err) {
      await interaction.editReply('\ud0dc\uc2a4\ud06c \ub85c\uadf8 \uc77d\uae30 \uc2e4\ud328: ' + err.message?.slice(0, 200));
    }

  } else if (commandName === 'run') {
    const taskId = interaction.options.getString('id');
    const taskIds = getTaskIds(BOT_HOME).map(t => t.value);
    if (!taskIds.includes(taskId)) {
      await interaction.reply({ content: `\u274c \ud0dc\uc2a4\ud06c ID \`${taskId}\` \ub97c \ucc3e\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.`, ephemeral: true });
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
        .setTitle(`\u2705 \ud0dc\uc2a4\ud06c \uc644\ub8cc: \`${taskId}\``)
        .setColor(0x2ecc71)
        .setDescription(`**${interaction.user.tag}** \ub2d8\uc774 \uc218\ub3d9 \uc2e4\ud589\ud588\uc2b5\ub2c8\ub2e4.`)
        .setTimestamp();
      await interaction.editReply({ embeds: [embed] });
    } catch (err) {
      const embed = new EmbedBuilder()
        .setTitle(`\u274c \ud0dc\uc2a4\ud06c \uc2e4\ud328: \`${taskId}\``)
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
    await interaction.reply(`\u2705 **${delay}** \ud6c4 \uc2e4\ud589 \uc608\uc57d\ub428\n> ${task}`);

  } else if (commandName === 'usage') {
    await interaction.deferReply();
    try {
      const cachePath = join(HOME, '.claude', 'usage-cache.json');
      const cfgPath   = join(HOME, '.claude', 'usage-config.json');
      const statsPath = join(HOME, '.claude', 'stats-cache.json');

      if (!existsSync(cachePath)) {
        await interaction.editReply('\u274c \uc0ac\uc6a9\ub7c9 \uce90\uc2dc \uc5c6\uc74c. Claude Code\ub97c \ud55c \ubc88 \uc2e4\ud589\ud574\uc8fc\uc138\uc694.');
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
      const tsStr = ts ? ts.toLocaleString('ko-KR', { timeZone: cfg.timezone ?? 'Asia/Seoul', hour12: false }) : '\uc54c \uc218 \uc5c6\uc74c';

      const embed = new EmbedBuilder()
        .setColor(color(maxPct))
        .setTitle('\u26a1 Claude Max \uc0ac\uc6a9\ub7c9')
        .addFields(
          {
            name: `5\uc2dc\uac04 \ud55c\ub3c4 (${limits.fiveH?.toLocaleString() ?? '?'} msgs)`,
            value: `\`${bar(fiveH.pct ?? 0)}\` **${fiveH.pct ?? '?'}%** \u2014 ${fiveH.remain ?? '?'} \ub0a8\uc74c\n\ub9ac\uc14b: ${fiveH.reset ?? '?'} (${fiveH.resetIn ?? '?'} \ud6c4)`,
            inline: false,
          },
          {
            name: `7\uc77c \ud55c\ub3c4 (${limits.sevenD?.toLocaleString() ?? '?'} msgs)`,
            value: `\`${bar(sevenD.pct ?? 0)}\` **${sevenD.pct ?? '?'}%** \u2014 ${sevenD.remain ?? '?'} \ub0a8\uc74c\n\ub9ac\uc14b: ${sevenD.reset ?? '?'} (${sevenD.resetIn ?? '?'} \ud6c4)`,
            inline: false,
          },
          {
            name: `Sonnet 7\uc77c (${limits.sonnet7D?.toLocaleString() ?? '?'} msgs)`,
            value: `\`${bar(sonnet.pct ?? 0)}\` **${sonnet.pct ?? '?'}%** \u2014 ${sonnet.remain ?? '?'} \ub0a8\uc74c\n\ub9ac\uc14b: ${sonnet.reset ?? '?'} (${sonnet.resetIn ?? '?'} \ud6c4)`,
            inline: false,
          },
        )
        .setFooter({ text: `\uce90\uc2dc \uae30\uc900: ${tsStr}` })
        .setTimestamp();

      if (existsSync(statsPath)) {
        try {
          const stats = JSON.parse(readFileSync(statsPath, 'utf-8'));
          const recent = (stats.dailyActivity ?? []).slice(-3).reverse();
          if (recent.length > 0) {
            const rows = recent.map(d => `\`${d.date}\` ${d.messageCount}msg / ${d.toolCallCount}tools`).join('\n');
            embed.addFields({ name: '\ucd5c\uadfc 3\uc77c \ud65c\ub3d9', value: rows, inline: false });
          }
        } catch { /* stats parsing failure ignored */ }
      }

      await interaction.editReply({ embeds: [embed] });
    } catch (err) {
      await interaction.editReply('\u274c \uc0ac\uc6a9\ub7c9 \uc870\ud68c \uc2e4\ud328: ' + (err.message?.slice(0, 300) || 'Unknown error'));
      log('error', 'Usage command failed', { error: err.message?.slice(0, 200) });
    }
  }
}
