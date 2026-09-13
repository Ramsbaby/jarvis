#!/usr/bin/env node
// runtime/ledger/*.jsonl 에서 최근 N일(기본 7) 이내 항목 수를 센다.
// 사용: node infra/scripts/ledger-recent-count.mjs [일수] [--json]
//       node infra/scripts/ledger-recent-count.mjs --selftest
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

const TS_KEYS = ['ts', 'created_at', 'timestamp'];

export function countLines(lines, cutoff) {
  let recent = 0, total = 0, skipped = 0;
  for (const line of lines) {
    if (!line.trim()) continue;
    total++;
    let t = NaN;
    try {
      const o = JSON.parse(line);
      for (const k of TS_KEYS) if (o?.[k] != null) { t = Date.parse(o[k]); break; }
    } catch { /* 깨진 줄 */ }
    if (Number.isNaN(t)) skipped++;
    else if (t >= cutoff) recent++;
  }
  return { recent, total, skipped };
}

function main() {
  const args = process.argv.slice(2);
  const days = Number(args.find(a => /^\d+$/.test(a)) ?? 7);
  const dir = process.env.LEDGER_DIR
    || path.join(process.env.BOT_HOME || path.join(import.meta.dirname, '..', '..', 'runtime'), 'ledger');
  const cutoff = Date.now() - days * 86400_000;

  const rows = readdirSync(dir).filter(n => n.endsWith('.jsonl')).sort()
    .map(f => ({ file: f, ...countLines(readFileSync(path.join(dir, f), 'utf8').split('\n'), cutoff) }));

  const sum = k => rows.reduce((a, r) => a + r[k], 0);
  if (args.includes('--json')) {
    console.log(JSON.stringify({ dir, days, cutoff: new Date(cutoff).toISOString(), rows, total: sum('recent') }));
    return;
  }
  console.log(`${dir} — 최근 ${days}일 (기준 ${new Date(cutoff).toISOString()})`);
  for (const r of rows.filter(r => r.recent > 0).sort((a, b) => b.recent - a.recent)) {
    console.log(`  ${String(r.recent).padStart(7)}  ${r.file}  (전체 ${r.total})`);
  }
  console.log(`  ${String(sum('recent')).padStart(7)}  = 합계 (파일 ${rows.length}개 / 전체 ${sum('total')}줄)`);
  if (sum('skipped')) console.log(`  타임스탬프 없음·파싱 실패 ${sum('skipped')}줄은 제외했습니다.`);
}

if (process.argv.includes('--selftest')) {
  const { strict: assert } = await import('node:assert');
  const now = Date.parse('2026-08-13T00:00:00Z');
  const cutoff = now - 7 * 86400_000;
  const r = countLines([
    '{"ts":"2026-08-12T11:47:28+0900"}',   // 이내 (오프셋 콜론 없음)
    '{"ts":"2026-08-12T15:48:26+09:00"}',  // 이내
    '{"ts":"2026-08-11T09:28:08.738Z"}',   // 이내
    '{"created_at":"2026-08-10T07:02:22.043Z"}', // 이내 (대체 키)
    '{"ts":"2026-07-01T00:00:00Z"}',       // 초과
    '{"ts":"not-a-date"}',                 // 스킵
    '{"foo":1}',                           // 스킵
    '{깨진 json',                          // 스킵
    '',                                    // 무시
  ], cutoff);
  assert.deepEqual(r, { recent: 4, total: 8, skipped: 3 });
  // 경계: cutoff 정각은 포함
  assert.equal(countLines([`{"ts":"${new Date(cutoff).toISOString()}"}`], cutoff).recent, 1);
  console.log('selftest ok');
} else {
  main();
}
