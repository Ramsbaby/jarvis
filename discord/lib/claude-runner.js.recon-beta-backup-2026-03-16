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
import { appendFile, writeFile as writeFileAsync, rename as renameAsync } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { userMemory } from './user-memory.js';
import {
  buildIdentitySection, buildLanguageSection, buildPersonaSection,
  buildPrinciplesSection, buildFormatSection, buildToolsSection,
  buildSafetySection, buildUserContextSection, isPreplyQuery, buildPreplySection,
} from './prompt-sections.js';

// ---------------------------------------------------------------------------
// Feedback detection — recognize user signals for learning loop
// ---------------------------------------------------------------------------

/**
 * Detect user feedback signals from message text.
 * Returns { type, fact? } or null if no feedback detected.
 */
export function detectFeedback(text) {
  const t = text.trim().toLowerCase();

  // 명시적 기억 명령: "기억해:", "/remember", "기억해줘", "메모해줘", "저장해줘", "알아둬"
  const rememberPrefixMatch = text.match(/^(기억해:|\/remember\s+|기억해줘[,:]?\s*|메모해줘[,:]?\s*|저장해줘[,:]?\s*|알아둬[,:]?\s*)/i);
  if (rememberPrefixMatch) {
    const fact = text.slice(rememberPrefixMatch[0].length).trim();
    return fact ? { type: 'remember', fact } : null;
  }

  // 긍정 피드백: 15자 이하 짧은 메시지에서만 (긴 대화 오인 방지)
  // "맞아", "아니" 같은 모호한 단어 제외 — "이게 맞아", "아니야"처럼 명확한 패턴만
  if (t.length <= 15 && /좋아|잘했어|이게 맞아|완벽|ㄱㅌ|굿|정확해|완벽해|고마워|감사해|도움됐어|덕분에|최고|ㄳ|땡큐/.test(t)) {
    return { type: 'positive' };
  }

  // 부정 피드백: 15자 이하 짧은 메시지에서만
  // "아니", "틀려" 단독 제외 — "아니야", "틀렸어" 등 명확한 패턴만
  if (t.length <= 15 && /별로야|틀렸어|다시 해|아니야|이건 아닌|잘못됐어|별로|틀림/.test(t)) {
    return { type: 'negative' };
  }

  // 교정 패턴: "앞으로는", "다음부터는", "이제부터는", "다음엔", "이다음엔", "그냥 ~해줘"
  const corrMatch = text.match(/^(앞으로는|다음부터는|이제부터는|다음엔|이다음엔)\s+(.+)/);
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
    // RAG 즉시 반영 (fire-and-forget)
    _syncUserMemoryMarkdown(userId).catch((e) => log('warn', 'processFeedback: RAG sync failed', { userId, error: e.message }));
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
const MODELS = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'models.json'), 'utf-8'));
const DISCORD_MCP_PATH = join(BOT_HOME, 'config', 'discord-mcp.json');
const USER_PROFILE_PATH = join(BOT_HOME, 'context', 'user-profile.md');
const OWNER_PROFILE_PATH = join(BOT_HOME, 'context', 'owner', 'owner-profile.md');
const CONV_HISTORY_DIR = join(BOT_HOME, 'context', 'discord-history');

// 오너 Discord ID — user_profiles.json에서 읽되, 파싱 실패 시 null (기능 비활성화)
let OWNER_DISCORD_ID = null;
try {
  const _profiles = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'user_profiles.json'), 'utf-8'));
  OWNER_DISCORD_ID = _profiles?.owner?.discordId ?? null;
} catch { /* user_profiles.json 없으면 비활성화 */ }
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
  log('info', 'Channel personas loaded', {
    count: Object.keys(CHANNEL_PERSONAS).length,
    channels: Object.keys(CHANNEL_PERSONAS).join(', '),
  });
} catch (personasErr) {
  log('error', 'personas.json load failed — channel personas disabled', { error: personasErr.message });
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

export async function execRagAsync(query, opts = {}) {
  // execFileSync → execFile (Promise) 로 교체: 이벤트 루프 차단(최대 7초) 방지
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execFileP = promisify(execFile);

  // --episodic 플래그: discord-history 에피소딕 메모리를 결과 앞에 노출
  const extraFlags = opts.episodic ? ['--episodic'] : [];

  try {
    const { stdout } = await execFileP(
      process.execPath,
      [join(BOT_HOME, 'lib', 'rag-query.mjs'), ...extraFlags, query],
      { timeout: 7000, encoding: 'utf-8', maxBuffer: 1024 * 200 },
    );
    return stdout || '';
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
  const senderName = profile?.name || 'Unknown';
  try {
    mkdirSync(CONV_HISTORY_DIR, { recursive: true });
    const now = new Date();
    const kst = new Date(now.getTime() + 9 * 3600 * 1000);
    const dateStr = kst.toISOString().slice(0, 10);
    const timeStr = kst.toISOString().slice(11, 16);
    const filePath = join(CONV_HISTORY_DIR, `${dateStr}.md`);
    const botName = process.env.BOT_NAME || 'Jarvis';
    const entry = `\n## [${dateStr} ${timeStr} KST] #${channelName}\n\n**${senderName}**: ${userMsg.slice(0, 1200)}\n\n**${botName}**: ${botMsg.slice(0, 3000)}\n\n---\n`;
    appendFileSync(filePath, entry, 'utf-8');
  } catch (err) {
    log('warn', 'Failed to save conversation turn', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// _syncUserMemoryMarkdown — user-memory를 discord-history/*.md로 기록
// rag-watch.mjs가 감지 → LanceDB 즉시 인덱싱 (RAG 피드백 루프 완성)
// ---------------------------------------------------------------------------

/**
 * RAG 마크다운용 민감정보 마스킹.
 * JSON(시스템 프롬프트 주입)은 원본 유지 — 봇이 예약번호 직접 질문에 여전히 답할 수 있음.
 * RAG는 키워드 연상 검색용이므로 마스킹해도 "삿포로 여행" 검색에는 지장 없음.
 */
function _redactForRag(text) {
  return text
    .replace(/예약번호\s+\d{6,}/g, '예약번호 [보안처리됨]')
    .replace(/PIN\s*:\s*\d+/gi, 'PIN:[****]')
    .replace(/비밀번호\s+\S+/g, '비밀번호 [****]');
}

async function _syncUserMemoryMarkdown(userId) {
  const wf = writeFileAsync;
  const rename = renameAsync;
  const memData = userMemory.get(userId);
  mkdirSync(CONV_HISTORY_DIR, { recursive: true });
  const mdPath = join(CONV_HISTORY_DIR, `user-memory-${userId}.md`);
  const tmpPath = `${mdPath}.tmp.${process.pid}`;
  const name = memData.name || userId;
  const lines = [
    `# ${name} 장기 기억 (자동 축적)`,
    `_마지막 업데이트: ${new Date().toISOString()}_`,
    '',
    '## 사실 (Facts)',
    ...memData.facts.slice(-30).map(f => `- ${_redactForRag(typeof f === 'string' ? f : (f?.text ?? ''))}`),
  ];
  if (memData.preferences?.length) {
    lines.push('', '## 선호 패턴 (Preferences)');
    lines.push(...memData.preferences.map(p => `- ${p}`));
  }
  if (memData.plans?.length) {
    const active = memData.plans.filter(p => !p.done);
    if (active.length) {
      lines.push('', '## 진행 중인 계획 (Plans)');
      lines.push(...active.map(p => `- [${p.key}] ${p.summary}`));
    }
  }
  // atomic write: tmp → rename (race condition + partial write 방지)
  await wf(tmpPath, lines.join('\n'), 'utf-8');
  await rename(tmpPath, mdPath);
  log('debug', 'User memory synced to RAG markdown', { userId, facts: memData.facts.length });
}

// ---------------------------------------------------------------------------
// _syncOwnerProfileMarkdown — 오너 전용: 추출 사실을 owner-profile.md에 자동 반영
// ---------------------------------------------------------------------------

const OWNER_AUTO_SECTION = '## 자동 추출 기억';

async function _syncOwnerProfileMarkdown(newFacts) {
  if (!newFacts?.length) return;
  try {
    let content = '';
    try { content = readFileSync(OWNER_PROFILE_PATH, 'utf-8'); } catch { /* 파일 없으면 새로 생성 */ }

    const sectionIdx = content.indexOf(OWNER_AUTO_SECTION);
    let existingFacts = [];

    if (sectionIdx !== -1) {
      // 섹션이 이미 있음 — 기존 항목 파싱 (중복 방지용)
      const sectionBody = content.slice(sectionIdx + OWNER_AUTO_SECTION.length);
      existingFacts = sectionBody.match(/^- .+/gm)?.map(l => l.slice(2).trim()) ?? [];
    }

    const toAdd = newFacts.filter(f => !existingFacts.includes(f));
    if (!toAdd.length) return; // 이미 다 있음

    const timestamp = new Date().toISOString().slice(0, 10);
    const newLines = toAdd.map(f => `- ${f} _(${timestamp})_`).join('\n');

    if (sectionIdx !== -1) {
      // 기존 섹션 끝에 append
      const insertAt = sectionIdx + OWNER_AUTO_SECTION.length;
      const before = content.slice(0, insertAt);
      const after = content.slice(insertAt);
      content = before + '\n' + newLines + after;
    } else {
      // 섹션 없음 — 파일 끝에 추가
      content = content.trimEnd() + '\n\n' + OWNER_AUTO_SECTION + '\n' + newLines + '\n';
    }

    const tmpPath = `${OWNER_PROFILE_PATH}.tmp.${process.pid}`;
    await writeFileAsync(tmpPath, content, 'utf-8');
    await renameAsync(tmpPath, OWNER_PROFILE_PATH);
    log('info', 'Owner profile auto-updated', { added: toAdd.length, facts: toAdd.map(f => f.slice(0, 60)) });
  } catch (err) {
    log('debug', '_syncOwnerProfileMarkdown failed (non-critical)', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// autoExtractMemory — 대화 종료 후 기억할 사실 자동 추출 (비동기 fire-and-forget)
// ---------------------------------------------------------------------------

// 쿨다운: 유저별 마지막 추출 시각 (메모리 내, 재시작 시 초기화)
const _extractCooldown = new Map();
const EXTRACT_COOLDOWN_MS = 10 * 60 * 1000; // 10분
const EXTRACT_MIN_LEN = 150; // 봇 응답이 이 길이 이상일 때만 추출
const EXTRACT_COOLDOWN_MAX_ENTRIES = 500; // 메모리 누수 방지 상한

/**
 * 대화 내용에서 미래에 유용할 사실을 추출해 userMemory에 저장.
 * 메인 응답에 영향 없도록 비동기 fire-and-forget으로 호출.
 */
export async function autoExtractMemory(userId, userMsg, botMsg) {
  if (!userId || botMsg.length < EXTRACT_MIN_LEN) return;

  const now = Date.now();
  const lastRun = _extractCooldown.get(userId) ?? 0;
  if (now - lastRun < EXTRACT_COOLDOWN_MS) return;

  // 메모리 누수 방지: 상한 초과 시 오래된 항목부터 절반 제거
  if (_extractCooldown.size >= EXTRACT_COOLDOWN_MAX_ENTRIES) {
    const sorted = [..._extractCooldown.entries()].sort((a, b) => a[1] - b[1]);
    for (const [k] of sorted.slice(0, sorted.length / 2)) _extractCooldown.delete(k);
  }
  _extractCooldown.set(userId, now);

  // 대괄호 없는 구분자 사용 — 정규식 greedy trap 방지 (A-3 버그 수정)
  const prompt = [
    '다음 대화에서 미래 대화에 도움될 구체적 사실을 추출해줘.',
    '기준: 사람 이름/일정/장소/선호/계획/결정 같은 구체적 정보. 일반 상식이나 자명한 사실 제외.',
    '없으면 빈 배열.',
    '',
    `<<사용자>>\n${userMsg.slice(0, 500)}`,
    `<<봇>>\n${botMsg.slice(0, 800)}`,
    '',
    '출력 형식 (JSON 배열만, 다른 텍스트 없이 마지막 줄에):',
    '["사실1", "사실2"]',
  ].join('\n');

  try {
    // subprocess(claude -p)는 non-TTY 환경에서 무한 대기(exit 143)하므로 Anthropic API 직접 호출
    const apiKey = process.env.ANTHROPIC_API_KEY;

    // 구독제(Claude Max) 환경: API 키 없음 → SDK query 경량 호출로 대체
    if (!apiKey) {
      try {
        const { query } = await import('@anthropic-ai/claude-agent-sdk');
        let sdkResult = '';
        const extractOpts = {
          cwd: BOT_HOME,
          allowedTools: [],
          permissionMode: 'bypassPermissions',
          maxTurns: 1,
          model: MODELS.small,
          systemPrompt: '아래 텍스트에서 기억할 사실을 JSON 배열로 추출하세요. ["사실1", "사실2"] 형식만 반환. 없으면 [].',
        };
        for await (const msg of query({ prompt, options: extractOpts })) {
          if ('result' in msg) { sdkResult = msg.result ?? ''; break; }
          if (msg.type === 'assistant') {
            const blk = msg.message?.content?.find?.(c => c.type === 'text');
            if (blk?.text) sdkResult = blk.text;
          }
        }
        // 결과 파싱은 아래 공통 로직 재사용을 위해 result 변수에 넣고 계속 진행
        // (단, fetch 경로를 우회하므로 인라인 처리)
        const raw2 = sdkResult.trim();
        let facts2 = null;
        let se2 = raw2.length - 1;
        while (se2 >= 0 && !facts2) {
          const cb = raw2.lastIndexOf(']', se2);
          if (cb === -1) break;
          let depth = 0, ob = -1;
          for (let j = cb; j >= 0; j--) {
            if (raw2[j] === ']') depth++;
            else if (raw2[j] === '[') { depth--; if (depth === 0) { ob = j; break; } }
          }
          if (ob === -1) { se2 = cb - 1; continue; }
          try {
            const p2 = JSON.parse(raw2.slice(ob, cb + 1));
            if (Array.isArray(p2) && p2.every(x => typeof x === 'string')) facts2 = p2;
          } catch { /* try next */ }
          se2 = ob - 1;
        }
        if (facts2) {
          let saved2 = 0;
          for (const f of facts2) {
            if (typeof f === 'string' && f.length > 5 && f.length < 200) {
              userMemory.addFact(userId, f); saved2++;
              log('info', 'Auto memory extracted (SDK)', { userId, fact: f.slice(0, 80) });
            }
          }
          if (saved2 > 0) {
            await _syncUserMemoryMarkdown(userId).catch(() => {});
            if (OWNER_DISCORD_ID && userId === OWNER_DISCORD_ID) {
              const sf2 = facts2.filter(f => typeof f === 'string' && f.length > 5 && f.length < 200);
              await _syncOwnerProfileMarkdown(sf2).catch(() => {});
            }
          }
        }
      } catch { /* Claude Max SDK 호출 실패 시 조용히 무시 */ }
      return;
    }

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'output-schemas-2025-02-19',
      },
      body: JSON.stringify({
        model: MODELS.small,
        max_tokens: 512,
        messages: [{ role: 'user', content: prompt }],
        output_schema: {
          type: 'array',
          items: { type: 'string' },
        },
      }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`API ${response.status}`);
    const data = await response.json();
    const result = data?.content?.[0]?.text ?? '';

    // Structured Outputs 보장으로 bracket-matching 불필요 — 직접 파싱
    let facts = null;
    try {
      const parsed = JSON.parse(result.trim());
      if (Array.isArray(parsed) && parsed.every(x => typeof x === 'string')) facts = parsed;
    } catch { /* invalid JSON — skip */ }
    if (!facts) {
      log('debug', 'autoExtractMemory: no valid JSON array found', { userId, raw: result.slice(-150) });
      return;
    }

    let saved = 0;
    for (const fact of facts) {
      if (typeof fact === 'string' && fact.length > 5 && fact.length < 200) {
        userMemory.addFact(userId, fact);
        saved++;
        log('info', 'Auto memory extracted', { userId, fact: fact.slice(0, 80) });
      }
    }

    // RAG 즉시 반영: user-memory 마크다운을 discord-history에 기록 → rag-watch 자동 감지
    if (saved > 0) {
      await _syncUserMemoryMarkdown(userId).catch((syncErr) =>
        log('debug', 'User memory RAG sync failed (non-critical)', { userId, error: syncErr.message })
      );
      // 오너인 경우 owner-profile.md에도 자동 반영 (어느 채널이든)
      if (OWNER_DISCORD_ID && userId === OWNER_DISCORD_ID) {
        const savedFacts = facts.filter(f => typeof f === 'string' && f.length > 5 && f.length < 200);
        await _syncOwnerProfileMarkdown(savedFacts).catch((e) =>
          log('debug', 'Owner profile sync failed (non-critical)', { error: e?.message })
        );
      }
    }
  } catch (err) {
    log('debug', 'autoExtractMemory failed (non-critical)', { userId, error: err.message });
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
  injectedSummary = '',
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

  // 4. Detect active user — null → guest (NOT owner fallback)
  const activeUserProfile = getUserProfile(userId);
  const isOwner = activeUserProfile?.type === 'owner';
  const isGuest = !activeUserProfile;

  // 4a. Build user context section (SSoT: prompt-sections.js)
  const userContextParts = buildUserContextSection({
    activeUserProfile,
    ownerName,
    ownerTitle,
    githubUsername,
    profileCache: createClaudeSession._profileCache,
  });

  const BOT_HOME = process.env.BOT_HOME || `${homedir()}/.jarvis`;

  // 5. Build system prompt — stable sections contribute to session hash
  const systemParts = [
    // ── 정체성 ──────────────────────────────────────────────────────────────
    buildIdentitySection({ botName: process.env.BOT_NAME, ownerName }),
    buildLanguageSection(),

    // ── 페르소나 ─────────────────────────────────────────────────────────────
    buildPersonaSection({ ownerName }),

    // ── 실행 원칙 + 포맷 금지 ────────────────────────────────────────────────
    buildPrinciplesSection(),
    buildFormatSection(),

    // ── 도구 선택 ────────────────────────────────────────────────────────────
    buildToolsSection({ botHome: BOT_HOME }),

    // ── 안전 ─────────────────────────────────────────────────────────────────
    buildSafetySection({ botHome: BOT_HOME }),

    // ── 사용자 컨텍스트 ──────────────────────────────────────────────────────
    ...userContextParts,
  ];

  // Channel-specific persona
  const channelPersona = channelId ? CHANNEL_PERSONAS[channelId] : null;
  if (channelPersona) systemParts.push('', channelPersona);

  // Session version check: compute hash from STABLE systemParts (persona + user context only).
  // memSnippet and usageSummary are intentionally excluded:
  //   - memSnippet changes on every memory addition → would force new session every turn
  //   - usageSummary contains time-varying data ("리셋 Xm 후") → same issue
  const stableSystemPrompt = systemParts.join('\n');
  const promptVersion = createHash('md5').update(stableSystemPrompt).digest('hex').slice(0, 8);

  // Dynamic sections: injected after hash (don't affect session continuity)
  // Preply tool guidance — only when query is Preply-related (saves ~50 tokens on unrelated queries)
  if (isPreplyQuery(prompt)) {
    systemParts.push(buildPreplySection({ botHome: BOT_HOME }));
  }

  // Per-user long-term memory (added AFTER hash — memory updates don't force session reset)
  if (userId) {
    let memSnippet;
    try {
      if (prompt) {
        memSnippet = userMemory.getRelevantMemories(userId, prompt);
      } else {
        memSnippet = userMemory.getPromptSnippet(userId);
      }
    } catch {
      memSnippet = userMemory.getPromptSnippet(userId);
    }
    if (memSnippet) systemParts.push('', '--- 사용자 기억 (User Memory) ---', memSnippet);
  }

  // Claude Max usage summary
  // "사용량" 키워드면 캐시 갱신 먼저 실행 (실시간 반영)
  const isUsageQuery = /사용량|사용향|usage|한도|rate.?limit/i.test(prompt);
  if (isUsageQuery) {
    try {
      const { spawnSync } = await import('node:child_process');
      spawnSync('python3', [join(HOME, '.claude', 'scripts', 'update-usage-cache.py')], { timeout: 8000 });
    } catch { /* ignore */ }
  }
  let usageSummary = '';
  try {
    const usageCachePath = join(HOME, '.claude', 'usage-cache.json');
    const usageCfgPath   = join(HOME, '.claude', 'usage-config.json');
    if (existsSync(usageCachePath)) {
      const uc = JSON.parse(readFileSync(usageCachePath, 'utf-8'));
      if (!uc.ok) throw new Error('cache not ready');
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
    // When resuming: system prompt (profile + channelPersona) is already stored in session.
    // Only inject dynamic per-turn data: sender identity, usage, and new attachments.
    const ctxParts = [];
    const senderLabel = isOwner
      ? `${ownerName}(${ownerTitle}님, user)`
      : isGuest
      ? '게스트(미등록 사용자)'
      : `${activeUserProfile.name}(${activeUserProfile.title})`;
    ctxParts.push(`[대화 상대] ${senderLabel}`);
    // Phase 2: 이전 세션 요약 주입 (resume 성공 시에도 DYNAMIC 섹션에 삽입)
    // 조건: injectedSummary 존재 (handlers.js가 30분+ 경과 시에만 전달)
    if (injectedSummary) {
      ctxParts.push(`[이전 작업 요약] ${injectedSummary}`);
      log('debug', 'createClaudeSession: injected previous session summary on resume', { threadId, summaryLen: injectedSummary.length });
    }
    // 사용량 현황은 80% 이상일 때만 주입 — 낮을 때 주입하면 Claude self-throttling 유발
    // 예외: 사용자가 "사용량" 키워드로 직접 조회할 때는 항상 주입
    if (usageSummary) {
      const isUsageQuery = /사용량|usage|한도|rate.?limit/i.test(prompt);
      let highUsage = isUsageQuery;
      if (!highUsage) {
        try {
          const usageCachePath = join(HOME, '.claude', 'usage-cache.json');
          const { existsSync, readFileSync } = await import('node:fs');
          if (existsSync(usageCachePath)) {
            const uc = JSON.parse(readFileSync(usageCachePath, 'utf-8'));
            highUsage = (uc.fiveH?.pct ?? 0) > 80 || (uc.sevenD?.pct ?? 0) > 80;
          }
        } catch { /* ignore */ }
      }
      if (highUsage) ctxParts.push(usageSummary);
    }
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
  // 개인 비서 용도 — CLI와 동일한 품질 보장. 무한루프 방지용 상한만 유지.
  const BUDGET_TURNS = { small: 50, medium: 200, large: 200 };
  const maxTurns = BUDGET_TURNS[contextBudget] ?? BUDGET_TURNS.medium;
  const BUDGET_MODEL = { small: MODELS.small, medium: MODELS.medium, large: MODELS.large };
  const model = BUDGET_MODEL[contextBudget] ?? BUDGET_MODEL.medium;
  const BUDGET_EFFORT = { small: 'low', medium: 'medium', large: 'high' };

  // 7. Load MCP server config (same servers, now as SDK mcpServers object)
  // ${ENV_VAR} 형식의 env var를 실제 값으로 치환 지원 (GITHUB_TOKEN 등)
  let mcpServers = {};
  try {
    const rawMcp = readFileSync(DISCORD_MCP_PATH, 'utf-8')
      .replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] ?? '');
    mcpServers = (JSON.parse(rawMcp)).mcpServers ?? {};
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
    effort: BUDGET_EFFORT[contextBudget] ?? 'medium',
    // inference_geo: 환경변수 설정 시에만 적용 (미설정 시 Anthropic 기본 라우팅)
    ...(process.env.INFERENCE_GEO ? { inference_geo: process.env.INFERENCE_GEO } : {}),
    includePartialMessages: true,
  };

  // 1M 토큰 컨텍스트: contextBudget 'large' 세션에서 활성화
  if (contextBudget === 'large') {
    if (!queryOptions.betas) queryOptions.betas = [];
    if (!queryOptions.betas.includes('context-1m-2025-08-07')) {
      queryOptions.betas.push('context-1m-2025-08-07');
    }
  }

  // _promptVersionMap: per-threadId 버전 캐시 (글로벌 싱글턴은 다채널 동시실행 시 오염됨)
  if (!createClaudeSession._promptVersionMap) createClaudeSession._promptVersionMap = new Map();
  // Prevent unbounded growth: prune oldest half when exceeding 100 entries
  if (createClaudeSession._promptVersionMap.size > 100) {
    const entries = [...createClaudeSession._promptVersionMap.entries()];
    createClaudeSession._promptVersionMap = new Map(entries.slice(entries.length / 2));
  }
  if (isResuming) {
    // Always re-inject systemPrompt on resume — context compaction can lose persona/tone rules
    // CRITICAL: use systemParts.join (includes memSnippet added after hash) not stableSystemPrompt
    queryOptions.systemPrompt = systemParts.join('\n');
    const savedVersion = createClaudeSession._promptVersionMap.get(threadId);
    if (savedVersion && savedVersion !== promptVersion) {
      log('info', 'System prompt changed, forcing new session', {
        threadId, oldVersion: savedVersion, newVersion: promptVersion,
      });
      // Force new session — don't resume stale system prompt.
      sessionId = null;
      // Notify handler that session was silently reset (맥락 단절 방지)
      yield { type: 'system', session_reset: true, reason: 'prompt_version_changed' };
    }
  } else {
    // New session: systemParts already includes usageSummary (added in else block above)
    queryOptions.systemPrompt = systemParts.join('\n');
  }
  createClaudeSession._promptVersionMap.set(threadId, promptVersion);

  if (sessionId) {
    queryOptions.resume = sessionId;
  }

  log('debug', 'createClaudeSession: starting query', {
    threadId, resume: !!sessionId, maxTurns, model, mcpCount: Object.keys(mcpServers).length,
  });

  // 9. Yield normalized events (with per-message timeout guard)
  // 180s: Agent 서브에이전트 지연 대응 (3일 연속 타임아웃 INC-TIMEOUT 2026-03-14)
  const SESSION_TIMEOUT_MS = 180_000;

  /**
   * Race a single iterator.next() call against a timeout.
   * Returns { timedOut: true } if the timeout fires first.
   */
  function _nextWithTimeout(iter, ms) {
    // iter.next()를 먼저 시작하고 promise를 보존 — 타임아웃이 race를 이겨도
    // 이미 in-flight인 promise를 버리지 않음 (응답 손실 방지)
    const nextPromise = iter.next();
    return new Promise((resolve, reject) => {
      const handle = setTimeout(() => resolve({ timedOut: true, pendingNext: nextPromise }), ms);
      nextPromise.then(
        (result) => { clearTimeout(handle); resolve(result); },
        (err)    => { clearTimeout(handle); reject(err); },
      );
    });
  }

  try {
    const iter = query({ prompt: effectivePrompt, options: queryOptions })[Symbol.asyncIterator]();
    while (true) {
      if (signal?.aborted) {
        log('debug', 'createClaudeSession: aborted by signal');
        break;
      }

      let iterResult;
      try {
        iterResult = await _nextWithTimeout(iter, SESSION_TIMEOUT_MS);
      } catch (sdkErr) {
        if (!signal?.aborted) {
          log('error', 'createClaudeSession: SDK error', { error: sdkErr.message });
          yield { type: 'result', result: '', is_error: true, error: sdkErr.message };
        }
        break;
      }

      if (iterResult.timedOut) {
        // Grace window: 타임아웃이 iter.next()와 race를 이겼을 수 있음.
        // in-flight promise를 500ms 더 기다려서 응답 손실 방지.
        log('warn', 'createClaudeSession: 90s inactivity — grace check', { threadId });
        const graceResult = await Promise.race([
          iterResult.pendingNext,
          new Promise((r) => setTimeout(() => r({ timedOut: true }), 500)),
        ]);
        if (!graceResult.timedOut) {
          // Grace 기간 내 응답 도착 — 정상 처리
          iterResult = graceResult;
        } else {
          log('error', 'createClaudeSession: confirmed inactivity timeout (90s)', { threadId });
          yield {
            type: 'result',
            result: '요청 처리 시간이 초과되었습니다 (90초). 잠시 후 다시 시도해주세요.',
            is_error: true,
            error: 'Session inactivity timeout (90s)',
          };
          break;
        }
      }

      if (iterResult.done) break;

      const msg = iterResult.value;
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
          // 토큰 사용량 포워딩 — handlers.js의 compaction trigger에서 사용
          usage: msg.usage ?? null,
        };
      } else if (msg.type === 'system' && msg.subtype === 'compact_boundary') {
        // 네이티브 SDK 컴팩션 완료 이벤트 — handlers.js에서 토큰 카운터 리셋
        yield {
          type: 'system',
          subtype: 'compact_boundary',
          pre_tokens: msg.compact_metadata?.pre_tokens ?? 0,
          session_id: msg.session_id ?? null,
        };
      } else if (msg.type === 'assistant' || msg.type === 'stream_event') {
        // Pass through: assistant (complete turn), stream_event (real-time streaming)
        yield msg;
      }
      // Unknown message types are silently ignored
    }
  } catch (err) {
    if (!signal?.aborted) {
      log('error', 'createClaudeSession: unexpected error', { error: err.message });
      yield { type: 'result', result: '', is_error: true, error: err.message };
    }
  }
}
