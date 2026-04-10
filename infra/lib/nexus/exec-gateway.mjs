/**
 * nexus/exec-gateway.mjs — 명령 실행 게이트웨이
 * 도구: exec, scan, cache_exec, log_tail, file_peek
 */

import { existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import {
  BOT_HOME, LOGS_DIR,
  clamp, mkResult, mkError, logTelemetry,
  runCmd, smartCompress, execFile,
  validateCommand, validatePath,
} from './shared.mjs';

// ---------------------------------------------------------------------------
// Concurrency limiter — scan() 동시 프로세스 상한 (macOS ulimit 보호)
// ---------------------------------------------------------------------------
const MAX_CONCURRENT_PROCS = 8; // macOS ulimit -n 256 기준 안전 상한

async function mapLimited(items, limit, fn) {
  const results = [];
  for (let i = 0; i < items.length; i += limit) {
    const batch = items.slice(i, i + limit);
    results.push(...await Promise.allSettled(batch.map(fn)));
  }
  return results;
}

// ---------------------------------------------------------------------------
// Circuit Breaker — 5분 내 2회 타임아웃 시 10분 차단 (exec 전용)
// ---------------------------------------------------------------------------
const _cbMap = new Map(); // cmd fingerprint → { count, firstAt, openUntil }

function cbCheck(cmd) {
  const key = cmd.trim().slice(0, 200);
  const entry = _cbMap.get(key);
  if (!entry) return null;
  if (Date.now() < entry.openUntil) {
    return { open: true, remaining: Math.ceil((entry.openUntil - Date.now()) / 60000) };
  }
  return null;
}

function cbRecord(cmd) {
  const key = cmd.trim().slice(0, 200);
  const now = Date.now();
  const WINDOW = 5 * 60 * 1000; // 5분 윈도우
  const BLOCK  = 10 * 60 * 1000; // 10분 차단
  const entry = _cbMap.get(key) || { count: 0, firstAt: now, openUntil: 0 };
  if (now - entry.firstAt > WINDOW) {
    _cbMap.set(key, { count: 1, firstAt: now, openUntil: 0 });
    return;
  }
  entry.count++;
  if (entry.count >= 2) entry.openUntil = now + BLOCK;
  _cbMap.set(key, entry);
}

// 만료 항목 정기 정리 (30분마다)
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of _cbMap) {
    if (now > v.openUntil + 30 * 60 * 1000) _cbMap.delete(k);
  }
}, 30 * 60 * 1000).unref();

// ---------------------------------------------------------------------------
// TTL Cache — LRU 200-entry cap
// ---------------------------------------------------------------------------
const cache = new Map();

export function getCached(cmd) {
  const entry = cache.get(cmd);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) { cache.delete(cmd); return null; }
  return entry;
}

export function setCached(cmd, output, ttlMs) {
  if (cache.size >= 200) {
    let oldestKey = null, oldestTime = Infinity;
    for (const [k, v] of cache) {
      if (v.createdAt < oldestTime) { oldestTime = v.createdAt; oldestKey = k; }
    }
    if (oldestKey !== null) cache.delete(oldestKey);
  }
  cache.set(cmd, { output, expiresAt: Date.now() + ttlMs, createdAt: Date.now() });
}

export function getCacheStats() {
  const now = Date.now();
  let active = 0;
  for (const v of cache.values()) {
    if (now <= v.expiresAt) active++;
  }
  return { total: cache.size, active, capacity: 200 };
}

// 만료 항목 주기적 정리 (5분마다)
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of cache) {
    if (now > v.expiresAt) cache.delete(k);
  }
}, 300_000).unref();

// ---------------------------------------------------------------------------
// Log aliases
// ---------------------------------------------------------------------------
function buildLogAliases() {
  const aliases = {
    'discord-bot':  `${LOGS_DIR}/discord-bot.out.log`,
    'discord':      `${LOGS_DIR}/discord-bot.out.log`,
    'cron':         `${LOGS_DIR}/cron.log`,
    'watchdog':     `${LOGS_DIR}/watchdog.log`,
    'bot-watchdog': `${LOGS_DIR}/bot-watchdog.log`,
    'guardian':     `${LOGS_DIR}/launchd-guardian.log`,
    'rag':          `${LOGS_DIR}/rag-index.log`,
    'e2e':          `${LOGS_DIR}/e2e-cron.log`,
    'health':       `${LOGS_DIR}/health.log`,
  };
  try {
    for (const f of readdirSync(LOGS_DIR)) {
      if (!f.endsWith('.log') && !f.endsWith('.jsonl')) continue;
      const key = f.replace(/\.(out\.log|log|jsonl)$/, '');
      if (!aliases[key]) aliases[key] = `${LOGS_DIR}/${f}`;
    }
  } catch { /* logs dir may not exist yet */ }
  return aliases;
}
const LOG_ALIASES = buildLogAliases();
export { LOG_ALIASES };

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------
export const TOOLS = [
  {
    name: 'exec',
    description:
      '⚠️ 마지막 수단 — 아래 전용 도구로 처리 불가한 커스텀 명령에만 사용:\n' +
      '• 로그 읽기(tail/cat .log) → log_tail 사용\n' +
      '• 반복 명령(ps/df/uptime/launchctl list/node -v) → cache_exec 사용\n' +
      '• 시스템 전체 상태 → health 사용\n' +
      '전용 도구가 없는 커스텀 명령에만 exec 사용. 컨텍스트 소모 98% 절약.',
    inputSchema: {
      type: 'object',
      properties: {
        cmd: { type: 'string', description: '실행할 bash 명령' },
        max_lines: { type: 'number', description: '반환할 최대 줄 수 (기본 50)', default: 50 },
        timeout_sec: { type: 'number', description: '타임아웃 초 (기본 10)', default: 10 },
      },
      required: ['cmd'],
    },
    annotations: { title: 'Execute Command', readOnlyHint: false, destructiveHint: true, openWorldHint: true },
  },
  {
    name: 'scan',
    description:
      '다중 명령 병렬 실행 → 단일 컨텍스트 엔트리로 합쳐 반환. ' +
      '여러 시스템 상태를 한 번에 조회할 때 사용. ' +
      '전체 응답 최대 100줄 (안전 상한, 항목별 예산 별도 적용).',
    inputSchema: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          description: '실행할 명령 목록',
          items: {
            type: 'object',
            properties: {
              cmd: { type: 'string', description: '실행할 bash 명령' },
              label: { type: 'string', description: '섹션 라벨 (기본: cmd)' },
              max_lines: { type: 'number', description: '이 명령의 최대 줄 수 (기본 20)', default: 20 },
            },
            required: ['cmd'],
          },
        },
      },
      required: ['items'],
    },
    annotations: { title: 'Parallel Scan', readOnlyHint: false, destructiveHint: true, openWorldHint: true },
  },
  {
    name: 'cache_exec',
    description:
      '✅ 반복 명령 전용 — ps, df, uptime, launchctl list, node -v 등 자주 호출되는 상태 조회에 반드시 사용. ' +
      'TTL 내 동일 명령 재요청 시 0ms 캐시 반환. exec보다 항상 우선.',
    inputSchema: {
      type: 'object',
      properties: {
        cmd: { type: 'string', description: '실행할 bash 명령' },
        ttl_sec: { type: 'number', description: '캐시 유지 시간 초 (기본 30)', default: 30 },
        max_lines: { type: 'number', description: '반환할 최대 줄 수 (기본 50)', default: 50 },
      },
      required: ['cmd'],
    },
    annotations: { title: 'Cached Execute', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'log_tail',
    description:
      '✅ 로그 파일 전용 — tail/cat 대신 항상 이 도구 사용. ' +
      '지원 이름: discord, cron, watchdog, rag, guardian, bot-watchdog, e2e, system-doctor 등. ' +
      '에러/경고 자동 하이라이팅. exec으로 .log 파일 읽지 말 것.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: '로그 이름 또는 절대 경로' },
        lines: { type: 'number', description: '읽을 줄 수 (기본 30)', default: 30 },
      },
      required: ['name'],
    },
    annotations: { title: 'Log Tail', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'file_peek',
    description:
      '파일 전체 대신 패턴 주변 줄만 추출. ' +
      '대용량 파일에서 필요한 부분만 읽을 때 사용.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '파일 경로' },
        pattern: { type: 'string', description: '검색할 패턴 (grep 정규식)' },
        context_lines: { type: 'number', description: '패턴 앞뒤 표시 줄 수 (기본 3)', default: 3 },
        max_matches: { type: 'number', description: '최대 매치 수 (기본 10)', default: 10 },
      },
      required: ['path', 'pattern'],
    },
    annotations: { title: 'File Peek', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
];

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
export async function handle(name, args, start) {
  if (name === 'exec') {
    const cmdCheck = validateCommand(args.cmd);
    if (!cmdCheck.ok) {
      logTelemetry('exec', Date.now() - start, { blocked: true, reason: cmdCheck.reason });
      return mkError(`🛡️ ${cmdCheck.reason}`, { tool: 'exec', blocked: true });
    }
    // Circuit breaker: 반복 타임아웃 차단
    const cb = cbCheck(args.cmd);
    if (cb) {
      logTelemetry('exec', 0, { cmd: args.cmd?.slice(0, 120), blocked: true, reason: 'circuit_open', remaining_min: cb.remaining });
      return mkError(
        `⚡ Circuit Breaker: 이 명령이 5분 내 반복 타임아웃됨. ${cb.remaining}분 후 재시도하거나 log_tail/cache_exec/health 사용.`,
        { circuit_open: true, remaining_min: cb.remaining },
      );
    }
    const maxLines = clamp(args.max_lines ?? 50, 1, 500);
    const timeout = clamp(args.timeout_sec ?? 10, 1, 120) * 1000;
    const { ok, output, exitCode, stdoutTruncated } = await runCmd(args.cmd, timeout);
    if (exitCode === -1) cbRecord(args.cmd); // 타임아웃 기록
    const compressed = smartCompress(output, maxLines);
    const prefix = ok ? '' : `[exit ${exitCode}] `;
    const resultLines = compressed.split('\n').length;
    logTelemetry('exec', Date.now() - start, { cmd: args.cmd?.slice(0, 120), cache_hit: false, result_lines: resultLines, exit_code: exitCode });
    return mkResult(prefix + compressed, { lines: resultLines, cache_hit: false, exit_code: exitCode, truncated: stdoutTruncated });
  }

  if (name === 'scan') {
    const items = args.items || [];
    if (items.length === 0) {
      logTelemetry('scan', Date.now() - start, { items: 0 });
      return mkResult('(항목 없음)', { items: 0, total_lines: 0 });
    }
    const settled = await mapLimited(items, MAX_CONCURRENT_PROCS, async (item) => {
        const safeLabel = String(item.label || item.cmd).replace(/[`$\\]/g, '').slice(0, 80);
        const cmdCheck = validateCommand(item.cmd);
        if (!cmdCheck.ok) return `=== ${safeLabel} ===\n🛡️ ${cmdCheck.reason}`;
        const cb = cbCheck(item.cmd);
        if (cb) return `=== ${safeLabel} ===\n⚡ Circuit Breaker: ${cb.remaining}분 차단 중`;
        const maxL = clamp(item.max_lines ?? 20, 1, 500);
        const { ok, output, exitCode } = await runCmd(item.cmd, 10000);
        if (exitCode === -1) cbRecord(item.cmd);
        const compressed = smartCompress(output, maxL);
        const prefix = ok ? '' : `[exit ${exitCode}] `;
        const originalLines = output.split('\n').length;
        const suffix = originalLines > maxL * 1.5 ? `\n[⚠ ${originalLines}줄 → ${maxL}줄로 잘림]` : '';
        return `=== ${safeLabel} ===\n${prefix}${compressed}${suffix}`;
    });
    const results = settled.map((r, i) => {
      if (r.status === 'fulfilled') return r.value;
      const safeLabel = String(items[i].label || items[i].cmd).replace(/[`$\\]/g, '').slice(0, 80);
      return `=== ${safeLabel} ===\n[오류: ${r.reason}]`;
    });
    const merged = results.join('\n\n');
    const mergedLines = merged.split('\n');
    logTelemetry('scan', Date.now() - start, { items: items.length, total_lines: mergedLines.length });
    if (mergedLines.length > 100) {
      return mkResult(
        mergedLines.slice(0, 100).join('\n') + `\n...[안전 상한 100줄 초과: 전체 ${mergedLines.length}줄]`,
        { items: items.length, total_lines: mergedLines.length },
      );
    }
    return mkResult(merged, { items: items.length, total_lines: mergedLines.length });
  }

  if (name === 'cache_exec') {
    const cmdCheck = validateCommand(args.cmd);
    if (!cmdCheck.ok) {
      logTelemetry('cache_exec', Date.now() - start, { blocked: true, reason: cmdCheck.reason });
      return mkError(`🛡️ ${cmdCheck.reason}`, { tool: 'cache_exec', blocked: true });
    }
    const ttlSec = clamp(args.ttl_sec ?? 30, 1, 3600);
    const maxLines = clamp(args.max_lines ?? 50, 1, 500);
    const cmd = args.cmd;
    const cached = getCached(cmd);
    if (cached) {
      const agoSec = Math.round((Date.now() - cached.createdAt) / 1000);
      const resultLines = cached.output.split('\n').length;
      logTelemetry('cache_exec', Date.now() - start, { cache_hit: true, result_lines: resultLines });
      return mkResult(`[캐시 ${agoSec}s전]\n${cached.output}`, { cache_hit: true, lines: resultLines });
    }
    const { ok, output, exitCode } = await runCmd(cmd, 10000);
    const compressed = smartCompress(output, maxLines);
    const prefix = ok ? '' : `[exit ${exitCode}] `;
    const result = prefix + compressed;
    setCached(cmd, result, ttlSec * 1000);
    const resultLines = result.split('\n').length;
    logTelemetry('cache_exec', Date.now() - start, { cache_hit: false, result_lines: resultLines, exit_code: exitCode });
    return mkResult(result, { cache_hit: false, lines: resultLines, exit_code: exitCode });
  }

  if (name === 'log_tail') {
    const lines = args.lines ?? 30;
    let filePath = args.name.startsWith('/') ? args.name : LOG_ALIASES[args.name];
    // 절대 경로인 경우 허용 범위 검사
    if (args.name.startsWith('/')) {
      const pathCheck = validatePath(args.name);
      if (!pathCheck.ok) {
        logTelemetry('log_tail', Date.now() - start, { blocked: true, reason: pathCheck.reason });
        return mkError(`🛡️ ${pathCheck.reason}`, { tool: 'log_tail', blocked: true });
      }
    }
    if (!filePath) {
      const available = Object.keys(LOG_ALIASES).join(', ');
      logTelemetry('log_tail', Date.now() - start, { log_name: args.name, error: 'unknown' });
      return mkError(`알 수 없는 로그: ${args.name}\n사용 가능: ${available}`, { log_name: args.name });
    }
    if (!existsSync(filePath)) {
      logTelemetry('log_tail', Date.now() - start, { log_name: args.name, error: 'not_found' });
      return mkError(`로그 파일 없음: ${filePath}`, { log_name: args.name });
    }
    const output = await new Promise((resolve) => {
      execFile('tail', ['-n', String(lines), filePath], { timeout: 5000, encoding: 'utf-8' },
        (err, stdout) => resolve(stdout || (err ? `오류: ${err.message}` : '(비어있음)')));
    });
    const compressed = smartCompress(output, lines);
    const linesReturned = compressed.split('\n').length;
    logTelemetry('log_tail', Date.now() - start, { log_name: args.name, lines_returned: linesReturned });
    return mkResult(compressed, { log_name: args.name, lines_returned: linesReturned });
  }

  if (name === 'file_peek') {
    const ctx = String(args.context_lines ?? 3);
    const maxM = String(args.max_matches ?? 10);
    const expandedPath = args.path.replace('~', homedir());
    // 경로 허용 범위 검사
    const pathCheck = validatePath(expandedPath);
    if (!pathCheck.ok) {
      logTelemetry('file_peek', Date.now() - start, { blocked: true, reason: pathCheck.reason });
      return mkError(`🛡️ ${pathCheck.reason}`, { tool: 'file_peek', blocked: true });
    }
    try { new RegExp(args.pattern); } catch (e) {
      logTelemetry('file_peek', Date.now() - start, { error: 'bad_pattern' });
      return mkError(`패턴 오류: ${e.message}`, { pattern: args.pattern });
    }
    const output = await new Promise((resolve) => {
      execFile('grep', ['-n', '-m', maxM, '-E', args.pattern, expandedPath, '-A', ctx, '-B', ctx],
        { timeout: 5000, encoding: 'utf-8' },
        (err, stdout) => resolve(stdout || '(no match)'),
      );
    });
    const matchesFound = (output.match(/^--$/gm) || []).length + (output !== '(no match)' ? 1 : 0);
    logTelemetry('file_peek', Date.now() - start, { matches_found: matchesFound, pattern: args.pattern });
    return mkResult(output.trimEnd(), { matches_found: matchesFound, pattern: args.pattern });
  }

  return null; // unknown tool — let orchestrator handle
}
