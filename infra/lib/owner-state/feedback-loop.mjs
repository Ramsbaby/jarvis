// feedback-loop.mjs — 4층 학습 루프: 발송 통찰 기록 + 주인님 반응 → 다음 판단 개선
//
// 루프: recordSent(발송 시 ledger 기록) → 주인님 반응 recordFeedback(noise/helpful)
//       → insight-llm.sh가 feedback.jsonl의 noise를 읽어 다음 프롬프트에 회피 주입.

import { appendFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const BOT_HOME = process.env.BOT_HOME || join(process.env.HOME, 'jarvis/runtime');
const DIR = join(BOT_HOME, 'state/owner-state');
const LEDGER = join(DIR, 'insight-ledger.jsonl');
const FEEDBACK = join(DIR, 'feedback.jsonl');

function hash(s) { let h = 0; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) | 0; return h; }

// 발송된 통찰을 ledger에 기록하고 id를 부여해 반환
export function recordSent(insights, ts) {
  const stamp = ts || new Date().toISOString();
  return insights.map(x => {
    const id = 'ins-' + stamp.replace(/[^0-9]/g, '').slice(0, 14) + '-' + Math.abs(hash(x.insight)).toString(36).slice(0, 4);
    appendFileSync(LEDGER, JSON.stringify({ id, ts: stamp, type: x.type, insight: x.insight }) + '\n');
    return { ...x, id };
  });
}

// 주인님 반응 기록 (verdict: helpful | noise)
export function recordFeedback(id, verdict, ts) {
  let insight = '';
  try {
    const rows = readFileSync(LEDGER, 'utf-8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l));
    const r = rows.find(x => x.id === id);
    if (r) insight = r.insight;
  } catch { /* ledger 없음 */ }
  appendFileSync(FEEDBACK, JSON.stringify({ id, verdict, insight, ts: ts || new Date().toISOString() }) + '\n');
  return insight;
}

// CLI: node feedback-loop.mjs feedback <id> <noise|helpful>
const [, , cmd, arg1, arg2] = process.argv;
if (cmd === 'feedback' && arg1 && arg2) {
  const ins = recordFeedback(arg1, arg2);
  console.log(`[feedback] ${arg1} → ${arg2}${ins ? ' ("' + ins.slice(0, 30) + '...")' : ''}`);
}
