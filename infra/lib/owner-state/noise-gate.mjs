// noise-gate.mjs — 3층 노이즈 게이트: 통찰을 3관문으로 거른다. 침묵이 기본값.
//
// 배경: 오답노트 "또 노이즈 발생" 사고들. LLM이 약한 통찰을 내도 여기서 막는다.
// 관문 ① 행동변화(action 구체) ② 실측근거(evidence 존재) ③ 미인지(최근 7일 발송 dedup)

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const BOT_HOME = process.env.BOT_HOME || join(process.env.HOME, 'jarvis/runtime');
const DIR = join(BOT_HOME, 'state/owner-state');

const insights = JSON.parse(readFileSync(join(DIR, 'insights-raw.json'), 'utf-8'));

// 과거 발송 통찰 (dedup용, 최근 7일)
let sentKeys = new Set();
try {
  const sent = readFileSync(join(DIR, 'insight-ledger.jsonl'), 'utf-8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l));
  const norm = s => String(s || '').replace(/\s+/g, '').replace(/[0-9]/g, '#').slice(0, 40);
  sentKeys = new Set(
    sent.filter(s => s.ts && (Date.now() - new Date(s.ts)) / 86400000 < 7).map(s => norm(s.insight))
  );
} catch { /* 첫 실행 — 발송 이력 없음 */ }

const norm = s => String(s || '').replace(/\s+/g, '').replace(/[0-9]/g, '#').slice(0, 40);

// 1층 값싼 눈: 코드가 잡은 확실한 fact-signals는 게이트 면제 → 무조건 통과 (비결정성 하한선)
let factSignals = [];
try { factSignals = JSON.parse(readFileSync(join(DIR, 'fact-signals.json'), 'utf-8')); } catch { /* 없으면 빈 배열 */ }
const factKeys = new Set(factSignals.map(f => norm(f.insight)));
const passed = [...factSignals];
const rejected = [];

for (const x of insights) {
  const reasons = [];
  if (!x.action || x.action.length < 8) reasons.push('행동 없음');           // 관문 1
  if (!x.evidence || x.evidence.length < 8) reasons.push('근거 없음');        // 관문 2
  if (sentKeys.has(norm(x.insight))) reasons.push('최근 7일 발송됨(중복)');    // 관문 3
  if (factKeys.has(norm(x.insight))) reasons.push('fact-signal 중복(코드가 이미 잡음)'); // 관문 4
  if (reasons.length === 0) passed.push(x);
  else rejected.push({ insight: x.insight, reasons });
}

writeFileSync(join(DIR, 'insights-gated.json'), JSON.stringify(passed, null, 2));
console.log(`[noise-gate] 입력 ${insights.length} → 통과 ${passed.length} / 차단 ${rejected.length}`);
rejected.forEach(r => console.log(`  ✗ ${r.insight.slice(0, 38)} — ${r.reasons.join(', ')}`));
if (passed.length === 0) console.log('  → 통과 0개: 발송 안 함 (침묵 = 정상)');
else passed.forEach(x => console.log(`  ✓ [${x.type}] ${x.insight.slice(0, 45)}`));
