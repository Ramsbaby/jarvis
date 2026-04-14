#!/usr/bin/env node
/**
 * gen-tasks-index.mjs — Task registry → documentation generator.
 *
 * Reads ~/.jarvis/config/tasks.json and emits:
 *   - infra/docs/TASKS-INDEX.md   (human-readable, grouped by team)
 *   - infra/docs/tasks-index.json (machine-readable mirror)
 *
 * Team inference:
 *   tasks.json rarely carries a `team` field, so we infer via keyword match
 *   against jarvis-board's team-registry.ts (SSoT). The keyword list is
 *   mirrored here to avoid a cross-repo import; keep in sync when the
 *   registry changes.
 *
 * Never throws — logs errors inline and keeps going. Run manually:
 *   node infra/scripts/gen-tasks-index.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

const HOME = os.homedir();
const TASKS_JSON = path.join(HOME, '.jarvis/config/tasks.json');
const VALIDATE_SCRIPT = path.resolve(new URL('.', import.meta.url).pathname, 'validate-tasks.mjs');

// tasks.json Schema 검증 — 실패 시 잘못된 인덱스 생성 방지
try {
  execFileSync(process.execPath, [VALIDATE_SCRIPT], { stdio: 'inherit' });
} catch {
  console.error('[gen-tasks-index] validate-tasks 실패 — 인덱스 생성 중단');
  process.exit(1);
}
const LOGS_DIR = path.join(HOME, '.jarvis/logs');
const OUT_DIR = path.resolve(new URL('.', import.meta.url).pathname, '../docs');
const OUT_MD = path.join(OUT_DIR, 'TASKS-INDEX.md');
const OUT_JSON = path.join(OUT_DIR, 'tasks-index.json');

// ────────────────────────────────────────────────────────────────────────────
// Team registry — mirror of ~/jarvis-board/lib/map/team-registry.ts
// Keyword substrings are matched against task.id (case-insensitive, substring).
// Order matters: first match wins when a task matches multiple teams.
// ────────────────────────────────────────────────────────────────────────────
const TEAM_REGISTRY = [
  // Order matters: earlier entries win on tie. Keep standup/president near top
  // so board-/council- keywords don't leak elsewhere.
  {
    id: 'standup',
    name: '회의실 (모닝 스탠드업)',
    keywords: ['standup', 'morning-brief', 'morning-standup'],
  },
  {
    id: 'president',
    name: '대표실 (CEO·이사회·KPI)',
    keywords: [
      'board-meeting', 'board-perf', 'board-conclude', 'board-topic',
      'ceo-daily-digest', 'council', 'scorecard', 'connections',
      'weekly-kpi', 'monthly-review', 'weekly-report', 'weekly-roi',
      'daily-summary',
    ],
  },
  {
    id: 'infra-lead',
    name: 'SRE실 (인프라·신뢰성)',
    keywords: [
      'infra-daily', 'system-doctor', 'system-health', 'health',
      'disk', 'glances', 'aggregate-metrics',
      'memory-cleanup', 'memory-expire', 'memory-sync', 'rate-limit',
      'log-cleanup', 'daily-restart', 'env-restore', 'token-sync',
      'bot-crash', 'discord-mention', 'stale-task', 'cost-alert',
    ],
  },
  {
    id: 'finance',
    name: '재무실 (AI 비용·시장·수입)',
    keywords: [
      'tqqq', 'market-alert', 'stock', 'macro',
      'finance-monitor', 'cost-monitor', 'tutoring', 'personal-schedule',
      'daily-usage', 'update-usage',
    ],
  },
  {
    id: 'trend-lead',
    name: '전략기획실 (트렌드·뉴스)',
    keywords: ['trend', 'news', 'calendar-alert', 'github-monitor', 'github-pr', 'recon'],
  },
  {
    id: 'record-lead',
    name: '데이터실 (메모리·RAG 백엔드)',
    keywords: [
      'record-daily', 'memory', 'session-sum', 'session-sync',
      'compact', 'rag-index', 'vault-sync', 'vault-auto-link',
      'private-sync',
    ],
  },
  {
    id: 'library',
    name: '자료실 (RAG 프론트엔드)',
    keywords: ['rag-bench'],
  },
  {
    id: 'growth-lead',
    name: '인재개발실 (커리어·학습)',
    keywords: [
      'career', 'commitment', 'growth', 'job', 'resume', 'interview',
      'academy', 'learning', 'study', 'lecture', 'boram',
    ],
  },
  {
    id: 'brand-lead',
    name: '마케팅실 (OSS·블로그)',
    keywords: ['brand', 'openclaw', 'blog', 'oss', 'github-star'],
  },
  {
    id: 'audit-lead',
    name: 'QA실 (품질·감사·E2E)',
    keywords: [
      'audit', 'cron-failure', 'kpi', 'e2e', 'regression',
      'doc-sync', 'doc-supervisor', 'gen-gotchas', 'gen-system-overview',
      'schedule-coherence', 'security-scan', 'weekly-code-review',
      'weekly-perf', 'tune-task', 'jira-sync',
    ],
  },
  {
    id: 'secretary',
    name: '컨시어지 (Discord 봇)',
    keywords: [
      'bot-quality', 'bot-self-critique', 'auto-diagnose',
      'skill-eval', 'ask-claude', 'weekly-usage-stats',
      'agent-batch-commit', 'jarvis-coder', 'dev-runner',
      'dev-event',
    ],
  },
];

const UNCATEGORIZED = { id: 'uncategorized', name: '미분류' };

// ────────────────────────────────────────────────────────────────────────────
// Cron → human readable (minimal, covers the common shapes in tasks.json)
// ────────────────────────────────────────────────────────────────────────────
const DOW = ['일', '월', '화', '수', '목', '금', '토'];

function cronToHuman(expr) {
  if (!expr || typeof expr !== 'string') return '(none)';
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) return expr;
  const [min, hour, dom, mon, dow] = parts;

  const pad = (n) => String(n).padStart(2, '0');

  const fmtTime = () => {
    if (/^\d+$/.test(hour) && /^\d+$/.test(min)) return `${pad(+hour)}:${pad(+min)}`;
    if (hour.startsWith('*/') && min === '0') return `${hour.slice(2)}시간마다`;
    if (min.startsWith('*/') && hour === '*') return `${min.slice(2)}분마다`;
    if (hour.includes('-') && /^\d+$/.test(min)) return `${hour}시 :${pad(+min)}`;
    if (hour.includes(',') && /^\d+$/.test(min)) return `${hour}시 :${pad(+min)}`;
    return `${hour}:${min}`;
  };

  const fmtDay = () => {
    if (dom === '*' && mon === '*' && dow === '*') return '매일';
    if (dom === '*' && mon === '*' && /^\d+(,\d+)*$/.test(dow)) {
      return dow.split(',').map((d) => `${DOW[+d]}요일`).join('·');
    }
    if (dom === '*' && mon === '*' && dow === '1-5') return '평일';
    if (dom === '*' && mon === '*' && dow === '0,6') return '주말';
    if (/^\d+$/.test(dom) && mon === '*') return `매월 ${dom}일`;
    return `${dom}/${mon}/${dow}`;
  };

  return `${fmtDay()} ${fmtTime()}`.trim();
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────
function safeExists(p) {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

function safeGlobExists(dir, pattern) {
  // pattern: "claude-stderr-<id>-*.log"
  try {
    const files = fs.readdirSync(dir);
    const re = new RegExp('^' + pattern.replace(/[.]/g, '\\.').replace(/\*/g, '.*') + '$');
    return files.some((f) => re.test(f));
  } catch {
    return false;
  }
}

// Explicit aliases: legacy task.team values → canonical registry id.
const TEAM_ALIASES = {
  council: 'president',
};

function inferTeam(task) {
  if (task.team && typeof task.team === 'string') {
    const canonical = TEAM_ALIASES[task.team] || task.team;
    const hit = TEAM_REGISTRY.find((t) => t.id === canonical || t.name.includes(canonical));
    if (hit) return hit;
    return { id: task.team, name: task.team };
  }
  const id = String(task.id || '').toLowerCase();
  for (const team of TEAM_REGISTRY) {
    if (team.keywords.some((kw) => id.includes(kw.toLowerCase()))) return team;
  }
  return UNCATEGORIZED;
}

function classifyType(task) {
  if (task.script) return 'script';
  if (task.prompt || task.prompt_file) return 'prompt';
  return 'unknown';
}

function handlerFor(task) {
  if (task.script) {
    const raw = String(task.script);
    return path.basename(raw.replace(/^~/, HOME).split(/\s+/)[0]);
  }
  if (task.prompt || task.prompt_file) return 'ask-claude.sh (LLM)';
  return '(none)';
}

function logsFor(task) {
  const id = task.id;
  const base = path.join(LOGS_DIR, `${id}.log`);
  const err = path.join(LOGS_DIR, `${id}-err.log`);
  const claudeStderr = safeGlobExists(LOGS_DIR, `claude-stderr-${id}-*.log`);
  return {
    stdout: { path: base, exists: safeExists(base) },
    stderr: { path: err, exists: safeExists(err) },
    claudeStderr: {
      pattern: `claude-stderr-${id}-*.log`,
      exists: claudeStderr,
    },
  };
}

function mark(b) {
  return b ? '✓' : '✗';
}

function homeShort(p) {
  return p.startsWith(HOME) ? '~' + p.slice(HOME.length) : p;
}

// ────────────────────────────────────────────────────────────────────────────
// Main
// ────────────────────────────────────────────────────────────────────────────
function main() {
  let raw;
  try {
    raw = fs.readFileSync(TASKS_JSON, 'utf8');
  } catch (e) {
    console.error(`[gen-tasks-index] cannot read ${TASKS_JSON}: ${e.message}`);
    process.exit(0);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    console.error(`[gen-tasks-index] invalid JSON in tasks.json: ${e.message}`);
    process.exit(0);
  }

  const tasks = Array.isArray(parsed) ? parsed : parsed.tasks || [];
  if (!tasks.length) {
    console.error('[gen-tasks-index] no tasks found');
    process.exit(0);
  }

  const enriched = tasks.map((t) => {
    const team = inferTeam(t);
    const type = classifyType(t);
    const logs = logsFor(t);
    return {
      id: t.id,
      name: t.name || t.id,
      schedule: t.schedule || null,
      scheduleHuman: cronToHuman(t.schedule),
      type,
      handler: handlerFor(t),
      team: { id: team.id, name: team.name },
      discordChannel: t.discordChannel || null,
      model: t.model || null,
      priority: t.priority || null,
      maxBudget: t.maxBudget || null,
      disabled: t.disabled === true || t.enabled === false,
      description: t.description || t.note || null,
      logs: {
        stdout: { path: homeShort(logs.stdout.path), exists: logs.stdout.exists },
        stderr: { path: homeShort(logs.stderr.path), exists: logs.stderr.exists },
        claudeStderr: {
          pattern: logs.claudeStderr.pattern,
          exists: logs.claudeStderr.exists,
        },
      },
    };
  });

  // group by team
  const groups = new Map();
  for (const t of enriched) {
    const key = t.team.id;
    if (!groups.has(key)) groups.set(key, { team: t.team, tasks: [] });
    groups.get(key).tasks.push(t);
  }

  // sort groups: known teams first (per TEAM_REGISTRY order), then uncategorized
  const order = [...TEAM_REGISTRY.map((t) => t.id), UNCATEGORIZED.id];
  const sortedGroups = [...groups.values()].sort((a, b) => {
    const ai = order.indexOf(a.team.id);
    const bi = order.indexOf(b.team.id);
    return (ai < 0 ? 999 : ai) - (bi < 0 ? 999 : bi);
  });
  for (const g of sortedGroups) g.tasks.sort((a, b) => a.id.localeCompare(b.id));

  // ── Markdown ────────────────────────────────────────────────────────────
  const now = new Date().toISOString();
  const teamDist = sortedGroups.map((g) => `${g.team.name}: ${g.tasks.length}`).join(' · ');
  const md = [];
  md.push('# Tasks Index');
  md.push('');
  md.push('> 🤖 Auto-generated by `infra/scripts/gen-tasks-index.mjs` — do not edit.');
  md.push(`> Last run: ${now}`);
  md.push('>');
  md.push('> Source: `~/.jarvis/config/tasks.json` · Team mapping: mirror of `~/jarvis-board/lib/map/team-registry.ts`');
  md.push('');
  md.push(`**총 태스크**: ${enriched.length}`);
  md.push('');
  md.push(`**팀별 분포**: ${teamDist}`);
  md.push('');
  const typeCount = enriched.reduce((a, t) => ((a[t.type] = (a[t.type] || 0) + 1), a), {});
  md.push(`**타입 분포**: script ${typeCount.script || 0} · prompt ${typeCount.prompt || 0} · unknown ${typeCount.unknown || 0}`);
  md.push('');
  md.push('---');
  md.push('');

  for (const g of sortedGroups) {
    md.push(`## ${g.team.name} (${g.tasks.length} tasks)`);
    md.push('');
    for (const t of g.tasks) {
      const disabledTag = t.disabled ? ' 🚫 **disabled**' : '';
      md.push(`### \`${t.id}\`${disabledTag}`);
      if (t.name && t.name !== t.id) md.push(`- **이름**: ${t.name}`);
      md.push(`- **스케줄**: \`${t.schedule || '(none)'}\` — ${t.scheduleHuman}`);
      md.push(`- **타입**: ${t.type === 'prompt' ? 'LLM prompt → `ask-claude.sh`' : t.type === 'script' ? `script → \`${t.handler}\`` : 'unknown'}`);
      if (t.model) md.push(`- **모델**: \`${t.model}\``);
      if (t.discordChannel) md.push(`- **Discord**: \`#${t.discordChannel}\``);
      if (t.priority) md.push(`- **우선순위**: ${t.priority}${t.maxBudget ? ` · budget \`${t.maxBudget}\`` : ''}`);
      const logLines = [
        `\`${t.logs.stdout.path}\` ${mark(t.logs.stdout.exists)}`,
        `\`${t.logs.stderr.path}\` ${mark(t.logs.stderr.exists)}`,
      ];
      if (t.type === 'prompt') {
        logLines.push(`\`${t.logs.claudeStderr.pattern}\` ${mark(t.logs.claudeStderr.exists)}`);
      }
      md.push(`- **로그**: ${logLines.join(' / ')}`);
      if (t.description) md.push(`- **설명**: ${t.description}`);
      md.push('');
    }
  }

  md.push('---');
  md.push('');
  md.push('## 갱신 방법');
  md.push('');
  md.push('```bash');
  md.push('node ~/jarvis/infra/scripts/gen-tasks-index.mjs');
  md.push('```');
  md.push('');
  md.push('태스크 추가·삭제 후 이 스크립트를 돌려 `TASKS-INDEX.md` 와 `tasks-index.json` 을 갱신한다.');
  md.push('');

  try {
    fs.mkdirSync(OUT_DIR, { recursive: true });
    fs.writeFileSync(OUT_MD, md.join('\n'), 'utf8');
  } catch (e) {
    console.error(`[gen-tasks-index] write MD failed: ${e.message}`);
  }

  // ── JSON ────────────────────────────────────────────────────────────────
  const payload = {
    generatedAt: now,
    source: homeShort(TASKS_JSON),
    totalTasks: enriched.length,
    teamDistribution: Object.fromEntries(sortedGroups.map((g) => [g.team.id, g.tasks.length])),
    typeDistribution: typeCount,
    groups: sortedGroups.map((g) => ({
      team: g.team,
      tasks: g.tasks,
    })),
  };
  try {
    fs.writeFileSync(OUT_JSON, JSON.stringify(payload, null, 2), 'utf8');
  } catch (e) {
    console.error(`[gen-tasks-index] write JSON failed: ${e.message}`);
  }

  const handlerSet = new Set(enriched.map((t) => t.handler));
  console.log(
    `Wrote ${enriched.length} tasks, ${sortedGroups.length} teams, ${handlerSet.size} handlers → ${homeShort(OUT_MD)}`,
  );
}

main();
