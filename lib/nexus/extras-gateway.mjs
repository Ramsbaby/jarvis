/**
 * extras-gateway.mjs — Discord send / cron trigger / memory lookup tools
 * Exposed via Nexus MCP server for external clients (Cursor, Claude Desktop)
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, writeFile } from 'node:fs/promises';
import { mkResult, mkError, logTelemetry, BOT_HOME } from './shared.mjs';

const execFileAsync = promisify(execFile);

// Discord REST API용 토큰 로드 (discord/.env 우선, 메모리 캐시)
let _cachedToken = null;
async function loadDiscordToken() {
  if (_cachedToken) return _cachedToken;
  const envPath = join(BOT_HOME, 'discord', '.env');
  try {
    const raw = await readFile(envPath, 'utf8');
    const m = raw.match(/^DISCORD_TOKEN=(.+)$/m);
    if (m) { _cachedToken = m[1].trim(); return _cachedToken; }
  } catch { /* fall through */ }
  _cachedToken = process.env.DISCORD_TOKEN || null;
  return _cachedToken;
}

// personas.json에서 채널명→ID 매핑 로드
async function loadChannelMap() {
  const personasPath = join(BOT_HOME, 'discord', 'personas.json');
  const raw = JSON.parse(await readFile(personasPath, 'utf8'));
  const map = {};
  for (const [channelId, persona] of Object.entries(raw)) {
    const m = persona.match(/--- Channel: (\S+)/);
    if (m) map[m[1]] = channelId;
  }
  return map;
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------
export const TOOLS = [
  {
    name: 'discord_send',
    description: 'Send a message to a Jarvis Discord channel',
    inputSchema: {
      type: 'object',
      properties: {
        channel: { type: 'string', description: 'Channel name (e.g. jarvis-ceo, jarvis)' },
        message: { type: 'string', description: 'Message content (markdown supported)' },
      },
      required: ['channel', 'message'],
    },
  },
  {
    name: 'run_cron',
    description: 'Immediately trigger a Jarvis scheduled job by name',
    inputSchema: {
      type: 'object',
      properties: {
        job: { type: 'string', description: 'Job name or id from tasks.json' },
      },
      required: ['job'],
    },
  },
  {
    name: 'get_memory',
    description: 'Semantic search Jarvis long-term memory (RAG)',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Search query' },
        limit: { type: 'number', description: 'Max results (default 5)' },
      },
      required: ['query'],
    },
  },
  {
    name: 'list_crons',
    description: 'List all Jarvis scheduled jobs with status/schedule',
    inputSchema: {
      type: 'object',
      properties: {
        filter: { type: 'string', description: 'Optional name filter (substring match)' },
      },
    },
  },
  {
    name: 'dev_queue',
    description: 'View/manage dev-runner task queue (queued/running/done)',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['list', 'status'], description: 'Action (default: list)' },
        task_id: { type: 'string', description: 'Task ID (for status action)' },
      },
    },
  },
  {
    name: 'context_bus',
    description: 'Read or append to the team context bus (shared bulletin board)',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['read', 'append'], description: 'read or append (default: read)' },
        message: { type: 'string', description: 'Message to append (required for append)' },
      },
    },
  },
  {
    name: 'emit_event',
    description: 'Emit a Jarvis event (triggers event-watcher within 30s)',
    inputSchema: {
      type: 'object',
      properties: {
        event: { type: 'string', description: 'Event name (e.g. system.alert, market.emergency)' },
        payload: { type: 'string', description: 'Optional JSON payload' },
      },
      required: ['event'],
    },
  },
  {
    name: 'usage_stats',
    description: 'Get Claude API token usage stats (today/month/budget)',
    inputSchema: { type: 'object', properties: {} },
  },
];

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/** Discord 채널에 메시지 전송 (Discord REST API v10) */
async function discordSend({ channel, message }) {
  if (!channel || !message) throw new Error('channel and message required');

  const token = await loadDiscordToken();
  if (!token) throw new Error('DISCORD_TOKEN 없음 — discord/.env 확인 필요');

  const channelMap = await loadChannelMap();
  const channelId = channelMap[channel];
  if (!channelId) {
    throw new Error(`채널 '${channel}' 없음. 사용 가능: ${Object.keys(channelMap).join(', ')}`);
  }

  const res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
    method: 'POST',
    headers: {
      'Authorization': `Bot ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ content: message }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Discord API 오류 ${res.status}: ${body}`);
  }

  const data = await res.json();
  return { ok: true, message_id: data.id, channel, channel_id: channelId };
}

/** 크론 작업 즉시 트리거
 *  - script 필드 있는 잡: bash 직접 실행
 *  - prompt 필드 잡:     bot-cron.sh TASK_ID 위임 (claude -p 경로)
 */
async function runCron({ job }) {
  if (!job) throw new Error('job name required');
  const tasksPath = join(BOT_HOME, 'config', 'tasks.json');
  const raw = JSON.parse(await readFile(tasksPath, 'utf8'));
  const tasks = raw.tasks || raw;
  const task = tasks.find(t => t.name === job || t.id === job);
  if (!task) {
    const names = tasks.slice(0, 20).map(t => t.name || t.id).join(', ');
    throw new Error(`job '${job}' 없음. 예시: ${names}…`);
  }

  // script 필드 있으면 직접 실행, 없으면 bot-cron.sh(prompt/LLM 경로) 위임
  if (task.script) {
    const scriptPath = task.script.replace(/^~/, homedir());
    const { stdout } = await execFileAsync('bash', [scriptPath], {
      timeout: 60000,
      env: { ...process.env, BOT_HOME },
    });
    return { ok: true, job, type: 'script', output: stdout.trim().slice(0, 500) };
  } else {
    const botCron = join(BOT_HOME, 'bin', 'bot-cron.sh');
    const { stdout } = await execFileAsync('bash', [botCron, task.id], {
      timeout: Number(task.timeout || 120) * 1000 + 10000,
      env: { ...process.env, BOT_HOME },
    });
    return { ok: true, job, type: 'prompt', output: stdout.trim().slice(0, 500) };
  }
}

/** 자비스 메모리 키워드 검색 */
async function getMemory({ query, limit = 5 }) {
  if (!query) throw new Error('query required');
  const ragQueryPath = join(BOT_HOME, 'lib', 'rag-query.mjs');
  const { stdout } = await execFileAsync('node', [ragQueryPath, query], { timeout: 15000 });
  return { ok: true, query, results: stdout.trim() };
}

/** 크론 목록 조회 */
async function listCrons({ filter } = {}) {
  const tasksPath = join(BOT_HOME, 'config', 'tasks.json');
  const raw = JSON.parse(await readFile(tasksPath, 'utf8'));
  const tasks = raw.tasks || raw;
  let filtered = tasks;
  if (filter) {
    const lf = filter.toLowerCase();
    filtered = tasks.filter(t => ((t.name || '') + (t.id || '')).toLowerCase().includes(lf));
  }
  return filtered.map(t => ({
    id: t.id,
    name: t.name,
    schedule: t.schedule || t.cron || '(manual)',
    enabled: t.enabled !== false,
    script: t.script || '(none)',
  }));
}

/** dev-queue 조회 */
async function devQueue({ action = 'list', task_id } = {}) {
  const queuePath = join(BOT_HOME, 'state', 'dev-queue.json');
  const data = JSON.parse(await readFile(queuePath, 'utf8'));
  const tasks = data.tasks || data;
  if (action === 'status' && task_id) {
    const task = tasks.find(t => t.id === task_id);
    if (!task) throw new Error(`task '${task_id}' not found`);
    return task;
  }
  return tasks.map(t => ({
    id: t.id,
    name: t.name,
    status: t.status,
    priority: t.priority,
  }));
}

/** context-bus 읽기/추가 */
async function contextBus({ action = 'read', message } = {}) {
  const busPath = join(BOT_HOME, 'state', 'context-bus.md');
  if (action === 'append') {
    if (!message) throw new Error('message required for append');
    const timestamp = new Date().toISOString().slice(0, 16);
    const entry = `\n---\n[${timestamp}] (MCP) ${message}\n`;
    const current = await readFile(busPath, 'utf8').catch(() => '');
    await writeFile(busPath, current + entry, 'utf8');
    return { ok: true, appended: entry.trim() };
  }
  const content = await readFile(busPath, 'utf8').catch(() => '(비어있음)');
  return { content: content.slice(-2000) }; // 최근 2000자
}

/** 이벤트 발행 */
async function emitEvent({ event, payload } = {}) {
  if (!event) throw new Error('event name required');
  const script = join(BOT_HOME, 'scripts', 'emit-event.sh');
  const args = [script, event];
  if (payload) args.push(payload);
  const { stdout } = await execFileAsync('bash', args, { timeout: 5000 });
  return { ok: true, event, output: stdout.trim() };
}

/** 사용량 통계 */
async function usageStats() {
  const script = join(BOT_HOME, 'scripts', 'usage-stats.sh');
  const { stdout } = await execFileAsync('bash', [script], { timeout: 10000 });
  return { ok: true, stats: stdout.trim().slice(0, 1000) };
}

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------
export async function handle(name, args, start) {
  const handlers = {
    discord_send: discordSend, run_cron: runCron, get_memory: getMemory,
    list_crons: listCrons, dev_queue: devQueue, context_bus: contextBus,
    emit_event: emitEvent, usage_stats: usageStats,
  };
  if (!(name in handlers)) return null;

  try {
    const result = await handlers[name](args ?? {});
    logTelemetry(name, Date.now() - start, {});
    return mkResult(JSON.stringify(result, null, 2));
  } catch (err) {
    logTelemetry(name, Date.now() - start, { error: err.message });
    return mkError(`오류: ${err.message}`, { tool: name });
  }
}
