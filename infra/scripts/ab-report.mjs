#!/usr/bin/env node
/**
 * ab-report.mjs — A/B 실험 ledger 리포트 조회 (P3-3)
 *
 * 사용법:
 *   node ~/.jarvis/scripts/ab-report.mjs            # 전체 실험 리포트
 *   node ~/.jarvis/scripts/ab-report.mjs throttle-v1 # 특정 실험만
 *
 * 출력:
 *   실험별 variant 분산 + avg elapsedMs + count
 *   응답시간 차이가 유의미한지(Δ%) 표시
 */

import { getExperimentReport, listExperiments } from '../discord/lib/ab-experiment.js';

const target = process.argv[2];

function fmt(report, name) {
  const lines = [`\n━━━ ${name} ━━━`];
  if (report.total === 0) {
    lines.push('  (ledger 비어있음 — 아직 수집된 outcome 없음)');
    return lines.join('\n');
  }
  lines.push(`  total: ${report.total} outcomes`);
  const entries = Object.entries(report.perVariant);
  const elapsedList = entries
    .map(([, v]) => v.avgElapsedMs)
    .filter(n => typeof n === 'number');
  const min = elapsedList.length > 0 ? Math.min(...elapsedList) : null;
  for (const [v, stat] of entries) {
    const pct = ((stat.count / report.total) * 100).toFixed(1);
    const avg = stat.avgElapsedMs ?? '-';
    const delta = (min !== null && stat.avgElapsedMs !== null && min > 0)
      ? ` (Δ ${(((stat.avgElapsedMs - min) / min) * 100).toFixed(1)}%)`
      : '';
    lines.push(`  • ${v}: ${stat.count} (${pct}%) · avg ${avg}ms${delta}`);
  }
  return lines.join('\n');
}

try {
  // ab-experiment.js의 _BUILTIN이 모듈 import 시 자동 등록됨
  const names = target ? [target] : listExperiments();
  if (names.length === 0) {
    console.log('등록된 실험 없음');
    process.exit(0);
  }
  for (const name of names) {
    const report = getExperimentReport(name);
    console.log(fmt(report, name));
  }
  console.log('');
} catch (err) {
  console.error('리포트 생성 실패:', err.message);
  process.exit(1);
}
