/**
 * Discord message handler — main entry point per incoming message.
 *
 * Exports: handleMessage(message, state)
 *   state = { sessions, rateTracker, semaphore, activeProcesses, client }
 */

import { writeFileSync, rmSync } from 'node:fs';
import { join, extname } from 'node:path';
import { EmbedBuilder } from 'discord.js';
import { log, sendNtfy } from './claude-runner.js';
import { StreamingMessage } from './session.js';
import {
  spawnClaude,
  parseStreamEvents,
  execRagAsync,
  saveConversationTurn,
  processFeedback,
} from './claude-runner.js';
import { userMemory } from './user-memory.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const INPUT_MAX_CHARS = 4000;
const TYPING_INTERVAL_MS = 8000;
const STALL_SOFT_MS = 10_000;
const STALL_HARD_MS = 30_000;

const EMOJI = {
  THINKING: '🧠',
  TOOL: '🛠️',
  WEB: '🌐',
  DONE: '✅',
  ERROR: '❌',
  STALL_SOFT: '⏳',
  STALL_HARD: '⚠️',
};

// ---------------------------------------------------------------------------
// handleMessage
// ---------------------------------------------------------------------------

export async function handleMessage(message, { sessions, rateTracker, semaphore, activeProcesses, client }) {
  log('debug', 'messageCreate received', {
    author: message.author.tag,
    bot: message.author.bot,
    channelId: message.channel.id,
    parentId: message.channel.parentId || null,
    isThread: message.channel.isThread?.() || false,
    contentLen: message.content?.length ?? 0,
  });

  if (message.author.bot) return;

  // Support multiple channels (CHANNEL_IDS comma-separated, fallback to CHANNEL_ID)
  const channelIds = (process.env.CHANNEL_IDS || process.env.CHANNEL_ID || '')
    .split(',')
    .map((id) => id.trim())
    .filter(Boolean);
  if (channelIds.length === 0) return;

  const isMainChannel = channelIds.includes(message.channel.id);
  const isThread =
    message.channel.isThread() && channelIds.includes(message.channel.parentId);

  if (!isMainChannel && !isThread) {
    log('debug', 'Message filtered out (not in allowed channel)', {
      channelId: message.channel.id,
      parentId: message.channel.parentId || null,
    });
    return;
  }

  const hasImages = message.attachments.size > 0 &&
    Array.from(message.attachments.values()).some((a) =>
      a.contentType?.startsWith('image/') || /\.(jpg|jpeg|png|gif|webp)$/i.test(a.name ?? ''),
    );
  if (!message.content && !hasImages) return;
  if (message.content.length > INPUT_MAX_CHARS) {
    await message.reply(
      `Message too long (${message.content.length} chars). Maximum is ${INPUT_MAX_CHARS}.`,
    );
    return;
  }

  // Text-based /remember or 기억해: command
  const rememberMatch = message.content.match(/^\/remember\s+(.+)/s) || message.content.match(/^기억해:\s*(.+)/s);
  if (rememberMatch) {
    const fact = rememberMatch[1].trim();
    if (fact) {
      userMemory.addFact(message.author.id, fact);
      await message.reply('기억했습니다 🧠');
      log('info', 'User memory saved via text command', { userId: message.author.id, fact: fact.slice(0, 100) });
    }
    return;
  }

  // Rate limit check
  const rate = rateTracker.check();
  if (rate.reject) {
    await message.reply('Rate limit approaching (90%). Please wait before sending more requests.');
    return;
  }
  if (rate.warn) {
    await message.channel.send(
      `Warning: ${rate.count}/${rate.max} requests used in the last 5h (${Math.round(rate.pct * 100)}%).`,
    );
  }

  if (!semaphore.acquire()) {
    await message.reply(`${process.env.BOT_NAME || 'Claude Bot'} is busy (${semaphore.max} concurrent requests). Please wait.`);
    return;
  }

  rateTracker.record();

  let thread;
  let sessionId = null;
  let sessionKey = null;
  let typingInterval = null;
  let stallTimer = null;
  let timeoutHandle = null;
  let workDir = null;
  let imageAttachments = [];
  let userPrompt = message.content;

  // Learning feedback loop: detect and persist user feedback signals
  const feedback = processFeedback(message.author.id, userPrompt);
  if (feedback) {
    log('info', 'Feedback detected', { userId: message.author.id, type: feedback.type });
  }

  const reactions = new Set();

  async function react(emoji) {
    try {
      if (!reactions.has(emoji)) {
        await message.react(emoji);
        reactions.add(emoji);
      }
    } catch { /* Missing permissions or message deleted */ }
  }

  async function unreact(emoji) {
    try {
      if (reactions.has(emoji)) {
        await message.reactions.cache.get(emoji)?.users?.remove(client.user.id);
        reactions.delete(emoji);
      }
    } catch { /* Best effort */ }
  }

  async function clearStatusReactions() {
    const statusEmojis = [EMOJI.THINKING, EMOJI.TOOL, EMOJI.WEB, EMOJI.STALL_SOFT, EMOJI.STALL_HARD];
    await Promise.allSettled(statusEmojis.map((e) => unreact(e)));
  }

  try {
    thread = message.channel;
    sessionKey = isThread ? thread.id : `${thread.id}-${message.author.id}`;
    sessionId = sessions.get(sessionKey);

    await react(EMOJI.THINKING);

    await thread.sendTyping();
    typingInterval = setInterval(() => {
      thread.sendTyping().catch(() => {});
    }, TYPING_INTERVAL_MS);

    // Download image attachments from Discord CDN
    for (const [, att] of message.attachments) {
      const isImage = att.contentType?.startsWith('image/') ||
        /\.(jpg|jpeg|png|gif|webp)$/i.test(att.name ?? '');
      if (!isImage) continue;
      try {
        const resp = await fetch(att.url);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const contentLength = parseInt(resp.headers.get('content-length') ?? '0', 10);
        if (contentLength > 20_000_000) throw new Error(`Image too large (${(contentLength / 1e6).toFixed(1)}MB, max 20MB)`);
        const buf = Buffer.from(await resp.arrayBuffer());
        const ext = att.contentType?.split('/')[1]?.split(';')[0] ||
          extname(att.name ?? '.jpg').slice(1) || 'jpg';
        const safeName = (att.name ?? `image_${att.id}.${ext}`)
          .replace(/[^a-zA-Z0-9._-]/g, '_');
        const localPath = join('/tmp', `claude-img-${att.id}.${ext}`);
        writeFileSync(localPath, buf);
        imageAttachments.push({ localPath, safeName });
        log('info', 'Downloaded attachment', { name: safeName, bytes: buf.length });
      } catch (err) {
        log('warn', 'Failed to download attachment', { id: att.id, error: err.message });
      }
    }
    if (!userPrompt.trim() && imageAttachments.length > 0) {
      userPrompt = '이 이미지를 분석해줘.';
    }

    const streamer = new StreamingMessage(thread, message, sessionKey);
    await streamer.sendPlaceholder();

    // RAG context search
    let ragContext = '';
    try {
      ragContext = await Promise.race([
        execRagAsync(userPrompt),
        new Promise(r => setTimeout(() => r(''), 8000)),
      ]);
    } catch (ragErr) {
      log('warn', 'RAG search failed', { error: ragErr.message?.slice(0, 200) });
    }

    async function runClaude(sid, streamer) {
      log('info', 'Spawning claude', {
        threadId: thread.id,
        resume: !!sid,
        promptLen: userPrompt.length,
        ragChars: ragContext.length,
      });

      const effectiveChannelId = isThread ? message.channel.parentId : message.channel.id;
      const { proc, rl, workDir: wd } = spawnClaude(userPrompt, {
        sessionId: sid,
        threadId: thread.id,
        channelId: effectiveChannelId,
        ragContext,
        attachments: imageAttachments,
        userId: message.author.id,
      });
      workDir = wd;

      timeoutHandle = setTimeout(() => {
        log('warn', 'Claude process timed out, killing', { threadId: thread.id });
        proc.kill('SIGTERM');
        setTimeout(() => { if (!proc.killed) proc.kill('SIGKILL'); }, 5000);
      }, 300_000);
      activeProcesses.set(sessionKey, { proc, timeout: timeoutHandle, typingInterval });

      let stderrBuf = '';
      proc.stderr.on('data', (chunk) => { stderrBuf += chunk.toString(); });

      let lastOutputTime = Date.now();
      let stallSoftFired = false;
      let stallHardFired = false;
      let lastAssistantText = '';
      let toolCount = 0;
      let retryNeeded = false;

      stallTimer = setInterval(async () => {
        const elapsed = Date.now() - lastOutputTime;
        if (elapsed >= STALL_HARD_MS && !stallHardFired) {
          stallHardFired = true;
          await react(EMOJI.STALL_HARD);
        } else if (elapsed >= STALL_SOFT_MS && !stallSoftFired) {
          stallSoftFired = true;
          await react(EMOJI.STALL_SOFT);
        }
      }, 2000);

      function resetStall() {
        lastOutputTime = Date.now();
        if (stallSoftFired) { unreact(EMOJI.STALL_SOFT); stallSoftFired = false; }
        if (stallHardFired) { unreact(EMOJI.STALL_HARD); stallHardFired = false; }
      }

      for await (const event of parseStreamEvents(rl)) {
        if (event.type === 'system') {
          if (event.session_id) {
            sessions.set(sessionKey, event.session_id);
            log('info', 'Session saved', { threadId: thread.id, sessionId: event.session_id });
          }
        } else if (event.type === 'assistant') {
          if (event.message?.content) {
            for (const block of event.message.content) {
              if (block.type === 'text') {
                const fullText = block.text;
                if (fullText.length > lastAssistantText.length) {
                  streamer.append(fullText.slice(lastAssistantText.length));
                  resetStall();
                }
                lastAssistantText = fullText;
              } else if (block.type === 'tool_use') {
                toolCount++;
                const toolName = block.name?.toLowerCase() || '';
                if (toolName.includes('web') || toolName.includes('search') || toolName.includes('fetch')) {
                  await react(EMOJI.WEB);
                } else {
                  await react(EMOJI.TOOL);
                }
                resetStall();
                log('info', `Tool: ${block.name}`, { threadId: thread.id });
              }
            }
          }
        } else if (event.type === 'content_block_delta') {
          if (event.delta?.type === 'text_delta' && event.delta?.text) {
            streamer.append(event.delta.text);
            resetStall();
          }
        } else if (event.type === 'result') {
          clearInterval(stallTimer);
          stallTimer = null;

          log('debug', 'Result event received', {
            subtype: event.subtype,
            isError: event.is_error ?? false,
            hasResult: !!event.result,
            resultLen: event.result?.length ?? 0,
            hasAssistantText: lastAssistantText.length > 0,
          });

          // Resume failure: clear bad session and signal retry
          if ((event.is_error || event.subtype === 'error_during_execution') && sid) {
            log('warn', 'Resume failed, retrying fresh', { sessionId: sid });
            sessions.delete(sessionKey);
            proc.kill('SIGTERM');
            retryNeeded = true;
            break;
          }

          // Fallback: use event.result text if buffer is empty
          if (event.result && !streamer.hasRealContent && lastAssistantText === '') {
            log('info', 'Using event.result fallback', { resultLen: event.result.length });
            streamer.append(event.result);
          }

          await streamer.finalize();

          const cost = event.cost_usd ?? event.cost ?? null;
          const resultSessionId = event.session_id ?? null;
          if (resultSessionId) sessions.set(sessionKey, resultSessionId);

          await clearStatusReactions();
          await react(EMOJI.DONE);

          const footerParts = [];
          if (cost !== null) footerParts.push(`$${Number(cost).toFixed(4)}`);
          if (toolCount > 0) footerParts.push(`${toolCount} tool${toolCount > 1 ? 's' : ''}`);
          if (footerParts.length > 0) {
            const embed = new EmbedBuilder()
              .setColor(0x57f287)
              .setFooter({ text: footerParts.join(' · ') })
              .setTimestamp();
            await thread.send({ embeds: [embed] });
          }

          log('info', 'Claude completed', { threadId: thread.id, cost, toolCount, sessionId: resultSessionId });

          if (lastAssistantText.length > 20) {
            const chName = isThread ? (message.channel.parent?.name ?? 'thread') : (message.channel.name ?? 'dm');
            saveConversationTurn(userPrompt, lastAssistantText, chName);
          }
        }
      }

      clearInterval(stallTimer);
      stallTimer = null;
      if (proc.exitCode === null) await new Promise((r) => proc.on('close', r));
      clearTimeout(timeoutHandle);
      timeoutHandle = null;
      activeProcesses.delete(sessionKey);

      if (!streamer.finalized && !retryNeeded) await streamer.finalize();

      return { retryNeeded, stderrBuf, lastAssistantText };
    }

    // First attempt
    let runResult = await runClaude(sessionId, streamer);

    // Retry with fresh session if resume caused error_during_execution
    if (runResult.retryNeeded) {
      log('info', 'Retrying claude with fresh session', { threadId: thread.id });
      sessionId = null;
      streamer.finalized = false;
      streamer.replyTo = message;
      runResult = await runClaude(null, streamer);
    }

    if (runResult.stderrBuf.trim() && !streamer.hasRealContent && runResult.lastAssistantText === '') {
      await clearStatusReactions();
      await react(EMOJI.ERROR);
      const errMsg = runResult.stderrBuf.trim().slice(0, 500);
      const embed = new EmbedBuilder()
        .setColor(0xed4245)
        .setTitle('Error')
        .setDescription(`\`\`\`\n${errMsg}\n\`\`\``)
        .setTimestamp();
      if (streamer.currentMessage) {
        await streamer.currentMessage.edit({ content: null, embeds: [embed], components: [] });
      } else {
        await thread.send({ embeds: [embed] });
      }
    }
  } catch (err) {
    log('error', 'handleMessage error', { error: err.message, stack: err.stack });

    await clearStatusReactions();
    await react(EMOJI.ERROR);

    const target = thread || message.channel;
    const embed = new EmbedBuilder()
      .setColor(0xed4245)
      .setTitle('Error')
      .setDescription(err.message?.slice(0, 500) || 'Unknown error')
      .setTimestamp();
    try {
      await target.send({ embeds: [embed] });
    } catch { /* Can't send to channel either */ }
    sendNtfy(`${process.env.BOT_NAME || 'Claude Bot'} Error`, err.message, 'high');
  } finally {
    if (typingInterval) clearInterval(typingInterval);
    if (stallTimer) clearInterval(stallTimer);
    if (timeoutHandle) clearTimeout(timeoutHandle);
    semaphore.release();
    if (sessionKey) activeProcesses.delete(sessionKey);

    // Keep workDir if session is alive (--resume needs stable cwd)
    if (workDir && sessionKey && !sessions.get(sessionKey)) {
      try {
        rmSync(workDir, { recursive: true, force: true });
      } catch { /* Best effort */ }
    }

    // Cleanup temp image files
    for (const { localPath } of imageAttachments) {
      try { rmSync(localPath, { force: true }); } catch { /* best effort */ }
    }
  }
}
