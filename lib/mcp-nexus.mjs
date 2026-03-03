#!/usr/bin/env node
/**
 * mcp-nexus.mjs — Context Intelligence Gateway
 *
 * 모든 시스템 조회가 이 게이트웨이를 통과한다.
 * 원시 출력(315KB) → 압축(5.4KB) → Claude 컨텍스트
 *
 * Context Mode 개념을 직접 구현 + 확장:
 * - 지능형 압축 (log/json/process/table 타입 자동 감지)
 * - scan(): 다중 명령 병렬 실행 → 단일 컨텍스트 엔트리
 * - TTL 캐시: 30초 내 중복 실행 방지
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { spawn, execFile } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const BOT_HOME = join(process.env.BOT_HOME || join(homedir(), 'claude-discord-bridge'));
const LOGS_DIR = join(BOT_HOME, 'logs');

const LOG_ALIASES = {
  'discord-bot':  join(LOGS_DIR, 'discord-bot.out.log'),
  'discord':      join(LOGS_DIR, 'discord-bot.out.log'),
  'cron':         join(LOGS_DIR, 'cron.log'),
  'watchdog':     join(LOGS_DIR, 'watchdog.log'),
  'bot-watchdog': join(LOGS_DIR, 'bot-watchdog.log'),
  'guardian':     join(LOGS_DIR, 'launchd-guardian.log'),
  'rag':          join(LOGS_DIR, 'rag-index.log'),
  'e2e':          join(LOGS_DIR, 'e2e-cron.log'),
  'health':       join(LOGS_DIR, 'health.log'),
};

// ---------------------------------------------------------------------------
// TTL Cache
// ---------------------------------------------------------------------------
const cache = new Map(); // key: cmd, value: { output, expiresAt }

function getCached(cmd) {
  const entry = cache.get(cmd);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) {
    cache.delete(cmd);
    return null;
  }
  return entry;
}

function setCached(cmd, output, ttlMs) {
  cache.set(cmd, { output, expiresAt: Date.now() + ttlMs });
}

// 만료 항목 주기적 정리 (5분마다)
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of cache) {
    if (now > v.expiresAt) cache.delete(k);
  }
}, 300_000).unref();

// ---------------------------------------------------------------------------
// Smart Compress — 출력 타입 자동 감지 + 전략별 압축
// ---------------------------------------------------------------------------

function detectStrategy(output) {
  if (!output || output.length < 10) return 'plain';
  const trimmed = output.trimStart();
  // JSON 감지
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return 'json';
  // Process list 감지 (ps aux 패턴)
  if (/\bPID\b/.test(trimmed.split('\n')[0]) || /^\S+\s+\d+\s+\d+\.\d+\s+\d+\.\d+/.test(trimmed.split('\n')[1] || '')) return 'process';
  // Log 감지 (timestamp + level 패턴)
  const logPattern = /\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}|(\b(ERROR|WARN|INFO|DEBUG)\b)/;
  const lines = trimmed.split('\n').slice(0, 10);
  const logMatches = lines.filter(l => logPattern.test(l)).length;
  if (logMatches >= 3) return 'log';
  // Table 감지 (| 구분자)
  const tableMatches = lines.filter(l => (l.match(/\|/g) || []).length >= 2).length;
  if (tableMatches >= 3) return 'table';
  return 'plain';
}

function compressLog(text, maxLines = 50) {
  const lines = text.split('\n');
  const errors = [];
  const warns = [];
  for (const line of lines) {
    if (/\bERROR\b/i.test(line)) errors.push(line);
    else if (/\bWARN(ING)?\b/i.test(line)) warns.push(line);
  }
  const important = [...errors.slice(-5), ...warns.slice(-5)];
  const recent = lines.slice(-20);
  const summary = `[로그 요약] 총 ${lines.length}줄, ${errors.length}오류, ${warns.length}경고`;
  const uniqueLines = [...new Set([...important, '---', ...recent])];
  const result = [summary, '', ...uniqueLines].join('\n');
  return result.split('\n').slice(0, maxLines).join('\n').trimEnd();
}

function compressJson(text, maxChars = 2000) {
  try {
    const obj = JSON.parse(text);
    const trimmed = JSON.stringify(obj, (key, val) => {
      // depth 제한: 중첩 객체/배열은 요약
      if (typeof val === 'object' && val !== null) {
        const str = JSON.stringify(val);
        if (str.length > 500) {
          if (Array.isArray(val)) return `[Array(${val.length})]`;
          const keys = Object.keys(val);
          if (keys.length > 8) return `{${keys.slice(0, 5).join(', ')}... +${keys.length - 5}}`;
        }
      }
      return val;
    }, 2);
    if (trimmed.length <= maxChars) return trimmed;
    return trimmed.slice(0, maxChars) + '\n...[JSON 잘림]';
  } catch {
    // JSON 파싱 실패 → 줄 단위 fallback
    return compressPlain(text, 40);
  }
}

function compressProcess(text) {
  const lines = text.split('\n').filter(l => l.trim());
  if (lines.length <= 1) return text.trimEnd();
  const header = lines[0];
  const procs = lines.slice(1);
  // 명령(마지막 필드) 기준 그룹화
  const groups = {};
  for (const line of procs) {
    const parts = line.trim().split(/\s+/);
    const cmd = parts.slice(10).join(' ') || parts[parts.length - 1] || 'unknown';
    // 기본 명령 이름만 추출
    const base = cmd.split('/').pop().split(' ')[0];
    if (!groups[base]) groups[base] = 0;
    groups[base]++;
  }
  const summary = Object.entries(groups)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 15)
    .map(([name, count]) => count > 1 ? `  ${name} x${count}` : `  ${name}`)
    .join('\n');
  return `[프로세스 요약] 총 ${procs.length}개\n${summary}`;
}

function compressPlain(text, maxLines = 50) {
  if (!text) return '(empty)';
  const lines = text.split('\n');
  if (lines.length <= maxLines) return text.trimEnd();
  const kept = lines.slice(-maxLines);
  return `...[${lines.length - maxLines}줄 생략]\n${kept.join('\n').trimEnd()}`;
}

function smartCompress(text, maxLines = 50) {
  if (!text) return '(empty)';
  const strategy = detectStrategy(text);
  switch (strategy) {
    case 'log':     return compressLog(text, maxLines);
    case 'json':    return compressJson(text);
    case 'process': return compressProcess(text);
    case 'table':   return compressPlain(text, maxLines); // 테이블은 줄 단위 보존
    default:        return compressPlain(text, maxLines);
  }
}

// ---------------------------------------------------------------------------
// Command Execution (async, with timeout)
// ---------------------------------------------------------------------------

function runCmd(cmd, timeoutMs = 10000) {
  return new Promise((resolve) => {
    const proc = spawn('bash', ['-c', cmd], {
      encoding: 'utf-8',
      timeout: timeoutMs,
      env: { ...process.env, PATH: process.env.PATH },
    });
    const MAX_BUF = 1 * 1024 * 1024; // 1MB per stream
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { if (stdout.length < MAX_BUF) stdout += d; });
    proc.stderr.on('data', (d) => { if (stderr.length < MAX_BUF) stderr += d; });

    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      resolve({ ok: false, output: `[타임아웃 ${timeoutMs / 1000}s]`, exitCode: -1 });
    }, timeoutMs);

    proc.on('close', (code) => {
      clearTimeout(timer);
      const combined = stdout + (stderr ? `\n[stderr] ${stderr.slice(0, 500)}` : '');
      resolve({ ok: code === 0, output: combined, exitCode: code });
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      resolve({ ok: false, output: `Error: ${err.message}`, exitCode: -1 });
    });
  });
}

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new Server(
  { name: 'nexus-cig', version: '2.0.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'exec',
      description:
        '명령을 서브프로세스에서 실행하고 지능형 압축된 출력 반환. ' +
        'log/json/process/table 타입 자동 감지하여 최적 압축. ' +
        'Bash 도구 대신 사용하면 컨텍스트 소모 최대 98% 절약.',
      inputSchema: {
        type: 'object',
        properties: {
          cmd: { type: 'string', description: '실행할 bash 명령' },
          max_lines: {
            type: 'number',
            description: '반환할 최대 줄 수 (기본 50)',
            default: 50,
          },
          timeout_sec: {
            type: 'number',
            description: '타임아웃 초 (기본 10)',
            default: 10,
          },
        },
        required: ['cmd'],
      },
    },
    {
      name: 'scan',
      description:
        '다중 명령 병렬 실행 → 단일 컨텍스트 엔트리로 합쳐 반환. ' +
        '여러 시스템 상태를 한 번에 조회할 때 사용. ' +
        '전체 응답 최대 100줄.',
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
    },
    {
      name: 'cache_exec',
      description:
        'TTL 캐시 지원 명령 실행. 동일 명령 반복 시 캐시 반환. ' +
        '빈번한 시스템 조회 (ps, df, uptime 등)에 적합.',
      inputSchema: {
        type: 'object',
        properties: {
          cmd: { type: 'string', description: '실행할 bash 명령' },
          ttl_sec: {
            type: 'number',
            description: '캐시 유지 시간 초 (기본 30)',
            default: 30,
          },
          max_lines: {
            type: 'number',
            description: '반환할 최대 줄 수 (기본 50)',
            default: 50,
          },
        },
        required: ['cmd'],
      },
    },
    {
      name: 'log_tail',
      description:
        '로그 파일을 이름으로 빠르게 읽기. ' +
        '이름: discord-bot, discord, cron, watchdog, bot-watchdog, guardian, rag, e2e, health. ' +
        '자동 지능형 압축 적용.',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: '로그 이름 또는 절대 경로' },
          lines: {
            type: 'number',
            description: '읽을 줄 수 (기본 30)',
            default: 30,
          },
        },
        required: ['name'],
      },
    },
    {
      name: 'health',
      description:
        '시스템 전체 상태를 단일 호출로 요약. ' +
        'LaunchAgent 상태, 디스크, 메모리, 프로세스, 크론 최근 실행 포함. ' +
        '에러 하이라이트 + 프로세스 요약 포함.',
      inputSchema: {
        type: 'object',
        properties: {},
      },
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
          context_lines: {
            type: 'number',
            description: '패턴 앞뒤 표시 줄 수 (기본 3)',
            default: 3,
          },
          max_matches: {
            type: 'number',
            description: '최대 매치 수 (기본 10)',
            default: 10,
          },
        },
        required: ['path', 'pattern'],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    // ----- exec -----
    if (name === 'exec') {
      const maxLines = args.max_lines ?? 50;
      const timeout = (args.timeout_sec ?? 10) * 1000;
      const { ok, output, exitCode } = await runCmd(args.cmd, timeout);
      const compressed = smartCompress(output, maxLines);
      const prefix = ok ? '' : `[exit ${exitCode}] `;
      return { content: [{ type: 'text', text: prefix + compressed }] };
    }

    // ----- scan -----
    if (name === 'scan') {
      const items = args.items || [];
      if (items.length === 0) {
        return { content: [{ type: 'text', text: '(항목 없음)' }] };
      }
      const results = await Promise.all(
        items.map(async (item) => {
          const label = item.label || item.cmd;
          const maxL = item.max_lines ?? 20;
          const { ok, output, exitCode } = await runCmd(item.cmd, 10000);
          const compressed = smartCompress(output, maxL);
          const prefix = ok ? '' : `[exit ${exitCode}] `;
          return `=== ${label} ===\n${prefix}${compressed}`;
        }),
      );
      // 전체 100줄 제한
      const merged = results.join('\n\n');
      const mergedLines = merged.split('\n');
      if (mergedLines.length > 100) {
        return {
          content: [{ type: 'text', text: mergedLines.slice(0, 100).join('\n') + '\n...[100줄 제한]' }],
        };
      }
      return { content: [{ type: 'text', text: merged }] };
    }

    // ----- cache_exec -----
    if (name === 'cache_exec') {
      const ttlSec = args.ttl_sec ?? 30;
      const maxLines = args.max_lines ?? 50;
      const cmd = args.cmd;

      const cached = getCached(cmd);
      if (cached) {
        const agoSec = Math.round((Date.now() - (cached.expiresAt - ttlSec * 1000)) / 1000);
        return { content: [{ type: 'text', text: `[캐시 ${agoSec}s전]\n${cached.output}` }] };
      }

      const { ok, output, exitCode } = await runCmd(cmd, 10000);
      const compressed = smartCompress(output, maxLines);
      const prefix = ok ? '' : `[exit ${exitCode}] `;
      const result = prefix + compressed;
      setCached(cmd, result, ttlSec * 1000);
      return { content: [{ type: 'text', text: result }] };
    }

    // ----- log_tail -----
    if (name === 'log_tail') {
      const lines = args.lines ?? 30;
      const filePath = args.name.startsWith('/') ? args.name : LOG_ALIASES[args.name];
      if (!filePath) {
        const available = Object.keys(LOG_ALIASES).join(', ');
        return { content: [{ type: 'text', text: `알 수 없는 로그: ${args.name}\n사용 가능: ${available}` }] };
      }
      if (!existsSync(filePath)) {
        return { content: [{ type: 'text', text: `로그 파일 없음: ${filePath}` }] };
      }
      const output = await new Promise((resolve) => {
        execFile('tail', ['-n', String(lines), filePath], { timeout: 5000, encoding: 'utf-8' },
          (err, stdout) => resolve(stdout || (err ? `오류: ${err.message}` : '(비어있음)')));
      });
      const compressed = smartCompress(output, lines);
      return { content: [{ type: 'text', text: compressed }] };
    }

    // ----- health -----
    if (name === 'health') {
      const checks = [
        // LaunchAgents
        `echo "=== LaunchAgents ==="`,
        `launchctl list ai.discord-bot 2>/dev/null | grep -E 'PID|Exit' || echo "discord-bot: NOT LOADED"`,
        `launchctl list ai.discord-watchdog 2>/dev/null | grep -E 'PID|Exit' || echo "watchdog: NOT LOADED"`,
        // 디스크/메모리
        `echo "=== 리소스 ==="`,
        `df -h / | tail -1 | awk '{print "Disk: "$5" used ("$3"/"$2")"}'`,
        `vm_stat | awk '/Pages free/{free=$3} /Pages active/{act=$3} END{printf "Mem free: %.1fGB\\n", (free+0)*4096/1073741824}'`,
        // 프로세스 요약 (스마트)
        `echo "=== 프로세스 ==="`,
        `ps aux | awk 'NR>1{split($11,a,"/"); name=a[length(a)]; cnt[name]++} END{n=asorti(cnt,sorted); for(i=1;i<=n&&i<=10;i++) printf "%s x%d\\n",sorted[i],cnt[sorted[i]]}' 2>/dev/null || echo "(ps 실패)"`,
        `echo ""`,
        `echo "Bot 프로세스:"`,
        `pgrep -fl "discord-bot.js" | head -3 || echo "  discord-bot.js: 실행중 아님"`,
        `pgrep -fl "claude.*-p" | head -3 || echo "  claude -p: 실행중 아님"`,
        // 크론 최근 실행
        `echo "=== 크론 최근 ==="`,
        `tail -5 "${join(LOGS_DIR, 'cron.log')}" 2>/dev/null || echo "(크론 로그 없음)"`,
        // health.json 에러 하이라이트
        `echo "=== 상태 ==="`,
        `cat "${join(BOT_HOME, 'state', 'health.json')}" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for k,v in d.items():
    if k=='checks': continue
    print(f'{k}: {v}')
if 'checks' in d:
    fails=[c for c in d['checks'] if c.get('status')!='ok']
    if fails:
        print('\\n[!] 실패 체크:')
        for f in fails[:5]:
            print(f'  - {f.get(\"name\",\"??\")}: {f.get(\"status\",\"??\")}: {f.get(\"message\",\"\")}')
    else:
        print(f'체크 {len(d[\"checks\"])}개 모두 OK')
" 2>/dev/null || echo "(health.json 없음)"`,
      ];
      const { output } = await runCmd(checks.join(' && '), 15000);
      return { content: [{ type: 'text', text: smartCompress(output, 60) }] };
    }

    // ----- file_peek -----
    if (name === 'file_peek') {
      const ctx = String(args.context_lines ?? 3);
      const maxM = String(args.max_matches ?? 10);
      const expandedPath = args.path.replace('~', homedir());
      // Use execFile to avoid shell injection from pattern argument
      const { execFile } = await import('node:child_process');
      const output = await new Promise((resolve) => {
        execFile('grep', ['-n', '-m', maxM, '-E', args.pattern, expandedPath, '-A', ctx, '-B', ctx],
          { timeout: 5000, encoding: 'utf-8' },
          (err, stdout) => resolve(stdout || '(no match)'),
        );
      });
      return { content: [{ type: 'text', text: output.trimEnd() }] };
    }

    return { content: [{ type: 'text', text: `알 수 없는 도구: ${name}` }], isError: true };
  } catch (err) {
    return { content: [{ type: 'text', text: `오류: ${err.message}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
