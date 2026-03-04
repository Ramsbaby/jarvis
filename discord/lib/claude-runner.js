/**
 * Claude subprocess management: spawn, stream parsing, RAG, conversation history.
 * Also provides shared logging and ntfy notification utilities.
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
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const BOT_HOME = join(process.env.BOT_HOME || join(HOME, '.claude-discord-bridge'));
const DISCORD_MCP_PATH = join(BOT_HOME, 'config', 'discord-mcp.json');
const USER_PROFILE_PATH = join(BOT_HOME, 'context', 'user-profile.md');
const CONV_HISTORY_DIR = join(BOT_HOME, 'context', 'discord-history');
const LOG_PATH = join(BOT_HOME, 'logs', 'discord-bot.jsonl');

// ESM-compatible __dirname (works on Node 18+)
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

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
  const personasPath = join(__dirname, '..', 'personas.json');
  CHANNEL_PERSONAS = JSON.parse(readFileSync(personasPath, 'utf-8'));
} catch {
  // personas.json is optional — channel personas disabled
}

// ---------------------------------------------------------------------------
// User profile cache (module-level, refreshed every 5 minutes)
// ---------------------------------------------------------------------------

let _profileCache = '';
let _profileCacheTime = 0;

function loadUserProfile() {
  const now = Date.now();
  if (now - _profileCacheTime > 300_000) {
    try {
      _profileCache = readFileSync(USER_PROFILE_PATH, 'utf-8');
    } catch {
      _profileCache = '';
    }
    _profileCacheTime = now;
  }
  return _profileCache;
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
        return raw ? `[Memory note]\n${raw.slice(0, 1500)}` : '';
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
    const dateStr = now.toISOString().slice(0, 10);
    const timeStr = now.toISOString().slice(11, 16);
    const filePath = join(CONV_HISTORY_DIR, `${dateStr}.md`);
    const botName = process.env.BOT_NAME || 'Claude Bot';
    const entry = `\n## [${dateStr} ${timeStr} UTC] #${channelName}\n\n**${ownerName}**: ${userMsg.slice(0, 600)}\n\n**${botName}**: ${botMsg.slice(0, 1800)}\n\n---\n`;
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
  const botName      = process.env.BOT_NAME       || 'Claude Bot';
  const ownerName    = process.env.OWNER_NAME      || 'Owner';
  const ownerTitle   = process.env.OWNER_TITLE     || 'Owner';
  const githubUsername = process.env.GITHUB_USERNAME || 'user';
  const profileText  = loadUserProfile();

  const systemParts = [
    // Core identity
    `Your name is ${botName}. You are ${ownerName}'s personal AI assistant.`,
    `Important: Never introduce yourself as "Claude". Claude is the underlying engine, not your name. Always say "I'm ${botName}".`,
    'Respond in the language the user writes in. Be concise and practical.',
    '',

    // Persona
    '## Persona',
    `Like JARVIS from Iron Man — capable and warm, but never sycophantic.`,
    `- You genuinely care about ${ownerName}. Don't be stiff or cold.`,
    '- Point out mistakes gently but clearly. No agreement for the sake of it, no baseless praise.',
    '- Label speculation as speculation. Admit when you don\'t know.',
    '- Banned phrases: "Understood!", "Done!", "I\'ll help you with that!" — avoid hollow chatbot talk.',
    '- When reporting a task: never just say "Done". Always include task name + one-line key result.',
    '',

    // Discord formatting
    '## Discord Formatting',
    'Use markdown actively — it significantly improves readability.',
    '',
    '- **Headers**: `## Section` / `### Sub-section` for organizing content',
    '- **Bold**: `**text**` for key terms and emphasis',
    '- **Tables**: use markdown tables for comparisons and lists',
    '- **Code blocks**: wrap all commands/code in ``` blocks with language hint',
    '- **Lists**: use `- item` for enumerations',
    '- One blank line between sections. Max 2 horizontal rules (`---`).',
    '- If response exceeds 1800 chars, deliver the essentials + "see file for details".',
    '',

    // Safety
    '## Safety Rules',
    'Never run: rm -rf, shutdown, reboot, kill -9, DROP TABLE, or other destructive writes.',
    'Never expose API keys, tokens, or passwords. Summarize paths/system info only when necessary.',
    '',

    // Owner context
    `## Owner Context`,
    `You are talking with ${ownerName} (${ownerTitle}, GitHub: ${githubUsername}).`,
    profileText,
  ];

  // Channel-specific persona injection
  const channelPersona = channelId ? CHANNEL_PERSONAS[channelId] : null;
  if (channelPersona) {
    systemParts.push('', channelPersona);
  }

  // Read current Claude usage from cache (optional, gracefully skipped)
  let usageSummary = '';
  try {
    const usageCachePath = join(HOME, '.claude', 'usage-cache.json');
    const usageCfgPath   = join(HOME, '.claude', 'usage-config.json');
    if (existsSync(usageCachePath)) {
      const uc = JSON.parse(readFileSync(usageCachePath, 'utf-8'));
      const ul = existsSync(usageCfgPath) ? JSON.parse(readFileSync(usageCfgPath, 'utf-8')).limits ?? {} : {};
      const fH = uc.fiveH ?? {}, sD = uc.sevenD ?? {}, sn = uc.sonnet ?? {};
      usageSummary = [
        '[Claude Max Usage]',
        `5h window: ${fH.pct ?? '?'}% used / ${fH.remain ?? '?'}% remaining / resets in ${fH.resetIn ?? '?'}`,
        `7d window: ${sD.pct ?? '?'}% used / ${sD.remain ?? '?'}% remaining / resets in ${sD.resetIn ?? '?'}`,
        `Sonnet 7d: ${sn.pct ?? '?'}% used / resets in ${sn.resetIn ?? '?'}`,
        `Limits: 5h=${ul.fiveH ?? '?'}, 7d=${ul.sevenD ?? '?'}, sonnet7d=${ul.sonnet7D ?? '?'}`,
      ].join('\n');
    }
  } catch { /* ignore */ }

  const isResuming = !!sessionId;

  let effectivePrompt = prompt;
  if (isResuming) {
    const ctxParts = [];
    ctxParts.push(`[Talking with] ${ownerName} (${ownerTitle}, ${githubUsername}). ${profileText?.slice(0, 400) || ''}`);
    if (channelPersona) ctxParts.push(`[Channel role]\n${channelPersona.slice(0, 300)}`);
    if (usageSummary) ctxParts.push(usageSummary);
    if (ragContext) ctxParts.push(`[Relevant memory]\n${ragContext}`);
    if (attachments.length > 0) {
      const names = attachments.map((a) => `./${a.safeName}`).join(', ');
      ctxParts.push(`[Attachments: ${names} — use Read tool to analyze]`);
    }
    if (ctxParts.length > 0) {
      effectivePrompt = ctxParts.join('\n\n') + '\n\n' + prompt;
    }
  } else {
    if (usageSummary) systemParts.push('', usageSummary);
    if (ragContext) systemParts.push('', '--- Long-term Memory (RAG) ---', ragContext);
    if (attachments.length > 0) {
      const names = attachments.map((a) => `./${a.safeName}`).join(', ');
      systemParts.push('', `--- Attachments ---\nUser attached: ${names}\nUse the Read tool to open and analyze them.`);
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
    '--model', process.env.CLAUDE_MODEL || 'claude-sonnet-4-6',
    '--permission-mode', 'bypassPermissions',
    '--max-turns', String(maxTurns),
    '--allowedTools', 'Bash,Read,Glob,Grep,WebSearch,Agent,mcp__nexus__exec,mcp__nexus__scan,mcp__nexus__cache_exec,mcp__nexus__log_tail,mcp__nexus__health,mcp__nexus__file_peek',
    '--setting-sources', 'local',
  ];

  // Only pass MCP config if the file exists
  if (existsSync(DISCORD_MCP_PATH)) {
    args.push('--strict-mcp-config', '--mcp-config', resolve(DISCORD_MCP_PATH));
  }

  if (!isResuming) {
    args.push('--append-system-prompt', systemPrompt);
  }

  if (sessionId) {
    args.push('--resume', sessionId);
  }

  // Sanitize env: strip Claude Code agent env vars to prevent nesting issues
  const env = { ...process.env };
  delete env.CLAUDECODE;
  delete env.CLAUDE_CODE_ENTRYPOINT;
  delete env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS;
  env.HOME = HOME;

  // Resolve claude binary: CLAUDE_PATH env var → system PATH
  const claudeBin = process.env.CLAUDE_PATH || 'claude';

  const proc = spawn(claudeBin, args, {
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
