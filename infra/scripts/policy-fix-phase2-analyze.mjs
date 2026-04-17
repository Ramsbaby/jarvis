#!/usr/bin/env node
/**
 * policy-fix-phase2-analyze.mjs
 * C-2 (Inactive) + C-3 (Paused) 40개 자동 분석.
 *
 * 의사결정 트리:
 *   C-3 (Paused):
 *     - 모두 "연속 3회 failure/timeout" — 근본 원인 수정 필요
 *     - 분류: TIMEOUT_CB / FAILURE_CB
 *     - Action: cron.log에서 사유 추출 → 사용자 결정
 *
 *   C-2 (Inactive):
 *     - failures > 0 && no recent success → DEAD (안전 disable)
 *     - failures = 0 && no last success → SCHEDULE_PENDING (월간/주간 도래 대기 가능)
 *     - depends에 paused/disabled 있음 → BLOCKED_BY_DEPS
 *     - schedule이 주간(weekday 지정) 또는 월간(특정 일) → SCHEDULED_RARE
 *     - 그 외 → UNKNOWN (수동 조사)
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HOME = homedir();
const TASKS = JSON.parse(readFileSync(join(HOME, 'jarvis/runtime/config/tasks.json'), 'utf-8'));
const MGR = JSON.parse(readFileSync(join(HOME, 'jarvis/runtime/state/cron-manager.json'), 'utf-8'));
const MANIFEST_PATH = join(HOME, 'jarvis/runtime/state/policy-fix-manifest.csv');

const tasks = TASKS.tasks || [];
const taskById = new Map(tasks.map(t => [t.id, t]));

// Parse manifest CSV
function parseCsv(text) {
  const lines = text.trim().split('\n');
  const headers = lines[0].split(',').map(h => h.replace(/^"|"$/g, ''));
  return lines.slice(1).map(line => {
    const cols = [];
    let cur = '', inQ = false;
    for (const ch of line) {
      if (ch === '"') inQ = !inQ;
      else if (ch === ',' && !inQ) { cols.push(cur); cur = ''; }
      else cur += ch;
    }
    cols.push(cur);
    const obj = {};
    headers.forEach((h, i) => obj[h] = cols[i] || '');
    return obj;
  });
}
const manifest = parseCsv(readFileSync(MANIFEST_PATH, 'utf-8'));

const c2 = manifest.filter(r => r.Category === 'C-2');
const c3 = manifest.filter(r => r.Category === 'C-3');

// Schedule classification
function scheduleRarity(cron) {
  if (!cron) return 'unknown';
  const parts = cron.split(/\s+/);
  if (parts.length !== 5) return 'unknown';
  const [m, h, dom, mon, dow] = parts;
  // 월간/연간 = 특정 일자 또는 특정 월
  if (dom !== '*' || mon !== '*') return 'monthly';
  // 주간 = 특정 요일
  if (dow !== '*') return 'weekly';
  return 'frequent';
}

// Dependency analysis
function depsBlocked(taskId) {
  const task = taskById.get(taskId);
  if (!task?.depends?.length) return null;
  const blockers = [];
  for (const dep of task.depends) {
    const depTask = taskById.get(dep);
    if (!depTask) blockers.push(`${dep}(missing)`);
    else if (depTask.enabled === false) blockers.push(`${dep}(disabled)`);
    else if (MGR.paused?.[dep]) blockers.push(`${dep}(paused)`);
  }
  return blockers.length ? blockers : null;
}

// C-3 분류
const c3Analysis = c3.map(r => {
  const id = r.NexusId;
  const pausedReason = MGR.paused?.[id]?.reason || 'unknown';
  const failCount = MGR.failures?.[id] || 0;
  const kind = pausedReason.includes('timeout') ? 'TIMEOUT_CB' : 'FAILURE_CB';
  return {
    label: r.Label, id, category: 'C-3', kind,
    reason: pausedReason, failCount,
    action: 'INVESTIGATE_THEN_UNPAUSE',
  };
});

// C-2 분류
const c2Analysis = c2.map(r => {
  const id = r.NexusId;
  const task = taskById.get(id);
  const failCount = MGR.failures?.[id] || 0;
  const lastSuccess = MGR.lastSuccess?.[id] || null;
  const hasLastRun = !!MGR.lastRun?.[id];
  const blockers = depsBlocked(id);
  const rarity = scheduleRarity(task?.schedule);

  let kind, action;
  if (blockers) {
    kind = 'BLOCKED_BY_DEPS';
    action = 'FIX_DEPS_FIRST';
  } else if (failCount > 0 && !lastSuccess) {
    kind = 'DEAD';
    action = 'SAFE_DISABLE_BOTH'; // tasks.json + plist 둘 다 정리
  } else if (failCount === 0 && !lastSuccess && !hasLastRun) {
    if (rarity === 'monthly' || rarity === 'weekly') {
      kind = 'SCHEDULE_PENDING';
      action = 'WAIT_FOR_NEXT_TRIGGER';
    } else {
      kind = 'NEVER_RAN';
      action = 'INVESTIGATE'; // 매일/시간대인데 한 번도 안 도는 건 이상
    }
  } else if (failCount === 0 && hasLastRun && !lastSuccess) {
    kind = 'RUNS_NEVER_SUCCEEDS';
    action = 'INVESTIGATE'; // 실행은 되지만 성공이 없음
  } else {
    kind = 'STALE_SUCCESS';
    action = 'REVIEW';
  }

  return {
    label: r.Label, id, category: 'C-2', kind, action,
    rarity, failCount, lastSuccess: lastSuccess || '',
    blockers: blockers ? blockers.join(',') : '',
    schedule: task?.schedule || '',
    enabled: task?.enabled !== false,
  };
});

// 그룹핑 + 출력
const all = [...c3Analysis, ...c2Analysis];
const byKind = {};
for (const r of all) {
  byKind[r.kind] ||= [];
  byKind[r.kind].push(r);
}

console.log('## Phase 2 자동 분석 결과 (40개)');
console.log('');
console.log('| Kind | 개수 | Action | 권장 |');
console.log('|---|---:|---|---|');
const summary = [
  ['TIMEOUT_CB',     'INVESTIGATE_THEN_UNPAUSE', 'cron.log 사유 확인 후 timeout 조정 + unpause'],
  ['FAILURE_CB',     'INVESTIGATE_THEN_UNPAUSE', '실패 사유 확인 후 수정 + unpause'],
  ['BLOCKED_BY_DEPS','FIX_DEPS_FIRST',           '의존 task 복구 우선'],
  ['DEAD',           'SAFE_DISABLE_BOTH',        '✅ 안전: tasks.json enabled=false + plist .disabled'],
  ['SCHEDULE_PENDING','WAIT_FOR_NEXT_TRIGGER',   '주간/월간 — 다음 도래 대기 (정상)'],
  ['NEVER_RAN',      'INVESTIGATE',              '⚠️ 자주 도는 스케줄인데 한 번도 안 돔'],
  ['RUNS_NEVER_SUCCEEDS','INVESTIGATE',          '⚠️ 실행은 되나 성공 없음'],
  ['STALE_SUCCESS',  'REVIEW',                   '오래된 성공 — 재평가'],
];
for (const [kind, action, desc] of summary) {
  console.log(`| ${kind} | ${(byKind[kind] || []).length} | ${action} | ${desc} |`);
}

// 세부 출력 (DEAD + INVESTIGATE 우선)
for (const kind of ['DEAD', 'NEVER_RAN', 'RUNS_NEVER_SUCCEEDS', 'STALE_SUCCESS', 'BLOCKED_BY_DEPS', 'TIMEOUT_CB', 'FAILURE_CB', 'SCHEDULE_PENDING']) {
  const items = byKind[kind];
  if (!items?.length) continue;
  console.log(`\n### ${kind} (${items.length}개)`);
  for (const r of items) {
    const detail = [
      r.failCount ? `fails:${r.failCount}` : '',
      r.lastSuccess ? `lastSuccess:${r.lastSuccess.slice(0,10)}` : 'noSuccess',
      r.schedule ? `cron:"${r.schedule}"` : '',
      r.blockers ? `blockers:[${r.blockers}]` : '',
    ].filter(Boolean).join(' / ');
    console.log(`  - ${r.label} → ${detail}`);
  }
}

// 액션 가능 라벨 출력 (다음 단계용)
const safeDisableLabels = (byKind.DEAD || []).map(r => r.label);
writeFileSync('/tmp/phase2-safe-disable.txt', safeDisableLabels.join('\n') + '\n');
const investigateLabels = [
  ...(byKind.NEVER_RAN || []),
  ...(byKind.RUNS_NEVER_SUCCEEDS || []),
  ...(byKind.STALE_SUCCESS || []),
].map(r => r.label);
writeFileSync('/tmp/phase2-investigate.txt', investigateLabels.join('\n') + '\n');

console.log(`\n---\n안전 자동 처리 가능: ${safeDisableLabels.length}개 → /tmp/phase2-safe-disable.txt`);
console.log(`수동 조사 필요: ${investigateLabels.length}개 → /tmp/phase2-investigate.txt`);