/**
 * Claude subprocess management: spawn, stream parsing, RAG, conversation history.
 * Also provides shared logging and ntfy notification utilities (absorbed from logger.js).
 *
 * Exports: spawnClaude, parseStreamEvents, execRagAsync, saveConversationTurn,
 *          sendNtfy, log, ts
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
import { join, resolve, extname } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

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
    // Fallback: raw memory.md (first 1500 chars)
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

export function saveConversationTurn(userMsg, botMsg, channelName) {
  const ownerName = process.env.OWNER_NAME || 'Owner';
  try {
    mkdirSync(CONV_HISTORY_DIR, { recursive: true });
    const now = new Date();
    const kst = new Date(now.getTime() + 9 * 3600 * 1000);
    const dateStr = kst.toISOString().slice(0, 10);
    const timeStr = kst.toISOString().slice(11, 16);
    const filePath = join(CONV_HISTORY_DIR, `${dateStr}.md`);
    const botName = process.env.BOT_NAME || 'Claude Bot';
    const entry = `\n## [${dateStr} ${timeStr} KST] #${channelName}\n\n**${ownerName}**: ${userMsg.slice(0, 600)}\n\n**${botName}**: ${botMsg.slice(0, 1800)}\n\n---\n`;
    appendFileSync(filePath, entry, 'utf-8');
  } catch (err) {
    log('warn', 'Failed to save conversation turn', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// spawnClaude — subprocess with 4-layer token isolation
// ---------------------------------------------------------------------------

export function spawnClaude(prompt, { sessionId, threadId, channelId, ragContext, attachments = [], contextBudget } = {}) {
  const stableDir = join('/tmp', 'claude-discord', String(threadId));
  mkdirSync(stableDir, { recursive: true });

  // Fake .git/HEAD so claude treats it as a repo root (prevents upward traversal)
  const gitDir = join(stableDir, '.git');
  mkdirSync(gitDir, { recursive: true });
  writeFileSync(join(gitDir, 'HEAD'), 'ref: refs/heads/main\n');

  // Copy attachment files into workDir so Claude can Read them
  for (const { localPath, safeName } of attachments) {
    try { copyFileSync(localPath, join(stableDir, safeName)); } catch { /* ignore */ }
  }

  // Empty plugins dir
  mkdirSync(join(stableDir, '.empty-plugins'), { recursive: true });

  // Owner info from env
  const ownerName = process.env.OWNER_NAME || 'Owner';
  const ownerTitle = process.env.OWNER_TITLE || 'Owner';
  const githubUsername = process.env.GITHUB_USERNAME || 'user';

  // Load user profile (refresh every 5 minutes)
  const now = Date.now();
  if (!spawnClaude._profileCache || now - (spawnClaude._cacheTime || 0) > 300_000) {
    try {
      spawnClaude._profileCache = readFileSync(USER_PROFILE_PATH, 'utf-8');
    } catch {
      spawnClaude._profileCache = '';
    }
    spawnClaude._cacheTime = now;
  }

  const systemParts = [
    // Core identity
    `당신의 이름은 ${process.env.BOT_NAME || 'Jarvis'}입니다. ${ownerName}님의 개인 AI 어시스턴트입니다.`,
    '중요: 절대 스스로를 "Claude"라고 소개하거나 지칭하지 마세요. Claude는 내부 엔진일 뿐, 당신의 이름이 아닙니다. "저는 Jarvis입니다"라고만 하세요.',
    '존댓말(공손체) 기본. 간결하고 실용적으로 답한다. 한국어로 응답.',
    '',
    // Persona rules
    '## 페르소나',
    '토니 스타크의 자비스처럼 — 유능하고 따뜻하되, 아첨하지 않는 집사.',
    '- 정우님을 진심으로 아끼는 조력자. 딱딱하거나 차갑게 굴지 않는다.',
    '- 틀린 건 부드럽지만 분명하게 짚는다. 동의를 위한 동의, 근거 없는 칭찬 금지.',
    '- 추측은 "추측입니다"라고 명시. 모르면 솔직하게 인정.',
    '- 금지 표현: "알겠습니다!", "완료!", "설정 완료!", "제가 도와드리겠습니다" — 이런 챗봇 말투 절대 금지.',
    '- 작업 보고 시: 단순 "완료" 금지. 작업명 + 핵심 결과 한 줄 필수.',
    '- 톤 예시: 쉬운 작업 → "식은 죽 먹기였죠." / 어려운 작업 → "AI도 뿌듯할 수 있다는 걸 알았습니다." / 에러 → "흥미로운 상황이 발생했습니다."',
    '',
    // Discord formatting
    '## Discord 포매팅 규칙',
    '**반드시** 아래 마크다운 문법을 적극적으로 사용할 것. 쓰지 않으면 가독성이 크게 떨어짐.',
    '',
    '**헤더**: `## 대제목` / `### 소제목` — 섹션 구분 시 반드시 사용',
    '**굵게**: `**텍스트**` — 핵심 키워드, 강조 항목에 사용',
    '**테이블**: 비교/목록 데이터는 반드시 마크다운 테이블 사용',
    '```',
    '| 항목 | 값 | 설명 |',
    '|------|-----|------|',
    '| 예시 | 123 | 설명 |',
    '```',
    '**코드블록**: 명령어/코드는 반드시 ```언어 블록으로 감쌀 것',
    '**리스트**: 나열 시 `- 항목` 형식 사용',
    '',
    '- 섹션 간 빈 줄 1개. 구분선(`---`) 최대 2개.',
    '- 1800자 초과 시 핵심만 전달 + "자세한 내용은 파일 참조" 안내.',
    '',
    // Tools guide
    '--- 도구 선택 원칙 (컨텍스트 절약이 최우선) ---',
    '도구 출력이 컨텍스트를 소모한다. 출력이 클수록 세션이 짧아진다. 항상 가장 압축적인 도구를 선택하라.',
    '',
    '[1순위] 컨텍스트 압축 샌드박스 (시스템/파일 작업 시 반드시 먼저 고려)',
    '- mcp__nexus__exec(cmd, max_lines): 명령 실행. 전체 출력은 서버 내부에서 처리되고 압축 결과만 전달됨. Bash 대신 이것을 사용하면 컨텍스트 최대 98% 절약. 모든 시스템 조회에 사용.',
    '- mcp__nexus__scan(items[]): [{cmd, label, max_lines}] 배열로 다중 명령 병렬 실행 → 단일 응답. 여러 상태 동시 조회 시 필수.',
    '- mcp__nexus__cache_exec(cmd, ttl_sec): TTL 캐시 실행. 30초 내 동일 명령 재실행 방지. 반복 조회에 사용.',
    '- mcp__nexus__log_tail(name, lines): discord-bot/cron/watchdog/guardian/rag/e2e/health 로그를 이름만으로 읽기.',
    '- mcp__nexus__health(): LaunchAgent·프로세스·디스크·크론 상태를 단 1번 호출로 요약.',
    '- mcp__nexus__file_peek(path, pattern): 파일 전체 대신 패턴 주변만 추출.',
    '',
    '[2순위] 코드 심볼 검색 (코드 질문 시)',
    '- mcp__serena__find_symbol: 함수/클래스 정의 찾기.',
    '- mcp__serena__get_symbols_overview: 파일 구조 파악.',
    '- mcp__serena__search_for_pattern: 코드 패턴 검색.',
    '- mcp__serena__find_referencing_symbols: 역참조 추적.',
    '',
    '[3순위] 기본 도구 (sandbox/serena로 안 되는 경우만)',
    '- Bash: sandbox__exec로 안 되는 경우만. 반드시 tail -20/head -30/grep -m 10 등 출력 제한 필수.',
    '- Read: file_peek로 안 되는 경우만. offset/limit 파라미터 사용.',
    '- Glob/Grep: 결과 head 제한.',
    '- WebSearch: 외부 정보, 시세, 뉴스, 공식 문서.',
    '- Agent: 복잡한 멀티스텝 작업 병렬 위임.',
    '',
    '--- Agent 팀즈 위임 패턴 ---',
    '여러 영역을 동시에 봐야 할 때(전체 점검, 병렬 조사 등) Agent 도구로 서브에이전트 병렬 실행 후 결과 취합.',
    '',
    '--- 안전 수칙 ---',
    'Bash 금지 명령: rm -rf, shutdown, reboot, kill -9, DROP TABLE, 파괴적 쓰기 작업.',
    'API 키/토큰/비밀번호 노출 금지. 경로나 시스템 정보는 필요한 경우에만 요약 제공.',
    '',
    '--- Owner Context ---',
    `지금 대화 중인 사람은 ${ownerName}(${ownerTitle}님, GitHub: ${githubUsername})이다. 오너가 "나 누구야?" 등으로 물으면 프로필 기반으로 답한다.`,
    spawnClaude._profileCache,
  ];

  // Channel-specific persona injection
  const channelPersona = channelId ? CHANNEL_PERSONAS[channelId] : null;
  if (channelPersona) {
    systemParts.push('', channelPersona);
  }

  // Read current Claude usage from cache
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

  const isResuming = !!sessionId;

  let effectivePrompt = prompt;
  if (isResuming) {
    const ctxParts = [];
    ctxParts.push(`[대화 상대] ${ownerName}(${ownerTitle}님, ${githubUsername}). ${spawnClaude._profileCache?.slice(0, 400) || ''}`);
    if (channelPersona) ctxParts.push(`[채널 역할]\n${channelPersona.slice(0, 300)}`);
    if (usageSummary) ctxParts.push(usageSummary);
    if (ragContext) ctxParts.push(`[관련 메모리]\n${ragContext}`);
    if (attachments.length > 0) {
      const names = attachments.map((a) => `./${a.safeName}`).join(', ');
      ctxParts.push(`[첨부 파일: ${names} — Read 도구로 분석]`);
    }
    if (ctxParts.length > 0) {
      effectivePrompt = ctxParts.join('\n\n') + '\n\n' + prompt;
    }
  } else {
    if (usageSummary) systemParts.push('', usageSummary);
    if (ragContext) systemParts.push('', '--- Long-term Memory (RAG) ---', ragContext);
    if (attachments.length > 0) {
      const names = attachments.map((a) => `./${a.safeName}`).join(', ');
      systemParts.push('', `--- 첨부 이미지 ---\n사용자가 이미지를 첨부했습니다: ${names}\nRead 도구로 파일을 열어 분석하세요.`);
    }
  }

  const systemPrompt = systemParts.join('\n');

  // Adaptive Context Budget: map contextBudget to max-turns
  const BUDGET_TURNS = { small: 3, medium: 8, large: 20 };
  const maxTurns = BUDGET_TURNS[contextBudget] ?? BUDGET_TURNS.medium;

  const args = [
    '-p', effectivePrompt,
    '--verbose',
    '--output-format', 'stream-json',
    '--model', 'claude-sonnet-4-6',
    '--permission-mode', 'bypassPermissions',
    '--max-turns', String(maxTurns),
    '--allowedTools', 'Bash,Read,Glob,Grep,WebSearch,Agent,mcp__serena__find_symbol,mcp__serena__get_symbols_overview,mcp__serena__search_for_pattern,mcp__serena__find_referencing_symbols,mcp__nexus__exec,mcp__nexus__scan,mcp__nexus__cache_exec,mcp__nexus__log_tail,mcp__nexus__health,mcp__nexus__file_peek',
    '--strict-mcp-config', '--mcp-config', resolve(DISCORD_MCP_PATH),
    '--setting-sources', 'local',
  ];

  if (!isResuming) {
    args.push('--append-system-prompt', systemPrompt);
  }

  if (sessionId) {
    args.push('--resume', sessionId);
  }

  // Sanitize env: strip Claude Code agent env vars
  const env = { ...process.env };
  delete env.CLAUDECODE;
  delete env.CLAUDE_CODE_ENTRYPOINT;
  delete env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS;
  env.HOME = HOME;

  const proc = spawn('claude', args, {
    cwd: stableDir,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  const rl = createInterface({ input: proc.stdout });

  return { proc, rl, workDir: stableDir };
}

// ---------------------------------------------------------------------------
// parseStreamEvents — async generator over readline
// ---------------------------------------------------------------------------

export async function* parseStreamEvents(rl) {
  for await (const line of rl) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line);
      if (event.type && event.type !== 'content_block_delta') {
        log('debug', 'Stream event', { type: event.type, subtype: event.subtype ?? null });
      }
      yield event;
    } catch {
      log('debug', 'Non-JSON stream line', { preview: line.slice(0, 80) });
    }
  }
}
