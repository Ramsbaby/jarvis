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

import { BoundedMap } from './bounded-map.js';
// v3.3 P0-D: interview-fast-path 모듈 eager import로 RAG warmup IIFE를 봇 기동 시 트리거.
// dynamic import 시점(첫 질의)에 warmup하면 의미 없음 — 여기서 선행 실행.
import './interview-fast-path.js';
import { writeFileSync, rmSync, readFileSync, existsSync, renameSync, appendFileSync, mkdirSync } from 'node:fs';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createReadStream } from 'node:fs';
const execFileAsync = promisify(execFile);

// OpenAI STT — gpt-4o-transcribe (2026-04 업그레이드, whisper-1 대체)
// 한국어 정확도·레이턴시 모두 우위. prompt 파라미터로 면접 도메인 힌트 주입하여
// 기술 용어(Spring, JPA, 트랜잭션 등) 오인식 방지.
async function transcribeVoiceMessage(att) {
  try {
    const resp = await fetch(att.url);
    if (!resp.ok) throw new Error(`Download failed: HTTP ${resp.status}`);
    const buf = Buffer.from(await resp.arrayBuffer());
    const oggPath = join('/tmp', `voice-${att.id}.ogg`);
    const mp3Path = join('/tmp', `voice-${att.id}.mp3`);
    writeFileSync(oggPath, buf);
    await execFileAsync('ffmpeg', ['-y', '-i', oggPath, '-q:a', '4', mp3Path]);
    rmSync(oggPath, { force: true });
    const { default: OpenAI } = await import('openai');
    const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
    const transcription = await openai.audio.transcriptions.create({
      file: createReadStream(mp3Path),
      model: 'gpt-4o-transcribe',
      language: 'ko',
      prompt: '한국어 대화. 기술/면접 도메인 용어: Spring Boot, WebFlux, JPA, QueryDSL, Kafka, Redis, AWS, gRPC, 트랜잭션, 데드락, 인덱스, 락, 커넥션 풀, 마이크로서비스, Kubernetes, 아키텍처, 트레이드오프, STAR, KPI, OKR, 이력서, 포트폴리오.',
    });
    rmSync(mp3Path, { force: true });
    return transcription.text?.trim() || null;
  } catch (err) {
    log('warn', 'Voice transcription failed', { id: att.id, error: err.message });
    return null;
  }
}
import discordPkg from 'discord.js';
const { EmbedBuilder } = discordPkg;
import { log, sendNtfy, sanitizeUnicode } from './claude-runner.js';
import { StreamingMessage, lastQueryStore } from './streaming.js';
import {
  createClaudeSession,
  saveConversationTurn,
  processFeedback,
  autoExtractMemory,
  reloadUserProfiles,
  getUserProfile,
  triggerDiscordMistakeExtract,
} from './claude-runner.js';
import { detectAnger, recordAngerSignal } from './anger-detector.mjs';
import { appendFeed } from './channel-feed.js';
import { generateCode, verifyCode } from './pairing.js';
import { userMemory } from '../../lib/user-memory.mjs';
import { t } from './i18n.js';
import { recordError } from './error-tracker.js';

// Extracted modules
import { PAST_REF_PATTERN, searchRagForContext } from './rag-helper.js';
import { INTERVIEW_CHANNEL_ID } from './slash-proxy.js';
import { saveSessionSummary, loadSessionSummary, loadSessionSummaryRecent, saveCompactionSummary, compactSessionWithAI } from './session-summary.js';
// classifyBudget 미사용 — 전역 opusplan 모드 (claude-runner.js에서 항상 Opus+thinking:adaptive)
import { pendingQueue, enqueue, processQueue } from './queue-processor.js';
import { MessageDebouncer } from './message-debouncer.js';
import { ProcessorContext, createPreProcessorRegistry } from './pre-processor.js';
import { isTutoringQuery } from './prompt-sections.js';
// langfuse 제거 (2026-04-17): Mac Mini 리소스 제약으로 로컬 JSONL 원장으로 교체.
// 측정 파일: response-ledger.jsonl / feedback-score.jsonl / reask-tracker.jsonl
//          / permission-denied.jsonl
// (tool-guard-trips.jsonl은 2026-04-17 가드 제거 후 더 이상 append 안 됨)
import { detectAndRecord as _trackCommitment } from './commitment-tracker.js';
import { detectStatType, sendStatVisual } from './stat-visual.js';
import { detectAnalyticalType, generateAndSendVisual } from './visual-gen.js';

// ---------------------------------------------------------------------------
// Message debouncer — 연속 메시지를 1.5s 대기 후 배치로 묶어 단일 Claude 호출
// (Best practice: production AI bot standard)
// ---------------------------------------------------------------------------
const _msgDebouncer = new MessageDebouncer();
/** cancel token restart 시 restartPrompt를 debounce 경유 후에도 보존 (messageId → prompt) */
const _promptOverrides = new BoundedMap(500, 10 * 60_000); // 500 items, 10min TTL

// Phase 0 Sensor: 유저별 직전 trace/prompt 캐시 — 피드백 도착 시 해당 trace에 score 부여
const _lastTraceByUser = new BoundedMap(1000, 24 * 60 * 60_000); // 1000 items, 24h TTL
const _lastPromptByUser = new BoundedMap(1000, 24 * 60 * 60_000);

// (2026-04-17 제거) MAX_TOOL_CALLS_PER_TURN 강제 가드 삭제 — SDK maxTurns + 타임아웃 + maxBudget으로 충분.
// toolCount 관측은 response-ledger.jsonl에 그대로 저장.

// Pre-processor registry (RAG context enrichment)
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

const _BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const PENDING_TASKS_PATH = join(_BOT_HOME, 'state', 'pending-tasks.json');
const _MODELS = JSON.parse(readFileSync(join(_BOT_HOME, 'config', 'models.json'), 'utf-8'));
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

function _savePendingTask(sessionKey, prompt, checkpoints = []) {
  try {
    let tasks = {};
    if (existsSync(PENDING_TASKS_PATH)) {
      tasks = JSON.parse(readFileSync(PENDING_TASKS_PATH, 'utf-8'));
    }
    _pruneExpiredPendingTasks(tasks); // 저장 시 만료 항목 일괄 정리
    tasks[sessionKey] = { prompt, savedAt: Date.now(), checkpoints };
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
    // 전체 task 객체 반환 (하위 호환: prompt 필드 보장)
    return { prompt: task.prompt, checkpoints: task.checkpoints ?? [] };
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
// Session end detection helpers (Phase 1)
// ---------------------------------------------------------------------------

/** 명시적 세션 종료 신호 패턴 */
const SESSION_END_PATTERN = /^(끝|마무리|여기까지|\/done)$/i;

/** 비활동 타임아웃: 30분 초과 시 이전 세션 자동 요약 트리거 */
const SESSION_IDLE_TIMEOUT_MS = 30 * 60 * 1000;

/**
 * 세션 마지막 활동 시각 기준 30분 경과 여부 확인.
 * sessions.data[sessionKey].updatedAt 필드 활용.
 */
function _isSessionIdle(sessions, sessionKey) {
  const entry = sessions.data?.[sessionKey];
  if (!entry?.updatedAt) return false;
  return Date.now() - entry.updatedAt > SESSION_IDLE_TIMEOUT_MS;
}

/**
 * 명시적 종료 신호 또는 비활동 타임아웃 감지 시 백그라운드 요약 트리거.
 * 메인 흐름을 차단하지 않음 (fire-and-forget).
 */
import { saveHandoff } from './session-handoff.js';
import { recordSilentError } from './error-ledger.js';

function _triggerSessionEndSummary(sessionKey, reason) {
  compactSessionWithAI(sessionKey).catch((e) =>
    log('debug', `_triggerSessionEndSummary: compaction failed (${reason})`, { sessionKey, error: e?.message }),
  );
  // Handoff 저장: 다음 세션이 구조화된 상태를 받을 수 있도록
  try {
    const summaryPath = join(_BOT_HOME, 'state', 'session-summaries', `${sessionKey}.md`);
    if (existsSync(summaryPath)) {
      const raw = readFileSync(summaryPath, 'utf-8');
      let lastTopic = '';
      // 1차: 원본 형식 "[YYYY-MM-DD HH:MM] User: 텍스트"
      const userTurns = raw.match(/\[\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\]\s+User:\s*(.+)/g) || [];
      if (userTurns.length) {
        lastTopic = userTurns[userTurns.length - 1].replace(/\[\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\]\s+User:\s*/, '').slice(0, 100);
      } else {
        // 2차: compaction 형식 — "### 마지막 진행 주제" 또는 "### 사용자 의도" 섹션
        const topicMatch = raw.match(/###\s*(?:마지막 진행 주제|사용자 의도)\s*\n([\s\S]*?)(?=\n###|\n---|\Z)/);
        if (topicMatch) lastTopic = topicMatch[1].trim().split('\n')[0].slice(0, 100);
      }
      // 3차: compaction에서 "### 미완 작업" 추출
      const pendingMatch = raw.match(/###\s*미완\s*작업\s*\n([\s\S]*?)(?=\n###|\n---|\Z)/);
      const pendingTasks = pendingMatch
        ? pendingMatch[1].trim().split('\n').filter(l => l.startsWith('-')).map(l => l.replace(/^-\s*/, '').slice(0, 80)).slice(0, 5)
        : [];
      saveHandoff(sessionKey, { lastTopic, keyDecisions: [], pendingTasks });
    }
  } catch (err) { recordSilentError('handlers.saveHandoff', err); }
  log('info', `Session end summary triggered (${reason})`, { sessionKey });
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const INPUT_MAX_CHARS = 4000;
const TYPING_INTERVAL_MS = 8000;

// 텍스트/문서 첨부 확장자 (handleMessage + _processBatch 공용)
const TEXT_DOC_EXTS = /\.(txt|md|html|htm|css|js|mjs|ts|java|py|json|xml|csv|yaml|yml|sh|bash|sql|log|properties|env|conf|toml|ini|kt|go|rs|cpp|c|h|rb|php|swift|gradle|pdf)$/i;


// Dedup: prevent same message from being processed twice (shard resume / race condition)
const processingMsgIds = new Set();

// Session compaction: Progressive Compaction (업계 권고 — Anthropic, OpenAI)
// 단일 80K 한방 대신 3단계: 40K(Tier 1 제거) → 60K(요약 축소) → 80K(전면 리셋)
const COMPACT_LEVELS = [
  { threshold: 40_000, action: 'lean' },           // Tier 1 섹션 미로드 (format-detail 등)
  { threshold: 60_000, action: 'compress_history' }, // 대화 요약 축소
  { threshold: 80_000, action: 'full_compact' },     // 전면 compaction + 세션 리셋
];
const COMPACT_THRESHOLD_TOKENS = 80_000; // 하위 호환
const sessionTokenCounts = new BoundedMap(1000, 60 * 60_000); // 1000 items, 60min TTL
// 재시작 시 in-memory 카운트는 sessions.getTokenCount()으로 복구


/**
 * compact 후 이전 JSONL 삭제 — 다음 resume 시 메모리 재폭증 방지.
 * JSONL 위치: ~/.claude/projects/-private-tmp-claude-discord-<threadId>/<sessionId>.jsonl
 */
function _deleteSessionJsonl(sessionId, threadId) {
  if (!sessionId || !threadId) return;
  try {
    const claudeDir = join(homedir(), '.claude', 'projects');
    // threadId를 경로로 인코딩: /private/tmp/claude-discord/<threadId> → -private-tmp-claude-discord-<threadId>
    const projectSlug = `/private/tmp/claude-discord/${threadId}`.replace(/\//g, '-');
    const jsonlPath = join(claudeDir, projectSlug, `${sessionId}.jsonl`);
    if (existsSync(jsonlPath)) {
      rmSync(jsonlPath);
      log('info', '_deleteSessionJsonl: deleted', { sessionId, threadId, path: jsonlPath });
    }
  } catch (err) {
    log('debug', '_deleteSessionJsonl: failed (non-critical)', { error: err.message });
  }
}


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
  if (/시장|주가|투자|stock|나스닥|soxl|nvda|환율|코인|매수|매도|차트/.test(lower)) return EMOJI.MARKET;
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
  if (/시장|주가|투자|stock|나스닥|soxl|nvda|환율|코인|매수|매도|차트/.test(lower)) return t('stream.thinking.market');
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

  // 봇 필터 + slash-proxy 예외:
  // 슬래시 커맨드 경로로 봇 자신이 프록시 발송한 메시지만 통과시키고,
  // 이 경우 message.author 를 원래 사용자의 User 객체로 교체해
  // 하류 로직(userId·displayName·memory 등 28개 참조)이 자연스럽게 원 사용자로 동작.
  if (message.author.bot) {
    try {
      const { consumeSlashProxy } = await import('./slash-proxy.js');
      const isSelf = message.author.id === message.client.user.id;
      if (!isSelf) return;
      const proxy = consumeSlashProxy(message.channel.id, message.content);
      if (!proxy) return;
      const origUser =
        message.client.users.cache.get(proxy.userId) ??
        (await message.client.users.fetch(proxy.userId).catch(() => null));
      if (!origUser) return;
      // Discord.js v14: message.author 는 getter 라 직접 할당 불가.
      // 대신 _proxyAuthor 저장 + getEffectiveAuthor() 헬퍼로 다운스트림이 조회.
      message._proxyAuthor = origUser;
      message._viaSlashProxy = true;
    } catch {
      return;
    }
  }

  // 프록시 우회 시 진짜 author 를 얻는 헬퍼 (message 객체에 주입해 어디서든 사용).
  // Discord.js v14 getter 특성상 message.author = X 가 먹히지 않아 이 패턴 필수.
  const effectiveAuthor = message._proxyAuthor ?? message.author;

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
  // 텍스트/문서 첨부 감지 (txt, md, html, java, py, json, pdf 등)
  const hasDocAtt = message.attachments.size > 0 &&
    Array.from(message.attachments.values()).some((a) => {
      const isPdf  = a.contentType === 'application/pdf' || /\.pdf$/i.test(a.name ?? '');
      const isText = TEXT_DOC_EXTS.test(a.name ?? '') || a.contentType?.startsWith('text/');
      return isPdf || isText;
    });
  const hasZipAtt = message.attachments.size > 0 &&
    Array.from(message.attachments.values()).some((a) =>
      a.contentType === 'application/zip' ||
      a.contentType === 'application/x-zip-compressed' ||
      a.contentType === 'application/octet-stream' && /\.zip$/i.test(a.name ?? '') ||
      /\.zip$/i.test(a.name ?? ''),
    );
  if (!message.content && !hasImages && !hasVoice && !hasDocAtt && !hasZipAtt) { processingMsgIds.delete(message.id); return; }
  if (message.content.length > INPUT_MAX_CHARS) {
    await message.reply(t('msg.tooLong', { length: message.content.length, max: INPUT_MAX_CHARS }));
    processingMsgIds.delete(message.id);
    return;
  }

  // ── 프롬프트 인젝션 감지 (로깅 전용, 차단 아님) ─────────────────────────
  // [2026-03-31] Discord → ask-claude 경로 취약점 모니터링
  // Claude 자체 안전장치가 1차 방어, 여기서는 패턴 감지 + 경고 로그만 기록
  if (message.content) {
    const injectionPatterns = [
      /ignore\s+(all\s+)?previous\s+instructions?/i,
      /disregard\s+(your\s+)?(system\s+)?prompt/i,
      /\[SYSTEM\]|\[\/SYSTEM\]/i,
      /you\s+are\s+now\s+(a\s+)?jailbroken/i,
      /새로운\s*지시사항|이전\s*지시\s*무시|시스템\s*프롬프트\s*무시/,
      /<\/?system>|<\/?instruction>/i,
    ];
    const detected = injectionPatterns.some(p => p.test(message.content));
    if (detected) {
      log('warn', 'Potential prompt injection detected', {
        userId: effectiveAuthor.id,
        channelId: message.channelId,
        contentLen: message.content.length,
        preview: message.content.slice(0, 80),
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Pairing — 미등록 사용자 접근 제어 + Owner !pair <code> 승인
  // ---------------------------------------------------------------------------
  const senderProfile = getUserProfile(effectiveAuthor.id);
  try {
    appendFileSync('/tmp/jarvis-guard-debug.log',
      `  → senderProfile check | author.id=${effectiveAuthor?.id} | profile=${senderProfile ? JSON.stringify({role:senderProfile.role, name:senderProfile.name}) : 'null'}\n`
    );
  } catch {}
  const senderIsOwner = senderProfile?.type === 'owner' || senderProfile?.role === 'owner';

  // ── last-activity 업데이트 (오너 채널 한정) ───────────────────────────────
  // 매 메시지마다 runtime/state/last-activity.json 갱신 → buildOwnerTimeContext 참조
  const _OWNER_CHANNEL_IDS = (process.env.OWNER_CHANNEL_IDS || '').split(',').filter(Boolean);
  if (senderIsOwner && _OWNER_CHANNEL_IDS.includes(message.channel.id)) {
    try {
      const _stateDir = join(_BOT_HOME, 'state');
      mkdirSync(_stateDir, { recursive: true });
      const _kstOffset = 9 * 3600_000;
      const _kstIso = new Date(Date.now() + _kstOffset).toISOString().replace('Z', '+09:00');
      writeFileSync(
        join(_stateDir, 'last-activity.json'),
        JSON.stringify({ timestamp: _kstIso, channel_id: message.channel.id, user_id: effectiveAuthor.id }, null, 2),
      );
    } catch { /* best-effort */ }
  }

  // ── 오너 스케줄 최초 1회 질문 (owner-schedule.json 없을 때) ─────────────
  if (senderIsOwner && _OWNER_CHANNEL_IDS.includes(message.channel.id) && message.content) {
    const _schedPath = join(_BOT_HOME, 'state', 'owner-schedule.json');
    const _askedPath = join(_BOT_HOME, 'state', 'owner-schedule-asked.json');
    // owner-schedule.json이 없고, asked 플래그도 없으면 → 질문 후 return
    if (!existsSync(_schedPath) && !existsSync(_askedPath)) {
      try {
        mkdirSync(join(_BOT_HOME, 'state'), { recursive: true });
        writeFileSync(_askedPath, JSON.stringify({ asked_at: new Date().toISOString() }, null, 2));
        await message.reply(
          `${senderProfile?.name || effectiveAuthor?.displayName || '주인님'}, 앞으로 더 자연스럽게 대화하기 위해 보통 몇 시에 기상하시고 몇 시에 취침하시는지 알려주시면 기억해두겠습니다. (예: 기상 7시, 취침 1시)`,
        );
        processingMsgIds.delete(message.id);
        return;
      } catch { /* 실패해도 진행 */ }
    }
    // owner-schedule-asked.json 있고 owner-schedule.json 없으면 → 답변 파싱 시도
    if (!existsSync(_schedPath) && existsSync(_askedPath)) {
      const _wakeMatch = message.content.match(/기상\s*[:：]?\s*(\d{1,2})(?::(\d{2}))?시?/);
      const _sleepMatch = message.content.match(/취침\s*[:：]?\s*(\d{1,2})(?::(\d{2}))?시?/);
      if (_wakeMatch || _sleepMatch) {
        try {
          const _fmtHour = (h, m) => `${String(h).padStart(2, '0')}:${String(m || 0).padStart(2, '0')}`;
          const _wakeTime = _wakeMatch ? _fmtHour(parseInt(_wakeMatch[1], 10), parseInt(_wakeMatch[2] || '0', 10)) : null;
          const _sleepTime = _sleepMatch ? _fmtHour(parseInt(_sleepMatch[1], 10), parseInt(_sleepMatch[2] || '0', 10)) : null;
          const _schedule = {
            wake_time: _wakeTime,
            sleep_time: _sleepTime,
            asked_at: (() => { try { return JSON.parse(readFileSync(_askedPath, 'utf-8')).asked_at; } catch { return new Date().toISOString(); } })(),
            confirmed: true,
          };
          writeFileSync(_schedPath, JSON.stringify(_schedule, null, 2));
          const _parts = [];
          if (_wakeTime) _parts.push(`기상 ${_wakeTime}`);
          if (_sleepTime) _parts.push(`취침 ${_sleepTime}`);
          await message.reply(`✅ 기억했습니다. ${_parts.join(', ')}으로 저장해뒀어요.`);
          processingMsgIds.delete(message.id);
          return;
        } catch { /* 파싱 실패 시 일반 처리로 fall-through */ }
      }
    }
  }

  // ── 스킬 자동 트리거 감지 (2026-04-24, Phase 1) ──────────────────────────
  // CLI UserPromptSubmit hook 방식을 Discord 표면에 이식. Jarvis 단일 뇌 완결.
  // Owner 채널 + 자연어 키워드 매칭 시 즉시 runSkill → 응답 → return.
  // Phase 3에서 /autoplan·/crisis·/deploy 에 버튼 결재 UX 추가 예정.
  if (senderIsOwner && message.content) {
    try {
      const { detectSkillTrigger } = await import('./skill-trigger.js');
      const trigger = detectSkillTrigger(message.content);
      if (trigger) {
        log('info', 'Skill trigger detected', {
          userId: effectiveAuthor.id,
          skill: trigger.skill,
          confidence: trigger.confidence,
          via: trigger.via,
        });
        const { runSkill } = await import('./skill-runner.js');
        const skillStartTs = Date.now();
        // 초기 placeholder (SDK query 30~60초 소요 — typing만으론 부족).
        const placeholder = await message.reply(
          `🔍 **\`/${trigger.skill}\`** 분석 중입니다... (0s)`
        ).catch(() => null);
        // typing indicator + placeholder 경과 시간 동시 갱신.
        // Discord rate limit: same message edit은 3초 간격이 안전.
        let typingInterval = setInterval(() => {
          message.channel.sendTyping().catch(() => {});
        }, 8000);
        let elapsedInterval = null;
        if (placeholder) {
          elapsedInterval = setInterval(() => {
            const elapsed = Math.floor((Date.now() - skillStartTs) / 1000);
            placeholder.edit({
              content: `🔍 **\`/${trigger.skill}\`** 분석 중입니다... (${elapsed}s)`,
            }).catch(() => {});
          }, 10000);
        }
        message.channel.sendTyping().catch(() => {});
        let result;
        try {
          result = await runSkill(trigger.skill, message.content, {
            context: { channelId: message.channelId, userId: effectiveAuthor.id },
          });
        } finally {
          clearInterval(typingInterval);
          if (elapsedInterval) clearInterval(elapsedInterval);
        }
        const skillDurMs = Date.now() - skillStartTs;
        log('info', 'Skill trigger completed', {
          skill: trigger.skill,
          durationMs: skillDurMs,
          userId: effectiveAuthor.id,
          textLength: result.text?.length ?? 0,
          error: result.error ?? null,
          via: result.via ?? 'api',
        });
        const header = `🎯 **스킬 \`/${trigger.skill}\`** (${trigger.via}, conf=${trigger.confidence})\n\n`;
        const bodyBudget = 2000 - header.length - 20;
        const reply = result.text.length > bodyBudget
          ? result.text.slice(0, bodyBudget) + '\n\n…(잘림)'
          : result.text;
        // placeholder 있으면 edit, 없으면 새 reply
        if (placeholder) {
          await placeholder.edit({ content: header + reply }).catch(async () => {
            await message.reply({ content: header + reply });
          });
        } else {
          await message.reply({ content: header + reply });
        }
        processingMsgIds.delete(message.id);
        return;
      }
    } catch (e) {
      log('error', 'Skill trigger handler failed', {
        error: e.message,
        stack: e.stack?.slice(0, 300),
      });
      // fall-through: 기존 Claude 경로 진행 (트리거 실패가 전체 봇 차단 유발 방지)
    }
  }

  // !pair <code> — Owner 전용 커맨드 (debounce 우회, 즉시 처리)
  const pairMatch = message.content.match(/^!pair\s+([A-Z2-9]{6})\s*$/i);
  if (pairMatch) {
    if (!senderIsOwner) {
      await message.reply('❌ Owner 전용 커맨드입니다.');
      processingMsgIds.delete(message.id);
      return;
    }
    const code = pairMatch[1].toUpperCase();
    const entry = verifyCode(code);
    if (!entry) {
      await message.reply(`❌ 코드 \`${code}\` — 유효하지 않거나 만료됐습니다. (TTL 10분)`);
      processingMsgIds.delete(message.id);
      return;
    }
    // user_profiles.json에 동적 등록
    try {
      const profilesPath = join(_BOT_HOME, 'config', 'user_profiles.json');
      const profiles = JSON.parse(readFileSync(profilesPath, 'utf-8'));
      // key: discord_{id} 형식으로 저장
      const profileKey = `discord_${entry.discordId}`;
      profiles[profileKey] = {
        name: entry.username,
        title: '게스트',
        type: 'guest',
        role: 'guest',
        discordId: entry.discordId,
        pairedAt: new Date().toISOString(),
        pairedBy: effectiveAuthor.id,
      };
      writeFileSync(profilesPath, JSON.stringify(profiles, null, 2));
      reloadUserProfiles();
      await message.reply(`✅ **${entry.username}** (${entry.discordId}) 등록 완료.\n- 프로필 키: \`${profileKey}\`\n- role: guest (변경하려면 user_profiles.json 직접 수정)`);
      log('info', '[pairing] 신규 사용자 등록', { profileKey, discordId: entry.discordId, username: entry.username });
    } catch (err) {
      await message.reply(`❌ user_profiles.json 업데이트 실패: ${err.message}`);
      log('error', '[pairing] 등록 실패', { error: err.message });
    }
    processingMsgIds.delete(message.id);
    return;
  }

  // 미등록 사용자(guest) 차단 — 페어링 코드 발급
  if (!senderProfile) {
    const code = generateCode(effectiveAuthor.id, effectiveAuthor.displayName || effectiveAuthor.username);
    await message.reply(
      `🔒 **미등록 사용자입니다.**\n\n` +
      `접근을 요청하려면 Owner에게 아래 코드를 전달하세요.\n\n` +
      `**페어링 코드: \`${code}\`**\n\n` +
      `_(유효시간 10분. Owner가 \`!pair ${code}\` 를 입력하면 등록됩니다.)_`,
    );
    // Owner 채널로도 알림 (OWNER_ALERT_CHANNEL_ID 있으면)
    const alertChannelId = process.env.OWNER_ALERT_CHANNEL_ID;
    if (alertChannelId) {
      try {
        const alertCh = state.client.channels.cache.get(alertChannelId)
          || await state.client.channels.fetch(alertChannelId).catch(() => null);
        if (alertCh) {
          await alertCh.send(
            `🔔 **[페어링 요청]** 미등록 사용자가 접근을 시도했습니다.\n` +
            `- 사용자: **${effectiveAuthor.displayName || effectiveAuthor.username}** (\`${effectiveAuthor.id}\`)\n` +
            `- 채널: <#${message.channel.id}>\n` +
            `- 코드: \`${code}\`\n\n` +
            `승인하려면: \`!pair ${code}\``,
          );
        }
      } catch (alertErr) {
        log('warn', '[pairing] owner alert 전송 실패', { error: alertErr.message });
      }
    }
    log('info', '[pairing] 미등록 사용자 차단 + 코드 발급', { userId: effectiveAuthor.id, username: effectiveAuthor.username, code });
    processingMsgIds.delete(message.id);
    return;
  }

  // Text-based /remember or 기억해: — debounce 없이 즉시 처리
  const rememberMatch = message.content.match(/^\/remember\s+(.+)/s) || message.content.match(/^기억해:\s*(.+)/s);
  if (rememberMatch) {
    const fact = rememberMatch[1].trim();
    if (fact) {
      userMemory.addFact(
        effectiveAuthor.id,
        fact,
        'discord-remember-cmd',
        'medium',
        effectiveAuthor.displayName || effectiveAuthor.username || '',
      );
      await message.reply(t('msg.remembered'));
      log('info', 'User memory saved via text command', { userId: effectiveAuthor.id, fact: fact.slice(0, 100) });
    }
    processingMsgIds.delete(message.id);
    return;
  }

  // 이미지/문서 첨부 → debounce 없이 즉시 처리 (CDN URL 만료 위험)
  // 슬래시 명령 → 즉시 처리
  const isBypassDebounce = hasImages || hasDocAtt || message.content.startsWith('/');
  const debounceKey = isThread ? message.channel.id : `${message.channel.id}-${effectiveAuthor.id}`;

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
  // handleMessage 에서 slash-proxy 로 주입한 실제 작성자. 없으면 원본 author 사용.
  // Discord.js v14 의 author 가 getter 라 직접 교체 불가이므로 이 패턴 필수.
  const effectiveAuthor = message._proxyAuthor ?? message.author;
  // 음성 메시지 판별 (_processBatch는 handleMessage 스코프 밖이므로 여기서 재계산)
  const voiceAtt = message.attachments?.size > 0
    ? Array.from(message.attachments.values()).find((a) =>
        a.contentType?.startsWith('audio/') || /\.(ogg|mp3|m4a|wav)$/i.test(a.name ?? ''),
      )
    : null;
  const hasVoice = !!voiceAtt;
  let batchContent = _buildBatchContent(messages); // Claude에 보낼 결합 프롬프트

  // Reply context: 답글 대상 메시지 내용을 컨텍스트로 주입
  const refMsg = message.reference?.messageId
    ? await message.channel.messages.fetch(message.reference.messageId).catch(() => null)
    : null;
  if (refMsg) {
    const refContent = refMsg.content?.slice(0, 800) || '';
    if (refContent) {
      batchContent = `[답글 대상 메시지]\n${refContent}\n\n[사용자 답글]\n${batchContent}`;
    }
  }

  // cancel token restart: processQueue → handleMessage → debouncer → 여기서 override 적용
  const _overrideKey = messages[messages.length - 1].id;
  const _override = _promptOverrides.get(_overrideKey);
  if (_override) { _promptOverrides.delete(_overrideKey); batchContent = _override; }

  // Lone surrogate 살균 — Anthropic API 400 "invalid high surrogate" 방지
  batchContent = sanitizeUnicode(batchContent);

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
    const queueKey = isThread ? message.channel.id : `${message.channel.id}-${effectiveAuthor.id}`;

    // Cancel Token: 동일 사용자 응답 생성 중 → 중단 후 통합 재시작
    // (Claude SDK: 동일 session_id 동시 호출 공식 미지원 — 직렬화 필수)
    const activeEntry = activeProcesses.get(queueKey);
    if (activeEntry) {
      const partialText = activeEntry.streamer?.buffer?.slice(0, 600) ?? '';
      const prevPrompt = activeEntry.originalPrompt ?? '';

      // 기존 스트림 중단 (재시작용 취소 — 타임아웃 메시지 출력 안 함)
      activeEntry.proc.kill('restart');
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
  const feedback = processFeedback(effectiveAuthor.id, userPrompt);
  if (feedback) {
    log('info', 'Feedback detected', { userId: effectiveAuthor.id, type: feedback.type });

    // Phase 0 Sensor: positive/negative/correction → feedback-score.jsonl 로컬 원장
    // (Langfuse 의존 제거 — Mac Mini 리소스 절약, JSONL로 1주 집계 충분)
    const prevTraceId = _lastTraceByUser.get(effectiveAuthor.id);
    const scoreMap = { positive: 1.0, negative: 0.0, correction: 0.3 };
    if (prevTraceId && scoreMap[feedback.type] !== undefined) {
      try {
        const ledgerDir = join(_BOT_HOME, 'state');
        mkdirSync(ledgerDir, { recursive: true });
        appendFileSync(
          join(ledgerDir, 'feedback-score.jsonl'),
          JSON.stringify({
            ts: new Date().toISOString(),
            source: 'discord-bot',
            traceId: prevTraceId,
            userId: effectiveAuthor.id,
            channelId: message.channel?.id ?? null,
            feedbackType: feedback.type,
            score: scoreMap[feedback.type],
            comment: String(userPrompt).slice(0, 200),
          }) + '\n'
        );
      } catch (e) {
        log('debug', 'feedback-score append failed (non-blocking)', { error: e?.message });
      }
    }

    // Phase 0 Sensor: negative/correction → reask-tracker.jsonl 적재
    if (feedback.type === 'negative' || feedback.type === 'correction') {
      try {
        const ledgerDir = join(_BOT_HOME, 'state');
        mkdirSync(ledgerDir, { recursive: true });
        appendFileSync(
          join(ledgerDir, 'reask-tracker.jsonl'),
          JSON.stringify({
            ts: new Date().toISOString(),
            source: 'discord-bot',
            userId: effectiveAuthor.id,
            channelId: message.channel?.id ?? null,
            feedbackType: feedback.type,
            feedbackText: String(userPrompt).slice(0, 240),
            prevPrompt: String(_lastPromptByUser.get(effectiveAuthor.id) ?? '').slice(0, 240),
            lastTraceId: prevTraceId ?? null,
          }) + '\n'
        );
      } catch (e) {
        log('debug', 'reask-tracker append failed (non-blocking)', { error: e?.message });
      }
    }
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
    sessionKey = isThread ? thread.id : `${thread.id}-${effectiveAuthor.id}`;
    sessionId = sessions.get(sessionKey);

    // ── Phase 1: 세션 종료 감지 ───────────────────────────────────────────
    // 1a. 명시적 종료 신호: "끝", "마무리", "여기까지", "/done"
    if (SESSION_END_PATTERN.test(userPrompt.trim())) {
      _triggerSessionEndSummary(sessionKey, 'explicit_end');
      await message.reply('세션을 마무리했어요. 대화 내용을 요약 저장합니다. 👋');
      processingMsgIds.delete(message.id);
      return;
    }

    // 1b. 비활동 타임아웃: 새 메시지 수신 시 이전 세션 마지막 활동 30분+ 경과 확인
    if (sessionId && _isSessionIdle(sessions, sessionKey)) {
      log('info', 'Session idle >30min — triggering background summary before new turn', { sessionKey });
      _triggerSessionEndSummary(sessionKey, 'idle_timeout');
      // 세션은 유지 (요약만 백그라운드 트리거, 대화는 계속)
    }

    // /compact 명령어: 수동 세션 컴팩트
    if (userPrompt.trim().toLowerCase() === '/compact') {
      const turns = sessionTokenCounts.get(sessionKey) ?? 0;
      const oldSessionId = sessions.get(sessionKey);
      // AI 시맨틱 compact 백그라운드 실행
      compactSessionWithAI(sessionKey).catch(e =>
        log('debug', 'compactSessionWithAI manual bg failed', { error: e?.message })
      );
      // JSONL 삭제
      if (oldSessionId) _deleteSessionJsonl(oldSessionId, thread?.id ?? message.channel?.id);
      sessions.delete(sessionKey);
      sessionTokenCounts.delete(sessionKey);
      log('info', 'Manual compact triggered', { sessionKey, turns });
      await message.reply(`🗜️ 세션 컴팩트 완료. (${turns}턴 → 리셋)\n다음 메시지부터 이전 대화 요약으로 재시작합니다.`);
      processingMsgIds.delete(message.id);
      return;
    }

    // Progressive Compaction: 3단계 (업계 권고 — Anthropic, OpenAI, LangChain)
    // 40K: Tier 1 섹션 미로드 (budgetMode=lean)
    // 60K: 대화 요약 축소 (compaction + 계속 유지)
    // 80K: 전면 세션 리셋
    let _budgetMode = 'normal';
    if (sessionId) {
      const tokens = sessionTokenCounts.get(sessionKey) ?? sessions.getTokenCount(sessionKey);
      if (Number.isFinite(tokens)) {
        if (tokens >= COMPACT_LEVELS[2].threshold) {
          // 80K: 전면 compaction + 세션 리셋
          const reason = `토큰 ${tokens.toLocaleString()} >= ${COMPACT_LEVELS[2].threshold.toLocaleString()} (full compact)`;
          log('info', 'Progressive compact L3: full reset', { reason, sessionKey, tokens });
          _deleteSessionJsonl(sessionId, thread.id);
          compactSessionWithAI(sessionKey).catch(
            (e) => log('warn', 'Auto-compact AI summary failed', { error: e.message }),
          );
          sessions.delete(sessionKey);
          sessionId = null;
          sessionTokenCounts.delete(sessionKey);
        } else if (tokens >= COMPACT_LEVELS[1].threshold) {
          // 60K: 축소 요약 + 세션 유지
          log('info', 'Progressive compact L2: compress history', { sessionKey, tokens });
          compactSessionWithAI(sessionKey).catch(
            (e) => log('warn', 'L2 compact failed', { error: e.message }),
          );
          _budgetMode = 'lean';
        } else if (tokens >= COMPACT_LEVELS[0].threshold) {
          // 40K: Tier 1 미로드만
          log('info', 'Progressive compact L1: lean mode', { sessionKey, tokens });
          _budgetMode = 'lean';
        }
      }
    }

    // "계속" 감지: 타임아웃으로 중단된 작업 재개
    const CONTINUE_PATTERN = /^(계속|continue|이어서|이어서\s*해줘?|계속\s*해줘?|continue from where you left off)$/i;
    let _continueHandled = false; // 세션 요약 중복 주입 방지 플래그
    if (CONTINUE_PATTERN.test(userPrompt.trim())) {
      const pending = _loadPendingTask(sessionKey);
      // "계속" 시 직전 주제만 주입 (전체 요약 대신) — 다중 주제 혼동 방지
      const recentSummary = loadSessionSummaryRecent(sessionKey);
      const summary = recentSummary || loadSessionSummary(sessionKey); // recent 실패 시 전체 fallback

      if (pending || summary) {
        // 컨텍스트 블록 조립: 세션 요약 + pending task 순서로 주입
        const contextParts = [];
        if (summary) {
          contextParts.push(summary.trimEnd());
          log('info', 'Session summary injected for 계속 resume', { threadId: thread.id });
        }
        if (pending) {
          const checkpointLines = (pending.checkpoints ?? []).length > 0
            ? '\n이미 완료된 단계:\n' + pending.checkpoints.map((c, i) => `  ${i + 1}. ${c}`).join('\n')
            : '';
          contextParts.push(`## 중단된 작업\n타임아웃으로 중단된 작업입니다. 아래 원래 요청을 이어서 완료해줘.\n원래 요청: "${pending.prompt}"${checkpointLines}`);
          _clearPendingTask(sessionKey);
          log('info', 'Pending task resumed via 계속', { threadId: thread.id, pendingLen: pending.prompt.length, checkpoints: pending.checkpoints?.length ?? 0 });
        }
        // 프롬프트 앞에 컨텍스트 주입 (세션 요약 → pending task → 유저 원문 순)
        userPrompt = contextParts.join('\n\n') + '\n\n' + '위 맥락을 바탕으로 중단된 작업을 이어서 진행해줘.';
        _continueHandled = true; // 아래 세션 요약 재주입 방지
      } else {
        // 2026-04-26 수정: pending·summary 없어도 fallback 메시지 대신 fall-through.
        // "계속"을 일반 처리 흐름으로 통과시켜 Claude가 직전 대화 컨텍스트를 보고 응답하도록.
        // 이전 동작: '이어받을 작업이 없습니다' fallback + return → Claude 진입 차단 → continuity-signal hook 무력화.
        log('info', 'Continue without pending/summary — fall through to default Claude flow', { threadId: thread.id, sessionKey });
      }
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

    // [2026-04-24] #jarvis-interview 채널 fast-path — claude-agent-sdk 우회.
    // claude-agent-sdk의 Claude Code CLI subprocess spawn 오버헤드(60초+)를 회피하기 위해
    // 해당 채널만 OpenAI gpt-4o-mini 직접 호출로 5초 이내 응답 보장.
    // 세션/스킬/MCP 전부 skip — personas.json의 jarvis-interview 페르소나 + RAG만으로 답변.
    if (message.channel.id === INTERVIEW_CHANNEL_ID) {
      clearInterval(typingInterval);

      // v4.36 (2026-04-26) Ralph 메타 명령 인터셉트 — fast-path 진입 전.
      // 가드: bot/webhook 메시지 무시 (무한 루프 방지), 정확 매칭만 (오탐 차단).
      const isAuthorBot = message.author.bot || message.webhookId;
      const trimmed = (userPrompt || '').trim();
      if (!isAuthorBot) {
        const isRalphStart = /^(랄프|ralph)\s*(켜|시작|start|on)$/i.test(trimmed);
        const isRalphStop = /^(랄프|ralph)\s*(꺼|중단|종료|stop|off)$/i.test(trimmed);
        const isRalphStatus = /^(랄프|ralph)\s*(상태|status)$/i.test(trimmed);
        if (isRalphStart || isRalphStop || isRalphStatus) {
          const { execFile } = await import('node:child_process');
          const { promisify } = await import('node:util');
          const exec = promisify(execFile);
          const home = process.env.HOME || '/Users/ramsbaby';
          try {
            if (isRalphStart) {
              const { stdout: pgrepOut } = await exec('pgrep', ['-f', 'interview-ralph-runner']).catch(() => ({ stdout: '' }));
              if (pgrepOut.trim()) {
                await message.reply(`⚠️ Ralph 이미 가동 중 (PID: ${pgrepOut.trim().split('\n').join(', ')}).\n중복 시동 차단했습니다. 끄려면 \`랄프 꺼\`.`);
              } else {
                const { stdout, stderr } = await exec('bash', [`${home}/jarvis/runtime/scripts/interview-ralph-start.sh`, '--round', '9', '--limit', '24']).catch(e => ({ stdout: '', stderr: e.message || String(e) }));
                const pidMatch = stdout.match(/PID\s+(\d+)/);
                const pid = pidMatch ? pidMatch[1] : '?';
                await message.reply(`🚀 **Ralph 시동 완료** — PID ${pid}, 라운드 9, 24문항 풀.\n• 진행: 약 50~70분 [검증 필요 — 실측 라운드별 분포 41~186초/문항]\n• 모니터: \`tail -f ~/jarvis/runtime/logs/interview-ralph-detached.log\`\n• 종료: 이 채널에 \`랄프 꺼\``);
              }
            } else if (isRalphStop) {
              const { stdout } = await exec('bash', [`${home}/jarvis/runtime/scripts/interview-ralph-stop.sh`, '--disable']).catch(e => ({ stdout: e.message || String(e) }));
              const lastLines = stdout.split('\n').slice(-8).join('\n');
              await message.reply(`🛑 **Ralph 정지 완료** (LaunchAgent 자동 부활 차단됨)\n\`\`\`\n${lastLines.slice(0, 1500)}\n\`\`\``);
            } else if (isRalphStatus) {
              const { stdout: pgrepOut } = await exec('pgrep', ['-af', 'interview-ralph-runner']).catch(() => ({ stdout: '' }));
              const status = pgrepOut.trim() ? `🔴 가동 중\n\`\`\`\n${pgrepOut.trim().slice(0, 800)}\n\`\`\`` : '🟢 정지';
              const { stdout: insightsRaw } = await exec('cat', [`${home}/jarvis/runtime/state/ralph-insights-block.json`]).catch(() => ({ stdout: '{}' }));
              let summary = '';
              try {
                const data = JSON.parse(insightsRaw);
                summary = `\n📊 누적 학습 (라운드 ${data.round || '?'})\n• ssotIssues: ${(data.ssotIssues || []).length}건\n• ssotIssuesByStar: ${Object.keys(data.ssotIssuesByStar || {}).length}개 STAR\n• aiTone: ${(data.aiTone || []).length}건\n• detailGaps: ${(data.detailGaps || []).length}건`;
              } catch { /* ignore */ }
              await message.reply(`📍 **Ralph 상태**\n${status}${summary}`);
            }
          } catch (err) {
            log('error', 'ralph meta-command failed', { error: err.message });
            await message.reply(`❌ Ralph 명령 실패: ${err.message.slice(0, 200)}`);
          }
          processingMsgIds.delete(message.id);
          return;
        }
      }

      const { runInterviewFastPath } = await import('./interview-fast-path.js');
      try {
        await runInterviewFastPath({ message, userInput: userPrompt });
      } catch (err) {
        log('error', 'interview-fast-path error', { error: err.message });
      }
      processingMsgIds.delete(message.id);
      return;
    }

    // [2026-04-24] 첨부 영구 저장 경로 — /tmp 대신 state/attachments/YYYY-MM-DD/
    // /tmp 는 OS 주기 정리 대상이라 분석 재시도 시 원본 유실. 영구 경로로 변경.
    const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
    const attachDir = join(_BOT_HOME, 'state', 'attachments', today);
    mkdirSync(attachDir, { recursive: true });

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
        const localPath = join(attachDir, `${att.id}_${safeName}`);
        writeFileSync(localPath, buf);
        imageAttachments.push({ localPath, safeName });
        log('info', 'Downloaded attachment', { name: safeName, bytes: buf.length, path: localPath });
      } catch (err) {
        log('warn', 'Failed to download attachment', { id: att.id, error: err.message });
      }
    }
    // Download text/document attachments from Discord CDN
    // 지원: txt, md, html, java, py, json, xml, csv, yaml, sh, sql, pdf 등
    const MAX_TEXT_BYTES = 20_000_000; // [2026-04-24] 2MB → 20MB 상향. 2012KB PDF 거부 사고로 확대.
    for (const [, att] of message.attachments) {
      const isImg = att.contentType?.startsWith('image/') ||
        /\.(jpg|jpeg|png|gif|webp)$/i.test(att.name ?? '');
      const isAud = att.contentType?.startsWith('audio/') ||
        /\.(ogg|mp3|m4a|wav)$/i.test(att.name ?? '');
      if (isImg || isAud) continue; // 이미 처리됨

      const fname   = att.name ?? '';
      const isPdf   = att.contentType === 'application/pdf' || /\.pdf$/i.test(fname);
      const isText  = TEXT_DOC_EXTS.test(fname) || att.contentType?.startsWith('text/');
      if (!isPdf && !isText) continue;

      try {
        const resp = await fetch(att.url);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const contentLength = parseInt(resp.headers.get('content-length') ?? '0', 10);
        if (contentLength > MAX_TEXT_BYTES) {
          await thread.send(`⚠️ 파일 "${fname}"이 너무 큽니다 (${(contentLength / 1024).toFixed(0)}KB, 최대 20MB).`);
          continue;
        }
        const buf = Buffer.from(await resp.arrayBuffer());
        log('info', 'Downloaded text/doc attachment', { name: fname, bytes: buf.length });

        if (isPdf) {
          // PDF → pdftotext 추출 시도, 실패 또는 빈 텍스트면 Claude Read 폴백
          // [2026-04-24] 영구 경로 사용: state/attachments/YYYY-MM-DD/{id}_{name}.pdf
          const safeFname = fname.replace(/[^a-zA-Z0-9가-힣._-]/g, '_');
          const pdfPath = join(attachDir, `${att.id}_${safeFname}`);
          writeFileSync(pdfPath, buf);
          let usedFallback = false;
          try {
            const { stdout } = await execFileAsync('/opt/homebrew/bin/pdftotext', [pdfPath, '-'], { maxBuffer: 20 * 1024 * 1024 });
            const extracted = stdout.trim();
            if (extracted) {
              // [2026-04-24] rmSync 제거 + 영구 경로 저장. 이미지 페이지 OCR 재확인·크로스체크 대비.
              log('info', 'PDF 텍스트 추출 완료 — 원본 영구 보존', { path: pdfPath, extractedLen: extracted.length });
              userPrompt = `[첨부 PDF: ${fname}]
${extracted}

[원본 PDF 경로: ${pdfPath} — 이미지 페이지 OCR 필요 시 Read 도구로 페이지별 확인 가능]

` + (userPrompt || '이 파일을 분석해주세요.');
            } else {
              // 이미지 기반 PDF 등 텍스트 추출 불가 → Claude Read 폴백
              usedFallback = true;
              log('info', 'pdftotext returned empty, falling back to Claude Read', { name: fname });
            }
          } catch {
            // pdftotext 오류 → Claude Read 폴백
            usedFallback = true;
            log('info', 'pdftotext failed, falling back to Claude Read', { name: fname });
          }
          if (usedFallback) {
            const safeName = fname.replace(/[^a-zA-Z0-9._-]/g, '_');
            imageAttachments.push({ localPath: pdfPath, safeName });
          }        } else {
          // 텍스트 계열 — 내용 직접 프롬프트에 주입
          const text = buf.toString('utf-8');
          const label = fname || `첨부_${att.id}`;
          userPrompt = `[첨부 파일: ${label}]\n${text}\n\n` + (userPrompt || '이 파일을 분석해주세요.');
        }
      } catch (err) {
        log('warn', 'Failed to process text/doc attachment', { id: att.id, error: err.message });
        await thread.send(`⚠️ 파일 "${att.name ?? att.id}" 처리 실패: ${err.message}`).catch(() => {});
      }
    }

    // Download and extract ZIP attachments
    // 내부 파일을 TEXT_DOC_EXTS 기준으로 필터링해 userPrompt에 주입
    const MAX_ZIP_BYTES = 10_000_000; // 10MB
    const MAX_ZIP_FILE_CHARS = 100_000; // 파일당 100KB
    for (const [, att] of message.attachments) {
      const isZip =
        att.contentType === 'application/zip' ||
        att.contentType === 'application/x-zip-compressed' ||
        (att.contentType === 'application/octet-stream' && /\.zip$/i.test(att.name ?? '')) ||
        /\.zip$/i.test(att.name ?? '');
      if (!isZip) continue;

      const fname = att.name ?? 'attachment.zip';
      const zipPath = join('/tmp', `claude-zip-${att.id}.zip`);
      const extractDir = join('/tmp', `claude-zip-${att.id}`);
      try {
        const resp = await fetch(att.url);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const contentLength = parseInt(resp.headers.get('content-length') ?? '0', 10);
        if (contentLength > MAX_ZIP_BYTES) {
          await thread.send(`⚠️ ZIP "${fname}"이 너무 큽니다 (${(contentLength / 1e6).toFixed(1)}MB, 최대 10MB).`);
          continue;
        }
        const buf = Buffer.from(await resp.arrayBuffer());
        writeFileSync(zipPath, buf);

        // 압축 해제
        await execFileAsync('unzip', ['-o', '-q', zipPath, '-d', extractDir]);

        // 텍스트 파일 목록
        const { stdout: fileList } = await execFileAsync('find', [extractDir, '-type', 'f']);
        const allFiles = fileList.trim().split('\n').filter(Boolean);
        const textFiles = allFiles.filter(f => TEXT_DOC_EXTS.test(f));

        if (textFiles.length === 0) {
          await thread.send(`⚠️ ZIP "${fname}" 내부에 지원되는 텍스트/코드 파일이 없습니다.`);
        } else {
          let zipContent = `[첨부 ZIP: ${fname} — 총 ${allFiles.length}개 파일 중 ${textFiles.length}개 텍스트 파일 분석]\n\n`;
          for (const filePath of textFiles.slice(0, 20)) {
            const relPath = filePath.replace(extractDir + '/', '');
            try {
              const fileContent = readFileSync(filePath, 'utf-8');
              const truncated = fileContent.length > MAX_ZIP_FILE_CHARS
                ? fileContent.slice(0, MAX_ZIP_FILE_CHARS) + '\n... (이하 생략)'
                : fileContent;
              zipContent += `--- ${relPath} ---\n${truncated}\n\n`;
            } catch { /* 바이너리 등 읽기 실패 파일 스킵 */ }
          }
          if (textFiles.length > 20) {
            zipContent += `⚠️ 파일이 많아 20개만 분석했습니다 (총 ${textFiles.length}개).\n`;
          }
          userPrompt = zipContent + (userPrompt ? '\n\n' + userPrompt : '이 파일들을 분석해주세요.');
        }
        log('info', 'Processed ZIP attachment', { name: fname, total: allFiles.length, text: textFiles.length });
      } catch (err) {
        log('warn', 'Failed to process ZIP attachment', { id: att.id, error: err.message });
        await thread.send(`⚠️ ZIP "${fname}" 처리 실패: ${err.message}`).catch(() => {});
      } finally {
        rmSync(zipPath, { force: true });
        rmSync(extractDir, { force: true, recursive: true });
      }
    }

    if (!userPrompt.trim() && imageAttachments.length > 0) {
      userPrompt = t('msg.analyzeImage');
    }

    const effectiveChannelId = isThread ? message.channel.parentId : message.channel.id;
    const chName = isThread ? (message.channel.parent?.name ?? 'thread') : (message.channel.name ?? 'dm');
    // 재생성 버튼 대비: sessionKey별 마지막 원본 쿼리 저장
    lastQueryStore.set(sessionKey, originalPrompt);
    streamer = new StreamingMessage(thread, message, sessionKey, effectiveChannelId);
    streamer.setContext(getContextualThinking(userPrompt, imageAttachments.length > 0));
    streamer.setChannelName(chName); // P0-3: 아티팩트 태그에 사용
    // P3-3: A/B 실험 variant 결정 — userId 기반 deterministic
    try { streamer.setUserId(effectiveAuthor?.id || message.author?.id || null); } catch { /* 비차단 */ }
    // P2-1: 상시 Status bar 활성화 — 채널 기준 모델 자동 감지
    if (process.env.STATUS_BAR_ENABLED !== '0') {
      try {
        const tier = _MODELS.channelOverrides?.[chName] || 'sonnet';
        const modelLabel = { power: 'Opus 4.7', sonnet: 'Sonnet 4.6', fast: 'Haiku 4.5' }[tier] || tier;
        streamer.setStatusMeta({ model: modelLabel, startedAt: Date.now(), turn: 0 });
      } catch { /* status bar 실패는 비차단 */ }
    }
    // [2026-04-24 진단 로그] sendPlaceholder 호출 지점 1 (본문 스트림용)
    log('info', '[PLACEHOLDER-ORIGIN]', { origin: 'handlers.js:1124 main-stream', streamerId: streamer._streamerId, msgId: message.id, threadId: thread.id });
    await streamer.sendPlaceholder();
    await streamer.updatePhase('🔍 요청 분석 중...');

    // Session summary pre-injection for resume safety
    // _continueHandled=true이면 이미 "계속" 블록에서 요약을 주입했으므로 중복 방지
    // sessionId 조건 제거: compact 직후 첫 턴(sessionId=null)에도 요약 주입
    // INTERVIEW_CHANNEL 예외: save 쪽에서 저장 안 하므로 load 해도 빈 값이지만
    // 혹시 과거 오염된 파일이 남아있을 수 있으므로 명시적으로 skip.
    // INTERVIEW_CHANNEL: 면접 전형 질문 Hard 가드 대상 채널.
    // env 미설정 시 기능 비활성(모든 채널에서 일반 응답) — 오너별 channel id 는 env 로만 관리.
    const INTERVIEW_CHANNEL = process.env.INTERVIEW_CHANNEL || '';
    let _summaryInjected = false;
    if (!_continueHandled && chName !== INTERVIEW_CHANNEL) {
      const summary = loadSessionSummary(sessionKey);
      if (summary) {
        // tutoring 질문인데 요약에 잘못된 MCP/캘린더 내용이 있으면 주입하지 않음
        const BAD_TUTORING_SUMMARY = /google calendar|캘린더.*mcp|mcp.*캘린더|settings\.json.*수정|재시작.*후.*다시/is;
        const skipSummary = isTutoringQuery(originalPrompt) && BAD_TUTORING_SUMMARY.test(summary);
        if (!skipSummary) {
          userPrompt = summary + userPrompt;
          _summaryInjected = true;
          log('info', 'Session summary pre-injected for resume safety', { threadId: thread.id });
        } else {
          log('info', 'Session summary skipped (bad tutoring context detected)', { threadId: thread.id });
        }
      }
    }

    // 새 세션이고 summary도 없으면 Discord 히스토리로 봇 이전 응답 컨텍스트 복원
    // (봇 재시작/세션 만료 후 "아까 뭐라 했어?" 같은 상황 대응)
    if (!_continueHandled && !sessionId && !_summaryInjected && !isTutoringQuery(originalPrompt)) {
      try {
        const cached = message.channel.messages.cache;
        const botId = message.client.user.id;
        const hasBotMsg = [...cached.values()].some(m => m.author.id === botId && m.id !== message.id);
        if (hasBotMsg) {
          const historyLines = [];
          let totalLen = 0;
          const MAX_HIST = 3000;
          const BOT_LIMIT = 1000;
          const sorted = [...cached.values()].sort((a, b) => a.createdTimestamp - b.createdTimestamp);
          for (const msg of sorted) {
            if (msg.id === message.id) continue;
            const isBot = msg.author.id === botId;
            let content = msg.content?.trim() || '';
            if (!content) continue;
            if (isBot && content.length > BOT_LIMIT) content = content.slice(0, BOT_LIMIT) + '...';
            const label = isBot ? 'Jarvis' : 'User';
            const line = `${label}: ${content}`;
            if (totalLen + line.length > MAX_HIST) break;
            historyLines.push(line);
            totalLen += line.length;
          }
          if (historyLines.length > 0) {
            userPrompt = `## 이전 대화 (세션 재연결 컨텍스트)\n${historyLines.join('\n')}\n\n` + userPrompt;
            log('info', 'Discord message cache injected for session reconnect', {
              messageCount: historyLines.length,
              totalLen,
            });
          }
        }
      } catch (histErr) {
        log('debug', 'Discord cache history inject failed', { error: histErr.message });
      }
    }

    const MAX_CONTINUATIONS = 10; // [2026-04-23] 5→10 상향. 이유: /verify 등 heavy skill 턴 소진으로 msg.truncated 반복 발생. 이론 상한 200×(1+10)=2200턴.
    let continuationCount = 0;
    let _autoResumeAttempts = 0; // 타임아웃 자동 재개 횟수 (최대 2회)

    async function runClaude(sid, streamer) {
      log('info', 'Starting Claude session', {
        threadId: thread.id,
        resume: !!sid,
        promptLen: userPrompt.length,
      });

      // AbortController replaces proc.kill()
      const abortController = new AbortController();

      // Compat shim: commands.js uses active.proc.kill() and active.proc.killed
      let aborted = false;
      let killReason = 'timeout'; // 'timeout' | 'restart' — 취소 원인 구분용
      const procShim = {
        kill: (reason = 'timeout') => { aborted = true; killReason = reason; abortController.abort(); },
        get killed() { return aborted; },
      };

      timeoutHandle = setTimeout(() => {
        log('warn', 'Claude session timed out, aborting', { threadId: thread.id });
        procShim.kill();
      }, 600_000);

      activeProcesses.set(sessionKey, { proc: procShim, timeout: timeoutHandle, typingInterval, userId: effectiveAuthor.id, streamer, originalPrompt, sessionKey });
      // 즉시 active-session 파일 기록 (watchdog이 5분 주기 전에 체크해도 보호됨)
      try { writeFileSync(join(_BOT_HOME, 'state', 'active-session'), String(Date.now())); } catch { /* best effort */ }

      let lastAssistantText = '';
      let toolCount = 0;
      let retryNeeded = false;
      let needsContinuation = false;
      let autoResumeNeeded = false;
      let hasStreamEvents = false;
      let lastStreamBlockWasTool = false; // 툴 블록 직후 텍스트 개행 삽입용
      const completedTools = []; // ② 세션 연속성: 완료된 툴 호출 체크포인트

      // Phase 2: resume 성공 시에도 이전 요약 주입
      // 조건: resume 세션 존재 && 마지막 활동 30분+ 경과 && 요약 파일 존재
      let _injectedSummary = '';
      if (sid && _isSessionIdle(sessions, sessionKey)) {
        try {
          const rawSummary = loadSessionSummary(sessionKey);
          if (rawSummary) {
            // 헤더/마크다운 제거 후 본문만 추출하여 300자 truncate
            const bodyOnly = rawSummary
              .replace(/^##.*$/gm, '')
              .replace(/\n{3,}/g, '\n')
              .trim();
            _injectedSummary = bodyOnly.slice(0, 1500);
            log('info', 'Phase2: previous session summary will be injected on resume', { sessionKey, len: _injectedSummary.length });
          }
        } catch (e) {
          log('debug', 'Phase2: failed to load session summary (non-critical)', { error: e?.message });
        }
      }

      for await (const event of createClaudeSession(userPrompt, {
        sessionId: sid,
        threadId: thread.id,
        channelId: effectiveChannelId,
        channelName: chName,
        attachments: imageAttachments,
        userId: (() => {
          try {
            appendFileSync('/tmp/jarvis-guard-debug.log',
              `  → before createClaudeSession | effectiveAuthor.id=${effectiveAuthor?.id} | viaSlashProxy=${message._viaSlashProxy} | clientUserId=${message.client?.user?.id}\n`
            );
          } catch {}
          return effectiveAuthor.id;
        })(),
        contextBudget,
        signal: abortController.signal,
        injectedSummary: _injectedSummary,
        _budgetMode,
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
          // 네이티브 SDK 컴팩션 완료 — 토큰 카운터 리셋 (SDK가 컨텍스트를 정리했음)
          if (event.subtype === 'compact_boundary') {
            log('info', 'Native compact_boundary received — resetting token counter', {
              threadId: thread.id, preTokens: event.pre_tokens,
            });
            sessionTokenCounts.delete(sessionKey);
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
            // toolCount 관측만 — 강제 중단 가드는 제거(2026-04-17).
            // 이유: SDK maxTurns + 10분 timeout + maxBudget이 이미 폭주를 차단함.
            //      8회 제한은 정상 세션 잘라먹는 premature safeguard로 판명(2건 실제 trip).
            //      response-ledger.jsonl에 toolCount 계속 기록되어 사후 패턴 분석 가능.
            const display = getToolDisplay(se.content_block.name || '');
            // P0-1: 통합 엔트리 — placeholder 모드면 updateStatus, 본문 스트리밍 중이면 prefix 라인
            streamer.setToolStatus(display.desc);
            // P2-1: 턴 카운터 증가 (상시 Status bar)
            streamer.incTurn();
            // ② 세션 연속성: 툴 호출 이름 기록 (최대 20개, 민감 툴 제외)
            const toolName = se.content_block.name || '';
            if (toolName && !toolName.includes('secret') && completedTools.length < 20) {
              completedTools.push(toolName);
            }
            // Tool Call Audit: 도구 호출 ledger에 기록 (Anthropic Verification 패턴)
            try {
              const safeTool = (toolName || '').replace(/[\n\r]/g, '_').slice(0, 100);
              const ledgerDir = join(_BOT_HOME, 'state');
              mkdirSync(ledgerDir, { recursive: true });
              const toolEntry = JSON.stringify({ ts: new Date().toISOString(), session: sessionKey, tool: safeTool }) + '\n';
              appendFileSync(join(ledgerDir, 'tool-call-ledger.jsonl'), toolEntry);
            } catch { /* ledger 기록 실패는 비차단 */ }
            log('info', `Tool: ${se.content_block.name}`, { threadId: thread.id });
          } else if (se.type === 'content_block_start' && se.content_block?.type === 'thinking') {
            // P0-1: thinking 블록 시작 — 본문 스트리밍 중이면 "🧠 생각 정리 중" prefix
            hasStreamEvents = true;
            streamer.setThinking(true);
          } else if (se.type === 'content_block_stop') {
            // P0-1: tool/thinking 블록 종료 → prefix 제거
            streamer.clearToolStatus();
            streamer.setThinking(false);
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
          // [2026-04-23 중복 송출 근본 수정] hasRealContent 가드 추가.
          //   이전 로직: finalized=false면 무조건 retry → AUP refusal로 중간 끊긴 응답이 이미 송출됐는데도 retry
          //   결과: 이전 부분 메시지 + 새 응답 → 주인님이 본 "청킹 후 새로 씀" 중복의 근본 원인.
          //   수정: 이미 실제 콘텐츠가 송출된 경우 sessionId만 초기화하고 retry 차단.
          if (event.is_error && sid && !streamer.finalized) {
            if (streamer.hasRealContent) {
              log('warn', 'Resume failed but partial content already sent — skip retry to avoid duplicate', { sessionId: sid });
              sessions.delete(sessionKey);
              // retryNeeded = false 유지: 중복 송출 방지
              break;
            }
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

          const cost = event.cost_usd ?? null;
          const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
          // P2-1: 최종 토큰을 Status bar 에 반영 (input+output 합산 = 실제 처리량)
          const totalTok = (event.usage?.input_tokens ?? 0) + (event.usage?.output_tokens ?? 0);
          if (totalTok > 0) streamer.setStatusMeta({ tokens: totalTok });

          // Phase 0 Sensor: 로컬 response-ledger (Langfuse 의존 제거)
          // feedback-score.jsonl과 traceId로 join 가능
          if (!event.is_error) {
            const localTraceId = `local-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
            try {
              const ledgerDir = join(_BOT_HOME, 'state');
              mkdirSync(ledgerDir, { recursive: true });
              appendFileSync(
                join(ledgerDir, 'response-ledger.jsonl'),
                JSON.stringify({
                  ts: new Date().toISOString(),
                  source: 'discord-bot',
                  traceId: localTraceId,
                  userId: effectiveAuthor?.id ?? null,
                  channelId: effectiveChannelId,
                  sessionId: thread.id,
                  toolCount,
                  cost_usd: cost,
                  elapsed_s: parseFloat(elapsed),
                  input_tokens: event.usage?.input_tokens ?? 0,
                  output_tokens: event.usage?.output_tokens ?? 0,
                  // 프롬프트 캐시 계측 (토큰 절감 효과 분석용)
                  //   cache_read: 재사용된 prefix 토큰 (캐시 히트)
                  //   cache_creation: 이번 턴에 새로 캐시에 기록한 토큰
                  cache_read_input_tokens: event.usage?.cache_read_input_tokens ?? 0,
                  cache_creation_input_tokens: event.usage?.cache_creation_input_tokens ?? 0,
                  stop_reason: event.stop_reason ?? null,
                  output_snippet: lastAssistantText.slice(0, 300),
                }) + '\n'
              );
            } catch (e) {
              log('debug', 'response-ledger append failed (non-blocking)', { error: e?.message });
            }
            // 유저별 직전 trace/prompt 캐시 — 다음 턴 피드백 도착 시 scoring 대상
            if (effectiveAuthor?.id) {
              _lastTraceByUser.set(effectiveAuthor.id, localTraceId);
              _lastPromptByUser.set(effectiveAuthor.id, String(originalPrompt).slice(0, 240));
            }
          }
          const rateStatus = rateTracker.check();

          // stop_reason 사람말로
          const stopLabel = event.stop_reason === 'end_turn' ? '✅ 완료'
            : event.stop_reason === 'max_turns'              ? '↩️ 연속 처리'
            : event.stop_reason === 'tool_use'               ? '🛠️ 도구 종료'
            : event.stop_reason ?? '-';

          // P2-1: Status bar 확장 — 모델/토큰/경과시간 포함 (Claude.ai 스타일)
          const _modelShort = /power|opus-4-7|opus-4-6/.test(modelLabel) ? 'Opus'
            : /opusplan/.test(modelLabel) ? 'Opus⁺'
            : /sonnet/.test(modelLabel) ? 'Sonnet'
            : /haiku/.test(modelLabel) ? 'Haiku'
            : modelLabel.replace('claude-', '');
          const _inTk = event.usage?.input_tokens ?? 0;
          const _outTk = event.usage?.output_tokens ?? 0;
          const _cacheRead = event.usage?.cache_read_input_tokens ?? 0;
          const _cacheCreate = event.usage?.cache_creation_input_tokens ?? 0;
          const _tokShort = (n) => n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
          const footerParts = [`🤖 ${_modelShort}`, `⏱️ ${elapsed}s`];
          if (_inTk + _outTk > 0) footerParts.push(`💭 ${_tokShort(_inTk)}↑ ${_tokShort(_outTk)}↓`);
          // 캐시 히트율: cache_read / (cache_read + cache_create + input_tokens) — 전체 prompt 기준
          // SDK는 cache hit 시 input_tokens 에서 재사용분을 제외한 신규분만 카운트
          const _totalPromptTok = _inTk + _cacheRead + _cacheCreate;
          if (_cacheRead > 0 && _totalPromptTok > 0) {
            const _cachePct = Math.round((_cacheRead / _totalPromptTok) * 100);
            footerParts.push(`🎯 ${_cachePct}% (${_tokShort(_cacheRead)})`);
          }
          if (toolCount > 0) footerParts.push(`🛠️ ${toolCount}`);
          footerParts.push(`📊 ${Math.round(rateStatus.pct * 100)}%`);
          const stopPrefix = event.stop_reason !== 'end_turn' ? `${stopLabel} · ` : '';

          // 가족 채널에서는 stats 숨김
          const quietIds = (process.env.QUIET_CHANNEL_IDS || '').split(',').map(s => s.trim()).filter(Boolean);
          const isQuiet = quietIds.includes(effectiveChannelId) || quietIds.includes(thread.id);

          // stats를 finalize 전에 buffer에 붙여 Discord edit 횟수 1회로 줄임
          if (!isQuiet) {
            const statsLine = `-# ${stopPrefix}${footerParts.join(' · ')}`;
            streamer.append('\n' + statsLine);
          }

          await streamer.finalize();
          await unreact(EMOJI.THINKING);
          await react(EMOJI.DONE);

          log('info', 'Claude completed', {
            threadId: thread.id, cost, toolCount, sessionId: resultSessionId,
            stopReason: event.stop_reason ?? 'unknown', elapsed: `${elapsed}s`,
          });

          if (lastAssistantText.length > 20) {
            saveConversationTurn(originalPrompt, lastAssistantText, chName, effectiveAuthor.id);
            // INTERVIEW_CHANNEL 은 세션 요약 저장 차단: 모의면접 시뮬 답변이 요약에 섞이면
            // 다음 턴에 pre-inject 되어 RAG·가드를 모두 우회하며 거짓 스토리 부활.
            if (chName !== INTERVIEW_CHANNEL) {
              saveSessionSummary(sessionKey, originalPrompt, lastAssistantText);
              // P0 Surface Learning Equalization: turn 종료 시 mistake-extractor 비동기 fork.
              // 디스코드 봇 학습 루프가 Claude Code CLI Stop 훅과 동등한 권한으로 작동.
              try {
                const sessionSummaryPath = join(_BOT_HOME, 'state', 'session-summaries',
                  `${sessionKey.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);
                triggerDiscordMistakeExtract(sessionSummaryPath);
              } catch (e) {
                log('debug', 'triggerDiscordMistakeExtract skipped', { error: e?.message });
              }
              // P2 Real-time Correction Detection: 사용자 분노 키워드 감지 → 즉시 등재 + 알림
              try {
                const ang = detectAnger(originalPrompt);
                if (ang.matched) {
                  recordAngerSignal({
                    userId: effectiveAuthor.id,
                    channelId: effectiveChannelId,
                    keyword: ang.keyword,
                    userText: originalPrompt,
                    assistantText: lastAssistantText,
                    sessionKey,
                  }).catch((e) => log('debug', 'recordAngerSignal outer catch', { error: e?.message }));
                }
              } catch (e) {
                log('debug', 'anger-detector skipped', { error: e?.message });
              }

              // 🛡️ 가드 #1 (2026-04-28): 자비스 응답 자체에 단정 표현이 있으면
              //   사용자 분노가 없어도 anger-signals.jsonl에 기록 → 다음 turn에
              //   "🚨 직전 정정" 헤더로 강제 주입되어 같은 단정 즉시 차단.
              try {
                const { recordSelfAssertiveSignal } = await import('./anger-detector.mjs');
                recordSelfAssertiveSignal({
                  userId: effectiveAuthor.id,
                  channelId: effectiveChannelId,
                  sessionKey,
                  userText: originalPrompt,
                  assistantText: lastAssistantText,
                }).catch((e) => log('debug', 'self-assertive outer catch', { error: e?.message }));
              } catch (e) {
                log('debug', 'self-assertive skipped', { error: e?.message });
              }
            }
            // 토큰 누적: result 이벤트의 usage.input_tokens (claude-runner.js에서 포워딩)
            const inputTokens = event.usage?.input_tokens ?? 0;
            if (inputTokens > 0) {
              const newTotal = (sessionTokenCounts.get(sessionKey) ?? sessions.getTokenCount(sessionKey) ?? 0) + inputTokens;
              sessionTokenCounts.set(sessionKey, newTotal);
              sessions.addTokens(sessionKey, inputTokens); // 영속화
              log('debug', 'Token count updated', { sessionKey, inputTokens, total: newTotal });
            }
            // 비동기 메모리 추출 — 메인 응답에 영향 없는 fire-and-forget
            autoExtractMemory(effectiveAuthor.id, originalPrompt, lastAssistantText, effectiveChannelId).catch((e) => log('debug', 'autoExtractMemory outer catch', { error: e?.message }));
            // 비동기 약속 감지 — Jarvis가 "하겠습니다" 발화 시 commitments.jsonl 기록
            _trackCommitment(lastAssistantText, { channelId: effectiveChannelId, userId: effectiveAuthor.id })
              .catch((e) => log('debug', 'commitment-tracker outer catch', { error: e?.message }));
          }
        }
      }

      clearTimeout(timeoutHandle);
      timeoutHandle = null;
      activeProcesses.delete(sessionKey);
      // 마지막 활성 채널 기록 → 재시작 후 알림 폴백용
      try { writeFileSync(join(_BOT_HOME, 'state', 'last-active-channel'), thread.id); } catch { /* best effort */ }
      // active-session 파일 삭제는 finally 블록에서 통합 처리 (예외 경로 포함)

      // 보류 중인 재시작 체크 — 마지막 세션 완료 시 graceful restart
      if (activeProcesses.size === 0) {
        const pendingOauthRestart = join(_BOT_HOME, 'state', 'pending-oauth-restart');
        const pendingDeploymentRestart = join(_BOT_HOME, 'state', 'pending-deployment-restart');

        // 2026-04-20: 5초 → 15초 연장
        // 5초는 Discord API finalize 지연 + 새 프로세스 기동(약 5~8초) + orphan cleanup
        // 이 겹쳐 race window를 만듦. 15초는 Discord client 모든 I/O 수렴 + 헬스체크
        // 파일 flush 여유 확보.
        const RESTART_DELAY_MS = 15000;
        if (existsSync(pendingOauthRestart)) {
          try { rmSync(pendingOauthRestart, { force: true }); } catch { /* ok */ }
          log('info', 'Pending OAuth restart: last session completed, restarting in 15s');
          setTimeout(() => process.kill(process.pid, 'SIGTERM'), RESTART_DELAY_MS);
        } else if (existsSync(pendingDeploymentRestart)) {
          let reason = 'deployment';
          try {
            reason = readFileSync(pendingDeploymentRestart, 'utf-8').trim() || reason;
            rmSync(pendingDeploymentRestart, { force: true });
          } catch { /* ok */ }
          log('info', 'Pending deployment restart: last session completed, restarting in 15s', { reason });
          setTimeout(() => process.kill(process.pid, 'SIGTERM'), RESTART_DELAY_MS);
        }
      }

      // Loop ended without result event
      if (!streamer.finalized && !retryNeeded && !needsContinuation) {
        if (aborted && killReason === 'manual') {
          // 사용자 수동 중단 — auto-resume 없이 즉시 finalize
          await streamer.finalize();
        } else if (aborted && killReason !== 'restart') {
          // 타임아웃: 2회까지 자동 재개, 이후에만 사용자에게 알림
          _savePendingTask(sessionKey, originalPrompt, completedTools);
          // [2026-04-23 중복 방지 #2] 부분 송출 후 auto-resume 차단
          //   주인님 4회 반복 사고의 진짜 주범: AUP refusal → aborted=true → autoResumeNeeded=true
          //   → while (autoResumeNeeded) 루프 반복 → 이미 송출된 내용을 처음부터 재작성
          //   수정: hasRealContent면 재개 대신 truncate 안내 후 finalize.
          if (!streamer.hasRealContent && _autoResumeAttempts < 2) {
            autoResumeNeeded = true;
            // finalize 스킵 — 외부 auto-resume 루프가 처리
          } else {
            // [2026-04-24] 오너 지시 — "응답이 중간에 끊겼습니다" 배너 제거.
            // hasRealContent 일 땐 조용히 finalize. 빈 응답일 때만 timeout 안내 유지.
            if (!streamer.hasRealContent) {
              streamer.append('\n\n' + t('msg.timeout'));
            }
            await streamer.finalize();
          }
        } else {
          if (streamer.hasRealContent && toolCount > 0) {
            // [2026-04-23 관측 패치] L1585 경로 실제 발생 여부 추적
            //   이 경로는 SDK for-await 가 result/error 없이 조용히 종료될 때 도달.
            //   5차 감사관 응답 절단의 유력 후보. 로그 안 남기던 blind spot 이었음.
            log('warn', 'Stream ended without result event — appending msg.truncated', {
              threadId: thread.id, toolCount, contentLen: streamer.buffer?.length ?? 0,
            });
            streamer.append('\n\n' + t('msg.truncated'));
          }
          await streamer.finalize();
        }
      }

      return { retryNeeded, needsContinuation, autoResumeNeeded, lastAssistantText, toolCount };
    }

    // 분석/트렌드 질문 → Claude가 HTML 생성 → Puppeteer → Discord (fire-and-forget)
    const _analyticalType = detectAnalyticalType(originalPrompt);
    if (_analyticalType) {
      generateAndSendVisual(originalPrompt, _analyticalType, thread).catch(() => {});
    } else if (detectStatType(originalPrompt)) {
      // 단순 수치 질문 → embed 카드
      sendStatVisual(originalPrompt, thread).catch(() => {});
    }

    // Pre-process: enrich userPrompt (RAG context)
    const preCtx = new ProcessorContext({
      originalPrompt,
      channelId: effectiveChannelId,
      threadId: thread.id,
      botHome: process.env.BOT_HOME || `${homedir()}/jarvis/runtime`,
      client,
    });
    await streamer.updatePhase('🔍 컨텍스트 검색 중...');
    userPrompt = await _preProcessorRegistry.run(userPrompt, preCtx);

    // ---------------------------------------------------------------------------
    // Hard 가드 — INTERVIEW_CHANNEL 에서 면접 전형 질문이 왔는데 mock-interview 스킬이
    // 명시적으로 켜지지 않은 경우, 모델이 창작하기 전에 고정 응답으로 short-circuit.
    // 이유: 프롬프트 지시("모의면접 쓸까요?"라고 먼저 확인)만으로는 LLM이 무시하고
    // 실증 없이 STAR 답변을 만들어낸다. 코드 레벨 가드가 유일한 해결책.
    // ---------------------------------------------------------------------------
    const INTERVIEW_PATTERNS = [
      /실수\s*경험/, /실패\s*경험/, /조직\s*갈등/, /갈등\s*경험/,
      /협업\s*경험/, /자기\s*소개/, /지원\s*동기/,
      /장단점/, /본인.*강점/, /본인.*약점/,
      /인상\s*깊었/, /도전\s*경험/, /성장\s*경험/,
      /조직경험.*실수/, /어려웠던.*경험/,
    ];
    // 가드는 원본 사용자 입력만 검사. userPrompt 는 이전 세션 요약 pre-inject 로
    // 오염된 상태라 여기서 패턴 매칭하면 과거 대화의 거짓말 스토리까지 잡혀 오탐 발생.
    const _rawInput = (message.content || '').trim();
    const hasInterviewPattern = INTERVIEW_PATTERNS.some((re) => re.test(_rawInput));
    const hasSkillTrigger = /^\/[a-zA-Z0-9_-]+/.test(_rawInput)
      || /모의면접|면접\s*연습|면접\s*답변|면접관\s*해줘/.test(_rawInput);

    // 모의면접 세션 활성 상태 체크 — /mock-interview 로 시작된 세션이면
    // 자연어 후속 질문도 스킬 모드로 처리 (가드 우회).
    const { isMockSessionActive, deactivateMockSession, activateMockSession: _activateMock } = await import('./slash-proxy.js');
    const mockActive = isMockSessionActive(effectiveChannelId, effectiveAuthor.id);

    // 키워드로 모의면접 시작한 경우도 세션 활성화
    if (hasSkillTrigger && /모의면접|면접\s*연습|면접\s*답변|면접관\s*해줘/.test(_rawInput)) {
      _activateMock(effectiveChannelId, effectiveAuthor.id);
    }

    // 세션 종료 트리거
    if (mockActive && /^(끝|그만|마무리|피드백\s*줘|총평)$/.test(_rawInput)) {
      deactivateMockSession(effectiveChannelId, effectiveAuthor.id);
      // 피드백 요청은 그대로 통과 (스킬이 피드백 모드로 처리)
    }

    // mockActive 이면 후속 자연어 메시지에도 스킬이 주입되도록 트리거 마커 prepend.
    // claude-runner 의 skill-loader 가 "모의면접" 키워드를 감지해 스킬 활성화.
    if (mockActive && !hasSkillTrigger) {
      userPrompt = `[모의면접 세션 진행중]\n\n${userPrompt}`;
    }

    // ---------------------------------------------------------------------------
    // 모의면접 범용 답변 가드 — 카드 하드코딩 없이 질문 유형별 원칙 + RAG 컨텍스트 주입.
    //
    // 구조:
    // 1. 세션 시작 시 RAG로 오너 프로필 전체를 pre-fetch (commands.js) → MOCK_CONTEXT
    // 2. 매 턴마다 질문 유형 감지 (취약성/자기소개/기술깊이/동기 등)
    // 3. 유형별 답변 원칙 + pre-fetch된 RAG 컨텍스트를 프롬프트에 주입
    // 4. Claude는 "재료(RAG) + 원칙(유형별 가이드)" 만으로 답변 생성 → 창작 차단
    // ---------------------------------------------------------------------------
    const QUESTION_TYPES = {
      vulnerability: /실수\s*경험|실패\s*경험|조직\s*갈등|갈등\s*경험|본인.*약점|단점.*경험|어려웠던.*경험|조직경험.*실수|조직경험.*실패|조직경험.*갈등/,
      intro: /자기\s*소개|간단.*소개|본인.*소개해|본인.*어떤/,
      motivation: /지원\s*동기|왜.*회사|왜.*지원|지원.*이유|어떻게.*지원/,
      techDepth: /어떤.*기술|가장.*관심.*기술|최근.*공부|기술.*스택|어떤.*프로젝트|아키텍처|설계/,
      collab: /협업|팀.*경험|동료.*갈등|의견.*차이|소통.*어려웠/,
      decision: /의사.*결정|판단.*근거|선택.*이유|왜.*그.*방법|트레이드오프/,
      leadership: /주도.*경험|리더|이끌어|설득.*경험/,
      growth: /성장.*경험|도전.*경험|새로.*배운|학습|인상.*깊었/,
      future: /앞으로.*목표|커리어.*계획|5년|3년|어떤.*개발자/,
    };
    let questionType = 'generic';
    for (const [type, re] of Object.entries(QUESTION_TYPES)) {
      if (re.test(_rawInput)) { questionType = type; break; }
    }
    // 면접 전용 채널(jarvis-interview)에서는 모든 질문을 면접 질문으로 간주 (generic 포함)
    const isInterviewQuestion = chName === 'jarvis-interview' || questionType !== 'generic' || /경험|답변|설명.*해|말해/.test(_rawInput);

    if (mockActive && isInterviewQuestion) {
      const { getMockContext } = await import('./slash-proxy.js');
      const mockCtx = getMockContext(effectiveChannelId, effectiveAuthor.id);
      const ragContextBlock = mockCtx?.context
        ? `\n\n[오너 실증 프로필 컨텍스트 — 답변의 재료는 여기에서만 가져와라]\n${mockCtx.context}\n`
        : '';
      const companyBlock = mockCtx?.company ? `\n[회사: ${mockCtx.company}]` : '';

      const TYPE_GUIDES = {
        vulnerability: `
[질문 유형: 취약성 · 실수/실패/갈등/약점 — 시니어 레벨 답변]

이 유형은 "실수를 덮지 않고 기술적으로 복기"하는 자각이 핵심. 빈 반성 문구가 아니라 **현상 vs 원인 혼동**을 구체적 기술 용어로 짚어야 면접관이 "시니어 감각 있다"고 판단.

**답변 3단 구조 필수:**
1. **실수 인정 (기술 수준 포함)**: "당시 저는 ○○ 로그를 보고 ×× 가설을 세웠습니다. 이는 현상과 원인을 혼동한 판단 미스였습니다"
2. **이유 설명 (개념 수준)**: "○○는 △△ 레벨의 문제이고, 실제 병목은 □□ 레벨이었는데, 표면 지표에만 매몰됐습니다"
3. **반전과 학습 (구체적 도구/방법)**: "로그/락 모니터링/덤프/쿼리 플랜 분석 등으로 본질을 파악했고, 이후 ○○ 가이드라인을 세웠습니다"

**데드락 문제를 쓸 경우 반드시 기술 정합성 유지:**
- 데드락의 원인은 **트랜잭션 Lock 점유 시간/범위 / 인덱스 미비 / 쿼리 플랜** 계열이지 커넥션 풀 크기가 아님
- 풀 크기를 초기 가설로 쓰려면 반드시 "이는 현상과 원인 혼동이었다"고 명시 (안 쓰면 가설 자체가 허술해 보임)
- 더 안전한 초기 가설: "인덱스 미비로 풀 스캔 발생 → Next-Key Lock 범위 확대" / "트랜잭션 범위 과대 설정"
- DB 엔진 언급 가능 (MySQL InnoDB, Oracle 등) — Lock 방식 차이 이해 시그널

**풀 이름 / 용어 정합성:**
- Lock 경합 = Lock Contention
- 락 점유 시간 = Lock Hold Time
- 범위 락 = Next-Key Lock (MySQL InnoDB)
- 근본 원인 분석 = Root Cause Analysis

**필수 포함:** 대안 1~2개 비교 / 수치 3종 / 팀 리뷰 맥락 / 이후 문서화·표준화
**금지:** "혼자 판단", "공유 없이", "테스트 생략", "몰래", 수치 없는 "개선"`,
        intro: `
[질문 유형: 자기소개]
- 구조: 경력 연차·핵심 기술 → 최근 성과 1개 (수치) → 지원 포지션 연결고리 1줄
- 금지: "저는 열정적이고 꼼꼼한 성격이라" 같은 직무 무관 성격 나열`,
        motivation: `
[질문 유형: 지원 동기]
- 구조: 회사 전략/도메인에서 본 강점 → 내 경험과 정확한 연결 → 무엇을 만들고 싶은지
- 필수: 회사 구체적 맥락 (서비스·최근 뉴스·기술 방향 중 1개)
- 금지: "좋은 회사라 지원했다" 같은 일반론`,
        techDepth: `
[질문 유형: 기술 깊이]
- 구조: 실제 적용 맥락 → 왜 이 기술 선택했나 (대안 비교) → 실제 만난 함정과 해결 → 측정 결과
- 필수: 트레이드오프 명시, 수치 지표 (p95·처리량·비용 등)
- 금지: 교과서적 정의만 늘어놓기
- **기술 정합성 주의**: 개념 층위를 혼동하지 말 것.
  예시 함정:
  - 데드락 ≠ 커넥션 풀 부족 (락 경합 vs 연결 고갈은 다른 층위)
  - N+1 ≠ 쿼리 느림 (반복 호출 vs 단일 쿼리 성능은 다름)
  - OSIV ≠ 트랜잭션 (View 범위 vs TX 범위)
  틀릴 법한 부분은 "○○는 △△ 레벨 문제이고, 실제는 □□ 레벨"처럼 층위 구분 명시`,
        collab: `
[질문 유형: 협업/갈등]
- 구조: 상황 → 상대 입장 이해 시도 → 데이터·근거 기반 대화 → 합의 도출 → 이후 관계
- 필수: 상대를 인격적으로 존중한 시그널, 결과가 서로에게 유익
- 금지: "제가 설득해서 제 뜻대로 됐다" 류 우월감`,
        decision: `
[질문 유형: 의사결정 근거]
- 구조: 옵션 A/B/C 명시 → 각 장단점 → 선택 기준 (운영비·확장성·팀 역량·리스크) → 선택 + 이후 검증
- 필수: 최소 2개 대안 비교, 선택 기준 명시적 언급`,
        leadership: `
[질문 유형: 리더십]
- 구조: 담당이 아닌데 먼저 제기한 문제 → 팀 동의 이끈 과정 (데이터·페어) → 구조적 개선 → 재발 방지
- 필수: "제가 먼저 제안했다" + 팀 합의 맥락`,
        growth: `
[질문 유형: 성장 경험]
- 구조: 모르던 영역 → 학습 방법 (문서·페어·사이드프로젝트) → 실무 적용 → 이후 확장
- 필수: 구체적 학습 과정 (책 제목·강의·페어 대상 중 1개)`,
        future: `
[질문 유형: 미래 목표]
- 구조: 단기(1~2년) 기술 목표 → 중기(3~5년) 역할 목표 → 지원 회사와 어떻게 연결되는지
- 필수: 회사 도메인·방향성과의 연결고리`,
        generic: `
[질문 유형: 범용 면접 질문]
- STAR 구조 (상황·과제·행동·결과)로 답변
- 실증 경험 기반, 수치 포함
- 끝에 조직 기여·학습 킥 1개`,
      };
      const typeGuide = TYPE_GUIDES[questionType] || TYPE_GUIDES.generic;

      userPrompt = `[모의면접 · 1분 30초 즉답]${companyBlock}

원 질문: ${_rawInput}
${typeGuide}
${ragContextBlock}
**답변 생성 규칙 (엄격):**
1. 어미는 모두 ~습니다/~합니다. 준말(~했어요/~거든요) 금지
2. 길이 370~420자 (1분 30초 분량). 초과·미달 금지
3. 위 컨텍스트의 실증 경험(STAR·이력서·수치)만 재료로 사용. 기술·수치·프로젝트 창작 금지
4. **필수 포함 3요소**:
   - 수치 3종: before→after + 기간/규모 중 1개
   - 선택지 비교 또는 트레이드오프 명시 1개 ("A도 검토했으나 B가 적합했습니다" 식)
   - 조직 기여 킥 1개 (표준화·문서화·패턴 재사용·재발 방지 중 하나)
5. **금지 표현**: "혼자 판단", "공유 없이", "몰래", "테스트 생략", "열심히 했습니다", "꼼꼼한 성격", 수치 없는 "효율화/개선"
6. 마지막 한 줄: **강점 파고드는 예상 꼬리질문** 1개. 약점 파고드는 꼬리질문("왜 처음부터 X로 안 했나요") 금지

바로 답변 생성 시작. 서론·설명 없이 답변 본문부터.`;
    }

    // 이전 카드 기반 분기 제거 (유지 이유: 기존 플로우 깨지지 않게 변수만 둠)
    const VULNERABILITY_PATTERNS_LEGACY = [/__never_match__/];
    const isVulnerabilityQuestion = VULNERABILITY_PATTERNS_LEGACY.some((re) => re.test(_rawInput));
    if (false && mockActive && isVulnerabilityQuestion) {
      userPrompt = `[모의면접 — 취약성 질문 · 즉답]

원 질문: ${_rawInput}

아래 카드 중 하나를 골라 1인칭 격식체로 확장하라. 카드 밖 사실 창작 금지.

[카드 A · 기술 가설 검증 과정에서 방향 재설정 — 스케줄러 데드락]
상황: 스케줄러 배치에서 데드락이 시간당 3회 발생. SLA 위반 직전
초기 가설: 인덱스/쿼리 플랜 이슈로 락 점유가 길어진다고 추정 → **팀 리뷰 후** 쿼리 플랜 분석·인덱스 튜닝 시범 적용 → 증상 미개선
재분석: 실제 원인은 20만 건을 **단일 트랜잭션으로 묶어 락을 20초 점유**하고 있던 트랜잭션 경계 설계
선택지 비교: ①배치 자체 분리는 스케줄 재편이 커서 제외, ②Pessimistic Lock은 경합 악화 우려, ③REQUIRES_NEW + 500건 Chunking 선택 — 자식 트랜잭션 독립 분리로 Lock 점유 시간 단축 + 부모 롤백 전파 차단
수치 근거: 500건은 당시 평균 행 크기 기준 단일 트랜잭션 1초 이내 완료되는 임계점
결과: Lock 20초→1ms, 데드락 시간당 3회→0회, 배치 실패율 소폭 하락 → 팀 표준 문서화·공유

[카드 B · 설계 타이밍 오판 → 패턴 리팩터 — IoT Adapter]
상황: IoT 신규 제조사 온보딩 초기, if-else 분기로 빠르게 가자는 팀 합의
초기 판단: 신규 3~4개 제조사까진 분기 로직으로 충분 → **팀 리뷰 거쳐** 도입
재분석: 분기 100줄 돌파 시점에 신규 제조사 추가마다 기존 로직 회귀 테스트 부담이 기하급수적으로 커지는 걸 확인
선택지 비교: ①if-else 유지+헬퍼 분리는 여전히 결합도↑, ②Strategy 패턴은 조건 분기 유지, ③Adapter 패턴 선택 — 제조사별 계약 격리로 신규 추가가 기존 로직에 영향 없음
결과: 온보딩 2주→2일(약 7배), 이후 신규 제조사는 같은 패턴 재사용 → 팀 내 설계 원칙으로 정착

[카드 C · 범위 추정 오판 → 전략 전환 — 배치 최적화]
상황: 야간 정산 배치가 3~4분 소요, 다음 배치 스케줄과 겹쳐 데이터 정합성 위협
초기 가설: 쿼리 튜닝으로 충분 → **팀 리뷰 후** 인덱스·조인 순서 수정 시범 적용 → 30% 개선에 그침
재분석: DB 병목이 아니라 단건 INSERT 반복에 따른 커넥션 오버헤드가 실제 원인
선택지 비교: ①트랜잭션 배치 크기만 늘리면 Lock 시간 증가, ②비동기 큐로 돌리면 순서 보장 이슈, ③JDBC Bulk Insert + ForkJoinPool 병렬화 선택 — 커넥션 오버헤드 제거 + CPU 코어 활용
결과: 3분→10초(20배), 이후 유사 배치 2건에 동일 패턴 적용 → 팀 내 표준 레퍼런스로 정착

**답변 규칙 (370~420자, 1분 30초):**
1. 어미 모두 ~습니다/~합니다. 준말(~했어요) 금지
2. **프레이밍 안전장치:**
   - "초기 판단 잘못" X → "초기 가설이 빗나갔다"
   - "빠르게 배포" X → "팀 리뷰 거쳐 시범 적용"
   - "혼자·공유 없이·몰래" 절대 금지
3. **포함 필수 요소 (대기업·빅테크 양쪽 킥):**
   - 수치 3종: before → after + 기간/규모
   - 비교 고려한 옵션 최소 1개 언급 ("다른 안도 검토했지만~" 식)
   - 조직 기여 킥 1개 (표준 문서화·패턴 재사용·팀 원칙)
4. 구조: 상황 → 초기 가설 → 전환 계기 → 선택 근거(1~2개 비교 포함) → 수치 결과 → 조직 기여
5. 마지막 한 줄: **강점 파고드는 꼬리질문**. 예: "선택지 비교는 어떤 기준으로 하셨나요?" / "500건 청킹 숫자 근거는?" / "이후 팀 표준으로 어떻게 확산시키셨나요?"

**꼬리질문 대비 메모 (답변 후 오너 외울 답안)**:
- Q "왜 REQUIRES_NEW·청킹 선택?"
  → "배치 분리는 스케줄 재편 부담, Pessimistic Lock은 경합 악화. REQUIRES_NEW는 자식 TX 독립으로 Lock 점유 시간 단축 + 롤백 전파 차단이 핵심. 500건은 테이블 평균 행 기준 단일 TX 1초 이내 임계점."
- Q "왜 Adapter 선택?"
  → "Strategy는 분기 조건 유지가 단점, Adapter는 제조사별 계약 격리로 신규 추가가 기존에 영향 없음."

사용자가 카드 지정 안 하면 질문 취지에 가장 맞는 카드 선택. 바로 답변 생성 시작.`;
    }

    // v4.39 (2026-04-27 주인님 지시): 면접 전형 질문 가드 영구 비활성.
    // 배경: env INTERVIEW_CHANNEL 설정 채널에서 면접 패턴 감지 시 가드 발동되어 안내 메시지 송출되던 사고. 사용자 의도와 정반대.
    // 사용자 의도: 면접 전용 채널만 자동 답변, 그 외 모든 채널은 가드 발동 X (일반 응답 흐름 유지).
    // 처방: 면접 전용 채널은 INTERVIEW_CHANNEL 매칭 안 되므로 어차피 자유 응답.
    //       그 외 채널의 면접 패턴 감지 가드는 false로 영구 차단.
    // 복구 방법: 아래 false를 chName === INTERVIEW_CHANNEL로 되돌림 (단 사용자 명시 결재 후).
    if (false && chName === INTERVIEW_CHANNEL && hasInterviewPattern && !hasSkillTrigger && !mockActive) {
      const guardMsg = `🎤 면접 전형 질문 감지됨.\n\n이 채널은 일반 커리어 상담 채널이라 자동으로 1인칭 면접 답변을 만들지 않습니다 (할루시네이션 방지).\n\n**모의면접 답변 만들려면:**\n\`/mock-interview 삼성물산\` (슬래시 커맨드)\n또는 \`면접 연습해줘: 조직 실수 경험 질문\` (자연어)\n\n**그냥 질문 자체에 대한 상담이면:** "상담 모드로 답해줘"라고 덧붙여 주세요.`;
      await message.reply(guardMsg).catch(() => message.channel.send(guardMsg));
      await streamer.finalize();
      try {
        appendFileSync('/tmp/jarvis-guard-debug.log',
          `\n[${new Date().toISOString()}] BLOCKED\n` +
          `  channel: ${chName}\n` +
          `  prompt: ${userPrompt.slice(0, 300)}\n` +
          `  hasInterviewPattern: ${hasInterviewPattern}\n` +
          `  hasSkillTrigger: ${hasSkillTrigger}\n`
        );
      } catch {}
      log('info', 'Interview question blocked', {
        channel: chName,
        preview: userPrompt.slice(0, 60),
      });
      return;
    }

    const LITE_CHANNEL_ID = process.env.LITE_CHANNEL_ID || '';
    const contextBudget = effectiveChannelId === LITE_CHANNEL_ID ? 'small' : 'large';
    const _chOverride = _MODELS.channelOverrides?.[chName];
    const modelLabel = contextBudget === 'small'
      ? 'claude-haiku'
      : (_chOverride ? `claude-${_chOverride}` : 'claude-opusplan');
    await streamer.updatePhase(`🧠 ${modelLabel} 호출 중...`);

    // First attempt
    let runResult = await runClaude(sessionId, streamer);

    // Retry with fresh session if resume caused error
    if (runResult.retryNeeded) {
      log('info', 'Retrying Claude with fresh session', { threadId: thread.id });
      sessionId = null;
      streamer.finalized = false;
      streamer._finalizeComplete = false;
      streamer.buffer = '';
      streamer.sentLength = 0;
      streamer.hasRealContent = false;
      streamer._textSent = false;
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

      // Session summary fallback — 중복 주입 방지
      if (!_summaryInjected) {
        const summary = loadSessionSummary(sessionKey);
        if (summary) {
          userPrompt = summary + userPrompt;
          _summaryInjected = true;
          log('info', 'Injected session summary fallback [path-D: auto-resume]', { threadId: thread.id });
        }
      }

      // RAG re-inject on retry: skip for tutoring queries (data already pre-injected)
      if (!isTutoringQuery(originalPrompt)) {
        // PAST_REF_PATTERN 감지 시 episodic 모드로 discord-history 우선 검색
        // family 채널: familyOnly=true → Owner stock/career 데이터 RAG 결과 제외
        const isEpisodic = PAST_REF_PATTERN.test(originalPrompt);
        const _famChIds = (process.env.FAMILY_CHANNEL_IDS || '').split(',').filter(Boolean);
        const _isFamilyRetry = _famChIds.includes(effectiveChannelId);
        const ragContext = await searchRagForContext(originalPrompt, 3, {
          ...(isEpisodic && { sourceFilter: 'episodic' }),
          ...(_isFamilyRetry && { familyOnly: true }),
        }).catch(() => null);
        if (ragContext) {
          const ragSnippet = ragContext.length > 600 ? ragContext.slice(0, 600) + '...' : ragContext;
          userPrompt = ragSnippet + '\n\n' + userPrompt;
          log('info', 'RAG re-injected on retry', { threadId: thread.id, ragLen: ragSnippet.length, familyOnly: _isFamilyRetry });
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

    // Auto-resume: 타임아웃 발생 시 사용자 입력 없이 자동 재개 (최대 2회)
    while (runResult.autoResumeNeeded) {
      _autoResumeAttempts++;
      log('info', 'Auto-resuming after timeout', { threadId: thread.id, attempt: _autoResumeAttempts });
      const pending = _loadPendingTask(sessionKey);
      if (pending) {
        const checkpointLines = (pending.checkpoints ?? []).length > 0
          ? '\n완료된 작업: ' + pending.checkpoints.join(', ')
          : '';
        userPrompt = `## 자동 재개 (시도 ${_autoResumeAttempts}/2)\n이전 응답이 타임아웃으로 중단됐습니다. 원래 요청을 이어서 완료해줘. 이미 완료된 작업은 반복하지 마.\n원래 요청: "${pending.prompt}"${checkpointLines}\n\n중단된 부분부터 이어서 진행해줘.`;
        _clearPendingTask(sessionKey);
      }
      const resumeSessionId = sessions.get(sessionKey);
      // streamer 재사용 가능 상태로 초기화
      streamer.finalized = false;
      streamer._finalizeComplete = false;
      runResult = await runClaude(resumeSessionId, streamer);
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
      recordError(thread.id, effectiveAuthor.id, 'no_response');
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
        recordError(target.id, effectiveAuthor.id, retryErr.message?.slice(0, 200));
      }
    }

    // Discord API 내부 오류 (메시지 삭제됨, 권한 없음 등) — 사용자에게 보여줄 필요 없음
    const isDiscordApiError = err.code != null && typeof err.code === 'number';
    if (isDiscordApiError) {
      log('warn', 'Discord API error (silent)', { code: err.code, message: err.message });
      return;
    }

    // Claude 처리 오류만 사용자에게 알림 — 디버깅용 세션ID 포함
    recordError(target.id, effectiveAuthor.id, err.message?.slice(0, 200));
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

// ---------------------------------------------------------------------------
// Regen / Summarize 버튼 지원 함수
// ---------------------------------------------------------------------------

/**
 * processingMsgIds에서 특정 messageId를 수동 해제.
 * regen 버튼 핸들러에서 bot 메시지의 dedup 해제 시 사용.
 */
export function clearProcessedId(msgId) {
  processingMsgIds.delete(msgId);
}

/**
 * 저장된 쿼리로 Claude 세션을 재실행해 channel에 응답 전송.
 * @param {import('discord.js').TextChannel} channel
 * @param {string} query - lastQueryStore에서 가져온 원본 쿼리
 * @param {string} sessionKey
 * @param {{ sessions: import('./store.js').SessionStore, activeProcesses: Map }} state
 */
export async function rerunQuery(channel, query, sessionKey, state, opts = {}) {
  const { sessions, activeProcesses } = state;
  const sessionId = sessions.get(sessionKey);

  const streamer = new StreamingMessage(channel, null, sessionKey, channel.id);
  streamer.setContext(opts.contextLabel ?? '🔄 재생성 중...');
  streamer.setChannelName(channel?.name || null); // P0-3: artifact 업로드 시 채널 태그
  // P3-3: 재생성에도 같은 userId 기반 variant 유지 (sessionKey에 userId 포함됨: ch-id:user-id)
  try {
    const parts = String(sessionKey || '').split(':');
    const uid = parts.length >= 2 ? parts[parts.length - 1] : null;
    if (uid) streamer.setUserId(uid);
  } catch { /* 비차단 */ }
  // [2026-04-24 진단 로그] sendPlaceholder 호출 지점 2 (슬래시/명령어 경로)
  log('info', '[PLACEHOLDER-ORIGIN]', { origin: 'handlers.js:2130 slash-or-cmd', streamerId: streamer._streamerId, sessionKey });
  await streamer.sendPlaceholder();

  const abortController = new AbortController();
  const procShim = {
    kill: (reason = 'manual') => { void reason; abortController.abort(); },
    get killed() { return abortController.signal.aborted; },
  };
  activeProcesses.set(sessionKey, { proc: procShim, streamer });

  try {
    // Option B: 세션 요약 주입 — handleMessage와 동일한 컨텍스트 품질 보장
    let fullQuery = query;
    const summary = loadSessionSummary(sessionKey);
    const BAD_RERUN_SUMMARY = /google calendar|캘린더.*mcp|mcp.*캘린더|settings\.json.*수정|재시작.*후.*다시/is;
    if (summary && !BAD_RERUN_SUMMARY.test(summary)) {
      fullQuery = summary + fullQuery;
      log('info', 'rerunQuery: session summary injected [path-E]', { sessionKey, summaryLen: summary.length });
    }

    // Pre-processor pipeline: RAG context enrichment
    // NOTE: contextBudget classification is skipped here — rerunQuery always uses opusplan
    // (createClaudeSession reads channel persona from channelId, budget is set in claude-runner.js)
    try {
      const preCtx = new ProcessorContext({
        originalPrompt: query,   // use original (un-summarized) query for pattern matching
        channelId: channel.id,
        threadId: channel.id,
        botHome: process.env.BOT_HOME || `${homedir()}/jarvis/runtime`,
        client: channel.client ?? null,
      });
      fullQuery = await _preProcessorRegistry.run(fullQuery, preCtx);
      log('info', 'rerunQuery: pre-processor pipeline applied', { sessionKey });
    } catch (ppErr) {
      log('warn', 'rerunQuery: pre-processor pipeline failed (continuing)', { sessionKey, error: ppErr.message });
    }

    for await (const event of createClaudeSession(fullQuery, {
      sessionId,
      threadId: channel.id,
      channelId: channel.id,  // ← createClaudeSession이 channelId로 페르소나 자동 로드
      attachments: [],
      signal: abortController.signal,
    })) {
      if (event.type === 'system' && event.session_id) {
        sessions.set(sessionKey, event.session_id);
      } else if (event.type === 'stream_event') {
        const se = event.event;
        if (se.type === 'content_block_delta' && se.delta?.type === 'text_delta' && se.delta?.text) {
          streamer.append(se.delta.text);
        } else if (se.type === 'content_block_start' && se.content_block?.type === 'tool_use') {
          // P0-1: updateStatus → setToolStatus 교체 (본문 스트리밍 중에도 prefix 표시)
          streamer.setToolStatus(`🔧 ${se.content_block.name || '도구 실행 중'}`);
        } else if (se.type === 'content_block_start' && se.content_block?.type === 'thinking') {
          // P0-1: thinking 블록 시작 → "🧠 생각 정리 중" prefix
          streamer.setThinking(true);
        } else if (se.type === 'content_block_stop') {
          // P0-1: tool/thinking 블록 종료 → prefix 제거
          streamer.clearToolStatus();
          streamer.setThinking(false);
        }
      }
    }
  } catch (err) {
    if (!abortController.signal.aborted) {
      log('error', 'rerunQuery failed', { sessionKey, error: err.message });
      await channel.send(`⚠️ 재생성 실패: ${err.message.slice(0, 200)}`).catch(() => {});
    }
  } finally {
    await streamer.finalize().catch(() => {});
    activeProcesses.delete(sessionKey);
    // 다음 regen에서도 원본 query 유지 (요약이 주입된 fullQuery가 아닌 원본)
    lastQueryStore.set(sessionKey, query);
  }
}
