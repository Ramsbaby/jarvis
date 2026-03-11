/**
 * Discord message handler — main entry point per incoming message.
 *
 * Exports: handleMessage(message, state)
 *   state = { sessions, rateTracker, semaphore, activeProcesses, client }
 *
 * Extracted modules:
 *   ./rag-helper.js      — RAG engine init + search
 *   ./session-summary.js — session summary save/load
 *   ./context-budget.js  — prompt budget classification
 *   ./queue-processor.js — pending message queue
 */

import { writeFileSync, rmSync, readFileSync, existsSync, renameSync } from 'node:fs';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createReadStream } from 'node:fs';
const execFileAsync = promisify(execFile);

// OpenAI Whisper (음성 인식)
async function transcribeVoiceMessage(att) {
  try {
    const resp = await fetch(att.url);
    if (!resp.ok) throw new Error(`Download failed: HTTP ${resp.status}`);
    const buf = Buffer.from(await resp.arrayBuffer());
    const oggPath = join('/tmp', `voice-${att.id}.ogg`);
    const mp3Path = join('/tmp', `voice-${att.id}.mp3`);
    writeFileSync(oggPath, buf);
    // ogg → mp3 변환 (Whisper는 mp3/wav/m4a 선호)
    await execFileAsync('ffmpeg', ['-y', '-i', oggPath, '-q:a', '4', mp3Path]);
    rmSync(oggPath, { force: true });
    const { default: OpenAI } = await import('openai');
    const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
    const transcription = await openai.audio.transcriptions.create({
      file: createReadStream(mp3Path),
      model: 'whisper-1',
      language: 'ko',
    });
    rmSync(mp3Path, { force: true });
    return transcription.text?.trim() || null;
  } catch (err) {
    log('warn', 'Voice transcription failed', { id: att.id, error: err.message });
    return null;
  }
}
import { EmbedBuilder } from 'discord.js';
import { log, sendNtfy } from './claude-runner.js';
import { StreamingMessage } from './session.js';
import {
  createClaudeSession,
  saveConversationTurn,
  processFeedback,
  autoExtractMemory,
} from './claude-runner.js';
import { userMemory } from './user-memory.js';
import { t } from './i18n.js';
import { recordError } from './error-tracker.js';

// Extracted modules
import { PAST_REF_PATTERN, searchRagForContext } from './rag-helper.js';
import { saveSessionSummary, loadSessionSummary } from './session-summary.js';
import { classifyBudget } from './context-budget.js';
import { pendingQueue, enqueue, processQueue } from './queue-processor.js';
import { MessageDebouncer } from './message-debouncer.js';
import { ProcessorContext, createPreProcessorRegistry } from './pre-processor.js';
import { isPreplyQuery } from './prompt-sections.js';

// ---------------------------------------------------------------------------
// Message debouncer — 연속 메시지를 1.5s 대기 후 배치로 묶어 단일 Claude 호출
// (Best practice: OpenClaw/프로덕션 AI 봇 표준)
// ---------------------------------------------------------------------------
const _msgDebouncer = new MessageDebouncer();
/** cancel token restart 시 restartPrompt를 debounce 경유 후에도 보존 (messageId → prompt) */
const _promptOverrides = new Map();

// Pre-processor registry (Preply schedule/income + RAG context enrichment)
const _preProcessorRegistry = createPreProcessorRegistry(searchRagForContext);

/** 배치된 메시지 내용을 하나의 프롬프트로 합침 */
function _buildBatchContent(messages) {
  if (messages.length === 1) return messages[0].content;
  return messages
    .map((m, i) => (i === 0 ? m.content : `(추가) ${m.content}`))
    .join('\n');
}

// ---------------------------------------------------------------------------
// Pending task state — timeout 발생 시 저장, "계속" 입력 시 재주입
// ---------------------------------------------------------------------------

const _BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const PENDING_TASKS_PATH = join(_BOT_HOME, 'state', 'pending-tasks.json');
const PENDING_TASK_TTL_MS = 30 * 60 * 1000; // 30분

function _pruneExpiredPendingTasks(tasks) {
  const now = Date.now();
  let pruned = 0;
  for (const key of Object.keys(tasks)) {
    if (now - (tasks[key]?.savedAt ?? 0) > PENDING_TASK_TTL_MS) {
      delete tasks[key];
      pruned++;
    }
  }
  return pruned;
}

function _savePendingTask(sessionKey, prompt) {
  try {
    let tasks = {};
    if (existsSync(PENDING_TASKS_PATH)) {
      tasks = JSON.parse(readFileSync(PENDING_TASKS_PATH, 'utf-8'));
    }
    _pruneExpiredPendingTasks(tasks); // 저장 시 만료 항목 일괄 정리
    tasks[sessionKey] = { prompt, savedAt: Date.now() };
    const tmp = `${PENDING_TASKS_PATH}.tmp`;
    writeFileSync(tmp, JSON.stringify(tasks));
    renameSync(tmp, PENDING_TASKS_PATH);
  } catch (err) { log('warn', 'Failed to save pending task', { error: err?.message }); }
}

function _loadPendingTask(sessionKey) {
  try {
    if (!existsSync(PENDING_TASKS_PATH)) return null;
    const tasks = JSON.parse(readFileSync(PENDING_TASKS_PATH, 'utf-8'));
    const task = tasks[sessionKey];
    if (!task) return null;
    if (Date.now() - task.savedAt > PENDING_TASK_TTL_MS) {
      _clearPendingTask(sessionKey);
      return null;
    }
    return task.prompt;
  } catch { return null; }
}

function _clearPendingTask(sessionKey) {
  try {
    if (!existsSync(PENDING_TASKS_PATH)) return;
    const tasks = JSON.parse(readFileSync(PENDING_TASKS_PATH, 'utf-8'));
    delete tasks[sessionKey];
    const tmp = `${PENDING_TASKS_PATH}.tmp`;
    writeFileSync(tmp, JSON.stringify(tasks));
    renameSync(tmp, PENDING_TASKS_PATH);
  } catch { /* best effort */ }
}

// ---------------------------------------------------------------------------
// Session thinking-block detector

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const INPUT_MAX_CHARS = 4000;
const TYPING_INTERVAL_MS = 8000;


// Dedup: prevent same message from being processed twice (shard resume / race condition)
const processingMsgIds = new Set();

const EMOJI = {
  DONE:      '\u2705',   // checkmark
  ERROR:     '\u274c',   // cross mark
  THINKING:  '\u23f3',   // hourglass
  CODE:      '\ud83d\udcbb', // laptop
  MARKET:    '\ud83d\udcb9', // chart
  SYSTEM:    '\ud83d\udda5', // desktop
  TRANSLATE: '\ud83c\udf0d', // globe
  EDUCATION: '\ud83d\udcda', // books
  IMAGE:     '\ud83d\uddbc', // picture frame
};

/** Return a contextual emoji based on message content */
function getContextualEmoji(prompt, hasImages) {
  if (hasImages) return EMOJI.IMAGE;
  const lower = (prompt || '').toLowerCase();
  if (/코드|함수|클래스|버그|디버그|리뷰|리팩터|개발|구현|에러|오류|스크립트|컴파일/.test(lower)) return EMOJI.CODE;
  if (/시장|주가|투자|tqqq|나스닥|soxl|nvda|환율|코인|매수|매도|차트/.test(lower)) return EMOJI.MARKET;
  if (/시스템|서버|인프라|로그|상태|크론|디스크|메모리|cpu|프로세스|배포/.test(lower)) return EMOJI.SYSTEM;
  if (/번역|영어|english|translate|영문|표현/.test(lower)) return EMOJI.TRANSLATE;
  if (/수업|학생|교육|한국어|커리큘럼|topik|문법/.test(lower)) return EMOJI.EDUCATION;
  return null;
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
// handleMessage — debounce gate (thin entry point)
// ---------------------------------------------------------------------------

export async function handleMessage(message, state) {
  const { rateTracker } = state;

  log('debug', 'messageCreate received', {
    author: message.author.tag,
    bot: message.author.bot,
    channelId: message.channel.id,
    parentId: message.channel.parentId || null,
    isThread: message.channel.isThread?.() || false,
    contentLen: message.content?.length ?? 0,
  });

  if (message.author.bot) return;

  // Dedup guard
  if (processingMsgIds.has(message.id)) {
    log('debug', 'Duplicate messageCreate ignored', { messageId: message.id });
    return;
  }
  processingMsgIds.add(message.id);

  const channelIds = (process.env.CHANNEL_IDS || process.env.CHANNEL_ID || '')
    .split(',').map((id) => id.trim()).filter(Boolean);
  if (channelIds.length === 0) return;

  const isMainChannel = channelIds.includes(message.channel.id);
  const isThread =
    message.channel.isThread() && channelIds.includes(message.channel.parentId);

  if (!isMainChannel && !isThread) {
    log('debug', 'Message filtered out (not in allowed channel)', {
      channelId: message.channel.id, parentId: message.channel.parentId || null,
    });
    processingMsgIds.delete(message.id);
    return;
  }

  const hasImages = message.attachments.size > 0 &&
    Array.from(message.attachments.values()).some((a) =>
      a.contentType?.startsWith('image/') || /\.(jpg|jpeg|png|gif|webp)$/i.test(a.name ?? ''),
    );
  // Discord 음성 메시지: contentType = audio/ogg, flags에 IS_VOICE_MESSAGE(8192) 포함
  const voiceAtt = message.attachments.size > 0
    ? Array.from(message.attachments.values()).find((a) =>
        a.contentType?.startsWith('audio/') || /\.(ogg|mp3|m4a|wav)$/i.test(a.name ?? ''),
      )
    : null;
  const hasVoice = !!voiceAtt;
  if (!message.content && !hasImages && !hasVoice) { processingMsgIds.delete(message.id); return; }
  if (message.content.length > INPUT_MAX_CHARS) {
    await message.reply(t('msg.tooLong', { length: message.content.length, max: INPUT_MAX_CHARS }));
    processingMsgIds.delete(message.id);
    return;
  }

  // Text-based /remember or 기억해: — debounce 없이 즉시 처리
  const rememberMatch = message.content.match(/^\/remember\s+(.+)/s) || message.content.match(/^기억해:\s*(.+)/s);
  if (rememberMatch) {
    const fact = rememberMatch[1].trim();
    if (fact) {
      userMemory.addFact(message.author.id, fact);
      await message.reply(t('msg.remembered'));
      log('info', 'User memory saved via text command', { userId: message.author.id, fact: fact.slice(0, 100) });
    }
    processingMsgIds.delete(message.id);
    return;
  }

  // 이미지 첨부 → debounce 없이 즉시 처리 (CDN URL 만료 위험)
  // 슬래시 명령 → 즉시 처리
  const isBypassDebounce = hasImages || message.content.startsWith('/');
  const debounceKey = isThread ? message.channel.id : `${message.channel.id}-${message.author.id}`;

  if (isBypassDebounce) {
    await _processBatch([message], state);
    return;
  }

  // Rate limit은 debounce flush 시점에 한 번만 체크 (개별 메시지마다 차감 방지)
  // debouncer에 추가 — 1.5초 침묵 후 또는 4초 max cap에 flush
  _msgDebouncer.add(debounceKey, message, (messages) => {
    _processBatch(messages, state).catch(
      (err) => log('error', 'Batch processing failed', { error: err.message }),
    );
  });

  // debounce 대기 중 ⏳ 리액션
  await message.react('⏳').catch(() => {});
}

// ---------------------------------------------------------------------------
// _processBatch — 실제 처리 (단일 또는 배치 메시지)
// ---------------------------------------------------------------------------

async function _processBatch(messages, { sessions, rateTracker, semaphore, activeProcesses, client }) {
  const message = messages[messages.length - 1]; // Discord 작업용 (reply, react 등)
  // 음성 메시지 판별 (_processBatch는 handleMessage 스코프 밖이므로 여기서 재계산)
  const voiceAtt = message.attachments?.size > 0
    ? Array.from(message.attachments.values()).find((a) =>
        a.contentType?.startsWith('audio/') || /\.(ogg|mp3|m4a|wav)$/i.test(a.name ?? ''),
      )
    : null;
  const hasVoice = !!voiceAtt;
  let batchContent = _buildBatchContent(messages); // Claude에 보낼 결합 프롬프트
  // cancel token restart: processQueue → handleMessage → debouncer → 여기서 override 적용
  const _overrideKey = messages[messages.length - 1].id;
  const _override = _promptOverrides.get(_overrideKey);
  if (_override) { _promptOverrides.delete(_overrideKey); batchContent = _override; }

  if (messages.length > 1) {
    log('info', 'Batch flushed', {
      count: messages.length,
      totalLen: batchContent.length,
      contents: messages.map(m => m.content.slice(0, 40)),
    });
    // ⏳ 리액션 제거
    for (const m of messages) {
      m.reactions?.cache?.get('⏳')?.users?.remove(m.client?.user?.id).catch(() => {});
    }
  }

  // cleanup: 배치 내 모든 메시지 dedup 해제 (마지막 메시지는 finally에서)
  for (let i = 0; i < messages.length - 1; i++) {
    processingMsgIds.delete(messages[i].id);
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

  // isThread/isMainChannel 재계산 (_processBatch는 message가 달라졌으므로)
  const channelIds2 = (process.env.CHANNEL_IDS || process.env.CHANNEL_ID || '')
    .split(',').map((id) => id.trim()).filter(Boolean);
  const isThread = message.channel.isThread() && channelIds2.includes(message.channel.parentId);

  if (!(await semaphore.acquire())) {
    const queueKey = isThread ? message.channel.id : `${message.channel.id}-${message.author.id}`;

    // Cancel Token: 동일 사용자 응답 생성 중 → 중단 후 통합 재시작
    // (Claude SDK: 동일 session_id 동시 호출 공식 미지원 — 직렬화 필수)
    const activeEntry = activeProcesses.get(queueKey);
    if (activeEntry) {
      const partialText = activeEntry.streamer?.buffer?.slice(0, 600) ?? '';
      const prevPrompt = activeEntry.originalPrompt ?? '';

      // 기존 스트림 중단
      activeEntry.proc.kill();
      log('info', 'Cancel token: aborted active generation for restart', { queueKey, prevPromptLen: prevPrompt.length });

      // 원래 요청 + 부분 응답 + 새 요청 통합 프롬프트
      const restartPrompt = [
        `이전 작업 중 추가 요청이 들어와 통합 재시작합니다.`,
        `[이전 요청] ${prevPrompt}`,
        partialText ? `[부분 응답 — 참고만] ${partialText}` : '',
        `[추가 요청] ${batchContent}`,
        `\n두 요청을 합쳐 완전하게 답변해줘.`,
      ].filter(Boolean).join('\n');

      // processingMsgIds 정리: early return이라 finally 미도달 → 수동 해제
      for (const m of messages) processingMsgIds.delete(m.id);
      _promptOverrides.set(message.id, restartPrompt); // processQueue → handleMessage → debouncer 경유 후 복원
      enqueue(queueKey, message, restartPrompt);
      await message.react('🔄').catch(() => {});
      return;
    }

    // 일반 큐잉 (다른 세션 처리 중)
    // processingMsgIds 정리: early return이라 finally 미도달 → 수동 해제
    for (const m of messages) processingMsgIds.delete(m.id);
    enqueue(queueKey, message, batchContent);
    await message.react('\u23f3');
    return;
  }

  rateTracker.record();

  let thread;
  let sessionId = null;
  let sessionKey = null;
  let typingInterval = null;
  let timeoutHandle = null;
  let imageAttachments = [];
  let userPrompt = batchContent;           // ← 배치 결합 프롬프트
  let streamer = null; // outer scope for finalize in catch
  const originalPrompt = batchContent;    // ← 배치 결합 프롬프트

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
  let retryHandled = false;
  try {
    thread = message.channel;
    sessionKey = isThread ? thread.id : `${thread.id}-${message.author.id}`;
    sessionId = sessions.get(sessionKey);

    // "계속" 감지: 타임아웃으로 중단된 작업 재개
    const CONTINUE_PATTERN = /^(계속|continue|이어서|이어서\s*해줘?|계속\s*해줘?|continue from where you left off)$/i;
    let _continueHandled = false; // 세션 요약 중복 주입 방지 플래그
    if (CONTINUE_PATTERN.test(userPrompt.trim())) {
      const pending = _loadPendingTask(sessionKey);
      const summary = loadSessionSummary(sessionKey);

      if (!pending && !summary) {
        // 이어받을 작업도, 세션 요약도 없음 → 안내만 하고 종료
        if (typingInterval) clearInterval(typingInterval);
        typingInterval = null;
        await message.reply('이어받을 작업이 없습니다. 새로운 질문이나 지시를 입력해주세요.');
        log('info', 'Continue requested but no pending task or session summary found', { threadId: thread.id, sessionKey });
        return;
      }

      // 컨텍스트 블록 조립: 세션 요약 + pending task 순서로 주입
      const contextParts = [];
      if (summary) {
        contextParts.push(summary.trimEnd());
        log('info', 'Session summary injected for 계속 resume', { threadId: thread.id });
      }
      if (pending) {
        contextParts.push(`## 중단된 작업\n타임아웃으로 중단된 작업입니다. 아래 원래 요청을 이어서 완료해줘.\n원래 요청: "${pending}"`);
        _clearPendingTask(sessionKey);
        log('info', 'Pending task resumed via 계속', { threadId: thread.id, pendingLen: pending.length });
      }
      // 프롬프트 앞에 컨텍스트 주입 (세션 요약 → pending task → 유저 원문 순)
      userPrompt = contextParts.join('\n\n') + '\n\n' + '위 맥락을 바탕으로 중단된 작업을 이어서 진행해줘.';
      _continueHandled = true; // 아래 세션 요약 재주입 방지
    }

    const hasImages = messages.some((m) =>
      m.attachments.size > 0 &&
      [...m.attachments.values()].some(
        (a) => a.contentType?.startsWith('image/') || /\.(jpg|jpeg|png|gif|webp)$/i.test(a.name ?? ''),
      ),
    );
    await react(EMOJI.THINKING);
    const ctxEmoji = getContextualEmoji(userPrompt, hasImages);
    if (ctxEmoji) await react(ctxEmoji);

    await thread.sendTyping();
    typingInterval = setInterval(() => {
      thread.sendTyping().catch(() => {});
    }, TYPING_INTERVAL_MS);

    // 🎙️ 음성 메시지 → Whisper 텍스트 변환
    if (hasVoice && voiceAtt && process.env.OPENAI_API_KEY) {
      log('info', 'Voice message detected, transcribing...', { id: voiceAtt.id });
      const transcript = await transcribeVoiceMessage(voiceAtt);
      if (transcript) {
        userPrompt = userPrompt
          ? `[음성 메시지 내용: "${transcript}"]\n\n${userPrompt}`
          : transcript;
        log('info', 'Voice transcription complete', { length: transcript.length });
      } else {
        await thread.send('🎙️ 음성 인식에 실패했습니다. 텍스트로 다시 입력해주세요.');
        processingMsgIds.delete(message.id);
        return;
      }
    }

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
    streamer = new StreamingMessage(thread, message, sessionKey, effectiveChannelId);
    streamer.setContext(getContextualThinking(userPrompt, imageAttachments.length > 0));
    await streamer.sendPlaceholder();

    // Session summary pre-injection for resume safety
    // _continueHandled=true이면 이미 "계속" 블록에서 요약을 주입했으므로 중복 방지
    if (sessionId && !_continueHandled) {
      const summary = loadSessionSummary(sessionKey);
      if (summary) {
        // Preply 질문인데 요약에 잘못된 MCP/캘린더 내용이 있으면 주입하지 않음
        const BAD_PREPLY_SUMMARY = /google calendar|캘린더.*mcp|mcp.*캘린더|settings\.json.*수정|재시작.*후.*다시/is;
        const skipSummary = isPreplyQuery(originalPrompt) && BAD_PREPLY_SUMMARY.test(summary);
        if (!skipSummary) {
          userPrompt = summary + userPrompt;
          log('info', 'Session summary pre-injected for resume safety', { threadId: thread.id });
        } else {
          log('info', 'Session summary skipped (bad Preply context detected)', { threadId: thread.id });
        }
      }
    }

    const MAX_CONTINUATIONS = 5;
    let continuationCount = 0;

    async function runClaude(sid, streamer) {
      log('info', 'Starting Claude session', {
        threadId: thread.id,
        resume: !!sid,
        promptLen: userPrompt.length,
      });

      // Budget based on original prompt (not inflated by summary/RAG injection)
      // Preply queries always get at least medium — short prompts like "오늘 수업?" get large injection
      let contextBudget = classifyBudget(originalPrompt, imageAttachments.length > 0);
      if (contextBudget === 'small' && isPreplyQuery(originalPrompt)) {
        contextBudget = 'medium';
        log('info', 'Budget upgraded: small→medium (Preply query detected)', { threadId: thread.id });
      }

      // AbortController replaces proc.kill()
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
      }, 600_000);

      activeProcesses.set(sessionKey, { proc: procShim, timeout: timeoutHandle, typingInterval, userId: message.author.id, streamer, originalPrompt, sessionKey });
      // 즉시 active-session 파일 기록 (watchdog이 5분 주기 전에 체크해도 보호됨)
      try { writeFileSync(join(_BOT_HOME, 'state', 'active-session'), String(Date.now())); } catch { /* best effort */ }

      let lastAssistantText = '';
      let toolCount = 0;
      let retryNeeded = false;
      let needsContinuation = false;
      let hasStreamEvents = false;
      let lastStreamBlockWasTool = false; // 툴 블록 직후 텍스트 개행 삽입용

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
          if (event.session_reset) {
            log('warn', 'Session silently reset inside createClaudeSession', {
              threadId: thread.id, reason: event.reason,
            });
          }
          if (event.session_id) {
            // thinking 블록이 있어도 저장. resume 실패 시 retryNeeded=true로 자동 폴백됨.
            sessions.set(sessionKey, event.session_id);
            log('info', 'Session saved', { threadId: thread.id, sessionId: event.session_id });
          }
        } else if (event.type === 'stream_event') {
          const se = event.event;
          if (se.type === 'content_block_delta' && se.delta?.type === 'text_delta' && se.delta?.text) {
            hasStreamEvents = true;
            // 툴 블록 직후 새 텍스트 시작 시 개행 삽입
            // buf가 이미 flush되어 비어있어도 hasRealContent면 이전 전송 내용 있음 → \n\n 필요
            if (lastStreamBlockWasTool && streamer.hasRealContent) {
              const buf = streamer.buffer ?? '';
              // 문장 끝(공백·줄바꿈·마침표·느낌표·물음표)일 때만 단락 구분
              // 단어 중간(예: "P" + 도구 + "ID 770...")이면 구분 없이 이어붙임
              const endsAtWordBoundary = buf.length === 0 || /[\s.!?。，、]$/.test(buf);
              if (endsAtWordBoundary && !buf.endsWith('\n')) streamer.append('\n\n');
              lastStreamBlockWasTool = false;
            }
            streamer.append(se.delta.text);
          } else if (se.type === 'content_block_start' && se.content_block?.type === 'tool_use') {
            hasStreamEvents = true;
            lastStreamBlockWasTool = true;
            toolCount++;
            const display = getToolDisplay(se.content_block.name || '');
            streamer.updateStatus(display.desc);
            log('info', `Tool: ${se.content_block.name}`, { threadId: thread.id });
          }
        } else if (event.type === 'assistant') {
          if (event.message?.content) {
            for (const block of event.message.content) {
              if (block.type === 'text') {
                lastAssistantText += (lastAssistantText ? '\n' : '') + block.text;
                if (!hasStreamEvents) {
                  streamer.append(block.text);
                }
              } else if (block.type === 'tool_use') {
                if (!hasStreamEvents) {
                  toolCount++;
                  const display = getToolDisplay(block.name || '');
                  streamer.updateStatus(display.desc);
                  log('info', `Tool: ${block.name}`, { threadId: thread.id });
                }
              }
            }
          }
        } else if (event.type === 'result') {
          log('debug', 'Result event received', {
            isError: event.is_error ?? false,
            hasResult: !!event.result,
            resultLen: event.result?.length ?? 0,
            hasAssistantText: lastAssistantText.length > 0,
            stopReason: event.stop_reason ?? 'unknown',
          });

          // Resume failure -> retry fresh (단, 이미 응답이 완료된 경우는 재시도 안 함)
          if (event.is_error && sid && !streamer.finalized) {
            log('warn', 'Resume failed, retrying fresh', { sessionId: sid });
            sessions.delete(sessionKey);
            retryNeeded = true;
            break;
          }

          // Fallback: use result text if nothing was streamed
          if (event.result && !streamer.hasRealContent) {
            log('info', 'Using event.result fallback', { resultLen: event.result.length });
            streamer.append(event.result);
          }

          const resultSessionId = event.session_id ?? null;
          if (resultSessionId) sessions.set(sessionKey, resultSessionId);

          // Auto-continue on max_turns
          if (event.stop_reason === 'max_turns' && resultSessionId && continuationCount < MAX_CONTINUATIONS) {
            continuationCount++;
            log('info', 'max_turns hit, auto-continuing', {
              threadId: thread.id, continuation: continuationCount, toolCount,
            });
            needsContinuation = true;
            break;
          }

          // Final max_turns (exhausted continuations)
          if (event.stop_reason === 'max_turns') {
            streamer.append('\n\n' + t('msg.truncated'));
            log('warn', 'Response truncated by max-turns (continuations exhausted)', { threadId: thread.id, toolCount });
          }

          await streamer.finalize();

          const cost = event.cost_usd ?? null;
          const usage = event.usage ?? null;

          await unreact(EMOJI.THINKING);
          await react(EMOJI.DONE);

          const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
          const rateStatus = rateTracker.check();

          // 토큰 포맷: 1234 → "1,234" / 12345 → "12.3k"
          const fmtToken = n => {
            if (n == null) return '-';
            return n >= 10000 ? `${(n / 1000).toFixed(1)}k` : n.toLocaleString();
          };

          // 세션 상태 레이블
          const sessionLabel = sid
            ? '🔗 재개됨'
            : resultSessionId ? '🆕 신규 저장' : '🆕 신규 (미저장)';

          // stop_reason 사람말로
          const stopLabel = event.stop_reason === 'end_turn' ? '✅ 완료'
            : event.stop_reason === 'max_turns'              ? '↩️ 연속 처리'
            : event.stop_reason === 'tool_use'               ? '🛠️ 도구 종료'
            : event.stop_reason ?? '-';

          // Compact one-line footer: Rate Limit % + 소요 시간 + 도구 횟수만 표시
          // (비용·세션ID·개별 토큰 수치 제거 — 본문보다 footer가 크던 문제 개선)
          const footerParts = [];
          footerParts.push(`${elapsed}s`);
          if (toolCount > 0) footerParts.push(`🛠${toolCount}`);
          footerParts.push(`📊${Math.round(rateStatus.pct * 100)}%`);

          // stop_reason은 비정상(max_turns/tool_use)일 때만 표시 — 정상 완료는 생략
          const stopPrefix = event.stop_reason !== 'end_turn' ? `${stopLabel} · ` : '';

          // 가족 채널에서는 stats 숨김
          const quietIds = (process.env.QUIET_CHANNEL_IDS || '').split(',').map(s => s.trim()).filter(Boolean);
          const isQuiet = quietIds.includes(effectiveChannelId) || quietIds.includes(thread.id);
          if (!isQuiet) {
            // embed 대신 main 메시지에 한 줄로 붙임 — 별도 카드 없애 화면 점유 최소화
            const statsLine = `-# ${stopPrefix}${footerParts.join(' · ')}`;
            const mainMsg = streamer.currentMessage;
            if (mainMsg && mainMsg.content && (mainMsg.content.length + statsLine.length + 1) <= 1990) {
              try {
                await mainMsg.edit({ content: mainMsg.content + '\n' + statsLine, components: [] });
              } catch {
                await thread.send(statsLine);
              }
            } else {
              await thread.send(statsLine);
            }
          }

          log('info', 'Claude completed', {
            threadId: thread.id, cost, toolCount, sessionId: resultSessionId,
            stopReason: event.stop_reason ?? 'unknown', elapsed: `${elapsed}s`,
          });

          if (lastAssistantText.length > 20) {
            const chName = isThread ? (message.channel.parent?.name ?? 'thread') : (message.channel.name ?? 'dm');
            saveConversationTurn(originalPrompt, lastAssistantText, chName, message.author.id);
            saveSessionSummary(sessionKey, originalPrompt, lastAssistantText);
            // 비동기 메모리 추출 — 메인 응답에 영향 없는 fire-and-forget
            autoExtractMemory(message.author.id, originalPrompt, lastAssistantText).catch((e) => log('debug', 'autoExtractMemory outer catch', { error: e?.message }));
          }
        }
      }

      clearTimeout(timeoutHandle);
      timeoutHandle = null;
      activeProcesses.delete(sessionKey);
      // active-session 파일 삭제는 finally 블록에서 통합 처리 (예외 경로 포함)

      // Loop ended without result event
      if (!streamer.finalized && !retryNeeded && !needsContinuation) {
        if (aborted) {
          streamer.append('\n\n' + t('msg.timeout'));
          _savePendingTask(sessionKey, originalPrompt);
        } else if (streamer.hasRealContent && toolCount > 0) {
          streamer.append('\n\n' + t('msg.truncated'));
        }
        await streamer.finalize();
      }

      return { retryNeeded, needsContinuation, lastAssistantText, toolCount };
    }

    // Pre-process: enrich userPrompt (Preply schedule/income data injection, RAG context)
    const preCtx = new ProcessorContext({
      originalPrompt,
      channelId: effectiveChannelId,
      threadId: thread.id,
      botHome: process.env.BOT_HOME || `${homedir()}/.jarvis`,
    });
    userPrompt = await _preProcessorRegistry.run(userPrompt, preCtx);

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
      streamer.fenceOpen = false;
      streamer.currentMessage = null;
      if (streamer._progressTimer) {
        clearInterval(streamer._progressTimer);
        streamer._progressTimer = null;
      }
      if (streamer._statusTimer) {
        clearTimeout(streamer._statusTimer);
        streamer._statusTimer = null;
      }
      streamer.replyTo = message;

      // Fallback: inject recent Discord history
      try {
        const recentMessages = await message.channel.messages.fetch({ limit: 20 });
        const botId = message.client.user.id;
        const historyLines = [];
        let totalLen = 0;
        const MAX_HISTORY_LEN = 6000;
        const BOT_MSG_LIMIT = 1500;

        const sorted = [...recentMessages.values()].reverse();
        for (const msg of sorted) {
          if (msg.id === message.id) continue;
          const isBot = msg.author.id === botId;
          let content = msg.content?.trim() || '';
          if (!content && msg.attachments.size > 0) {
            content = '[이미지]';
          }
          if (!content) continue;
          if (isBot && content.length > BOT_MSG_LIMIT) {
            content = content.slice(0, BOT_MSG_LIMIT) + '...';
          }
          const label = isBot ? 'Jarvis' : 'User';
          const line = `${label}: ${content}`;
          if (totalLen + line.length > MAX_HISTORY_LEN) break;
          historyLines.push(line);
          totalLen += line.length;
        }

        if (historyLines.length > 0) {
          const historyBlock = `## 이전 대화 (세션 복구 참고)\n${historyLines.join('\n')}\n\n`;
          userPrompt = historyBlock + originalPrompt;
          log('info', 'Injected Discord history fallback', {
            threadId: thread.id,
            messageCount: historyLines.length,
            historyLen: totalLen,
          });
        }
      } catch (histErr) {
        log('warn', 'Failed to fetch Discord history for fallback', {
          threadId: thread.id,
          error: histErr.message,
        });
      }

      // Session summary fallback
      const summary = loadSessionSummary(sessionKey);
      if (summary) {
        userPrompt = summary + userPrompt;
        log('info', 'Injected session summary fallback', { threadId: thread.id });
      }

      // RAG re-inject on retry: skip for Preply queries (data already pre-injected)
      if (!isPreplyQuery(originalPrompt)) {
        const ragContext = await searchRagForContext(originalPrompt).catch(() => null);
        if (ragContext) {
          const ragSnippet = ragContext.length > 600 ? ragContext.slice(0, 600) + '...' : ragContext;
          userPrompt = ragSnippet + '\n\n' + userPrompt;
          log('info', 'RAG re-injected on retry', { threadId: thread.id, ragLen: ragSnippet.length });
        }
      }

      runResult = await runClaude(null, streamer);
    }

    // Auto-continue: resume session to finish incomplete response
    while (runResult.needsContinuation) {
      const contSessionId = sessions.get(sessionKey);
      log('info', 'Auto-continuing session', { threadId: thread.id, sessionId: contSessionId });
      userPrompt = `이전 응답이 턴 제한으로 중단됐다. 지금까지 도구 ${runResult.toolCount ?? 0}회 사용. 남은 작업만 집중해서 완료해줘. 이미 한 작업은 반복하지 마.`;
      runResult = await runClaude(contSessionId, streamer);
    }

    // If nothing was produced, show generic error
    if (!streamer.hasRealContent && runResult.lastAssistantText === '') {
      await react(EMOJI.ERROR);
      const embed = new EmbedBuilder()
        .setColor(0xed4245)
        .setDescription(t('error.noResponse'))
        .setTimestamp();
      if (streamer.currentMessage) {
        try {
          await streamer.currentMessage.edit({ content: null, embeds: [embed], components: [] });
        } catch (editErr) {
          // 10008: Unknown Message — placeholder가 이미 없음 → 새 메시지로 fallback
          if (editErr.code === 10008) {
            log('warn', 'placeholder message gone (10008), sending new message', { messageId: streamer.currentMessage.id });
            await thread.send({ embeds: [embed] });
          } else {
            throw editErr;
          }
        }
      } else {
        await thread.send({ embeds: [embed] });
      }
      recordError(thread.id, message.author.id, 'no_response');
    }
  } catch (err) {
    log('error', 'handleMessage error', { error: err.message, stack: err.stack });

    // ▌ 커서 제거 — catch로 빠졌을 때 placeholder 메시지 정리
    if (streamer && !streamer.finalized) {
      try { await streamer.finalize(); } catch { /* best effort */ }
    }

    await react(EMOJI.ERROR);

    const target = thread || message.channel;

    // Transient error auto-retry
    const isTransient = /ETIMEDOUT|ECONNRESET|ENOTFOUND|SDK error|process exited/i.test(err.message || '');
    if (isTransient && !message._retried) {
      message._retried = true;
      retryHandled = true;
      log('info', 'Auto-retrying after transient error', { error: err.message });
      try {
        await target.send({ content: '\u23f3 일시적 오류 발생. 자동으로 재시도합니다...' });
        await semaphore.release();
        return handleMessage(message, { sessions, rateTracker, semaphore, activeProcesses, client });
      } catch (retryErr) {
        log('error', 'Auto-retry also failed', { error: retryErr.message });
        recordError(target.id, message.author.id, retryErr.message?.slice(0, 200));
      }
    }

    // Discord API 내부 오류 (메시지 삭제됨, 권한 없음 등) — 사용자에게 보여줄 필요 없음
    const isDiscordApiError = err.code != null && typeof err.code === 'number';
    if (isDiscordApiError) {
      log('warn', 'Discord API error (silent)', { code: err.code, message: err.message });
      return;
    }

    // Claude 처리 오류만 사용자에게 알림 — 디버깅용 세션ID 포함
    recordError(target.id, message.author.id, err.message?.slice(0, 200));
    sendNtfy(`${process.env.BOT_NAME || 'Claude Bot'} Error`, err.message, 'high');
    // 에러 시에만 세션ID 표시 (디버깅 필요)
    const errSessionId = sessionId || sessions.get(sessionKey) || null;
    const errFooter = errSessionId ? `-# 세션: \`${errSessionId.slice(0, 12)}…\`` : null;
    if (errFooter) {
      try { await target.send(errFooter); } catch { /* best effort */ }
    }
  } finally {
    processingMsgIds.delete(message.id);
    if (typingInterval) clearInterval(typingInterval);
    if (timeoutHandle) clearTimeout(timeoutHandle);
    if (!retryHandled) await semaphore.release();
    // retryHandled=true이면 재귀 호출이 이미 새 entry를 set했으므로 삭제 금지
    if (sessionKey && !retryHandled) activeProcesses.delete(sessionKey);
    // active-session 파일 정리 (runClaude 예외 포함 모든 종료 경로에서 보장)
    if (activeProcesses.size === 0) {
      try { rmSync(join(_BOT_HOME, 'state', 'active-session'), { force: true }); } catch { /* best effort */ }
    }

    // Process queued messages
    await processQueue(sessionKey, handleMessage, { sessions, rateTracker, semaphore, activeProcesses, client });

    // Keep workDir if session is alive
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
