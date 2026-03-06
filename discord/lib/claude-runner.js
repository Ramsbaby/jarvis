/**
 * Claude session management via @anthropic-ai/claude-agent-sdk.
 * Replaces the former subprocess-based approach (claude -p CLI spawning).
 *
 * Exports: createClaudeSession, execRagAsync, saveConversationTurn,
 *          sendNtfy, log, ts, detectFeedback, processFeedback
 */

import {
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
  appendFileSync,
  copyFileSync,
} from 'node:fs';
import { appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { userMemory } from './user-memory.js';

// ---------------------------------------------------------------------------
// Feedback detection — recognize user signals for learning loop
// ---------------------------------------------------------------------------

/**
 * Detect user feedback signals from message text.
 * Returns { type, fact? } or null if no feedback detected.
 */
export function detectFeedback(text) {
  const t = text.trim().toLowerCase();

  if (t.startsWith('기억해:') || t.startsWith('/remember ')) {
    const fact = text.replace(/^(기억해:|\/remember\s+)/i, '').trim();
    return fact ? { type: 'remember', fact } : null;
  }

  if (/^(좋아|잘했어|이게 맞아|완벽|ㄱㅌ|굿|맞아|정확해|완벽해)/.test(t)) {
    return { type: 'positive' };
  }

  if (/^(별로야|틀렸어|다시 해|아니야|이건 아닌|잘못됐어|틀려)/.test(t)) {
    return { type: 'negative' };
  }

  const corrMatch = text.match(/^(앞으로는|다음부터는)\s+(.+)/);
  if (corrMatch) {
    return { type: 'correction', fact: corrMatch[2] };
  }

  return null;
}

/**
 * Process detected feedback and persist to user memory.
 */
export function processFeedback(userId, text) {
  const fb = detectFeedback(text);
  if (!fb) return null;

  if (fb.type === 'remember' && fb.fact) {
    userMemory.addFact(userId, fb.fact);
    log('info', 'Feedback: remember', { userId, fact: fb.fact.slice(0, 100) });
  } else if (fb.type === 'correction' && fb.fact) {
    const data = userMemory.get(userId);
    if (!data.corrections.includes(fb.fact)) {
      data.corrections.push(fb.fact);
      data.updatedAt = new Date().toISOString();
      const usersDir = join(process.env.BOT_HOME || join(homedir(), '.jarvis'), 'state', 'users');
      mkdirSync(usersDir, { recursive: true });
      writeFileSync(join(usersDir, `${userId}.json`), JSON.stringify(data, null, 2));
    }
    log('info', 'Feedback: correction', { userId, fact: fb.fact.slice(0, 100) });
  } else if (fb.type === 'positive') {
    log('info', 'Feedback: positive', { userId });
  } else if (fb.type === 'negative') {
    log('info', 'Feedback: negative', { userId });
  }

  return fb;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const BOT_HOME = join(process.env.BOT_HOME || join(HOME, '.jarvis'));
const DISCORD_MCP_PATH = join(BOT_HOME, 'config', 'discord-mcp.json');
const USER_PROFILE_PATH = join(BOT_HOME, 'context', 'user-profile.md');
const CONV_HISTORY_DIR = join(BOT_HOME, 'context', 'discord-history');
const LOG_PATH = join(BOT_HOME, 'logs', 'discord-bot.jsonl');

// ---------------------------------------------------------------------------
// Logging utilities
// ---------------------------------------------------------------------------

export function ts() {
  return new Date().toISOString();
}

export function log(level, msg, data) {
  const line = { ts: ts(), level, msg, ...data };
  console.log(`[${line.ts}] ${level}: ${msg}`);
  appendFile(LOG_PATH, JSON.stringify(line) + '\n').catch(() => {});
}

export async function sendNtfy(title, message, priority = 'default') {
  const topic = process.env.NTFY_TOPIC || '';
  const server = process.env.NTFY_SERVER || 'https://ntfy.sh';
  if (!topic) return;
  try {
    await fetch(`${server}/${topic}`, {
      method: 'POST',
      body: String(message).slice(0, 1000),
      headers: {
        'Title': title,
        'Priority': priority,
        'Tags': 'robot',
      },
    });
  } catch (err) {
    log('warn', 'ntfy send failed', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// Load CHANNEL_PERSONAS from personas.json (gitignored, fallback to {})
// ---------------------------------------------------------------------------

let CHANNEL_PERSONAS = {};
try {
  const personasPath = join(import.meta.dirname, '..', 'personas.json');
  CHANNEL_PERSONAS = JSON.parse(readFileSync(personasPath, 'utf-8'));
} catch {
  log('warn', 'personas.json not found — channel personas disabled');
}

// ---------------------------------------------------------------------------
// Load USER_PROFILES from config/user_profiles.json
// Maps Discord user IDs to named profiles (owner, family, etc.)
// Env overrides: OWNER_DISCORD_ID, BORAM_DISCORD_ID
// ---------------------------------------------------------------------------

let USER_PROFILES = {};
try {
  const userProfilesPath = join(BOT_HOME, 'config', 'user_profiles.json');
  USER_PROFILES = JSON.parse(readFileSync(userProfilesPath, 'utf-8'));
  if (process.env.OWNER_DISCORD_ID && USER_PROFILES.owner) {
    USER_PROFILES.owner.discordId = process.env.OWNER_DISCORD_ID;
  }
  if (process.env.BORAM_DISCORD_ID && USER_PROFILES.boram) {
    USER_PROFILES.boram.discordId = process.env.BORAM_DISCORD_ID;
  }
} catch {
  log('warn', 'user_profiles.json not found — single-user (owner) mode');
}

/**
 * Returns the profile for a Discord user ID, or null if not found.
 * Returns null (→ owner fallback) if discordId is empty/unset.
 */
function getUserProfile(discordUserId) {
  if (!discordUserId) return null;
  return Object.values(USER_PROFILES).find(
    (p) => p.discordId && p.discordId === discordUserId,
  ) || null;
}

// ---------------------------------------------------------------------------
// execRagAsync — semantic memory search via rag-query.mjs
// ---------------------------------------------------------------------------

export async function execRagAsync(query) {
  const { execFileSync } = await import('node:child_process');
  try {
    const result = execFileSync(
      process.execPath,
      [join(BOT_HOME, 'lib', 'rag-query.mjs'), query],
      { timeout: 7000, encoding: 'utf-8', maxBuffer: 1024 * 200 },
    );
    return result || '';
  } catch {
    try {
      const memPath = join(BOT_HOME, 'rag', 'memory.md');
      if (existsSync(memPath)) {
        const raw = readFileSync(memPath, 'utf-8').trim();
        return raw ? `[기억 메모]\n${raw.slice(0, 1500)}` : '';
      }
    } catch { /* ignore */ }
    return '';
  }
}

// ---------------------------------------------------------------------------
// saveConversationTurn — append to daily file for RAG indexing
// ---------------------------------------------------------------------------

export function saveConversationTurn(userMsg, botMsg, channelName, userId = null) {
  const profile = userId ? getUserProfile(userId) : null;
  const senderName = profile?.name || process.env.OWNER_NAME || 'Owner';
  try {
    mkdirSync(CONV_HISTORY_DIR, { recursive: true });
    const now = new Date();
    const kst = new Date(now.getTime() + 9 * 3600 * 1000);
    const dateStr = kst.toISOString().slice(0, 10);
    const timeStr = kst.toISOString().slice(11, 16);
    const filePath = join(CONV_HISTORY_DIR, `${dateStr}.md`);
    const botName = process.env.BOT_NAME || 'Jarvis';
    const entry = `\n## [${dateStr} ${timeStr} KST] #${channelName}\n\n**${senderName}**: ${userMsg.slice(0, 600)}\n\n**${botName}**: ${botMsg.slice(0, 1800)}\n\n---\n`;
    appendFileSync(filePath, entry, 'utf-8');
  } catch (err) {
    log('warn', 'Failed to save conversation turn', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// createClaudeSession — SDK-based async generator
// Replaces the former spawnClaude() + parseStreamEvents() pair.
//
// Yields normalized events compatible with the former stream-json format:
//   { type: 'system', session_id }
//   { type: 'assistant', message: { content: [...] } }
//   { type: 'content_block_delta', delta: { type: 'text_delta', text } }
//   { type: 'result', result, session_id, is_error, cost_usd }
// ---------------------------------------------------------------------------

export async function* createClaudeSession(prompt, {
  sessionId, threadId, channelId, ragContext, attachments = [],
  contextBudget, userId, signal,
} = {}) {
  // 1. Setup stable workDir — same 4-layer token isolation as before
  const stableDir = join('/tmp', 'claude-discord', String(threadId));
  mkdirSync(stableDir, { recursive: true });
  mkdirSync(join(stableDir, '.git'), { recursive: true });
  writeFileSync(join(stableDir, '.git', 'HEAD'), 'ref: refs/heads/main\n');
  mkdirSync(join(stableDir, '.empty-plugins'), { recursive: true });

  // 2. Copy attachments into workDir so Claude can Read them
  for (const { localPath, safeName } of attachments) {
    try { copyFileSync(localPath, join(stableDir, safeName)); } catch { /* ignore */ }
  }

  // 3. Load user profile (5-minute cache)
  const nowMs = Date.now();
  if (!createClaudeSession._profileCache || nowMs - (createClaudeSession._cacheTime || 0) > 300_000) {
    try {
      createClaudeSession._profileCache = readFileSync(USER_PROFILE_PATH, 'utf-8');
    } catch {
      createClaudeSession._profileCache = '';
    }
    createClaudeSession._cacheTime = nowMs;
  }

  const ownerName = process.env.OWNER_NAME || 'Owner';
  const ownerTitle = process.env.OWNER_TITLE || 'Owner';
  const githubUsername = process.env.GITHUB_USERNAME || 'user';

  // 4. Detect active user — owner fallback if not registered
  const activeUserProfile = getUserProfile(userId);
  const isOwner = !activeUserProfile || activeUserProfile.type === 'owner';

  // 4a. Build user context section
  const userContextParts = isOwner
    ? [
        '--- Owner Context ---',
        `지금 대화 중인 사람은 ${ownerName}(${ownerTitle}님, GitHub: ${githubUsername})이다. 오너가 "나 누구야?" 등으로 물으면 프로필 기반으로 답한다.`,
        createClaudeSession._profileCache,
      ]
    : [
        '--- 사용자 컨텍스트 ---',
        `지금 대화 중인 사람은 ${activeUserProfile.name}(${activeUserProfile.title})이다. ${activeUserProfile.bio || ''}`.trim(),
        activeUserProfile.persona ? `응답 가이드: ${activeUserProfile.persona}` : '',
      ].filter(Boolean);

  // 5. Build system prompt
  const systemParts = [
    `당신의 이름은 ${process.env.BOT_NAME || 'Jarvis'}입니다. ${ownerName}님의 개인 AI 어시스턴트입니다.`,
    '중요: 절대 스스로를 "Claude"라고 소개하거나 지칭하지 마세요. Claude는 내부 엔진일 뿐, 당신의 이름이 아닙니다. "저는 Jarvis입니다"라고만 하세요.',
    '존댓말(공손체) 기본. 간결하고 실용적으로 답한다. 한국어로 응답.',
    '',
    '## 페르소나',
    '토니 스타크의 자비스처럼 — 유능하고 따뜻하되, 아첨하지 않는 집사.',
    `- ${ownerName}님을 진심으로 아끼는 조력자. 틀린 건 부드럽지만 분명하게 짚는다.`,
    '- 추측은 "추측입니다" 명시. 모르면 솔직히 인정.',
    '',
    '## 응답 스타일',
    '- 챗봇 말투 금지 ("알겠습니다!", "완료!", "제가 도와드리겠습니다" 등). 대신: "~했습니다(결과)", "원인: ... / 조치: ..." 형식.',
    `- 독백·혼잣말 금지. 모든 응답은 ${ownerName}님에게 직접 보고하는 형식. 도구 사용 중 생각 스트리밍 금지, 결론만 보고.`,
    '- 간단한 질문은 간결하게(5줄 이하). 분석·코딩은 필요한 만큼.',
    '- 톤: 쉬운 작업 → "식은 죽 먹기였죠." / 에러 → "흥미로운 상황이 발생했습니다."',
    '',
    '## Discord 포매팅',
    '리스트(`- 항목`) 사용, 테이블 금지(모바일 미지원). 코드는 ```블록. 헤더는 섹션 3개 이상일 때만. 이모지 적절히, 남발 금지.',
    '',
    '--- 도구 선택 (작업 성격에 따라 최적 도구 선택, 출력량 최소화) ---',
    '',
    '[코드] Serena 우선 → cat/grep 대신 심볼 단위 탐색으로 정확도+턴 절약',
    '- get_symbols_overview(파일 구조) → find_symbol(정의, include_body=true) → search_for_pattern(regex) → find_referencing_symbols(역참조)',
    '- 수정: replace_symbol_body(전체 교체), insert_after/before_symbol(추가), Edit(줄 단위), Write(새 파일)',
    '',
    '[시스템] Nexus 우선 → Bash 대신 사용 시 컨텍스트 98% 절약',
    '- exec(cmd), scan(다중 병렬), cache_exec(TTL), log_tail(로그), health(상태 요약), file_peek(패턴 추출)',
    '',
    '[기억] rag_search(query) — "저번에", "기억해?" 등 과거 참조 시 먼저 호출',
    '[기타] Bash(인터랙티브만, 출력 제한 필수), Read(offset/limit), WebSearch(외부 정보), Agent(병렬 위임)',
    '',
    '안전: rm -rf/shutdown/reboot/kill -9/DROP TABLE 금지. API 키·토큰 노출 금지.',
    '',
    ...userContextParts,
  ];

  // Channel-specific persona
  const channelPersona = channelId ? CHANNEL_PERSONAS[channelId] : null;
  if (channelPersona) systemParts.push('', channelPersona);

  // Per-user long-term memory
  if (userId) {
    const memSnippet = userMemory.getPromptSnippet(userId);
    if (memSnippet) systemParts.push('', '--- 사용자 기억 (User Memory) ---', memSnippet);
  }

  // Claude Max usage summary
  let usageSummary = '';
  try {
    const usageCachePath = join(HOME, '.claude', 'usage-cache.json');
    const usageCfgPath   = join(HOME, '.claude', 'usage-config.json');
    if (existsSync(usageCachePath)) {
      const uc = JSON.parse(readFileSync(usageCachePath, 'utf-8'));
      const ul = existsSync(usageCfgPath) ? JSON.parse(readFileSync(usageCfgPath, 'utf-8')).limits ?? {} : {};
      const fH = uc.fiveH ?? {}, sD = uc.sevenD ?? {}, sn = uc.sonnet ?? {};
      usageSummary = [
        '[Claude Max 사용량 현황]',
        `5시간: ${fH.pct ?? '?'}% 사용 / 잔여 ${fH.remain ?? '?'}% / 리셋 ${fH.resetIn ?? '?'} 후`,
        `7일: ${sD.pct ?? '?'}% 사용 / 잔여 ${sD.remain ?? '?'}% / 리셋 ${sD.resetIn ?? '?'} 후`,
        `Sonnet 7일: ${sn.pct ?? '?'}% 사용 / 잔여 ${sn.remain ?? '?'}% / 리셋 ${sn.resetIn ?? '?'} 후`,
        `한도: 5h=${ul.fiveH ?? '?'}, 7d=${ul.sevenD ?? '?'}, sonnet7d=${ul.sonnet7D ?? '?'}`,
      ].join('\n');
    }
  } catch { /* ignore */ }

  // 5. Build effective prompt (same logic as former spawnClaude)
  const isResuming = !!sessionId;
  let effectivePrompt = prompt;

  if (isResuming) {
    // When resuming: add context to the prompt (system prompt is already in session)
    const ctxParts = [];
    if (isOwner) {
      ctxParts.push(`[대화 상대] ${ownerName}(${ownerTitle}님, ${githubUsername}). ${createClaudeSession._profileCache?.slice(0, 400) || ''}`);
    } else {
      ctxParts.push(`[대화 상대] ${activeUserProfile.name}(${activeUserProfile.title}). ${activeUserProfile.bio?.slice(0, 200) || ''}`);
    }
    if (channelPersona) ctxParts.push(`[채널 역할]\n${channelPersona.slice(0, 800)}`);
    if (usageSummary) ctxParts.push(usageSummary);
    // RAG는 mcp__nexus__rag_search 도구로 아젠틱하게 검색 (사전 주입 제거)
    if (attachments.length > 0) {
      const names = attachments.map((a) => `./${a.safeName}`).join(', ');
      ctxParts.push(`[첨부 파일: ${names} — Read 도구로 분석]`);
    }
    if (ctxParts.length > 0) {
      effectivePrompt = ctxParts.join('\n\n') + '\n\n' + prompt;
    }
  } else {
    // New session: add context to system prompt
    if (usageSummary) systemParts.push('', usageSummary);
    // RAG는 mcp__nexus__rag_search 도구로 아젠틱하게 검색 (사전 주입 제거)
    if (attachments.length > 0) {
      const names = attachments.map((a) => `./${a.safeName}`).join(', ');
      systemParts.push('', `--- 첨부 이미지 ---\n사용자가 이미지를 첨부했습니다: ${names}\nRead 도구로 파일을 열어 분석하세요.`);
    }
  }

  // 6. Adaptive max-turns + model selection
  const BUDGET_TURNS = { small: 5, medium: 30, large: 60 };
  const maxTurns = BUDGET_TURNS[contextBudget] ?? BUDGET_TURNS.medium;
  const BUDGET_MODEL = { small: 'claude-sonnet-4-6', medium: 'claude-sonnet-4-6', large: 'claude-opus-4-6' };
  const model = BUDGET_MODEL[contextBudget] ?? BUDGET_MODEL.medium;

  // 7. Load MCP server config (same servers, now as SDK mcpServers object)
  let mcpServers = {};
  try {
    const mcpConfig = JSON.parse(readFileSync(DISCORD_MCP_PATH, 'utf-8'));
    mcpServers = mcpConfig.mcpServers ?? {};
  } catch (err) {
    log('warn', 'Failed to load discord-mcp.json — MCP disabled', { error: err.message });
  }

  // 8. SDK query
  const { query } = await import('@anthropic-ai/claude-agent-sdk');

  const queryOptions = {
    cwd: stableDir,
    pathToClaudeCodeExecutable: process.env.CLAUDE_BINARY || join(homedir(), '.local/bin/claude'),
    allowedTools: [
      'Bash', 'Read', 'Write', 'Edit', 'Glob', 'Grep', 'WebSearch', 'Agent',
      'mcp__nexus__exec', 'mcp__nexus__scan', 'mcp__nexus__cache_exec',
      'mcp__nexus__log_tail', 'mcp__nexus__health', 'mcp__nexus__file_peek',
      'mcp__nexus__rag_search',
      'mcp__serena__find_symbol', 'mcp__serena__get_symbols_overview',
      'mcp__serena__search_for_pattern', 'mcp__serena__find_referencing_symbols',
      'mcp__serena__read_memory', 'mcp__serena__find_file',
      'mcp__serena__replace_symbol_body', 'mcp__serena__insert_after_symbol',
      'mcp__serena__insert_before_symbol',
    ],
    permissionMode: 'bypassPermissions',
    allowDangerouslySkipPermissions: true,
    mcpServers,
    maxTurns,
    model,
  };

  // Session version check: force new session if system prompt changed since last session
  const fullSystemPrompt = systemParts.join('\n');
  const promptVersion = createHash('md5').update(fullSystemPrompt).digest('hex').slice(0, 8);

  if (isResuming) {
    const savedVersion = createClaudeSession._promptVersion;
    if (savedVersion && savedVersion !== promptVersion) {
      log('info', 'System prompt changed, forcing new session', {
        threadId, oldVersion: savedVersion, newVersion: promptVersion,
      });
      // Force new session — don't resume stale system prompt
      sessionId = null;
      queryOptions.systemPrompt = fullSystemPrompt;
    }
  } else {
    queryOptions.systemPrompt = fullSystemPrompt;
  }
  createClaudeSession._promptVersion = promptVersion;

  if (sessionId) {
    queryOptions.resume = sessionId;
  }

  log('debug', 'createClaudeSession: starting query', {
    threadId, resume: !!sessionId, maxTurns, model, mcpCount: Object.keys(mcpServers).length,
  });

  // 9. Yield normalized events
  try {
    for await (const msg of query({ prompt: effectivePrompt, options: queryOptions })) {
      if (signal?.aborted) {
        log('debug', 'createClaudeSession: aborted by signal');
        break;
      }

      if (msg.type === 'system' && msg.subtype === 'init') {
        yield { type: 'system', session_id: msg.session_id };
      } else if ('result' in msg) {
        yield {
          type: 'result',
          result: msg.result ?? '',
          session_id: msg.session_id ?? null,
          is_error: false,
          cost_usd: msg.cost_usd ?? null,
          stop_reason: msg.stop_reason ?? null,
        };
      } else if (msg.type === 'assistant' || msg.type === 'content_block_delta') {
        // Pass through unchanged — handlers.js already handles both types
        yield msg;
      }
      // Unknown message types are silently ignored
    }
  } catch (err) {
    if (!signal?.aborted) {
      log('error', 'createClaudeSession: SDK error', { error: err.message });
      yield { type: 'result', result: '', is_error: true, error: err.message };
    }
  }
}
