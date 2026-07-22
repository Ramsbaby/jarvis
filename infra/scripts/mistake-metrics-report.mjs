#!/usr/bin/env node
// mistake-metrics-report.mjs — 교정 지표 리포트 (Phase 5 · 2026-07-11 신설)
//
// 목적: "자비스가 실제로 나아지고 있는가"를 감이 아닌 숫자로 판정한다.
// 배경: 2026-07-11 메모리 회귀 사고 후 울트라계획 Phase 5 — 2주 측정 후
//       정정 빈도가 유의미하게 감소하지 않으면 대체 도구 검토가 정당하다는
//       탈출 기준을 주인님께 제공하기 위한 측정 인프라.
//
// 지표 4종:
//   ① 주간 오답노트 신규 등재 수 (learned-mistakes.md `## YYYY-MM-DD` 헤더 — 최근 4주)
//   ② autolearn 활성 룰의 재발 카운트 (텍스트 룰 효과 프록시)
//   ③ promoter run_metrics 최근 7일 (applied/escalated 추이)
//   ④ 읽기 강제 훅 발동 수 (context-state-inject.jsonl)
//
// 실행: node ~/jarvis/infra/scripts/mistake-metrics-report.mjs
// 기록: ~/jarvis/runtime/ledger/correction-metrics.jsonl (append — 회차 간 비교용)
// 크론 미등재 (CRON-INTRODUCTION-CHECKLIST 통과 전) — 온디맨드 실행.

import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { readAllMistakes } from '../lib/learned-mistakes.mjs'; // [2026-07-22] 본체+아카이브 통합 조회
import { homedir } from 'node:os';

const HOME = homedir();
const MISTAKES = join(HOME, 'jarvis/runtime/wiki/meta/learned-mistakes.md');
const AUTOLEARN = join(HOME, '.claude/rules/jarvis-autolearn.md');
const PROMOTER_LEDGER = join(HOME, 'jarvis/runtime/ledger/promoter-ledger.jsonl');
const INJECT_LOG = join(HOME, 'jarvis/runtime/logs/context-state-inject.jsonl');
const OUT_LEDGER = join(HOME, 'jarvis/runtime/ledger/correction-metrics.jsonl');

function nowKST() {
  return new Date(Date.now() + 9 * 3600e3).toISOString().replace(/\.\d+Z$/, '+09:00');
}

// ① 주간 오답노트 신규 등재 수 (최근 28일, 7일 버킷)
function weeklyMistakes() {
  if (!existsSync(MISTAKES)) return null;
  const dates = [...readAllMistakes().matchAll(/^## (\d{4}-\d{2}-\d{2}) — /gm)] // [2026-07-22] 본체+아카이브 합산
    .map((m) => m[1]);
  const today = new Date(nowKST().slice(0, 10));
  const buckets = [0, 0, 0, 0]; // [이번 주(0~6일 전), 1주 전, 2주 전, 3주 전]
  for (const d of dates) {
    const age = Math.floor((today - new Date(d)) / 86400e3);
    if (age >= 0 && age < 28) buckets[Math.floor(age / 7)] += 1;
  }
  return { total_entries: dates.length, weekly: buckets };
}

// ② autolearn 활성 룰 재발 카운트 (룰 본문의 "재발 N건" 표기 집계)
function autolearnRecurrence() {
  if (!existsSync(AUTOLEARN)) return null;
  const content = readFileSync(AUTOLEARN, 'utf-8');
  const rules = [...content.matchAll(/## \[자동학습\] (.+?) \(BLOCKING[\s\S]*?재발 (\d+)건/g)]
    .map((m) => ({ title: m[1].trim(), recurrence_7d: parseInt(m[2], 10) }))
    .sort((a, b) => b.recurrence_7d - a.recurrence_7d);
  return { active_rules: rules.length, top5: rules.slice(0, 5) };
}

// ③ promoter run_metrics 최근 7일 합계
function promoterMetrics() {
  if (!existsSync(PROMOTER_LEDGER)) return null;
  const cutoff = new Date(Date.now() - 7 * 86400e3);
  const sum = { runs: 0, applied: 0, escalated: 0, held: 0 };
  for (const line of readFileSync(PROMOTER_LEDGER, 'utf-8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const d = JSON.parse(line);
      if (d.type !== 'run_metrics' || new Date(d.ts) < cutoff) continue;
      sum.runs += 1;
      sum.applied += d.applied || 0;
      sum.escalated += d.escalated || 0;
      sum.held += d.held || 0;
    } catch { /* 손상 라인 무시 */ }
  }
  return sum;
}

// ④ 읽기 강제 훅 발동 수 (누적 + 최근 7일)
function injectStats() {
  if (!existsSync(INJECT_LOG)) return { total: 0, last7d: 0 };
  const cutoff = new Date(Date.now() - 7 * 86400e3);
  let total = 0, last7d = 0;
  for (const line of readFileSync(INJECT_LOG, 'utf-8').split('\n')) {
    if (!line.trim()) continue;
    total += 1;
    try { if (new Date(JSON.parse(line).ts) >= cutoff) last7d += 1; } catch { /* 무시 */ }
  }
  return { total, last7d };
}

const report = {
  ts: nowKST(),
  weekly_mistakes: weeklyMistakes(),
  autolearn: autolearnRecurrence(),
  promoter_7d: promoterMetrics(),
  state_inject: injectStats(),
};

// 사람용 요약 출력
const w = report.weekly_mistakes;
console.log(`📊 교정 지표 리포트 — ${report.ts}`);
if (w) console.log(`① 오답노트 주간 신규: 이번주 ${w.weekly[0]}건 | 1주전 ${w.weekly[1]} | 2주전 ${w.weekly[2]} | 3주전 ${w.weekly[3]} (누적 ${w.total_entries}건)`);
if (report.autolearn) {
  console.log(`② autolearn 활성 룰 ${report.autolearn.active_rules}개 — 재발 top5:`);
  report.autolearn.top5.forEach((r) => console.log(`   - ${r.title}: 재발 ${r.recurrence_7d}건`));
}
if (report.promoter_7d) console.log(`③ promoter 최근 7일: 실행 ${report.promoter_7d.runs}회 · 룰적용 ${report.promoter_7d.applied} · 훅승격후보 ${report.promoter_7d.escalated} · 보류 ${report.promoter_7d.held}`);
console.log(`④ 읽기 강제 훅 발동: 최근 7일 ${report.state_inject.last7d}회 (누적 ${report.state_inject.total}회)`);

// 회차 기록 (비교용)
mkdirSync(join(HOME, 'jarvis/runtime/ledger'), { recursive: true });
appendFileSync(OUT_LEDGER, JSON.stringify(report) + '\n', 'utf-8');
console.log(`\n기록: ${OUT_LEDGER}`);
