/**
 * extras-gateway.mjs — Discord send / cron trigger / memory lookup tools
 * Exposed via Nexus MCP server for external clients (Cursor, Claude Desktop)
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { mkResult, mkError, logTelemetry, BOT_HOME } from './shared.mjs';

const execFileAsync = promisify(execFile);

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
];

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/** Discord 채널에 메시지 전송 */
async function discordSend({ channel, message }) {
  if (!channel || !message) throw new Error('channel and message required');
  const script = join(BOT_HOME, 'scripts', 'discord-send.sh');
  const { stdout, stderr } = await execFileAsync('bash', [script, channel, message], { timeout: 10000 });
  return { ok: true, stdout: stdout.trim(), stderr: stderr.trim() };
}

/** 크론 작업 즉시 트리거 */
async function runCron({ job }) {
  if (!job) throw new Error('job name required');
  const tasksPath = join(BOT_HOME, 'config', 'tasks.json');
  const tasks = JSON.parse(await readFile(tasksPath, 'utf8'));
  const task = tasks.find(t => t.name === job || t.id === job);
  if (!task) throw new Error(`job not found: ${job}. Available: ${tasks.map(t => t.name).join(', ')}`);
  const runnerPath = join(BOT_HOME, 'bin', 'dev-runner.sh');
  const { stdout } = await execFileAsync('bash', [runnerPath, '--once', job], { timeout: 30000 });
  return { ok: true, job, output: stdout.trim() };
}

/** 자비스 메모리 키워드 검색 */
async function getMemory({ query, limit = 5 }) {
  if (!query) throw new Error('query required');
  const ragQueryPath = join(BOT_HOME, 'lib', 'rag-query.mjs');
  const { stdout } = await execFileAsync('node', [ragQueryPath, query], { timeout: 15000 });
  return { ok: true, query, results: stdout.trim() };
}

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------
export async function handle(name, args, start) {
  const handlers = { discord_send: discordSend, run_cron: runCron, get_memory: getMemory };
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
