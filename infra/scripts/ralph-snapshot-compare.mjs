#!/usr/bin/env node
// ralph-snapshot-compare.mjs — A/B 비교 리포트 자동 생성
// 2026-04-28 비서실장 3차
//
// 사용:
//   node ralph-snapshot-compare.mjs <snapshot-A-dir> <snapshot-B-dir>
//   node ralph-snapshot-compare.mjs latest-r1-baseline-serial latest-r2-concurrency3-hybrid
//     → ~/.openclaw-data/runtime/state/snapshots/comparison-<A>-vs-<B>-<timestamp>.md 생성
//
// 비교 메트릭:
//   - 평균 초/문항 (87.8 → ?)
//   - 1라운드 총 시간 (161분 → ?)
//   - 비용/문항 ($0.011 → ?)
//   - 비용 총합 ($1.10 → ?)
//   - forbid 적발 카운트
//   - verifier-server 응답 시간 (단일 → 동시 3)
//   - regex verifier 정확도 (LLM과 비교)
//   - race condition 흔적 (forbid 중복 등재 검사)

import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { join, basename, isAbsolute } from 'node:path';
import { homedir } from 'node:os';

const SNAP_ROOT = join(homedir(), '.openclaw-data/runtime/state/snapshots');

function resolveSnapPath(arg) {
  if (isAbsolute(arg)) return arg;
  return join(SNAP_ROOT, arg);
}

function loadJsonl(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf-8').split('\n').filter(Boolean).map(l => {
    try { return JSON.parse(l); } catch { return null; }
  }).filter(Boolean);
}

function loadJson(path) {
  if (!existsSync(path)) return null;
  try { return JSON.parse(readFileSync(path, 'utf-8')); } catch { return null; }
}

function loadSnapshot(dir) {
  if (!existsSync(dir)) {
    console.error(`❌ snapshot not found: ${dir}`);
    process.exit(1);
  }
  return {
    dir,
    label: basename(dir),
    manifest: loadJson(join(dir, 'manifest.json')),
    rounds: loadJsonl(join(dir, 'ralph-rounds.jsonl')),
    insights: loadJsonl(join(dir, 'ralph-insights.jsonl')),
    forbid: loadJson(join(dir, 'ralph-forbid-list.json')),
    ledger: loadJsonl(join(dir, 'openai-ledger.jsonl')),
  };
}

function lastRound(snap) {
  if (!snap.rounds.length) return null;
  return snap.rounds[snap.rounds.length - 1];
}

function ledgerCostSum(ledgerLines, sinceTs = null) {
  return ledgerLines
    .filter(l => !sinceTs || (l.ts && l.ts >= sinceTs))
    .reduce((s, l) => s + (l.costUsd || 0), 0);
}

function detectRaceConditions(snap) {
  const issues = [];
  // 1. forbid 중복 등재 검사
  if (snap.forbid && Array.isArray(snap.forbid.forbidPatterns)) {
    const seen = new Set();
    const dups = [];
    for (const p of snap.forbid.forbidPatterns) {
      if (seen.has(p)) dups.push(p);
      seen.add(p);
    }
    if (dups.length) issues.push({ type: 'forbid-duplicate', count: dups.length, samples: dups.slice(0, 5) });
  }
  // 2. insights.jsonl 동일 ts 다중 entry (같은 ms에 여러 worker 동시 write)
  const tsCount = {};
  for (const ins of snap.insights) {
    const k = ins.ts;
    tsCount[k] = (tsCount[k] || 0) + 1;
  }
  const dupTs = Object.entries(tsCount).filter(([_, c]) => c > 1);
  if (dupTs.length) issues.push({ type: 'insight-same-ts', count: dupTs.length, hint: '동일 ms 멀티 write — race-safe queue 작동 검증 필요' });
  return issues;
}

function hybridStatsBreakdown(snap) {
  const lr = lastRound(snap);
  if (!lr || !lr.hybridStats) return null;
  const total = lr.hybridStats.regexPass + lr.hybridStats.regexFail + lr.hybridStats.regexRevise + lr.hybridStats.llmFallback;
  return {
    ...lr.hybridStats,
    total,
    llmSkipRate: total ? `${((total - lr.hybridStats.llmFallback) / total * 100).toFixed(1)}%` : 'N/A',
  };
}

// v4.57 (2026-04-29 비서실장): per-qid delta 테이블 — AB 테스트 공정 비교용
function perQidDelta(insightsA, insightsB) {
  // qid별 최신 entry (같은 qid가 여러 번 나오면 마지막 것 사용)
  const mapA = new Map();
  const mapB = new Map();
  for (const e of insightsA) mapA.set(e.qid, e);
  for (const e of insightsB) mapB.set(e.qid, e);
  const common = [...mapA.keys()].filter(qid => mapB.has(qid));
  if (common.length === 0) return null;
  return common.map(qid => {
    const a = mapA.get(qid);
    const b = mapB.get(qid);
    const dOverall = ((b.overallScore || 0) - (a.overallScore || 0));
    const dSsot    = ((b.ssotScore    || 0) - (a.ssotScore    || 0));
    const dHuman   = ((b.humanScore   || 0) - (a.humanScore   || 0));
    const trend = dOverall > 0.2 ? '✅' : dOverall < -0.2 ? '⚠️' : '➖';
    return { qid, aOverall: a.overallScore, bOverall: b.overallScore, dOverall,
             aSsot: a.ssotScore, bSsot: b.ssotScore, dSsot,
             aHuman: a.humanScore, bHuman: b.humanScore, dHuman, trend };
  }).sort((a, b) => b.dOverall - a.dOverall);
}

function metric(label, a, b, unit = '', better = 'lower') {
  const av = typeof a === 'number' ? a.toFixed(2) : a;
  const bv = typeof b === 'number' ? b.toFixed(2) : b;
  let delta = '';
  if (typeof a === 'number' && typeof b === 'number' && a !== 0) {
    const pct = ((b - a) / a * 100).toFixed(1);
    const sign = pct > 0 ? '+' : '';
    const arrow = better === 'lower'
      ? (b < a ? '✅' : (b > a ? '⚠️' : '➖'))
      : (b > a ? '✅' : (b < a ? '⚠️' : '➖'));
    delta = ` (${sign}${pct}% ${arrow})`;
  }
  return `| ${label} | ${av}${unit} | ${bv}${unit} | ${delta} |`;
}

function main() {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    console.error('usage: node ralph-snapshot-compare.mjs <snapshot-A> <snapshot-B>');
    console.error('  e.g.: node ralph-snapshot-compare.mjs latest-r1-baseline-serial latest-r2-concurrency3-hybrid');
    process.exit(1);
  }
  const snapA = loadSnapshot(resolveSnapPath(args[0]));
  const snapB = loadSnapshot(resolveSnapPath(args[1]));
  const lrA = lastRound(snapA);
  const lrB = lastRound(snapB);

  if (!lrA || !lrB) {
    console.error(`❌ snapshot에 ralph-rounds.jsonl 없음 (A: ${!!lrA}, B: ${!!lrB})`);
    process.exit(1);
  }

  // Race detection
  const raceA = detectRaceConditions(snapA);
  const raceB = detectRaceConditions(snapB);

  // Hybrid stats
  const hybridA = hybridStatsBreakdown(snapA);
  const hybridB = hybridStatsBreakdown(snapB);

  // Cost (snapshot ledger 기준 — 단순 합)
  const costA = ledgerCostSum(snapA.ledger);
  const costB = ledgerCostSum(snapB.ledger);
  const costPerQA = lrA.questionsCount ? costA / lrA.questionsCount : 0;
  const costPerQB = lrB.questionsCount ? costB / lrB.questionsCount : 0;

  // Forbid count
  const forbidCountA = snapA.forbid?.forbidPatterns?.length || 0;
  const forbidCountB = snapB.forbid?.forbidPatterns?.length || 0;

  // Avg score (insights)
  const avgScoreA = snapA.insights.length ? snapA.insights.reduce((s, i) => s + (i.overallScore || 0), 0) / snapA.insights.length : 0;
  const avgScoreB = snapB.insights.length ? snapB.insights.reduce((s, i) => s + (i.overallScore || 0), 0) / snapB.insights.length : 0;

  const ts = new Date().toISOString().replace(/[:.]/g, '').replace('T', '-').slice(0, 13);
  const outPath = join(SNAP_ROOT, `comparison-${snapA.label}-vs-${snapB.label}-${ts}.md`);

  const md = `# Ralph A/B 비교 리포트

**생성 시각**: ${new Date().toISOString()}

| 항목 | A: ${snapA.label} | B: ${snapB.label} |
|---|---|---|
| 라벨 | ${snapA.label} | ${snapB.label} |
| 라운드 | r${lrA.roundId} | r${lrB.roundId} |
| Concurrency | ${lrA.concurrency || 1} | ${lrB.concurrency || 1} |
| Hybrid Verifier | ${lrA.hybridVerifier ? '✅' : '❌'} | ${lrB.hybridVerifier ? '✅' : '❌'} |

## 핵심 메트릭

| 항목 | A | B | 변화 |
|---|---|---|---|
${metric('총 시간 (분)', lrA.totalSec / 60, lrB.totalSec / 60, '분', 'lower')}
${metric('평균 초/문항', lrA.avgSec, lrB.avgSec, '초', 'lower')}
${metric('OK 카운트', lrA.okCount, lrB.okCount, '', 'higher')}
${metric('ERR 카운트', lrA.errCount, lrB.errCount, '', 'lower')}
${metric('총 비용', costA, costB, ' USD', 'lower')}
${metric('비용/문항', costPerQA, costPerQB, ' USD', 'lower')}
${metric('평균 메타 점수', avgScoreA, avgScoreB, '/10', 'higher')}
${metric('forbid 누적', forbidCountA, forbidCountB, '개', 'higher')}

## Hybrid Verifier 메트릭 (B만)

${hybridB ? `- regex PASS: ${hybridB.regexPass}
- regex FAIL: ${hybridB.regexFail}
- regex REVISE: ${hybridB.regexRevise}
- LLM fallback: ${hybridB.llmFallback}
- **LLM skip률: ${hybridB.llmSkipRate}** (= 비용 절감 추정치)
` : '- (B에 hybrid verifier 미적용)'}

## Race Condition 검사

### A snapshot
${raceA.length ? raceA.map(r => `- ⚠️ ${r.type}: ${JSON.stringify(r)}`).join('\n') : '- ✅ 검출된 race 흔적 없음'}

### B snapshot
${raceB.length ? raceB.map(r => `- ⚠️ ${r.type}: ${JSON.stringify(r)}`).join('\n') : '- ✅ 검출된 race 흔적 없음'}

## 라운드 메타 통계 (verdict 분포)

| 항목 | A | B |
|---|---|---|
| sample size | ${lrA.metaStats?.sampleSize || 0} | ${lrB.metaStats?.sampleSize || 0} |
| avg score | ${lrA.metaStats?.avgOverallScore || 'N/A'} | ${lrB.metaStats?.avgOverallScore || 'N/A'} |
| PASS | ${lrA.metaStats?.passCount || 0} | ${lrB.metaStats?.passCount || 0} |
| REVISE | ${lrA.metaStats?.reviseCount || 0} | ${lrB.metaStats?.reviseCount || 0} |
| FAIL | ${lrA.metaStats?.failCount || 0} | ${lrB.metaStats?.failCount || 0} |

## Per-qid 점수 비교 (AB 테스트 공정 비교)

${(() => {
  const delta = perQidDelta(snapA.insights, snapB.insights);
  if (!delta) return '_공통 qid 없음 — AB 테스트가 아닌 다른 질문셋이 사용됨. `--replay-round N` 으로 동일 질문 재출제 권장._';
  const avgDelta = delta.reduce((s, r) => s + r.dOverall, 0) / delta.length;
  const improved = delta.filter(r => r.dOverall > 0.2).length;
  const declined = delta.filter(r => r.dOverall < -0.2).length;
  const header = `공통 qid **${delta.length}개** | 개선 ✅ ${improved}개 | 유지 ➖ ${delta.length - improved - declined}개 | 하락 ⚠️ ${declined}개 | 평균 Δoverall **${avgDelta >= 0 ? '+' : ''}${avgDelta.toFixed(2)}**\n`;
  const table = [
    '| qid | A overall | B overall | Δ | A ssot | B ssot | A human | B human | |',
    '|---|---|---|---|---|---|---|---|---|',
    ...delta.map(r =>
      `| ${r.qid} | ${r.aOverall ?? '-'} | ${r.bOverall ?? '-'} | ${r.dOverall >= 0 ? '+' : ''}${r.dOverall.toFixed(1)} | ${r.aSsot ?? '-'} | ${r.bSsot ?? '-'} | ${r.aHuman ?? '-'} | ${r.bHuman ?? '-'} | ${r.trend} |`
    ),
  ].join('\n');
  return header + '\n' + table;
})()}

## 결론

- **시간 효율**: B가 A 대비 ${lrA.totalSec ? `${((1 - lrB.totalSec / lrA.totalSec) * 100).toFixed(1)}%` : 'N/A'} 단축
- **비용 효율**: B가 A 대비 ${costA ? `${((1 - costB / costA) * 100).toFixed(1)}%` : 'N/A'} 절감
- **품질 유지**: 평균 메타 점수 ${avgScoreA.toFixed(2)} → ${avgScoreB.toFixed(2)} (${avgScoreB >= avgScoreA - 0.5 ? '✅ 회귀 없음' : '⚠️ 점수 하락'})
- **race 안정성**: ${raceB.length === 0 ? '✅ B에 race 흔적 없음' : `⚠️ B에 race 흔적 ${raceB.length}건`}

---

생성기: \`ralph-snapshot-compare.mjs\` (2026-04-29 비서실장 v4.57)
`;

  writeFileSync(outPath, md);
  console.log(`✅ 비교 리포트 생성: ${outPath}`);
  console.log(`\n핵심 요약:`);
  console.log(`   ⏱  시간: ${(lrA.totalSec/60).toFixed(1)}분 → ${(lrB.totalSec/60).toFixed(1)}분`);
  console.log(`   💰 비용: $${costA.toFixed(4)} → $${costB.toFixed(4)}`);
  console.log(`   📊 점수: ${avgScoreA.toFixed(2)} → ${avgScoreB.toFixed(2)}`);
  if (hybridB) console.log(`   🔍 LLM skip: ${hybridB.llmSkipRate}`);
}

main();
