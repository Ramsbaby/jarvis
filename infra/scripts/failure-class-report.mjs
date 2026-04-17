#!/usr/bin/env node
// failure-class-report.mjs
//
// Phase 1 (2026-04-17): 실패 관측가능성 — retry.jsonl 을 failure_class / classification 기준으로 분포 리포트.
// retry-wrapper.sh 가 새로 기록하는 `failure_class` 필드를 조회하는 단일 창구.
//
// Usage:
//   node ~/jarvis/infra/scripts/failure-class-report.mjs              # 최근 7일
//   node ~/jarvis/infra/scripts/failure-class-report.mjs --days=1     # 최근 1일
//   node ~/jarvis/infra/scripts/failure-class-report.mjs --days=30    # 최근 30일
//   node ~/jarvis/infra/scripts/failure-class-report.mjs --task=<id>  # 단일 태스크
//
// 출력: 텍스트 테이블 (stdout). Discord 알림 등 side effect 없음.

import fs from 'node:fs';
import os from 'node:os';
import readline from 'node:readline';

const HOME = os.homedir();
const RETRY_LOG_CANDIDATES = [
  `${HOME}/jarvis/runtime/logs/retry.jsonl`,
  `${HOME}/.jarvis/logs/retry.jsonl`,
];

function parseArgs() {
  const args = { days: 7, task: null };
  for (const a of process.argv.slice(2)) {
    let m;
    if ((m = a.match(/^--days=(\d+)$/))) args.days = parseInt(m[1], 10);
    else if ((m = a.match(/^--task=(.+)$/))) args.task = m[1];
  }
  return args;
}

function locateLog() {
  for (const f of RETRY_LOG_CANDIDATES) {
    try {
      if (fs.existsSync(f)) return f;
    } catch {}
  }
  return null;
}

async function readRecords(file, sinceIso, taskFilter) {
  const records = [];
  const rl = readline.createInterface({
    input: fs.createReadStream(file),
    crlfDelay: Infinity,
  });
  for await (const line of rl) {
    if (!line.trim()) continue;
    let d;
    try {
      d = JSON.parse(line);
    } catch {
      continue;
    }
    if (!d.timestamp || !d.task_id) continue;
    if (d.timestamp < sinceIso) continue;
    if (taskFilter && d.task_id !== taskFilter) continue;
    records.push(d);
  }
  return records;
}

function tally(records, field) {
  const m = new Map();
  for (const r of records) {
    const v = r[field] || '(none)';
    m.set(v, (m.get(v) || 0) + 1);
  }
  return [...m.entries()].sort((a, b) => b[1] - a[1]);
}

function tallyTaskBy(records, predicate) {
  const m = new Map();
  for (const r of records) {
    if (!predicate(r)) continue;
    m.set(r.task_id, (m.get(r.task_id) || 0) + 1);
  }
  return [...m.entries()].sort((a, b) => b[1] - a[1]);
}

function fmt(entries, total, topN = 10) {
  return entries
    .slice(0, topN)
    .map(([k, n]) => {
      const pct = total > 0 ? ((n / total) * 100).toFixed(1) : '0.0';
      return `  ${String(n).padStart(5)} (${pct.padStart(5)}%)  ${k}`;
    })
    .join('\n');
}

async function main() {
  const args = parseArgs();
  const file = locateLog();
  if (!file) {
    console.error('[report] retry.jsonl not found at', RETRY_LOG_CANDIDATES);
    process.exit(1);
  }
  const sinceDate = new Date(Date.now() - args.days * 86400 * 1000);
  const sinceIso = sinceDate.toISOString();

  const records = await readRecords(file, sinceIso, args.task);
  const total = records.length;

  if (total === 0) {
    console.log(`(no records in last ${args.days}d${args.task ? ' for ' + args.task : ''})`);
    return;
  }

  const success = records.filter((r) => r.classification === 'success');
  const failure = records.filter((r) => r.classification !== 'success');

  console.log(`# failure-class-report  (last ${args.days}d${args.task ? ', task=' + args.task : ''})`);
  console.log(`source: ${file}`);
  console.log(`since:  ${sinceIso}`);
  console.log();
  console.log(`total records: ${total}`);
  console.log(`  success:     ${success.length}  (${((success.length / total) * 100).toFixed(1)}%)`);
  console.log(`  failure:     ${failure.length}  (${((failure.length / total) * 100).toFixed(1)}%)`);
  console.log();

  console.log('## classification (retry-intent)');
  console.log(fmt(tally(records, 'classification'), total));
  console.log();

  // failure_class: Phase 1 신규 필드. 과거 데이터는 없으므로 "(none)" 이 많이 나올 수 있음.
  const haveFC = records.filter((r) => r.failure_class);
  console.log(`## failure_class (Phase 1 tagged: ${haveFC.length} / ${total})`);
  console.log(fmt(tally(haveFC, 'failure_class'), haveFC.length || 1));
  console.log();

  // Content-error 분리 리포트 — exit 0 SUCCESS 구멍 감지 케이스
  const contentErrors = records.filter((r) => (r.failure_class || '').startsWith('CONTENT_ERROR'));
  if (contentErrors.length > 0) {
    console.log('## ⚠️ CONTENT_ERROR (exit 0 인데 응답이 에러)');
    console.log(`  count: ${contentErrors.length}`);
    const byTask = tallyTaskBy(records, (r) => (r.failure_class || '').startsWith('CONTENT_ERROR'));
    console.log(fmt(byTask, contentErrors.length));
    console.log();
  }

  // Top failing tasks
  console.log('## top failing tasks');
  console.log(fmt(tallyTaskBy(records, (r) => r.classification !== 'success'), failure.length || 1));
}

main().catch((e) => {
  console.error('[report] fatal:', e);
  process.exit(1);
});
