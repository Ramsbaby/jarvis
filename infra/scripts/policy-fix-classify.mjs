#!/usr/bin/env node
/**
 * policy-fix-classify.mjs
 * Jarvis 크론 정책 정합화 — LaunchAgent 분류 매니페스트 생성기.
 *
 * 분류:
 *   A   = 코어 long-running daemon (KeepAlive=true)
 *   B   = 단발 스케줄, Nexus 미등록 — 이관 대상
 *   C-1 = Nexus 중복 + Nexus 7일 내 실행 기록 있음 (즉시 disable 안전)
 *   C-2 = Nexus 등록되었으나 lastSuccess 없음/7일 초과 (Inactive)
 *   C-3 = Nexus paused
 *   C-4 = tasks.json에서 명시적 disabled
 *
 * 출력: ~/.jarvis/state/policy-fix-manifest.csv
 */
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join, basename } from 'node:path';

const HOME = homedir();
const LA_DIR = join(HOME, 'Library/LaunchAgents');
const TASKS_JSON = join(HOME, '.jarvis/config/tasks.json');
const CRON_MANAGER_JSON = join(HOME, '.jarvis/state/cron-manager.json');
const MANIFEST = join(HOME, '.jarvis/state/policy-fix-manifest.csv');

const SEVEN_DAYS_MS = 7 * 24 * 3600 * 1000;
const NOW = Date.now();

function plistGet(file, key) {
  try {
    return execSync(`plutil -extract ${key} raw -o - "${file}"`, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
  } catch { return null; }
}

function plistGetArrayElement(file, key, idx) {
  try {
    return execSync(`plutil -extract ${key}.${idx} raw -o - "${file}"`, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
  } catch { return null; }
}

function detectScheduleKind(file) {
  if (plistGet(file, 'KeepAlive') === 'true') return 'KeepAlive';
  if (plistGet(file, 'StartInterval')) return `StartInterval(${plistGet(file, 'StartInterval')}s)`;
  // StartCalendarInterval may be dict or array — just detect presence
  try {
    execSync(`plutil -extract StartCalendarInterval raw -o - "${file}"`, { stdio: ['pipe', 'pipe', 'ignore'] });
    return 'StartCalendarInterval';
  } catch {}
  if (plistGet(file, 'RunAtLoad') === 'true') return 'RunAtLoad-only';
  try {
    execSync(`plutil -extract WatchPaths raw -o - "${file}"`, { stdio: ['pipe', 'pipe', 'ignore'] });
    return 'WatchPaths';
  } catch {}
  return 'none';
}

// Load tasks.json — build maps
const tasksData = JSON.parse(readFileSync(TASKS_JSON, 'utf-8'));
const tasks = tasksData.tasks || [];
const taskById = new Map();
const taskByScriptBasename = new Map();
for (const t of tasks) {
  taskById.set(t.id, t);
  if (t.script) taskByScriptBasename.set(basename(t.script), t);
}

// Load cron-manager state
let mgrState = { lastSuccess: {}, paused: {} };
try {
  mgrState = JSON.parse(readFileSync(CRON_MANAGER_JSON, 'utf-8'));
} catch {}

function isRecentSuccess(taskId) {
  const ts = mgrState.lastSuccess?.[taskId];
  if (!ts) return false;
  const t = new Date(ts).getTime();
  return !isNaN(t) && (NOW - t) < SEVEN_DAYS_MS;
}

function isPaused(taskId) {
  return !!mgrState.paused?.[taskId];
}

// Scan plist files (exclude .disabled and .nexus_primary)
const allFiles = readdirSync(LA_DIR);
const plistFiles = allFiles
  .filter(f => /^(ai|com)\.jarvis\..+\.plist$/.test(f))
  .map(f => join(LA_DIR, f));

const rows = [];
for (const file of plistFiles) {
  const label = plistGet(file, 'Label') || basename(file, '.plist');
  const program0 = plistGetArrayElement(file, 'ProgramArguments', '0');
  const program1 = plistGetArrayElement(file, 'ProgramArguments', '1');
  const programPath = (program0 && program0.endsWith('bash')) ? program1 : program0;
  const scriptBn = programPath ? basename(programPath) : '';
  const scheduleKind = detectScheduleKind(file);

  // Match to Nexus task: try by Label suffix, then by script basename
  const labelSuffix = label.replace(/^(ai|com)\.jarvis\./, '');
  let matchedTask = taskById.get(labelSuffix);
  if (!matchedTask && scriptBn) matchedTask = taskByScriptBasename.get(scriptBn);
  const nexusId = matchedTask?.id || '';

  let category;
  if (scheduleKind === 'KeepAlive' || scheduleKind === 'WatchPaths') {
    category = 'A';
  } else if (matchedTask) {
    if (matchedTask.enabled === false) category = 'C-4';
    else if (isPaused(nexusId)) category = 'C-3';
    else if (isRecentSuccess(nexusId)) category = 'C-1';
    else category = 'C-2';
  } else {
    category = 'B';
  }

  const action =
    category === 'A' ? 'keep' :
    category === 'C-1' ? 'disable-plist-now' :
    category === 'C-4' ? 'disable-plist-now' :
    category === 'C-3' ? 'review-paused' :
    category === 'C-2' ? 'investigate-inactive' :
    'migrate-to-nexus'; // B

  rows.push({
    label,
    category,
    scheduleKind,
    nexusId,
    scriptBn,
    action,
    nexusLastSuccess: mgrState.lastSuccess?.[nexusId] || '',
    nexusPaused: isPaused(nexusId) ? 'yes' : '',
    nexusEnabled: matchedTask ? (matchedTask.enabled === false ? 'no' : 'yes') : '',
  });
}

// Sort: category, label
const order = { 'A': 0, 'C-1': 1, 'C-2': 2, 'C-3': 3, 'C-4': 4, 'B': 5 };
rows.sort((a, b) => (order[a.category] - order[b.category]) || a.label.localeCompare(b.label));

// Write CSV
const header = 'Label,Category,ScheduleKind,NexusId,ScriptBasename,Action,NexusLastSuccess,NexusPaused,NexusEnabled\n';
const lines = rows.map(r =>
  [r.label, r.category, r.scheduleKind, r.nexusId, r.scriptBn, r.action, r.nexusLastSuccess, r.nexusPaused, r.nexusEnabled]
    .map(v => `"${String(v).replace(/"/g, '""')}"`)
    .join(',')
).join('\n');
writeFileSync(MANIFEST, header + lines + '\n');

// Summary
const counts = rows.reduce((m, r) => { m[r.category] = (m[r.category] || 0) + 1; return m; }, {});
console.log(`✓ Manifest: ${MANIFEST} (${rows.length} rows)`);
console.log('Distribution:');
for (const cat of ['A', 'B', 'C-1', 'C-2', 'C-3', 'C-4']) {
  console.log(`  ${cat}: ${counts[cat] || 0}`);
}
