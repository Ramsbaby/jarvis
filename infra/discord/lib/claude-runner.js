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
  statSync,
} from 'node:fs';
import { appendFile, writeFile as writeFileAsync, rename as renameAsync } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { userMemory } from '../../lib/user-memory.mjs';
import {
  detectFeedback as _sharedDetectFeedback,
  processFeedback as _sharedProcessFeedback,
  sanitizeUnicode as _sharedSanitizeUnicode,
} from '../../lib/feedback-loop.mjs';
import {
  buildIdentitySection, buildLanguageSection, buildPersonaSection,
  buildPrinciplesSection, buildFormatCoreSection, buildFormatDetailSection,
  buildFormatSection, buildToolsSection, buildToolsCodeDetailSection,
  buildSafetySection, buildUserContextSection,
  buildOwnerPreferencesSection, buildOwnerPersonaSection, buildOwnerVisualizationSection, buildFamilyBriefingContext,
  buildWikiContextSection, buildAngerCorrectionSection,
  buildHarnessAutoTriggerSection, buildFactsKeywordSection, buildEvidenceMandateSection,
  buildOwnerTimeContext,
} from './prompt-sections.js';
import { getPromptHarness, Tier } from './prompt-harness.js';
import { loadHandoff, formatHandoffForPrompt } from './session-handoff.js';
import { buildChannelFeedSection } from './channel-feed.js';
import { checkSensitivePath } from './security-guard.js';

import { recordSilentError } from './error-ledger.js';

// LLM Wiki 실시간 기록 — 대화 종료 시 facts를 위키에도 저장
let _addFactToWiki = null;
async function wikiAddFact(userId, fact, opts = {}) {
  try {
    if (!_addFactToWiki) {
      const mod = await import('./wiki-engine.mjs');
      _addFactToWiki = mod.addFactToWiki;
    }
    if (_addFactToWiki) {
      _addFactToWiki(userId, fact, { source: 'discord', ...opts });
    }
  } catch (err) { recordSilentError('claude-runner.wikiAddFact', err); }
}

// ─────────────────────────────────────────────────────────────────────────────
// Discord turn → mistake-extractor 학습 루프 (Surface Learning Equalization · P0)
// 비대칭 해소: CLI는 Stop 훅으로 추출되지만 Discord turn은 추출 안 됨 → 같은 편향 무한 재발.
// turn 종료 직후 setImmediate로 fire-and-forget. 응답 지연 0.
// ─────────────────────────────────────────────────────────────────────────────
export function triggerDiscordMistakeExtract(sessionSummaryFilePath) {
  setImmediate(async () => {
    try {
      const { spawn } = await import('node:child_process');
      const NODE_BIN = process.execPath;
      const SCRIPT = join(BOT_HOME, '..', 'infra', 'scripts', 'mistake-extractor.mjs');
      // BOT_HOME 미설정 시 기본 경로 fallback
      const scriptPath = existsSync(SCRIPT) ? SCRIPT : join(homedir(), 'jarvis/infra/scripts/mistake-extractor.mjs');
      if (!existsSync(scriptPath)) {
        recordSilentError('claude-runner.mistake-extract', new Error(`script not found: ${scriptPath}`));
        return;
      }
      if (!existsSync(sessionSummaryFilePath)) return; // 세션 요약이 아직 flush 안 됐으면 skip
      const child = spawn(NODE_BIN, [scriptPath, '--file', sessionSummaryFilePath], {
        detached: true,
        stdio: 'ignore',
        env: { ...process.env, DISCORD_TURN_SOURCE: '1' }, // ledger source 구분용
      });
      child.unref(); // 부모 프로세스 종료와 무관하게 진행
    } catch (err) {
      recordSilentError('claude-runner.mistake-extract', err);
    }
  });
}

// ---------------------------------------------------------------------------
// Feedback detection — recognize user signals for learning loop
// ---------------------------------------------------------------------------

// Phase 0.5: detect/process/sanitize 로직은 infra/lib/feedback-loop.mjs 로 추출 (표면 통합 SSoT).
// 여기서는 Discord 전용 부수효과(RAG sync) 주입하는 래퍼만 유지 — 외부 호출자(handlers.js 등) 하위호환 보장.

export const sanitizeUnicode = _sharedSanitizeUnicode;
export const detectFeedback = _sharedDetectFeedback;

/**
 * Discord용 processFeedback — RAG 마크다운 동기화 콜백을 묶어서 공통 모듈에 위임.
 * 외부 시그니처 (userId, text) 유지하여 기존 호출부 변경 없음.
 */
export function processFeedback(userId, text) {
  const { fb } = _sharedProcessFeedback({
    userId,
    text,
    source: 'discord-bot',
    onFactSaved: (uid) => _syncUserMemoryMarkdown(uid),
    onCorrectionSaved: () => { /* corrections는 RAG md에 포함 안 됨 — syncMarkdown 생략 */ },
  });
  if (fb) {
    if (fb.type === 'remember') log('info', 'Feedback: remember', { userId, fact: fb.fact?.slice(0, 100) });
    else if (fb.type === 'correction') log('info', 'Feedback: correction', { userId, fact: fb.fact?.slice(0, 100) });
    else log('info', `Feedback: ${fb.type}`, { userId });
  }
  return fb;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const BOT_HOME = join(process.env.BOT_HOME || join(HOME, 'jarvis/runtime'));
const MODELS = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'models.json'), 'utf-8'));
const DISCORD_MCP_PATH = join(BOT_HOME, 'config', 'discord-mcp.json');
const USER_PROFILE_PATH = join(BOT_HOME, 'context', 'user-profile.md');
const OWNER_PROFILE_PATH = join(BOT_HOME, 'context', 'owner', 'owner-profile.md');
const CONV_HISTORY_DIR = join(BOT_HOME, 'context', 'discord-history');

// 세션 기반 히스토리 파일 관리
// 봇 프로세스 1회 실행 = 세션 1개 = 파일 1개 (YYYY-MM-DD-HHMMSS.md)
// 이유: 하루 단위 파일(YYYY-MM-DD.md)은 250KB+까지 커져 RAG 인덱서가 파일당 100청크를 만들어 CPU 폭주
// 세션 단위로 쪼개면 자연스럽게 10~30KB 수준 → 캡 없이 완전 인덱싱 가능
let _currentSessionFile = null;
export function getSessionHistoryFile() {
  if (!_currentSessionFile) {
    const kst = new Date(Date.now() + 9 * 3600 * 1000);
    const dateStr = kst.toISOString().slice(0, 10);
    const timeStr = kst.toISOString().slice(11, 19).replace(/:/g, '');
    mkdirSync(CONV_HISTORY_DIR, { recursive: true });
    _currentSessionFile = join(CONV_HISTORY_DIR, `${dateStr}-${timeStr}.md`);
  }
  return _currentSessionFile;
}

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
// Load CHANNEL_PERSONAS from personas.json — self-healing on startup
// 1) Missing → auto-restore from backup + ntfy alert
// 2) Loaded OK → refresh backup to keep it current
// ---------------------------------------------------------------------------

const PERSONAS_PATH = join(import.meta.dirname, '..', 'personas.json');
const PERSONAS_BACKUP = join(BOT_HOME, 'state', 'config-backups', 'personas.json.backup');

let CHANNEL_PERSONAS = {};
(function loadPersonasWithSelfHeal() {
  // Step 1: auto-restore if file missing
  if (!existsSync(PERSONAS_PATH)) {
    log('error', '[INTEGRITY] personas.json missing — attempting auto-restore from backup');
    if (existsSync(PERSONAS_BACKUP)) {
      try {
        copyFileSync(PERSONAS_BACKUP, PERSONAS_PATH);
        log('info', '[INTEGRITY] personas.json restored from backup successfully');
        sendNtfy(
          '⚠️ personas.json 자동 복구',
          '봇 시작 시 personas.json 누락 감지 → 백업에서 복구 완료. 원인 점검 권고.',
          'high'
        ).catch(() => {});
      } catch (restoreErr) {
        log('error', '[INTEGRITY] personas.json restore failed', { error: restoreErr.message });
        sendNtfy('🚨 personas.json 복구 실패', '백업 복구 실패. 채널 페르소나 비활성화됨. 즉시 수동 조치 필요.', 'urgent').catch(() => {});
        return;
      }
    } else {
      log('error', '[INTEGRITY] personas.json AND backup both missing — channel personas DISABLED');
      sendNtfy('🚨 personas.json + 백업 모두 없음', '채널 페르소나 비활성화됨. 즉시 수동 복구 필요.', 'urgent').catch(() => {});
      return;
    }
  }

  // Step 2: load
  try {
    CHANNEL_PERSONAS = JSON.parse(readFileSync(PERSONAS_PATH, 'utf-8'));
    log('info', 'Channel personas loaded', {
      count: Object.keys(CHANNEL_PERSONAS).length,
      channels: Object.keys(CHANNEL_PERSONAS).join(', '),
    });
    // Step 3: refresh backup with current state so backup never goes stale
    try {
      mkdirSync(join(BOT_HOME, 'state', 'config-backups'), { recursive: true });
      copyFileSync(PERSONAS_PATH, PERSONAS_BACKUP);
    } catch (backupErr) {
      log('warn', '[INTEGRITY] personas.json backup refresh failed', { error: backupErr.message });
    }
  } catch (personasErr) {
    log('error', 'personas.json load/parse failed — channel personas disabled', { error: personasErr.message });
  }
})();

// ---------------------------------------------------------------------------
// Load USER_PROFILES from config/user_profiles.json
// Maps Discord user IDs to named profiles (owner, family, etc.)
// Env overrides: OWNER_DISCORD_ID, FAMILY_DISCORD_ID
// ---------------------------------------------------------------------------

let USER_PROFILES = {};
try {
  const userProfilesPath = join(BOT_HOME, 'config', 'user_profiles.json');
  USER_PROFILES = JSON.parse(readFileSync(userProfilesPath, 'utf-8'));
  if (process.env.OWNER_DISCORD_ID && USER_PROFILES.owner) {
    USER_PROFILES.owner.discordId = process.env.OWNER_DISCORD_ID;
  }
  if (process.env.FAMILY_DISCORD_ID && USER_PROFILES.family) {
    USER_PROFILES.family.discordId = process.env.FAMILY_DISCORD_ID;
  }
} catch {
  log('warn', 'user_profiles.json not found — single-user (owner) mode');
}

/**
 * Returns the profile for a Discord user ID, or null if not found.
 * Returns null (→ owner fallback) if discordId is empty/unset.
 */
export function getUserProfile(discordUserId) {
  if (!discordUserId) return null;
  return Object.values(USER_PROFILES).find(
    (p) => p.discordId && p.discordId === discordUserId,
  ) || null;
}

/**
 * user_profiles.json을 디스크에서 다시 읽어 USER_PROFILES를 갱신한다.
 * pair 승인 후 봇 재시작 없이 신규 사용자를 즉시 인식하기 위해 호출.
 */
export function reloadUserProfiles() {
  try {
    const userProfilesPath = join(BOT_HOME, 'config', 'user_profiles.json');
    const fresh = JSON.parse(readFileSync(userProfilesPath, 'utf-8'));
    if (process.env.OWNER_DISCORD_ID && fresh.owner) {
      fresh.owner.discordId = process.env.OWNER_DISCORD_ID;
    }
    if (process.env.FAMILY_DISCORD_ID && fresh.family) {
      fresh.family.discordId = process.env.FAMILY_DISCORD_ID;
    }
    // USER_PROFILES 내용을 새 데이터로 교체 (참조 유지)
    for (const k of Object.keys(USER_PROFILES)) delete USER_PROFILES[k];
    Object.assign(USER_PROFILES, fresh);
    log('info', '[pairing] user_profiles.json 핫 리로드 완료', { count: Object.keys(USER_PROFILES).length });
  } catch (err) {
    log('warn', '[pairing] user_profiles.json 핫 리로드 실패', { error: err.message });
  }
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
//
// RAG 오염 방지: "시뮬레이션 턴" 만 제외 (채널 전체가 아님).
// 모의면접 스킬이 활성화된 턴 → 답변이 Jarvis 가공한 시뮬레이션 이므로
// 실증 경험처럼 RAG 색인되면 자기 오염 루프 발생. 이런 턴만 배제.
// 일반 커리어 상담·이력서 피드백·이직 전략 등은 정상 저장 → RAG 활용.
//
// 판별: userMsg 에 슬래시 커맨드 또는 스킬 트리거 키워드가 포함됐는지 확인.
// ---------------------------------------------------------------------------

function _isSimulationTurn(userMsg) {
  if (!userMsg) return false;
  const text = userMsg.toLowerCase();
  // 슬래시 커맨드 형태 — ~/jarvis/runtime/skills/<name>.md 파일 존재 여부로 판정.
  // (claude-runner 상단의 fs/path/os 임포트를 공유)
  const slashMatch = userMsg.trim().match(/^\/([a-zA-Z0-9_-]+)/);
  if (slashMatch) {
    const skillPath = join(HOME, '.jarvis', 'skills', `${slashMatch[1]}.md`);
    if (existsSync(skillPath)) return true;
  }
  // 트리거 키워드 — 스킬 frontmatter triggers와 정합. 추가 스킬 생길 때 이 배열도 확장.
  // privacy:allow career-narratives — mock-interview 스킬 활성 트리거 (기능 필수, 서사 아님)
  const triggers = ['모의면접', '면접 연습', '면접 답변', '면접 준비', '면접관 해줘']; // privacy:allow career-narratives
  return triggers.some((t) => text.includes(t.toLowerCase()));
}

export function saveConversationTurn(userMsg, botMsg, channelName, userId = null) {
  if (_isSimulationTurn(userMsg)) {
    log('debug', 'Skipping conversation save (simulation turn)', { channelName });
    return;
  }
  const profile = userId ? getUserProfile(userId) : null;
  const senderName = profile?.name || 'Unknown';
  try {
    const now = new Date();
    const kst = new Date(now.getTime() + 9 * 3600 * 1000);
    const dateStr = kst.toISOString().slice(0, 10);
    const timeStr = kst.toISOString().slice(11, 16);
    const filePath = getSessionHistoryFile();
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
 * RAG는 키워드 연상 검색용이므로 마스킹해도 "destination-b 여행" 검색에는 지장 없음.
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

// User Memory 해시 캐시 — 메모리 내용 변화 없으면 getRelevantMemories 재호출 스킵
const memoryHashCache = new Map();

// 쿨다운: 유저별 마지막 추출 시각 (메모리 내, 재시작 시 초기화)
const _extractCooldown = new Map();
const EXTRACT_COOLDOWN_MS = 10 * 60 * 1000; // 10분
const EXTRACT_MIN_LEN = 150; // 봇 응답이 이 길이 이상일 때만 추출
const EXTRACT_COOLDOWN_MAX_ENTRIES = 500; // 메모리 누수 방지 상한

/**
 * 대화 내용에서 미래에 유용할 사실을 추출해 userMemory에 저장.
 * 메인 응답에 영향 없도록 비동기 fire-and-forget으로 호출.
 */
export async function autoExtractMemory(userId, userMsg, botMsg, channelId = null) {
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

  const FAMILY_CHANNEL_IDS = (process.env.FAMILY_CHANNEL_IDS || process.env.FAMILY_CHANNEL_ID || '').split(',').filter(Boolean);
  const isFamilyChannel = !!channelId && FAMILY_CHANNEL_IDS.includes(channelId);

  // family 채널 전용 추출 프롬프트 — Owner/시스템 데이터 오염 방지
  const prompt = isFamilyChannel ? [
    '다음은 가족 멤버(튜터 플랫폼 강사)와 AI 자비스의 대화입니다.',
    '가족 멤버에 대한 미래 대화에 유용한 구체적 사실만 추출해줘.',
    '기준: 학생 정보(이름/국적/수업시간), 가족, 여행 계획, 건강, 생활 이벤트, 선호 패턴.',
    '없으면 빈 배열 [].',
    '',
    '⚠️ 반드시 지킬 규칙:',
    '- 수업 건수/수입 금액 같은 날짜 종속 숫자는 추출하지 말 것 (다음날 틀림).',
    '- 봇 내부 시스템 메시지(⚠️ 데이터 미수신, --- 브리핑, userId: 등)는 추출 금지.',
    '- 개발/코딩/봇 인프라/주식/RAG 관련 내용은 가족 멤버 사실이 아님 — 추출 금지.',
    '- [2026-xx-xx] User: ... Jarvis: ... 형태의 대화 스니펫은 추출 금지.',
    '- 150자 이상 되는 사실은 추출 금지 (요약이 아닌 원문 복붙 방지).',
    '',
    '⭐ 중요도 점수 (1-5): 5=핵심 선호/제약, 4=구체적 계획/사람, 3=유용하지만 맥락적, 2=일시적, 1=자명.',
    '→ score 3 이상만 추출.',
    '',
    `<<가족 멤버 메시지>>\n${userMsg.slice(0, 400)}`,
    `<<자비스 응답>>\n${botMsg.slice(0, 600)}`,
    '',
    '출력 형식 (JSON 배열만, 다른 텍스트 없이 마지막 줄에):',
    '[{"fact":"사실1","score":4}, {"fact":"사실2","score":5}]',
  ].join('\n') : [
    '다음 대화에서 미래 대화에 도움될 구체적 사실을 추출해줘.',
    '기준: 사람 이름/일정/장소/선호/계획/결정 같은 구체적 정보. 일반 상식이나 자명한 사실 제외.',
    '없으면 빈 배열.',
    '',
    '⚠️ 금지 규칙 (반드시 준수):',
    '- 외부 게시판(Workgroup 등)의 다른 사용자 발언을 오너 사실로 기록하지 말 것.',
    '- 봇이 게시판 피드 내용을 요약·인용한 경우, 그 내용은 오너 발언이 아니다.',
    '- the user의 직접 발언인지 불명확하면 추출하지 않는다.',
    '- "오너의 계정명은 X다", "오너는 X를 선호한다" 형태는 오너가 직접 말한 경우에만 기록.',
    '',
    '⭐ 중요도 점수 (1-5, Mem0 패턴):',
    '- 5: 핵심 결정/선호/제약 (반복 참조 예상)',
    '- 4: 구체적 계획/일정/사람 정보',
    '- 3: 유용하지만 맥락 의존적',
    '- 2: 일시적 사실 (며칠 후 무의미)',
    '- 1: 자명하거나 일반적',
    '→ score 3 이상만 추출. 2 이하는 버린다.',
    '',
    `<<사용자>>\n${userMsg.slice(0, 500)}`,
    `<<봇>>\n${botMsg.slice(0, 800)}`,
    '',
    '출력 형식 (JSON 배열만, 다른 텍스트 없이 마지막 줄에):',
    '[{"fact":"사실1","score":4}, {"fact":"사실2","score":5}]',
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
          const FAMILY_JUNK_RE = /userid.*family|userid.*owner|userid.*boram|compacted at|사용자 의도|완료된 작업|미완 작업|핵심 참조|\[20\d\d-\d\d-\d\d \d\d:\d\d:\d\d\]/i;
          const IMPORTANCE_THRESHOLD = 3; // Mem0 패턴: score 3 이상만 저장
          let saved2 = 0;
          for (const item of facts2) {
            // 호환: {"fact":"...", "score":N} 형식 또는 기존 "string" 형식 둘 다 처리
            const f = typeof item === 'string' ? item : item?.fact;
            const score = typeof item === 'object' ? (item?.score ?? 5) : 5; // 기존 형식은 점수 5 기본
            if (!f || typeof f !== 'string') continue;
            if (f.length <= 5 || f.length >= 160) continue;
            if (isFamilyChannel && FAMILY_JUNK_RE.test(f)) continue;
            if (score < IMPORTANCE_THRESHOLD) {
              log('debug', 'Auto memory skipped (low importance)', { userId, fact: f.slice(0, 60), score });
              continue;
            }
            userMemory.addFact(userId, f, 'discord-auto-extract-sdk'); saved2++;
            wikiAddFact(userId, f); // LLM Wiki 실시간 기록
            log('info', 'Auto memory extracted (SDK)', { userId, fact: f.slice(0, 80), score });
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

    // Structured Outputs 또는 자유형 JSON 파싱 — [{fact, score}] 또는 ["string"] 호환
    let facts = null;
    try {
      const parsed = JSON.parse(result.trim());
      if (Array.isArray(parsed)) facts = parsed;
    } catch { /* invalid JSON — skip */ }
    if (!facts) {
      log('debug', 'autoExtractMemory: no valid JSON array found', { userId, raw: result.slice(-150) });
      return;
    }

    const FAMILY_JUNK_RE2 = /userid.*family|userid.*owner|userid.*boram|compacted at|사용자 의도|완료된 작업|미완 작업|핵심 참조|\[20\d\d-\d\d-\d\d \d\d:\d\d:\d\d\]/i;
    const IMPORTANCE_THRESHOLD2 = 3;
    let saved = 0;
    for (const item of facts) {
      const fact = typeof item === 'string' ? item : item?.fact;
      const score = typeof item === 'object' ? (item?.score ?? 5) : 5;
      if (!fact || typeof fact !== 'string') continue;
      if (fact.length <= 5 || fact.length >= 160) continue;
      if (isFamilyChannel && FAMILY_JUNK_RE2.test(fact)) continue;
      if (score < IMPORTANCE_THRESHOLD2) {
        log('debug', 'Auto memory skipped (low importance)', { userId, fact: fact.slice(0, 60), score });
        continue;
      }
      userMemory.addFact(userId, fact, 'discord-auto-extract');
      wikiAddFact(userId, fact);
      saved++;
      log('info', 'Auto memory extracted', { userId, fact: fact.slice(0, 80), score });
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
  sessionId, threadId, channelId, channelName, ragContext, attachments = [],
  contextBudget, userId, signal,
  injectedSummary = '',
  _budgetMode = 'normal',  // Progressive Compaction: 'normal' | 'lean'
} = {}) {
  // 0. 슬래시 커맨드 인터셉터 — `/skillname args` 형태면 스킬 로드 + 인자를 프롬프트로
  // CLI의 `/mock-interview 삼성물산` 경험을 디스코드에서도 동일하게 제공 (SSoT 공유).
  let _injectedSkillBody = null;
  try {
    const { matchSkillByCommand } = await import('./skill-loader.js');
    const cmd = matchSkillByCommand(prompt);
    if (cmd) {
      _injectedSkillBody = { name: cmd.skill.name, body: cmd.skill.body };
      prompt = cmd.args || '시작해줘';
      log('info', 'Slash command skill invoked', { skill: cmd.skill.name, args: cmd.args });
    }
  } catch (cmdErr) {
    log('warn', 'Slash command interceptor failed (non-critical)', { error: cmdErr.message });
  }

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

  // 3a. Load owner preferences (5-minute cache) — injected into Stable prompt
  //     context/owner/preferences.md: tool/service constraints (calendar, tasks, etc.)
  if (!createClaudeSession._ownerPrefsCache || nowMs - (createClaudeSession._ownerPrefsCacheTime || 0) > 300_000) {
    try {
      const BOT_HOME_EARLY = process.env.BOT_HOME || `${homedir()}/jarvis/runtime`;
      createClaudeSession._ownerPrefsCache = buildOwnerPreferencesSection({ botHome: BOT_HOME_EARLY });
    } catch {
      createClaudeSession._ownerPrefsCache = '';
    }
    createClaudeSession._ownerPrefsCacheTime = nowMs;
  }

  const ownerName = process.env.OWNER_NAME || 'Owner';
  const ownerTitle = process.env.OWNER_TITLE || 'Owner';
  const githubUsername = process.env.GITHUB_USERNAME || 'user';

  // 4. Detect active user — null → guest (NOT owner fallback)
  const activeUserProfile = getUserProfile(userId);
  const isOwner = activeUserProfile?.type === 'owner' || activeUserProfile?.role === 'owner';
  const isGuest = !activeUserProfile;
  try {
    const { appendFileSync } = await import('node:fs');
    appendFileSync('/tmp/jarvis-guard-debug.log',
      `  → createClaudeSession | userId=${userId} | activeProfile=${activeUserProfile ? JSON.stringify({role:activeUserProfile.role,name:activeUserProfile.name}) : 'null'} | isOwner=${isOwner} | isGuest=${isGuest}\n`
    );
  } catch {}

  // 4a. Build user context section (SSoT: prompt-sections.js)
  const userContextParts = buildUserContextSection({
    activeUserProfile,
    ownerName,
    ownerTitle,
    githubUsername,
    profileCache: createClaudeSession._profileCache,
  });

  const BOT_HOME = process.env.BOT_HOME || `${homedir()}/jarvis/runtime`;

  // 5. Build system prompt — Prompt Harness (Tiered Lazy Loading)
  //    Tier 0: 항상 로드 (<3KB) — identity, language, persona, principles, format-core, tools, safety
  //    Tier 1: 키워드 매칭 시만 — format-detail (비교/차트/표 관련 쿼리)
  // Harness 섹션 등록 (싱글톤 + 등록 완료 플래그로 레이스 컨디션 방지)
  const harness = getPromptHarness();
  if (!createClaudeSession._harnessRegistered) {
    createClaudeSession._harnessRegistered = true; // 원자적 플래그 — 동시 호출에서 중복 등록 방지
    // Tier 0 — 항상 로드 (등록 순서가 session hash에 영향 — 변경 금지)
    harness.register('identity', Tier.CORE, () => buildIdentitySection({ botName: process.env.BOT_NAME, ownerName }));
    harness.register('language', Tier.CORE, () => buildLanguageSection());
    harness.register('persona', Tier.CORE, () => buildPersonaSection({ ownerName }));
    harness.register('principles', Tier.CORE, () => buildPrinciplesSection());
    harness.register('format-core', Tier.CORE, () => buildFormatCoreSection());
    harness.register('tools', Tier.CORE, () => buildToolsSection({ botHome: BOT_HOME }));
    harness.register('safety', Tier.CORE, () => buildSafetySection({ botHome: BOT_HOME }));
    // Tier 1 — 키워드 매칭 시만 로드
    harness.register('format-detail', Tier.CONTEXTUAL, () => buildFormatDetailSection(),
      /비교|vs|차이점|장단점|표|차트|그래프|추이|트렌드|TABLE|CHART|CV2|Mermaid|다이어그램|플로우/i);
    // 2026-04-26: 코드 키워드 시 Serena 5단계 풀 가이드 주입 (월 누수 차단)
    harness.register('tools-code-detail', Tier.CONTEXTUAL, () => buildToolsCodeDetailSection(),
      /코드|함수|클래스|구현|버그|디버깅|리팩터|컴포넌트|모듈|메서드|클래스|\.tsx?|\.jsx?|\.mjs|\.py|jarvis-board|VirtualOffice|TeamBriefingPopup|canvas-draw|prompt-sections|claude-runner|handlers\.js/i);
  }

  // 토큰 예산 모드: Progressive Compaction에서 전달
  const _tokenBudgetMode = _budgetMode || 'normal';
  const { prompt: harnessPrompt, loadedSections } = harness.assemble(prompt, { budgetMode: _tokenBudgetMode });

  const systemParts = [
    harnessPrompt,
    // ── 사용자 컨텍스트 ──────────────────────────────────────────────────────
    ...userContextParts,
  ];

  // Channel-specific persona
  const channelPersona = channelId ? CHANNEL_PERSONAS[channelId] : null;
  if (channelPersona) {
    // Owner가 family 채널에 접근한 경우: family 페르소나 대신 Owner 컨텍스트 우선
    // (Owner userId 기반 정확한 감지 — 3인칭 패턴 의존 제거)
    const FAMILY_CHANNEL_ID = process.env.FAMILY_CHANNEL_ID || '';
    if (channelId === FAMILY_CHANNEL_ID && isOwner) {
      systemParts.push(
        '',
        `--- Owner가 family 채널에서 대화 중 ---`,
        `지금 메시지는 가족 멤버가 아닌 Owner(${ownerName}님)가 보낸 것입니다.`,
        `가족 멤버 페르소나(반말 금지·💕 이모지 등)로 응답하지 말 것.`,
        `이 채널은 가족 멤버가 보는 채널이므로 가족 멤버에 대한 제3자 언급은 신중히.`,
        `Owner 대상 일반 대화 원칙으로 응답.`,
        `참고 — 가족 멤버 채널 페르소나:\n${channelPersona}`,
      );
    } else {
      systemParts.push('', channelPersona);
    }
  }

  // ---------------------------------------------------------------------------
  // 공통 스킬 주입 (~/jarvis/runtime/skills/) — CLI·Discord·Mac 앱이 SSoT로 공유
  // 주입 우선순위:
  //   1) 슬래시 커맨드 (`/skillname args`) — 명시적, 최우선
  //   2) 채널 매칭 (skill의 channels에 현재 채널 포함)
  //   3) 트리거 키워드 매칭 (자연어 발화 중 키워드 포함)
  // 중복은 스킬 이름 기준으로 제거.
  //
  // 성능 최적화: mock-interview 의 경우 handlers.js 가 이미 질문 유형별 가이드 +
  // RAG 컨텍스트 + 엄격 규칙을 userPrompt 에 넣어줌. 스킬 본문(4200자) 중복 주입은
  // 낭비이므로 mock-interview 는 skill-loader 단계에서 스킵.
  // ---------------------------------------------------------------------------
  try {
    const { matchSkills } = await import('./skill-loader.js');
    const injected = new Set();
    const SKIP_SKILLS_WHEN_INLINE = new Set(['mock-interview']);
    if (_injectedSkillBody && !SKIP_SKILLS_WHEN_INLINE.has(_injectedSkillBody.name)) {
      systemParts.push('', `--- 스킬 활성화: ${_injectedSkillBody.name} (슬래시 커맨드) ---\n${_injectedSkillBody.body}`);
      injected.add(_injectedSkillBody.name);
      log('info', 'Skill injected via slash', { skill: _injectedSkillBody.name });
    } else if (_injectedSkillBody) {
      log('info', 'Skill body skipped (handled inline in handlers.js)', { skill: _injectedSkillBody.name });
    }
    const matchedSkills = matchSkills({ channelName, messageText: prompt });
    for (const { skill, byChannel, byTrigger } of matchedSkills) {
      if (injected.has(skill.name)) continue;
      if (SKIP_SKILLS_WHEN_INLINE.has(skill.name)) continue;
      const reason = byChannel ? `채널: ${channelName}` : `트리거 키워드`;
      systemParts.push('', `--- 스킬 활성화: ${skill.name} (${reason}) ---\n${skill.body}`);
      injected.add(skill.name);
      log('info', 'Skill injected', { skill: skill.name, reason, channelName });
    }
  } catch (skillErr) {
    log('warn', 'Skill loader failed (non-critical)', { error: skillErr.message });
  }

  // Owner system preferences (Stable) — survives session resets & bot restarts
  // Only injected for owner to avoid bloating non-owner sessions
  if (isOwner) {
    // Persona & behaviour rules (anti-bias, root-cause, clarification, self-learning)
    const personaSection = buildOwnerPersonaSection({ botHome: BOT_HOME });
    if (personaSection) systemParts.push('', personaSection);

    // Operational preferences (tool constraints, scheduling rules, etc.)
    if (createClaudeSession._ownerPrefsCache) {
      systemParts.push('', createClaudeSession._ownerPrefsCache);
    }

    // Visual output design policy (AI Slop prevention) — applies to Discord cards, jarvis-board, etc.
    const visualizationSection = buildOwnerVisualizationSection({ botHome: BOT_HOME });
    if (visualizationSection) systemParts.push('', visualizationSection);

  }

  // Session version check: compute hash from STABLE systemParts (persona + user context only).
  // memSnippet and usageSummary are intentionally excluded:
  //   - memSnippet changes on every memory addition → would force new session every turn
  //   - usageSummary contains time-varying data ("리셋 Xm 후") → same issue
  // Session hash: Tier 0(Core) 섹션만으로 계산 — Tier 1은 쿼리마다 달라지므로 제외
  const stableSystemPrompt = harness.assembleCoreOnly();
  const promptVersion = createHash('md5').update(stableSystemPrompt).digest('hex').slice(0, 8);

  // Dynamic sections: injected after hash (don't affect session continuity)

  // family 채널 브리핑 컨텍스트 — 오늘 브리핑이 발송된 경우 수업 데이터 주입
  // webhook 발송 메시지는 대화 히스토리에 없으므로 LLM이 수치를 지어내는 것을 방지
  if (channelId) {
    const FAMILY_CHANNEL_ID_BR = process.env.FAMILY_CHANNEL_ID || '';
    if (channelId === FAMILY_CHANNEL_ID_BR) {
      const briefingCtx = buildFamilyBriefingContext({ botHome: BOT_HOME });
      if (briefingCtx) systemParts.push('', briefingCtx);
    }
  }

  // Per-user long-term memory (added AFTER hash — memory updates don't force session reset)
  if (userId) {
    let memSnippet;
    try {
      // 해시 캐싱: 메모리 내용 변화 없고 토큰 여유 있으면 캐시된 결과 재사용
      const rawMemData = userMemory.get(userId);
      const rawMemStr = JSON.stringify(rawMemData);
      const currentHash = createHash('md5').update(rawMemStr).digest('hex');
      const cached = memoryHashCache.get(userId);
      if (cached && cached.hash === currentHash) {
        memSnippet = cached.snippet;
      } else {
        if (prompt) {
          memSnippet = userMemory.getRelevantMemories(userId, prompt);
        } else {
          memSnippet = userMemory.getPromptSnippet(userId);
        }
        memoryHashCache.set(userId, { hash: currentHash, snippet: memSnippet });
      }
    } catch {
      memSnippet = userMemory.getPromptSnippet(userId);
    }
    if (memSnippet) systemParts.push('', '--- 사용자 기억 (User Memory) ---', memSnippet);
  }

  // Channel feed context (dynamic — 채널에 최근 전송된 봇/크론/알람 메시지)
  // 사용자가 "방금 크론이 보낸 거 뭐야?" 등 채널 컨텍스트를 참조할 때 재질문 방지
  if (channelName) {
    const feedCtx = buildChannelFeedSection(channelName, 15);
    if (feedCtx) systemParts.push('', feedCtx);
  }

  // Session Handoff (dynamic — 이전 세션의 구조화된 상태 전달)
  // Anthropic Sensors 패턴: compacted summary보다 정확한 토픽/결정/미완료 전달
  // sessionKey는 handlers.js와 동일 구성: threadId-userId (thread 기반) 또는 channelId-userId
  {
    const handoffKey = `${threadId}-${userId}`;
    const handoff = loadHandoff(handoffKey);
    const handoffText = formatHandoffForPrompt(handoff);
    if (handoffText) systemParts.push('', handoffText);
  }

  // LLM Wiki context (dynamic — 세션 해시 영향 없음)
  // 2-track: 전역 도메인 위키 + 사용자 개인 페이지(pages/{userId}/)
  if (userId && isOwner && prompt) {
    const wikiCtx = buildWikiContextSection({ prompt, botHome: BOT_HOME, userId });
    if (wikiCtx) systemParts.push('', wikiCtx);
  }

  // 🔍 가드 #5 (2026-04-29): _facts.md 키워드 매칭 자동 발췌
  // SSoT Cross-Link 봉쇄 해소 — career/_summary.md로 _facts.md 4000줄이
  // 영구 invisible이던 사고 영구 차단. 사용자 발화 키워드 → _facts grep top 8.
  if (isOwner && prompt) {
    try {
      const factsCtx = buildFactsKeywordSection({ prompt, botHome: BOT_HOME });
      if (factsCtx) systemParts.push('', factsCtx);
    } catch { /* best-effort */ }
  }

  // 🛡️ 가드 #9 (2026-04-29) — 실측 의무 트리거 (Evidence Mandate)
  // 사용자 prompt가 인프라/시스템 검토 카테고리(딥다이브·검토·분석·왜·메카니즘 등)면
  // 시스템 프롬프트에 실측 의무 룰 강제 prepend → 거짓 단정 패턴 6건 인프라 차원 차단.
  // 가드 #10(단정 표현 검출)과 함께 동작 — prepend된 룰을 LLM이 보면 단정 자체가 줄어듦.
  if (isOwner && prompt) {
    try {
      const evidenceMandate = buildEvidenceMandateSection({ prompt });
      if (evidenceMandate) systemParts.push('', evidenceMandate);
    } catch { /* best-effort */ }
  }

  // 🕐 오너 시간 컨텍스트 — KST 현재시각 + 마지막 활동 경과시간 + 수면 패턴
  // Dynamic section: 세션 해시에 영향 없음. 파일 없어도 봇 크래시 없음.
  if (isOwner) {
    try {
      const timeCtx = buildOwnerTimeContext({ botHome: BOT_HOME });
      if (timeCtx) systemParts.push('', timeCtx);
    } catch { /* best-effort */ }
  }

  // 🚨 직전 정정 신호 (Harness P2) — 24h 이내 분노 신호 1건 강제 주입
  // learned-mistakes top5 캡 밖이라도 즉시 LLM에 노출하여 같은 편향 재발 차단.
  if (isOwner) {
    const angerSection = buildAngerCorrectionSection({ botHome: BOT_HOME });
    if (angerSection) systemParts.push('', angerSection);
  }

  // 🔧 가드 #2 (2026-04-28) 자동 하네스 트리거 — "동작 원리/메커니즘" 류 키워드 매칭 시
  //   관련 cross-check 스크립트 자동 실행 → 결과를 system prompt에 강제 주입.
  //   LLM이 페르소나 자연어 룰만 보고 코드 SSoT 누락하는 거짓 답변 차단.
  if (isOwner) {
    try {
      const harnessSection = await buildHarnessAutoTriggerSection(prompt);
      if (harnessSection) systemParts.push('', harnessSection);
    } catch { /* best-effort */ }
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
    // Channel feed: resume 시에도 최신 채널 활동 주입 (세션 연속성과 무관하게 매턴 갱신)
    // limit=5 — 토큰 절약. cron/alert만 의미 있는 컨텍스트이므로 최근 5개로 충분
    if (channelName) {
      const feedCtx = buildChannelFeedSection(channelName, 5);
      if (feedCtx) ctxParts.push(feedCtx);
    }
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
      const names = attachments.map((a) => join(stableDir, a.safeName)).join(', ');
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
      const names = attachments.map((a) => join(stableDir, a.safeName)).join(', ');
      systemParts.push('', `--- 첨부 이미지 ---\n사용자가 이미지를 첨부했습니다: ${names}\nRead 도구로 파일을 열어 분석하세요.`);
    }
  }

  // 6. 모델 선택
  // jarvis-lite(small) → Haiku (빠른 응답, 50턴)
  // channelOverrides에 등록된 채널 → 지정 모델 (직접 실행, opusplan 아님)
  // 그 외 → opusplan (계획 Opus, 실행 Sonnet, 200턴)
  // P2-2: ADAPTIVE_MODEL_ENABLED=1 이면 프롬프트 분류로 trivial → fast 다운그레이드.
  const maxTurns = contextBudget === 'small' ? 50 : 200;
  let channelModelKey = channelName && MODELS.channelOverrides?.[channelName];
  if (process.env.ADAPTIVE_MODEL_ENABLED === '1' && contextBudget !== 'small' && channelModelKey) {
    try {
      const { resolveModelTier } = await import('./adaptive-model.js');
      const resolved = resolveModelTier(channelModelKey, prompt);
      if (resolved.downgraded) {
        log('info', 'adaptive-model: downgraded', {
          from: channelModelKey, to: resolved.tier, reason: resolved.reason,
          channelName, promptLen: prompt.length,
        });
        channelModelKey = resolved.tier;
      }
    } catch (err) {
      log('warn', 'adaptive-model routing failed (using base tier)', { error: err.message });
    }
  }
  const model = contextBudget === 'small' ? MODELS.fast : (channelModelKey ? MODELS[channelModelKey] : 'opusplan');

  // 7. Load MCP server config (same servers, now as SDK mcpServers object)
  // 우선순위: discord-mcp.json > ~/.mcp.json (nexus, serena, serena-board 필터)
  // ${ENV_VAR} 형식의 env var를 실제 값으로 치환 지원 (GITHUB_TOKEN 등)
  //
  // 성능 최적화: mock-interview 스킬이 활성화된 턴은 MCP 전부 스킵.
  // - 이유 1: 면접 답변 생성에 RAG/serena/github 도구 불필요 (스킬 본문만으로 충분)
  // - 이유 2: MCP 서버 초기화가 첫 쿼리에 5~10초 오버헤드
  // - 이유 3: 도구가 로드되면 모델이 RAG 호출을 고민하다 지연 증가
  let mcpServers = {};
  const _isMockInterviewTurn = _injectedSkillBody?.name === 'mock-interview' ||
    /모의면접|면접\s*연습|면접\s*답변|면접관\s*해줘/.test(prompt);
  if (_isMockInterviewTurn) {
    log('info', 'MCP servers skipped for mock-interview turn (speed optimization)');
  } else try {
    const rawMcp = readFileSync(DISCORD_MCP_PATH, 'utf-8')
      .replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] ?? '');
    mcpServers = (JSON.parse(rawMcp)).mcpServers ?? {};
  } catch {
    // discord-mcp.json 없으면 ~/.mcp.json에서 봇에 필요한 서버만 필터링
    const BOT_MCP_ALLOWLIST = ['nexus', 'serena', 'serena-board'];
    try {
      const globalMcp = JSON.parse(readFileSync(join(HOME, '.mcp.json'), 'utf-8'));
      const allServers = globalMcp.mcpServers ?? {};
      for (const name of BOT_MCP_ALLOWLIST) {
        if (allServers[name]) mcpServers[name] = allServers[name];
      }
      if (Object.keys(mcpServers).length > 0) {
        log('info', 'MCP fallback: loaded from ~/.mcp.json', { servers: Object.keys(mcpServers) });
      } else {
        log('warn', 'No MCP servers found in discord-mcp.json or ~/.mcp.json — MCP disabled');
      }
    } catch {
      log('warn', 'No MCP config found (discord-mcp.json / ~/.mcp.json) — MCP disabled');
    }
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
      'mcp__nexus__discord_send', 'mcp__nexus__run_cron', 'mcp__nexus__get_memory',
      'mcp__nexus__list_crons', 'mcp__nexus__dev_queue', 'mcp__nexus__context_bus',
      'mcp__nexus__emit_event', 'mcp__nexus__usage_stats',
      'mcp__nexus__wg_me', 'mcp__nexus__wg_feed', 'mcp__nexus__wg_get_post',
      'mcp__nexus__wg_comment', 'mcp__nexus__wg_create_post',
      // activate_project 제거: 공유 SSE 서버에서 프로젝트 전환 시 동시 세션 컨텍스트 충돌 위험
      'mcp__serena__check_onboarding_performed',
      'mcp__serena__find_symbol', 'mcp__serena__get_symbols_overview',
      'mcp__serena__search_for_pattern', 'mcp__serena__find_referencing_symbols',
      'mcp__serena__read_memory', 'mcp__serena__write_memory', 'mcp__serena__find_file',
      'mcp__serena__replace_symbol_body', 'mcp__serena__insert_after_symbol',
      'mcp__serena__insert_before_symbol',
      // serena-board: jarvis-board 워크스페이스 (자비스맵 등 코드 접근)
      'mcp__serena-board__check_onboarding_performed',
      'mcp__serena-board__find_symbol', 'mcp__serena-board__get_symbols_overview',
      'mcp__serena-board__search_for_pattern', 'mcp__serena-board__find_referencing_symbols',
      'mcp__serena-board__read_memory', 'mcp__serena-board__write_memory', 'mcp__serena-board__find_file',
      'mcp__serena-board__replace_symbol_body', 'mcp__serena-board__insert_after_symbol',
      'mcp__serena-board__insert_before_symbol',
    ],
    // Phase 0 Sensor (재설계 2026-04-17): canUseTool → PreToolUse 훅 전환.
    // 이유: SDK 'default' 모드에서 내부 'allow' 판정된 tool은 canUseTool 콜백을
    //      아예 호출하지 않아 Read/Glob/Grep 등 대부분 tool에 대한 민감 경로 검사
    //      bypass 가능. PreToolUse 훅은 SDK 내부 판정과 무관하게 모든 tool에 발화.
    //
    // 2026-04-20: 'default' → 'bypassPermissions'.
    //   SDK 내장 센서티브 리스트(~/.claude/** 등)가 권한 프롬프트를 띄우는데
    //   Discord 봇에는 승인 UI가 없어 자동 거부 처리됨 → 정당한 작업(.claude/
    //   commands/* archive 이동 등)도 막힘. bypassPermissions 로 SDK 내장 체크
    //   우회. 진짜 민감 경로(.env / .ssh/id_* / secrets/*) 차단은 아래 PreToolUse
    //   훅의 security-guard.js 가 단일 책임(SSoT)으로 보증.
    permissionMode: 'bypassPermissions',
    hooks: {
      PreToolUse: [{
        hooks: [async (input) => {
          // (2026-04-22 제거) MAX_TOOL_CALLS=8 하드코딩 가드 삭제.
          // 이유: 오너 지시로 조사형 세션에서 턴당 8회 제한이 실사용을 가로막음.
          // handlers.js:95 주석과 SSoT 동기화 — SDK maxTurns(200) + 10분 timeout +
          // maxBudget이 이미 폭주를 차단. 단일 책임은 MAX_CONTINUATIONS=5(handlers.js).
          // 2026-04-26: Read on 큰 코드 파일 → Serena 강제 전환 (월 누수 차단)
          try {
            if (input.tool_name === 'Read' && input.tool_input?.file_path) {
              const fp = String(input.tool_input.file_path);
              const isCode = /\.(tsx?|jsx?|mjs|cjs|py)$/i.test(fp);
              if (isCode) {
                try {
                  const st = statSync(fp);
                  if (st.size > 80_000) { // ~1500줄 이상
                    log('warn', 'PreToolUse: Read code 통째 차단 → Serena 권고', { fp: fp.slice(-80), size: st.size });
                    return {
                      hookSpecificOutput: {
                        hookEventName: 'PreToolUse',
                        permissionDecision: 'deny',
                        permissionDecisionReason: `코드 파일(${st.size} bytes ≈ 1500줄 이상)은 mcp__serena__get_symbols_overview → find_symbol(include_body=true)로 접근하세요. Read는 .md/.json/짧은 설정만.`,
                      },
                    };
                  }
                } catch { /* statSync 실패 시 fail-open */ }
              }
            }
          } catch (err) {
            log('error', 'PreToolUse Read-guard threw (fail-open)', { error: err?.message });
          }

          try {
            const blocked = checkSensitivePath(input.tool_name, input.tool_input);
            if (blocked) {
              log('warn', 'PreToolUse: denied (sensitive path)', {
                tool: input.tool_name, blocked: String(blocked).slice(0, 160),
              });
              try {
                const ledgerDir = join(HOME, 'jarvis/runtime', 'state');
                mkdirSync(ledgerDir, { recursive: true });
                appendFileSync(
                  join(ledgerDir, 'permission-denied.jsonl'),
                  JSON.stringify({
                    ts: new Date().toISOString(),
                    source: 'discord-bot',
                    tool: input.tool_name,
                    blocked: String(blocked).slice(0, 160),
                  }) + '\n'
                );
              } catch { /* ledger best-effort */ }
              return {
                hookSpecificOutput: {
                  hookEventName: 'PreToolUse',
                  permissionDecision: 'deny',
                  permissionDecisionReason: `민감 경로 차단: ${String(blocked).slice(0, 120)}`,
                },
              };
            }
          } catch (err) {
            // 훅 자체 오류 시 fail-open (봇 먹통 방지 우선). 로그로 감지 가능하게 기록.
            log('error', 'PreToolUse hook threw (fail-open)', { error: err?.message });
          }
          return { continue: true };
        }],
        timeout: 5,
      }],
    },
    mcpServers,
    maxTurns,
    model,
    // effort: channelName 우선 → channelId fallback (사용자가 채널 ID로 직접 등록 가능)
    ...((() => {
      const effortKey = (channelName && MODELS.effortOverrides?.[channelName])
                       || (channelId && MODELS.effortOverrides?.[channelId]);
      return effortKey ? { effort: effortKey } : {};
    })()),
    // inference_geo: 환경변수 설정 시에만 적용 (미설정 시 Anthropic 기본 라우팅)
    ...(process.env.INFERENCE_GEO ? { inference_geo: process.env.INFERENCE_GEO } : {}),
    includePartialMessages: true,
  };

  // 1M 토큰 컨텍스트 항상 활성화
  if (!queryOptions.betas) queryOptions.betas = [];
  if (!queryOptions.betas.includes('context-1m-2025-08-07')) {
    queryOptions.betas.push('context-1m-2025-08-07');
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
  // 300s: ultrathink/복잡 요청 대응 (180s → 300s 2026-03-25)
  const SESSION_TIMEOUT_MS = 300_000;

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

  // Lone surrogate 살균 — API 400 "invalid high surrogate" 방지
  // effectivePrompt와 systemPrompt 양쪽 모두 처리 (RAG snippet, memory 등 외부 출처 포함)
  effectivePrompt = sanitizeUnicode(effectivePrompt);
  if (queryOptions.systemPrompt) {
    queryOptions.systemPrompt = sanitizeUnicode(queryOptions.systemPrompt);
  }

  // Harness P1: System prompt 실측 dump
  // 매 turn 시스템 프롬프트의 실제 char/section 통계를 snapshot 파일에 덮어쓰기.
  // 추정 금지 — 실측 강제. dump-system-prompt.mjs 또는 grep으로 확인 가능.
  // 비활성화: env JARVIS_PROMPT_DUMP_DISABLE=1
  if (process.env.JARVIS_PROMPT_DUMP_DISABLE !== '1' && queryOptions.systemPrompt) {
    try {
      const snapPath = join(BOT_HOME, 'state', 'system-prompt-snapshot.md');
      const sysPrompt = queryOptions.systemPrompt;
      const ts = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
      const sections = sysPrompt.split(/\n(?=---|###)/g);
      const snapshot = `# System Prompt Snapshot (Harness P1)
ts: ${ts} KST
total_chars: ${sysPrompt.length}
total_estimated_tokens: ${Math.round(sysPrompt.length / 4)}
section_count: ${sections.length}
prompt_chars: ${(effectivePrompt || '').length}
user_id: ${userId || 'n/a'}
channel_id: ${channelId || 'n/a'}
session_id: ${sessionId || 'n/a'}
thread_id: ${threadId || 'n/a'}

---

${sysPrompt}
`;
      writeFileSync(snapPath, snapshot, 'utf-8');
    } catch (err) {
      recordSilentError('claude-runner.prompt-dump', err);
    }
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
        log('warn', 'createClaudeSession: 300s inactivity — grace check', { threadId });
        const graceResult = await Promise.race([
          iterResult.pendingNext,
          new Promise((r) => setTimeout(() => r({ timedOut: true }), 500)),
        ]);
        if (!graceResult.timedOut) {
          // Grace 기간 내 응답 도착 — 정상 처리
          iterResult = graceResult;
        } else {
          log('error', 'createClaudeSession: confirmed inactivity timeout (300s)', { threadId });
          if (!signal?.aborted) {
            yield {
              type: 'result',
              result: '요청 처리 시간이 초과되었습니다 (5분). 복잡한 요청이거나 API 응답이 지연된 것 같습니다. 잠시 후 다시 시도해주세요.',
              is_error: true,
              error: 'Session inactivity timeout (300s)',
            };
          }
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