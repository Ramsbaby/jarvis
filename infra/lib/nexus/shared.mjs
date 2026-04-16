/**
 * nexus/shared.mjs — 공통 유틸리티
 * 압축 엔진, 명령 실행, 구조화 출력, 텔레메트리
 */

import { spawn, execFile, execSync } from 'node:child_process';
import { appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const BOT_HOME = join(process.env.BOT_HOME || join(homedir(), '.jarvis'));
export const LOGS_DIR = join(BOT_HOME, 'logs');
export const STATE_DIR = join(BOT_HOME, 'state');
export const TELEMETRY_FILE = join(LOGS_DIR, 'nexus-telemetry.jsonl');
// Phase 0 Sensor: 표면 통합 측정 ledger (Discord 봇·CLI 훅과 동일 경로)
export const MCP_SENSOR_FILE = join(STATE_DIR, 'mcp-tool-call.jsonl');

// MCP stdio 서버는 클라이언트(CLI/app)의 subprocess로 뜬다.
// 부모 프로세스 정보를 1회 캐싱해서 source 추정 (Claude Code CLI vs 앱 vs 기타).
let _cachedSource = null;
function detectMcpSource() {
  if (_cachedSource) return _cachedSource;
  try {
    const ppid = process.ppid;
    const cmd = execSync(`ps -p ${ppid} -o command= 2>/dev/null || true`, { encoding: 'utf-8' }).trim();
    if (/Claude\s*\.app|Anthropic/i.test(cmd)) _cachedSource = 'mcp-claude-app';
    else if (/claude[\/ ]|claude-code|\.local\/bin\/claude/i.test(cmd)) _cachedSource = 'mcp-claude-code-cli';
    else if (/node.*discord-bot/i.test(cmd)) _cachedSource = 'mcp-discord-bot';
    else _cachedSource = 'mcp-unknown';
  } catch {
    _cachedSource = 'mcp-unknown';
  }
  return _cachedSource;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
export function clamp(val, min, max) { return Math.min(Math.max(Number(val) || min, min), max); }

// ---------------------------------------------------------------------------
// Structured output
// ---------------------------------------------------------------------------
export function mkResult(data, meta = {}) {
  return { content: [{ type: 'text', text: JSON.stringify({ status: 'ok', data, meta }) }] };
}
export function mkError(data, meta = {}) {
  return {
    content: [{ type: 'text', text: JSON.stringify({ status: 'error', data, meta }) }],
    isError: true,
  };
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------
export function logTelemetry(tool, durationMs, meta = {}) {
  const ts = new Date().toISOString();
  try {
    appendFileSync(
      TELEMETRY_FILE,
      JSON.stringify({ ts, tool, duration_ms: durationMs, ...meta }) + '\n'
    );
  } catch { /* never block on telemetry */ }
  // Phase 0 Sensor: 표면 통합 ledger (Discord/CLI/MCP 합본 분석용)
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    appendFileSync(
      MCP_SENSOR_FILE,
      JSON.stringify({ ts, source: detectMcpSource(), tool, duration_ms: durationMs, ...meta }) + '\n'
    );
  } catch { /* sensor는 텔레메트리보다 엄격히 비차단 */ }
}

// ---------------------------------------------------------------------------
// Command Safety — 위험 명령 차단 (MCP 외부 노출 보호)
// ---------------------------------------------------------------------------
const BLOCKED_PATTERNS = [
  /\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*\s+|--recursive)/, // rm -rf, rm -r
  /\bmkfs\b/, /\bdd\b\s+if=/, /\bshutdown\b/, /\breboot\b/,
  /\bkill\s+-9\s/, /\bkillall\b/,
  /\bDROP\s+(TABLE|DATABASE)\b/i, /\bTRUNCATE\b/i,
  /\/etc\/(shadow|passwd|sudoers)/, /\.ssh\/id_/,
  /API_KEY/, /SECRET/,
  /\bcurl\b.*\|\s*bash/, /\bwget\b.*\|\s*bash/, // pipe to shell
  /\bchmod\s+777\b/, /\bchown\s+root\b/,
  /\bnc\s+-[le]/, // netcat listener
  /\bpython[3]?\s+-c\s+.*import\s+(os|subprocess|socket)\b/,
];

export function validateCommand(cmd) {
  if (!cmd || typeof cmd !== 'string') return { ok: false, reason: 'empty command' };
  for (const pattern of BLOCKED_PATTERNS) {
    if (pattern.test(cmd)) {
      return { ok: false, reason: `차단: ${pattern.source} 패턴 매칭` };
    }
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Path Safety — 허용 디렉토리 외 접근 차단
// ---------------------------------------------------------------------------
const ALLOWED_PATH_PREFIXES = [
  BOT_HOME,
  '/tmp/',
  '/private/tmp/',
];

export function validatePath(filePath) {
  if (!filePath || typeof filePath !== 'string') return { ok: false, reason: 'empty path' };
  const resolved = filePath.replace(/^~/, process.env.HOME || '');
  const isAllowed = ALLOWED_PATH_PREFIXES.some(p => resolved.startsWith(p));
  if (!isAllowed) return { ok: false, reason: `경로 제한: ${ALLOWED_PATH_PREFIXES.join(', ')} 외 접근 차단` };
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Smart Compress
// ---------------------------------------------------------------------------
export function detectStrategy(output) {
  if (!output || output.length < 10) return 'plain';
  const trimmed = output.trimStart();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return 'json';
  if (/\bPID\b/.test(trimmed.split('\n')[0]) || /^\S+\s+\d+\s+\d+\.\d+\s+\d+\.\d+/.test(trimmed.split('\n')[1] || '')) return 'process';
  const logPattern = /\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}|(\b(ERROR|WARN|INFO|DEBUG)\b)/;
  const lines = trimmed.split('\n').slice(0, 10);
  if (lines.filter(l => logPattern.test(l)).length >= 3) return 'log';
  if (lines.filter(l => (l.match(/\|/g) || []).length >= 2).length >= 3) return 'table';
  return 'plain';
}

export function compressLog(text, maxLines = 50) {
  const lines = text.split('\n');
  const errors = [];
  const warns = [];
  for (const line of lines) {
    if (/\b(ERROR|CRITICAL|FATAL|ALERT)\b/i.test(line)) errors.push(line);
    else if (/\bWARN(ING)?\b/i.test(line)) warns.push(line);
  }
  const summary = `[로그 요약] 총 ${lines.length}줄, ${errors.length}오류, ${warns.length}경고`;
  const unique = [...new Set([...errors.slice(-5), ...warns.slice(-5), '---', ...lines.slice(-20)])];
  return [summary, '', ...unique].join('\n').split('\n').slice(0, maxLines).join('\n').trimEnd();
}

export function compressJson(text, maxChars = 2000) {
  try {
    const obj = JSON.parse(text);
    const trimmed = JSON.stringify(obj, (key, val) => {
      if (typeof val === 'object' && val !== null) {
        const str = JSON.stringify(val);
        if (str.length > 500) {
          if (Array.isArray(val)) {
            const sample = val.slice(0, 3).map(v => {
              const s = typeof v === 'string' ? v : JSON.stringify(v);
              return s.length > 80 ? s.slice(0, 77) + '...' : s;
            });
            return `[Array(${val.length}): ${sample.join(', ')}${val.length > 3 ? ', ...' : ''}]`;
          }
          const keys = Object.keys(val);
          if (keys.length > 8) return `{${keys.slice(0, 5).join(', ')}... +${keys.length - 5}}`;
        }
      }
      return val;
    }, 2);
    if (trimmed.length <= maxChars) return trimmed;
    return trimmed.slice(0, maxChars) + '\n...[JSON 잘림]';
  } catch {
    return compressPlain(text, 40);
  }
}

export function compressProcess(text) {
  const lines = text.split('\n').filter(l => l.trim());
  if (lines.length <= 1) return text.trimEnd();
  const procs = lines.slice(1);
  const groups = {};
  for (const line of procs) {
    const parts = line.trim().split(/\s+/);
    const pid = parts[1] || '?';
    const cmd = parts.slice(10).join(' ') || parts[parts.length - 1] || 'unknown';
    const base = cmd.split('/').pop().split(' ')[0];
    const firstArg = parts.slice(11).join(' ').split('/').pop().slice(0, 60) || '';
    if (!groups[base]) groups[base] = { count: 0, pids: [] };
    groups[base].count++;
    groups[base].pids.push({ pid, arg: firstArg });
  }
  const summaryLines = [`[프로세스 요약] 총 ${procs.length}개`];
  for (const [name, { count, pids }] of Object.entries(groups).sort((a, b) => b[1].count - a[1].count).slice(0, 15)) {
    const topPids = pids.slice(0, 3);
    summaryLines.push(`  ${name} x${count} (PIDs: ${topPids.map(p => p.pid).join(' ')}${count > 3 ? ` +${count - 3}` : ''})`);
    for (const { pid, arg } of topPids) {
      if (arg) summaryLines.push(`    └─ ${pid}: ${arg}`);
    }
  }
  return summaryLines.join('\n');
}

export function compressPlain(text, maxLines = 50) {
  if (!text) return '(empty)';
  const lines = text.split('\n');
  if (lines.length <= maxLines) return text.trimEnd();
  return `...[${lines.length - maxLines}줄 생략]\n${lines.slice(-maxLines).join('\n').trimEnd()}`;
}

export function smartCompress(text, maxLines = 50) {
  if (!text) return '(empty)';
  switch (detectStrategy(text)) {
    case 'log':     return compressLog(text, maxLines);
    case 'json':    return compressJson(text);
    case 'process': return compressProcess(text);
    default:        return compressPlain(text, maxLines);
  }
}

// ---------------------------------------------------------------------------
// Command execution (async, SIGTERM→SIGKILL, 1MB truncation)
// ---------------------------------------------------------------------------
export function runCmd(cmd, timeoutMs = 10000) {
  return new Promise((resolve) => {
    const proc = spawn('bash', ['-c', cmd], {
      encoding: 'utf-8',
      env: { ...process.env, PATH: process.env.PATH },
    });
    const MAX_BUF = 1 * 1024 * 1024;
    let stdout = '';
    let stderr = '';
    let stdoutTruncated = false;

    proc.stdout.on('data', (d) => {
      if (stdout.length < MAX_BUF) { stdout += d; if (stdout.length >= MAX_BUF) stdoutTruncated = true; }
    });
    proc.stderr.on('data', (d) => {
      if (stderr.length < MAX_BUF) stderr += d;
    });

    let resolved = false;
    const timer = setTimeout(() => {
      proc.kill('SIGTERM');
      setTimeout(() => { try { proc.kill('SIGKILL'); } catch {} }, 2000);
      resolved = true;
      const partial = stdout.length > 0
        ? `\n[부분 출력 ${stdout.length}B]\n${stdout.slice(0, 2000)}`
        : '';
      resolve({ ok: false, output: `[타임아웃 ${timeoutMs / 1000}s]${partial}`, exitCode: -1, stdoutTruncated: stdout.length >= MAX_BUF });
    }, timeoutMs);

    proc.on('close', (code) => {
      if (resolved) return;
      clearTimeout(timer);
      let combined = stdout + (stderr ? `\n[stderr] ${stderr.slice(0, 500)}` : '');
      if (stdoutTruncated) combined = `[출력 잘림: 1MB+ 수신됨]\n` + combined;
      resolve({ ok: code === 0, output: combined, exitCode: code, stdoutTruncated });
    });

    proc.on('error', (err) => {
      if (resolved) return;
      clearTimeout(timer);
      resolve({ ok: false, output: `Error: ${err.message}`, exitCode: -1, stdoutTruncated: false });
    });
  });
}

// execFile re-export for gateways that need it
export { execFile };
