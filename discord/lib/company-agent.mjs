/**
 * Jarvis Company Agent Runner
 * @anthropic-ai/claude-agent-sdk 기반 자비스 컴퍼니 팀장 에이전트
 *
 * Usage: node company-agent.mjs --team <name>
 * Teams: council | infra | record | brand | career | academy | trend | standup
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import {
  readFileSync, writeFileSync, mkdirSync,
  existsSync, appendFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

// Allow running from within Claude Code (nested session guard bypass)
delete process.env.CLAUDECODE;

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const MODELS = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'models.json'), 'utf-8'));
const OWNER_NAME = process.env.OWNER_NAME || 'Owner';
const LOG_DIR  = join(BOT_HOME, 'logs');
const REPORTS  = join(BOT_HOME, 'rag', 'teams', 'reports');
const CTX_BUS  = join(BOT_HOME, 'state', 'context-bus.md');
const VAULT_TEAMS = join(homedir(), 'Jarvis-Vault', '03-teams');
const VAULT_STANDUP = join(homedir(), 'Jarvis-Vault', '02-daily', 'standup');

mkdirSync(LOG_DIR, { recursive: true });
mkdirSync(REPORTS, { recursive: true });
mkdirSync(join(BOT_HOME, 'state'), { recursive: true });

// --team argument
const teamArg = (() => {
  const idx = process.argv.indexOf('--team');
  if (idx !== -1) return process.argv[idx + 1];
  const eq = process.argv.find((a) => a.startsWith('--team='));
  return eq?.split('=')[1] ?? null;
})();

// --event <type> --data <json> argument (이벤트 드리븐 팀 활성화)
const eventArg = (() => {
  const idx = process.argv.indexOf('--event');
  if (idx !== -1) return process.argv[idx + 1];
  const eq = process.argv.find((a) => a.startsWith('--event='));
  return eq?.split('=')[1] ?? null;
})();
const eventData = (() => {
  const idx = process.argv.indexOf('--data');
  if (idx !== -1) try { return JSON.parse(process.argv[idx + 1]); } catch { return {}; }
  return {};
})();

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

function loadJSON(path) {
  try { return JSON.parse(readFileSync(path, 'utf-8')); } catch { return {}; }
}
// MCP 설정 전용 로더: ${ENV_VAR} 보간 지원
function loadMcpJSON(path) {
  try {
    const raw = readFileSync(path, 'utf-8')
      .replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] ?? '');
    return JSON.parse(raw);
  } catch { return {}; }
}

const monitoring = loadJSON(join(BOT_HOME, 'config', 'monitoring.json'));
const mcpCfg     = loadMcpJSON(join(BOT_HOME, 'config', 'discord-mcp.json'));
const MCP        = mcpCfg.mcpServers ?? {};

const NOW  = new Date();
const KST  = new Date(NOW.getTime() + 9 * 3600_000);
const DATE = KST.toISOString().slice(0, 10);
const WEEK = (() => {
  const d = new Date(KST);
  d.setUTCHours(0, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
  const y = d.getUTCFullYear();
  const w = Math.ceil((((d - new Date(Date.UTC(y, 0, 1))) / 86400_000) + 1) / 7);
  return `${y}-W${String(w).padStart(2, '0')}`;
})();

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function log(level, msg) {
  const label = eventArg ? `event:${eventArg}` : (teamArg ?? '?');
  const line = `[${new Date().toISOString()}] [${level.toUpperCase()}] [${label}] ${msg}`;
  console.log(line);
  appendFileSync(
    join(LOG_DIR, 'company-agent.jsonl'),
    JSON.stringify({ ts: new Date().toISOString(), level, team: label, msg }) + '\n',
  );
}

async function sendWebhook(channelKey, content) {
  const url = monitoring.webhooks?.[channelKey];
  if (!url || !content) return;
  content = content.replace(/https?:\/\/[^ )>\n]+/g, '');
  // Discord 2000자 제한으로 청킹 — 단어/줄 경계에서 자르기
  const LIMIT = 1990;
  let pos = 0;
  while (pos < content.length) {
    let end = pos + LIMIT;
    if (end < content.length) {
      // 줄바꿈 → 공백 순으로 경계 탐색
      const cutNl = content.lastIndexOf('\n', end);
      const cutSp = content.lastIndexOf(' ', end);
      if (cutNl > pos) end = cutNl + 1;
      else if (cutSp > pos) end = cutSp + 1;
    }
    const chunk = content.slice(pos, end);
    try {
      await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content: chunk }),
      });
      if (end < content.length) await new Promise((r) => setTimeout(r, 500));
    } catch (e) { log('warn', `webhook(${channelKey}) failed: ${e.message}`); }
    pos = end;
  }
}

function readContextBus() {
  try { return readFileSync(CTX_BUS, 'utf-8'); } catch { return ''; }
}

function updateContextBus(report) {
  const header = `# 자비스 컴퍼니 Context Bus\n_업데이트: ${KST.toISOString().slice(0, 16)} KST_\n\n`;
  writeFileSync(CTX_BUS, header + report, 'utf-8');
}

// task-runner.jsonl 호환 로깅 (measure-kpi.sh가 읽음)
function logTaskResult(taskId, status, ms) {
  appendFileSync(
    join(LOG_DIR, 'task-runner.jsonl'),
    JSON.stringify({ ts: new Date().toISOString(), taskId, status, durationMs: ms }) + '\n',
  );
}

// ---------------------------------------------------------------------------
// Shared tool sets
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Team Definitions (loaded from YAML files in teams/ directory)
// ---------------------------------------------------------------------------

import { loadTeams } from './team-loader.mjs';

const TEAMS_DIR = join(BOT_HOME, 'teams');
const TEMPLATE_VARS = {
  DATE, WEEK, OWNER_NAME, BOT_HOME, LOG_DIR, REPORTS, CTX_BUS,
  DATE_MONTH: DATE.slice(0, 7),
};

const TEAMS = loadTeams(TEAMS_DIR, TEMPLATE_VARS, REPORTS);

// Fallback: warn if no teams loaded
if (Object.keys(TEAMS).length === 0) {
  console.error('[company-agent] WARNING: No teams loaded from YAML. Check ~/.jarvis/teams/');
}

// Legacy TEAMS block removed — now loaded from ~/.jarvis/teams/*/team.yml
// See: team-loader.mjs, ADR-007

// ---------------------------------------------------------------------------
// Event → Team routing (이벤트가 팀을 직접 깨움)
// ---------------------------------------------------------------------------

const EVENT_ROUTES = {
  // TQQQ 급등/급락 → 파이낸스팀(손절/익절 판단 지원)
  'tqqq-critical': {
    teams: ['finance'],
    promptPrefix: (data) =>
      `🚨 **긴급 이벤트**: TQQQ ${data.level === 'critical' ? '손절선 하회' : '급락 경고'} — 현재가 $${data.price} (${data.change || ''})\n이 이벤트에 맞춰 보고서를 작성하라. 평소 보고와 다르게 이 상황에 대한 즉각 분석이 핵심이다.\n\n`,
  },
  // 디스크 위험 → 인프라팀(긴급 점검)
  'disk-critical': {
    teams: ['infra'],
    promptPrefix: (data) =>
      `🚨 **긴급 이벤트**: 디스크 사용률 ${data.usage}% — 임계치 초과\n정기 점검이 아닌 디스크 공간 확보에 집중하라. 삭제 가능한 파일 목록과 예상 확보량을 보고하라.\n\n`,
  },
  // Claude 과부하 → 인프라팀(프로세스 정리)
  'claude-overload': {
    teams: ['infra'],
    promptPrefix: (data) =>
      `⚠️ **이벤트**: Claude 동시 실행 ${data.count}개 감지\n현재 실행 중인 claude 프로세스를 점검하고 비정상 프로세스가 있는지 확인하라.\n\n`,
  },
  // GitHub 새 커밋 → 브랜드팀(블로그/포트폴리오 업데이트 검토)
  'new-commits': {
    teams: ['brand'],
    promptPrefix: (data) =>
      `📦 **이벤트**: 이번 주 GitHub 커밋 ${data.count}건 감지\n새로운 커밋 내용을 기반으로 블로그 포스트 제안을 업데이트하라.\n\n`,
  },
  // 시스템 장애 → 인프라팀(긴급 복구)
  'system-failure': {
    teams: ['infra'],
    promptPrefix: (data) =>
      `🔴 **긴급 이벤트**: ${data.service || '서비스'} 장애 감지 — ${data.message || ''}\n원인 파악과 복구 방안을 즉시 보고하라.\n\n`,
  },
};

// 이벤트 로그 기록 (event-bus.jsonl)
function logEvent(eventType, data, teams) {
  const busFile = join(BOT_HOME, 'state', 'event-bus.jsonl');
  appendFileSync(busFile, JSON.stringify({
    ts: new Date().toISOString(), event: eventType, data, teams,
  }) + '\n');
}

// 이벤트 → 팀 실행 (순차)
async function dispatchEvent(eventType) {
  const route = EVENT_ROUTES[eventType];
  if (!route) {
    console.error(`Unknown event: "${eventType}". Available: ${Object.keys(EVENT_ROUTES).join(', ')}`);
    process.exit(1);
  }

  log('info', `Event "${eventType}" → teams: [${route.teams.join(', ')}]`);
  logEvent(eventType, eventData, route.teams);

  const results = [];
  for (const teamName of route.teams) {
    log('info', `Event dispatch: ${eventType} → ${teamName}`);
    const r = await runTeam(teamName, route.promptPrefix(eventData));
    results.push({ team: teamName, ...r });
  }
  return results;
}

// ---------------------------------------------------------------------------
// Main runner
// ---------------------------------------------------------------------------

async function runTeam(name, eventPromptPrefix = '') {
  const team = TEAMS[name];
  if (!team) {
    console.error(`Unknown team: "${name}". Available: ${Object.keys(TEAMS).join(', ')}`);
    process.exit(1);
  }

  log('info', `Starting ${team.name}`);
  const t0 = Date.now();

  const opts = {
    cwd: BOT_HOME,
    pathToClaudeCodeExecutable: process.env.CLAUDE_BINARY || join(homedir(), '.local/bin/claude'),
    allowedTools: team.tools,
    permissionMode: 'bypassPermissions',
    allowDangerouslySkipPermissions: true,
    mcpServers: MCP,
    maxTurns: team.maxTurns,
    model: MODELS.medium,
    systemPrompt: `${team.system}
[공통 원칙] 긍정 편향 금지. "정상", "✅ 문제없음" 남발하지 마라. 이상 있는 것만 상세히, 정상은 한 줄 이하로.
모든 수치는 직접 확인한 데이터 기반. 과거 기억이나 추정으로 보고 금지. URL/링크 포함 금지.`,
  };
  if (team.agents) opts.agents = team.agents;

  // 이벤트 트리거 시 프롬프트 앞에 이벤트 컨텍스트 주입
  const prompt = eventPromptPrefix ? eventPromptPrefix + team.prompt : team.prompt;

  let result = '';
  let isError = false;

  try {
    for await (const msg of query({ prompt, options: opts })) {
      if ('result' in msg) result = msg.result ?? '';
    }
  } catch (err) {
    log('error', `SDK error: ${err.message}`);
    result = `[오류] ${team.name} 실행 실패: ${err.message}`;
    isError = true;
  }

  const elapsed = Math.round((Date.now() - t0) / 1000);
  log('info', `Completed in ${elapsed}s — ${result.length} chars`);

  // task-runner.jsonl 호환 로그 (measure-kpi.sh 기존 호환)
  logTaskResult(team.taskId, isError ? 'FAILED' : 'SUCCESS', Date.now() - t0);

  // 보고서 파일 저장
  if (result && team.report) {
    try {
      writeFileSync(team.report, result, 'utf-8');
      log('info', `Report saved: ${team.report}`);
    } catch (e) { log('warn', `Report save failed: ${e.message}`); }
  }

  // Vault에도 병렬 저장 (Obsidian 연동)
  if (result && !isError) {
    try {
      if (name === 'standup') {
        mkdirSync(VAULT_STANDUP, { recursive: true });
        const vaultPath = join(VAULT_STANDUP, `${DATE}.md`);
        writeFileSync(vaultPath, result, 'utf-8');
        log('info', `Vault standup saved: ${vaultPath}`);
      } else if (team.report) {
        const vaultTeamDir = join(VAULT_TEAMS, name);
        mkdirSync(vaultTeamDir, { recursive: true });
        const filename = team.report.split('/').pop();
        const vaultPath = join(vaultTeamDir, filename);
        writeFileSync(vaultPath, result, 'utf-8');
        log('info', `Vault report saved: ${vaultPath}`);
      }
    } catch (e) { log('warn', `Vault save failed: ${e.message}`); }
  }

  // Discord 웹훅 전송
  if (result && team.discord) {
    await sendWebhook(team.discord, result);
    log('info', `Sent to #${team.discord}`);
  }

  // Council → context-bus 업데이트
  if (name === 'council' && result && !isError) {
    updateContextBus(result);
    log('info', 'context-bus updated');
  }

  return { result, isError, elapsed };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

if (eventArg) {
  // 이벤트 드리븐 모드: --event <type> --data '{"key":"val"}'
  dispatchEvent(eventArg).then((results) => {
    const failed = results.some((r) => r.isError);
    process.exit(failed ? 1 : 0);
  }).catch((err) => {
    console.error(`Fatal: ${err.message}`);
    process.exit(1);
  });
} else if (teamArg) {
  runTeam(teamArg).then(({ isError }) => {
    process.exit(isError ? 1 : 0);
  }).catch((err) => {
    console.error(`Fatal: ${err.message}`);
    process.exit(1);
  });
} else {
  console.error(`Usage: node company-agent.mjs --team <name>`);
  console.error(`       node company-agent.mjs --event <type> [--data '{"key":"val"}']`);
  console.error(`Teams: ${Object.keys(TEAMS).join(' | ')}`);
  console.error(`Events: ${Object.keys(EVENT_ROUTES).join(' | ')}`);
  process.exit(1);
}
