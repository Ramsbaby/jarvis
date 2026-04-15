/**
 * extras-gateway.mjs — Discord send / cron trigger / memory lookup tools
 * Exposed via Nexus MCP server for external clients (Cursor, Claude Desktop)
 */

import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, appendFile, open as fsOpen, stat as fsStat } from 'node:fs/promises';
import { mkResult, mkError, logTelemetry, BOT_HOME } from './shared.mjs';
import { listTasks, getTask } from '../task-store.mjs';
import { addFactToWiki } from '../../discord/lib/wiki-engine.mjs';

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
    annotations: { title: 'Discord Send', readOnlyHint: false, destructiveHint: false, openWorldHint: true },
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
    annotations: { title: 'Run Cron Job', readOnlyHint: false, destructiveHint: true, openWorldHint: true },
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
    annotations: { title: 'Get Memory', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
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
    annotations: { title: 'List Cron Jobs', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'dev_queue',
    description: 'View/manage jarvis-coder task queue (queued/running/done)',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['list', 'status'], description: 'Action (default: list)' },
        task_id: { type: 'string', description: 'Task ID (for status action)' },
      },
    },
    annotations: { title: 'Dev Queue', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
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
    annotations: { title: 'Context Bus', readOnlyHint: false, destructiveHint: false, openWorldHint: false },
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
    annotations: { title: 'Emit Event', readOnlyHint: false, destructiveHint: false, openWorldHint: true },
  },
  {
    name: 'usage_stats',
    description: 'Get Claude API token usage stats (today/month/budget)',
    inputSchema: { type: 'object', properties: {} },
    annotations: { title: 'Usage Stats', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'nexus_stats',
    description: '넥서스 MCP 도구 사용 통계. 도구별 호출 빈도, 평균/P95 응답시간, 타임아웃 수, 느린 명령어, 최근 에러 요약. 넥서스 성능 진단 및 쁨뻥이짓 탐지에 사용.',
    inputSchema: {
      type: 'object',
      properties: {
        n: { type: 'number', description: '분석할 최근 항목 수 (기본 500, 최대 2000)' },
      },
    },
    annotations: { title: 'Nexus Stats', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'wiki_add_fact',
    description: '사실 1개를 Jarvis 위키의 {domain}/_facts.md 에 즉시 주입. 표면(디스코드/Claude Code CLI/macOS 앱)에 무관하게 같은 뇌에 쓰기. 도메인은 키워드 기반으로 자동 감지되며 필요 시 override 가능. source 태그로 사후 감사 지원. 오너의 명시적 "기억해" 요청이나 대화 중 확정된 사실·결정·선호 포착 시 사용.',
    inputSchema: {
      type: 'object',
      properties: {
        fact: { type: 'string', description: '기억할 사실 1줄 (짧고 검색 가능한 단위, 5~160자 권장).' },
        domain: { type: 'string', description: '(선택) 도메인 명시. 생략 시 키워드 기반 자동 감지 (career/ops/tech/finance/personal 등).' },
        source: { type: 'string', description: '(선택) 주입 표면 태그. 예: "claude-code-cli", "claude-app", "claude-code-remember". 기본값 "mcp-client".' },
      },
      required: ['fact'],
    },
    annotations: { title: 'Wiki Add Fact', readOnlyHint: false, destructiveHint: false, openWorldHint: false },
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
    const scriptPath = resolve(task.script.replace(/^~/, homedir()));
    // path traversal 방어: BOT_HOME 하위 경로만 허용
    const resolvedBotHome = resolve(BOT_HOME);
    if (!scriptPath.startsWith(resolvedBotHome + '/') && !scriptPath.startsWith(resolvedBotHome + '\\')) {
      throw new Error(`script 경로가 BOT_HOME 밖입니다: ${scriptPath}`);
    }
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
  const ragQueryPath = join(import.meta.dirname, '..', '..', '..', 'rag', 'lib', 'rag-query.mjs');
  const { stdout } = await execFileAsync('node', [ragQueryPath, query, String(limit)], { timeout: 15000 });
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
  if (action === 'status' && task_id) {
    const task = getTask(task_id);
    if (!task) throw new Error(`task '${task_id}' not found`);
    return task;
  }
  const tasks = listTasks();
  return tasks.map(t => ({
    id: t.id,
    name: t.name,
    status: t.status,
    priority: t.priority,
  }));
}

/** context-bus 읽기/추가 (appendFile로 OS-level atomic append 보장) */
async function contextBus({ action = 'read', message } = {}) {
  const busPath = join(BOT_HOME, 'state', 'context-bus.md');
  if (action === 'append') {
    if (!message) throw new Error('message required for append');
    const timestamp = new Date().toISOString().slice(0, 16);
    const entry = `\n---\n[${timestamp}] (MCP) ${message}\n`;
    // appendFile: O_APPEND 플래그로 OS 레벨 원자적 추가 — 동시 write 경합 없음
    await appendFile(busPath, entry, 'utf8');
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

/** 넥서스 텔레메트리 통계 */
async function nexusStats({ n = 500 } = {}) {
  const telePath = join(BOT_HOME, 'logs', 'nexus-telemetry.jsonl');

  // 파일 뒤에서 200KB만 읽기
  const MAX_BYTES = 200 * 1024;
  let raw;
  try {
    const stat = await fsStat(telePath);
    if (stat.size > MAX_BYTES) {
      const fh = await fsOpen(telePath, 'r');
      try {
        const buf = Buffer.alloc(MAX_BYTES);
        const { bytesRead } = await fh.read(buf, 0, MAX_BYTES, stat.size - MAX_BYTES);
        raw = buf.subarray(0, bytesRead).toString('utf8');
        // 첫 줄은 잘린 줄일 수 있으므로 첫 개행 이후부터 사용
        const firstNewline = raw.indexOf('\n');
        raw = firstNewline >= 0 ? raw.slice(firstNewline + 1) : raw;
      } finally {
        await fh.close();
      }
    } else {
      raw = await readFile(telePath, 'utf8');
    }
  } catch {
    raw = '';
  }

  const lines = raw.trim().split('\n').filter(Boolean);
  const entries = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const recent = entries.slice(-Math.min(Number(n) || 500, 2000));
  if (recent.length === 0) return { total: 0, note: '텔레메트리 없음' };

  const toolCounts = {};
  const toolDurs = {};
  const recentErrors = [];
  const slowCmds = [];

  for (const e of recent) {
    toolCounts[e.tool] = (toolCounts[e.tool] || 0) + 1;
    if (!toolDurs[e.tool]) toolDurs[e.tool] = [];
    toolDurs[e.tool].push(e.duration_ms);
    if (e.error) recentErrors.push({ ts: e.ts?.slice(11, 16), tool: e.tool, error: String(e.error).slice(0, 80) });
    if (e.duration_ms > 5000 && e.cmd) slowCmds.push({ ts: e.ts?.slice(11, 16), cmd: e.cmd?.slice(0, 80), dur_s: (e.duration_ms / 1000).toFixed(1) });
  }

  const toolStats = Object.entries(toolCounts)
    .sort((a, b) => b[1] - a[1])
    .map(([tool, count]) => {
      const durs = [...toolDurs[tool]].sort((a, b) => a - b);
      const avg = Math.round(durs.reduce((s, d) => s + d, 0) / durs.length);
      const p95 = durs[Math.floor(durs.length * 0.95)] ?? 0;
      const timeouts = durs.filter(d => d >= 9900).length;
      return { tool, count, pct: `${((count / recent.length) * 100).toFixed(1)}%`, avg_ms: avg, p95_ms: p95, timeouts };
    });

  return {
    period: `${recent[0]?.ts?.slice(0, 16)} ~ ${recent[recent.length - 1]?.ts?.slice(0, 16)}`,
    total: recent.length,
    tool_stats: toolStats,
    slow_cmds: slowCmds.slice(-5),
    recent_errors: recentErrors.slice(-5),
  };
}

// ---------------------------------------------------------------------------
// wiki_add_fact — Jarvis 위키에 사실 1개 즉시 주입 (표면 통합 메모리 Phase 2)
// ---------------------------------------------------------------------------

/** 사실 1개를 wiki-engine의 addFactToWiki로 주입. 표면 구분을 위한 source 태깅. */
async function wikiAddFactTool({ fact, domain, source }) {
  if (typeof fact !== 'string') {
    throw new Error('fact (string) required');
  }
  const trimmed = fact.trim();
  if (trimmed.length < 5) {
    throw new Error('fact too short (min 5 chars)');
  }
  if (trimmed.length > 500) {
    throw new Error('fact too long (max 500 chars) — 짧고 검색 가능한 단위로 분할 필요');
  }

  const opts = { source: (typeof source === 'string' && source.trim()) ? source.trim() : 'mcp-client' };
  if (typeof domain === 'string' && domain.trim()) {
    opts.domainOverride = domain.trim();
  }

  const writtenDomain = addFactToWiki(null, trimmed, opts);
  return {
    status: 'ok',
    domain: writtenDomain,
    source: opts.source,
    fact: trimmed.slice(0, 120) + (trimmed.length > 120 ? '...' : ''),
  };
}

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------
export async function handle(name, args, start) {
  const handlers = {
    discord_send: discordSend, run_cron: runCron, get_memory: getMemory,
    list_crons: listCrons, dev_queue: devQueue, context_bus: contextBus,
    emit_event: emitEvent, usage_stats: usageStats, nexus_stats: nexusStats,
    wiki_add_fact: wikiAddFactTool,
  };
  if (!(name in handlers)) return null;

  try {
    const result = await handlers[name](args ?? {});
    // 도구별 유용한 메타 기록
    const meta = {};
    if (name === 'discord_send') { meta.channel = args?.channel; meta.msg_len = args?.message?.length; }
    else if (name === 'run_cron') { meta.job = args?.job; }
    else if (name === 'get_memory') { meta.query = args?.query?.slice(0, 60); }
    else if (name === 'list_crons') { meta.filter = args?.filter; }
    else if (name === 'emit_event') { meta.event = args?.event; }
    else if (name === 'wiki_add_fact') { meta.fact = args?.fact?.slice(0, 60); meta.source = args?.source; meta.domain = args?.domain; }
    logTelemetry(name, Date.now() - start, meta);
    return mkResult(JSON.stringify(result, null, 2));
  } catch (err) {
    logTelemetry(name, Date.now() - start, { error: err.message });
    return mkError(`오류: ${err.message}`, { tool: name });
  }
}
