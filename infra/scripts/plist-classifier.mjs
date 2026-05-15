#!/usr/bin/env node
/**
 * plist-classifier.mjs — Library/LaunchAgents 직접 plist 분류
 *
 * 분류 카테고리 (SSoT 4-A 룰):
 *   - daemon       : KeepAlive=true OR Long-running 프로세스 → 허용 유지
 *   - boot-trigger : RunAtLoad=true + OnDemand → 허용 유지
 *   - periodic     : StartCalendarInterval / StartInterval 사용 → tasks.json 이관 권고
 *   - hybrid       : KeepAlive + Calendar 동시 → 검토 필요
 *
 * 동작:
 *   - tasks.json 미등록 plist만 검사 (registered는 정상)
 *   - 각 plist의 키 (KeepAlive, StartCalendarInterval 등) 추출
 *   - 카테고리별 권고 출력 (dry-run, 변경 없음)
 */

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join, basename } from 'node:path';

const HOME = homedir();
const LA_DIR = join(HOME, 'Library/LaunchAgents');
const TASKS_PATH = join(HOME, 'jarvis/runtime/config/tasks.json');

function plistKeys(path) {
  // plutil로 JSON 변환 후 파싱
  try {
    const json = execSync(`plutil -convert json -o - "${path}"`, { encoding: 'utf8' });
    return JSON.parse(json);
  } catch { return null; }
}

function classify(plist) {
  if (!plist) return 'parse-fail';

  const hasKeepAlive = plist.KeepAlive === true || (typeof plist.KeepAlive === 'object');
  const hasRunAtLoad = plist.RunAtLoad === true;
  const hasCalendar = !!plist.StartCalendarInterval;
  const hasInterval = typeof plist.StartInterval === 'number';

  if (hasKeepAlive && (hasCalendar || hasInterval)) return 'hybrid';
  if (hasKeepAlive) return 'daemon';
  if (hasCalendar || hasInterval) return 'periodic';
  if (hasRunAtLoad) return 'boot-trigger';
  return 'unknown';
}

function summarizeSchedule(plist) {
  if (plist.StartInterval) return `every ${plist.StartInterval}s`;
  if (plist.StartCalendarInterval) {
    const c = Array.isArray(plist.StartCalendarInterval)
      ? plist.StartCalendarInterval[0]
      : plist.StartCalendarInterval;
    const fields = ['Minute', 'Hour', 'Day', 'Month', 'Weekday'].map(f => c[f] ?? '*');
    return `${fields[1] ?? '*'}:${(fields[0] ?? '*').toString().padStart(2, '0')} (cal)`;
  }
  if (plist.KeepAlive) return 'always-on';
  if (plist.RunAtLoad) return 'on-load';
  return 'unknown';
}

function main() {
  const tasksJson = JSON.parse(readFileSync(TASKS_PATH, 'utf8'));
  const registeredIds = new Set(tasksJson.tasks.map(t => t.id));

  const plists = readdirSync(LA_DIR)
    .filter(f => /^(ai|com)\.jarvis\..+\.plist$/.test(f))
    .map(f => ({ filename: f, label: f.replace(/^(ai|com)\.jarvis\./, '').replace(/\.plist$/, '') }));

  const groups = {
    'daemon': [],
    'boot-trigger': [],
    'periodic': [],
    'hybrid': [],
    'unknown': [],
    'parse-fail': []
  };

  for (const p of plists) {
    if (registeredIds.has(p.label)) continue; // 이미 SSoT 등록 — 정상

    const fullPath = join(LA_DIR, p.filename);
    const plist = plistKeys(fullPath);
    const kind = classify(plist);
    const sched = plist ? summarizeSchedule(plist) : 'n/a';

    groups[kind].push({ label: p.label, schedule: sched });
  }

  console.log(`📋 직접 plist (tasks.json 미등록) 분류\n`);
  console.log('═'.repeat(60));

  const order = ['daemon', 'boot-trigger', 'periodic', 'hybrid', 'unknown', 'parse-fail'];
  const rec = {
    'daemon': '✅ 허용 유지 (long-running 데몬)',
    'boot-trigger': '✅ 허용 유지 (부팅 1회)',
    'periodic': '🔁 tasks.json 이관 권고',
    'hybrid': '⚠️  검토 필요 (KeepAlive + Calendar 충돌)',
    'unknown': '❓ 수동 분류 필요',
    'parse-fail': '❌ plist 손상'
  };

  let totalPeriodic = 0;
  for (const cat of order) {
    if (!groups[cat].length) continue;
    console.log(`\n[${cat}] ${groups[cat].length}건 — ${rec[cat]}`);
    for (const item of groups[cat]) {
      console.log(`  · ${item.label.padEnd(30)} ${item.schedule}`);
    }
    if (cat === 'periodic') totalPeriodic = groups[cat].length;
  }

  console.log('\n═'.repeat(60));
  console.log(`📊 요약`);
  console.log(`  허용 (daemon + boot): ${groups.daemon.length + groups['boot-trigger'].length}건`);
  console.log(`  tasks.json 이관 권고: ${totalPeriodic}건`);
  console.log(`  검토 필요: ${groups.hybrid.length + groups.unknown.length}건`);
  console.log('═'.repeat(60));
  console.log('\n🔍 dry-run only — tasks.json 변경 없음.');
}

main();
