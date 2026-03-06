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
  createClaudeSession,
  saveConversationTurn,
  processFeedback,
} from './claude-runner.js';
import { userMemory } from './user-memory.js';
import { t } from './i18n.js';
import { recordError } from './error-tracker.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const INPUT_MAX_CHARS = 4000;
const TYPING_INTERVAL_MS = 8000;

const EMOJI = {
  DONE:      '\u2705',   // ✅
  ERROR:     '\u274c',   // ❌
  THINKING:  '\u23f3',   // ⏳ 응답 대기 중
  CODE:      '\ud83d\udcbb', // 💻
  MARKET:    '\ud83d\udcb9', // 💹
  SYSTEM:    '\ud83d\udda5', // 🖥️  (fe0f는 variation selector, react엔 기본 형태)
  TRANSLATE: '\ud83c\udf0d', // 🌍
  EDUCATION: '\ud83d\udcda', // 📚
  IMAGE:     '\ud83d\uddbc', // 🖼️
};

/** 메시지 내용에 따라 처리 중 표시할 컨텍스트 이모지 반환 */
function getContextualEmoji(prompt, hasImages) {
  if (hasImages) return EMOJI.IMAGE;
  const lower = (prompt || '').toLowerCase();
  if (/코드|함수|클래스|버그|디버그|리뷰|리팩터|개발|구현|에러|오류|스크립트|컴파일/.test(lower)) return EMOJI.CODE;
  if (/시장|주가|투자|tqqq|나스닥|soxl|nvda|환율|코인|매수|매도|차트/.test(lower)) return EMOJI.MARKET;
  if (/시스템|서버|인프라|로그|상태|크론|디스크|메모리|cpu|프로세스|배포/.test(lower)) return EMOJI.SYSTEM;
  if (/번역|영어|english|translate|영문|표현/.test(lower)) return EMOJI.TRANSLATE;
  if (/수업|학생|교육|한국어|커리큘럼|topik|문법/.test(lower)) return EMOJI.EDUCATION;
  return null; // 기본 — THINKING만 표시
}

// ---------------------------------------------------------------------------
// Dynamic tool display — contextual emoji + description per tool
// ---------------------------------------------------------------------------

const TOOL_DISPLAY = {
  // File operations
  Read:  { desc: '\ud83d\udcd6 파일을 읽고 있어요' },
  Edit:  { desc: '\u270f\ufe0f 코드를 수정 중' },
  Write: { desc: '\ud83d\udcdd 파일을 작성 중' },
  // Search
  Grep:  { desc: '\ud83d\udd0d 코드를 검색 중' },
  Glob:  { desc: '\ud83d\udcc2 파일을 찾는 중' },
  // Execution
  Bash:  { desc: '\u26a1 명령어 실행 중' },
  // Web
  WebSearch: { desc: '\ud83c\udf10 웹 검색 중' },
  WebFetch:  { desc: '\ud83c\udf10 웹 페이지 확인 중' },
  // Agent
  Agent: { desc: '\ud83e\udd16 에이전트 투입' },
  // MCP Nexus (1st priority tools)
  mcp__nexus__exec:       { desc: '\u26a1 시스템 명령 실행 중' },
  mcp__nexus__scan:       { desc: '\ud83d\udce1 병렬 스캔 중' },
  mcp__nexus__cache_exec: { desc: '\u26a1 캐시 명령 실행 중' },
  mcp__nexus__log_tail:   { desc: '\ud83d\udccb 로그를 확인하고 있어요' },
  mcp__nexus__health:     { desc: '\ud83c\udfe5 시스템 건강 점검 중' },
  mcp__nexus__file_peek:  { desc: '\ud83d\udd2e 파일 내용 확인 중' },
  mcp__nexus__rag_search: { desc: '\ud83e\udde0 기억을 검색하고 있어요' },
  // MCP Serena (2nd priority — code symbol tools)
  mcp__serena__find_symbol:            { desc: '\ud83e\uddec 코드 심볼 탐색 중' },
  mcp__serena__get_symbols_overview:   { desc: '\ud83e\uddec 코드 구조 파악 중' },
  mcp__serena__search_for_pattern:     { desc: '\ud83d\udd0d 패턴 검색 중' },
  mcp__serena__find_referencing_symbols: { desc: '\ud83d\udd17 참조 추적 중' },
  mcp__serena__find_file:              { desc: '\ud83d\udcc2 파일을 찾는 중' },
  mcp__serena__read_memory:            { desc: '\ud83e\udde0 프로젝트 메모리 확인 중' },
};

/** Look up emoji + description for a tool name, with keyword fallback. */
function getToolDisplay(toolName) {
  if (TOOL_DISPLAY[toolName]) return TOOL_DISPLAY[toolName];
  const lower = (toolName || '').toLowerCase();
  if (lower.includes('rag') || lower.includes('memory')) return { desc: '\ud83e\udde0 기억을 검색 중' };
  if (lower.includes('search') || lower.includes('find')) return { desc: '\ud83d\udd0d 검색 중' };
  if (lower.includes('read') || lower.includes('get')) return { desc: '\ud83d\udcd6 데이터 확인 중' };
  if (lower.includes('write') || lower.includes('create') || lower.includes('edit')) return { desc: '\u270f\ufe0f 작성 중' };
  if (lower.includes('web') || lower.includes('fetch') || lower.includes('brave')) return { desc: '\ud83c\udf10 웹 확인 중' };
  if (lower.includes('exec') || lower.includes('bash') || lower.includes('run')) return { desc: '\u26a1 실행 중' };
  if (lower.includes('git') || lower.includes('github')) return { desc: '\ud83d\udce6 저장소 확인 중' };
  if (lower.includes('symbol') || lower.includes('lsp') || lower.includes('serena')) return { desc: '\ud83e\uddec 코드 구조 분석 중' };
  return { desc: `\ud83d\udee0\ufe0f ${toolName}` };
}

// ---------------------------------------------------------------------------
// Context-aware initial thinking message
// ---------------------------------------------------------------------------

function getContextualThinking(prompt, hasImages) {
  if (hasImages) return t('stream.thinking.image');
  const lower = (prompt || '').toLowerCase();
  if (/코드|함수|클래스|버그|디버그|리뷰|리팩터|개발|구현|에러|오류|스크립트|컴파일/.test(lower)) return t('stream.thinking.code');
  if (/시장|주가|투자|tqqq|나스닥|soxl|nvda|환율|코인|매수|매도|차트/.test(lower)) return t('stream.thinking.market');
  if (/시스템|서버|인프라|로그|상태|크론|디스크|메모리|cpu|프로세스|배포/.test(lower)) return t('stream.thinking.system');
  if (/번역|영어|english|translate|영문|표현/.test(lower)) return t('stream.thinking.translate');
  if (/수업|학생|교육|한국어|커리큘럼|topik|문법/.test(lower)) return t('stream.thinking.education');
  return t('stream.thinking');
}

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
      t('msg.tooLong', { length: message.content.length, max: INPUT_MAX_CHARS }),
    );
    return;
  }

  // Text-based /remember or 기억해: command
  const rememberMatch = message.content.match(/^\/remember\s+(.+)/s) || message.content.match(/^기억해:\s*(.+)/s);
  if (rememberMatch) {
    const fact = rememberMatch[1].trim();
    if (fact) {
      userMemory.addFact(message.author.id, fact);
      await message.reply(t('msg.remembered'));
      log('info', 'User memory saved via text command', { userId: message.author.id, fact: fact.slice(0, 100) });
    }
    return;
  }

  // Rate limit check
  const rate = rateTracker.check();
  if (rate.reject) {
    await message.reply(t('rate.reject'));
    return;
  }
  if (rate.warn) {
    await message.channel.send(
      t('rate.warn', { count: rate.count, max: rate.max, pct: Math.round(rate.pct * 100) }),
    );
  }

  if (!semaphore.acquire()) {
    await message.reply(t('msg.busy', { botName: process.env.BOT_NAME || 'Claude Bot', max: semaphore.max }));
    return;
  }

  rateTracker.record();

  let thread;
  let sessionId = null;
  let sessionKey = null;
  let typingInterval = null;
  let timeoutHandle = null;
  let imageAttachments = [];
  let userPrompt = message.content;

  // Learning feedback loop
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
      const r = message.reactions.cache.get(emoji);
      if (r) await r.users.remove(message.client.user.id);
      reactions.delete(emoji);
    } catch { /* ignore */ }
  }

  const startTime = Date.now();
  try {
    thread = message.channel;
    sessionKey = isThread ? thread.id : `${thread.id}-${message.author.id}`;
    sessionId = sessions.get(sessionKey);

    // 능동형 응답대기 리액션 — 메시지 수신 즉시 처리 시작 표시
    await react(EMOJI.THINKING);
    const ctxEmoji = getContextualEmoji(userPrompt, imageAttachments.length > 0);
    if (ctxEmoji) await react(ctxEmoji);

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
      userPrompt = t('msg.analyzeImage');
    }

    const effectiveChannelId = isThread ? message.channel.parentId : message.channel.id;
    const streamer = new StreamingMessage(thread, message, sessionKey, effectiveChannelId);
    streamer.setContext(getContextualThinking(userPrompt, imageAttachments.length > 0));
    await streamer.sendPlaceholder();

    // RAG는 mcp__nexus__rag_search 도구로 아젠틱하게 검색 (사전 주입 제거)
    // Claude가 대화 중 필요할 때 직접 rag_search를 호출한다.

    const MAX_CONTINUATIONS = 2;
    let continuationCount = 0;

    async function runClaude(sid, streamer) {
      log('info', 'Starting Claude session', {
        threadId: thread.id,
        resume: !!sid,
        promptLen: userPrompt.length,
      });

      const LARGE_KEYWORDS = /코드|분석|파일|구조|함수|클래스|디버그|확인|리뷰|왜|어떻게|동작|안됨|안되|안돼|수정|추가|만들어|고쳐|바꿔|구현|삭제|에러|오류|버그|리팩터|개발|스크립트|explain|debug|analyze|review|fix|implement|edit|refactor/i;
      const contextBudget = userPrompt.length > 200 || LARGE_KEYWORDS.test(userPrompt) ? 'large' : 'medium';

      // AbortController replaces proc.kill() — clean async cancellation
      const abortController = new AbortController();

      // Compat shim: commands.js uses active.proc.kill() and active.proc.killed
      let aborted = false;
      const procShim = {
        kill: () => { aborted = true; abortController.abort(); },
        get killed() { return aborted; },
      };

      timeoutHandle = setTimeout(() => {
        log('warn', 'Claude session timed out, aborting', { threadId: thread.id });
        procShim.kill();
      }, 480_000);

      activeProcesses.set(sessionKey, { proc: procShim, timeout: timeoutHandle, typingInterval });

      let lastAssistantText = '';
      let toolCount = 0;
      let retryNeeded = false;
      let needsContinuation = false;

      for await (const event of createClaudeSession(userPrompt, {
        sessionId: sid,
        threadId: thread.id,
        channelId: effectiveChannelId,
        attachments: imageAttachments,
        userId: message.author.id,
        contextBudget,
        signal: abortController.signal,
      })) {
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
                }
                lastAssistantText = fullText;
              } else if (block.type === 'tool_use') {
                toolCount++;
                const display = getToolDisplay(block.name || '');
                streamer.updateStatus(display.desc);
                log('info', `Tool: ${block.name}`, { threadId: thread.id });
              }
            }
          }
        } else if (event.type === 'content_block_delta') {
          if (event.delta?.type === 'text_delta' && event.delta?.text) {
            streamer.append(event.delta.text);
          }
        } else if (event.type === 'result') {
          log('debug', 'Result event received', {
            isError: event.is_error ?? false,
            hasResult: !!event.result,
            resultLen: event.result?.length ?? 0,
            hasAssistantText: lastAssistantText.length > 0,
            stopReason: event.stop_reason ?? 'unknown',
          });

          // Resume failure → retry fresh
          if (event.is_error && sid) {
            log('warn', 'Resume failed, retrying fresh', { sessionId: sid });
            sessions.delete(sessionKey);
            retryNeeded = true;
            break;
          }

          // Fallback: use result text if streamer buffer is empty
          if (event.result && !streamer.hasRealContent && lastAssistantText === '') {
            log('info', 'Using event.result fallback', { resultLen: event.result.length });
            streamer.append(event.result);
          }

          const resultSessionId = event.session_id ?? null;
          if (resultSessionId) sessions.set(sessionKey, resultSessionId);

          // Auto-continue on max_turns (up to MAX_CONTINUATIONS times)
          if (event.stop_reason === 'max_turns' && resultSessionId && continuationCount < MAX_CONTINUATIONS) {
            continuationCount++;
            log('info', 'max_turns hit, auto-continuing', {
              threadId: thread.id, continuation: continuationCount, toolCount,
            });
            needsContinuation = true;
            break;
          }

          // Final max_turns (exhausted continuations) — notify user
          if (event.stop_reason === 'max_turns') {
            streamer.append('\n\n' + t('msg.truncated'));
            log('warn', 'Response truncated by max-turns (continuations exhausted)', { threadId: thread.id, toolCount });
          }

          await streamer.finalize();

          const cost = event.cost_usd ?? null;

          // ⏳ 제거 → ✅ 교체
          await unreact(EMOJI.THINKING);
          await react(EMOJI.DONE);

          const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
          const footerParts = [];
          if (cost !== null) footerParts.push(`$${Number(cost).toFixed(4)}`);
          if (toolCount > 0) footerParts.push(`\ud83d\udee0\ufe0f ${toolCount}`);
          footerParts.push(`${elapsed}s`);
          const embed = new EmbedBuilder()
            .setColor(0x57f287)
            .setFooter({ text: footerParts.join(' \u00b7 ') })
            .setTimestamp();
          await thread.send({ embeds: [embed] });

          log('info', 'Claude completed', {
            threadId: thread.id, cost, toolCount, sessionId: resultSessionId,
            stopReason: event.stop_reason ?? 'unknown', elapsed: `${elapsed}s`,
          });

          if (lastAssistantText.length > 20) {
            const chName = isThread ? (message.channel.parent?.name ?? 'thread') : (message.channel.name ?? 'dm');
            saveConversationTurn(userPrompt, lastAssistantText, chName, message.author.id);
          }
        }
      }

      clearTimeout(timeoutHandle);
      timeoutHandle = null;
      activeProcesses.delete(sessionKey);

      // Loop ended without result event — likely max-turns or abort
      if (!streamer.finalized && !retryNeeded && !needsContinuation) {
        if (aborted) {
          streamer.append('\n\n' + t('msg.timeout'));
        } else if (streamer.hasRealContent && toolCount > 0) {
          streamer.append('\n\n' + t('msg.truncated'));
        }
        await streamer.finalize();
      }

      return { retryNeeded, needsContinuation, lastAssistantText, toolCount };
    }

    // First attempt
    let runResult = await runClaude(sessionId, streamer);

    // Retry with fresh session if resume caused error
    if (runResult.retryNeeded) {
      log('info', 'Retrying Claude with fresh session', { threadId: thread.id });
      sessionId = null;
      streamer.finalized = false;
      streamer.buffer = '';
      streamer.sentLength = 0;
      streamer.hasRealContent = false;
      streamer._statusLines = [];
      streamer._toolCount = 0;
      if (streamer._progressTimer) {
        clearInterval(streamer._progressTimer);
        streamer._progressTimer = null;
      }
      if (streamer._statusTimer) {
        clearTimeout(streamer._statusTimer);
        streamer._statusTimer = null;
      }
      streamer.replyTo = message;
      runResult = await runClaude(null, streamer);
    }

    // Auto-continue: resume session with "계속해줘" to finish incomplete response
    while (runResult.needsContinuation) {
      const contSessionId = sessions.get(sessionKey);
      log('info', 'Auto-continuing session', { threadId: thread.id, sessionId: contSessionId });
      userPrompt = `이전 응답이 턴 제한으로 중단됐다. 지금까지 도구 ${runResult.toolCount ?? 0}회 사용. 남은 작업만 집중해서 완료해줘. 이미 한 작업은 반복하지 마.`;
      runResult = await runClaude(contSessionId, streamer);
    }

    // If nothing was produced (no text, no result), show generic error
    if (!streamer.hasRealContent && runResult.lastAssistantText === '') {
      await react(EMOJI.ERROR);
      const embed = new EmbedBuilder()
        .setColor(0xed4245)
        .setTitle(t('error.title'))
        .setDescription(t('error.noResponse'))
        .addFields({ name: t('error.helpTitle'), value: t('error.noResponse.help') })
        .setTimestamp();
      if (streamer.currentMessage) {
        await streamer.currentMessage.edit({ content: null, embeds: [embed], components: [] });
      } else {
        await thread.send({ embeds: [embed] });
      }
      recordError(thread.id, message.author.id, 'no_response');
    }
  } catch (err) {
    log('error', 'handleMessage error', { error: err.message, stack: err.stack });

    await react(EMOJI.ERROR);

    const target = thread || message.channel;

    // 일시적 에러(네트워크, SDK)일 경우 1회 자동 재시도
    const isTransient = /ETIMEDOUT|ECONNRESET|ENOTFOUND|SDK error|process exited/i.test(err.message || '');
    if (isTransient && !message._retried) {
      message._retried = true;
      log('info', 'Auto-retrying after transient error', { error: err.message });
      try {
        await target.send({ content: '⏳ 일시적 오류 발생. 자동으로 재시도합니다...' });
        semaphore.release(); // 세마포어 해제 후 재진입
        return handleMessage(message, { sessions, rateTracker, semaphore, activeProcesses, client });
      } catch (retryErr) {
        log('error', 'Auto-retry also failed', { error: retryErr.message });
        recordError(target.id, message.author.id, retryErr.message?.slice(0, 200));
      }
    }

    const embed = new EmbedBuilder()
      .setColor(0xed4245)
      .setTitle(t('error.generic'))
      .setDescription(err.message?.slice(0, 400) || 'Unknown error')
      .addFields({ name: t('error.helpTitle'), value: t('error.generic.help') })
      .setTimestamp();
    try {
      await target.send({ embeds: [embed] });
    } catch { /* Can't send to channel either */ }
    recordError(target.id, message.author.id, err.message?.slice(0, 200));
    sendNtfy(`${process.env.BOT_NAME || 'Claude Bot'} Error`, err.message, 'high');
  } finally {
    if (typingInterval) clearInterval(typingInterval);
    if (timeoutHandle) clearTimeout(timeoutHandle);
    semaphore.release();
    if (sessionKey) activeProcesses.delete(sessionKey);

    // Keep workDir if session is alive (resume needs stable cwd)
    const threadId = thread?.id;
    if (threadId && sessionKey && !sessions.get(sessionKey)) {
      try {
        rmSync(join('/tmp', 'claude-discord', String(threadId)), { recursive: true, force: true });
      } catch { /* Best effort */ }
    }

    // Cleanup temp image files
    for (const { localPath } of imageAttachments) {
      try { rmSync(localPath, { force: true }); } catch { /* best effort */ }
    }
  }
}
