// extract-insights.mjs — llm_call 출력({result,...})에서 통찰 JSON 배열만 추출
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const BOT_HOME = process.env.BOT_HOME || join(process.env.HOME, 'jarvis/runtime');
const DIR = join(BOT_HOME, 'state/owner-state');

let arr = [];
try {
  const raw = JSON.parse(readFileSync(join(DIR, 'llm-out.json'), 'utf-8'));
  let txt = (raw.result || '[]').replace(/```json\s*|```/g, '').trim();
  try {
    arr = JSON.parse(txt);
  } catch {
    const m = txt.match(/\[[\s\S]*\]/);   // 텍스트 속 JSON 배열 폴백 추출
    arr = m ? JSON.parse(m[0]) : [];
  }
  if (!Array.isArray(arr)) arr = [];
} catch (e) {
  console.error('[extract] llm-out 파싱 실패:', e.message);
}

writeFileSync(join(DIR, 'insights-raw.json'), JSON.stringify(arr, null, 2));
console.log(`[extract] ✅ 통찰 ${arr.length}개 추출`);
arr.forEach((x, i) => console.log(`  ${i + 1}. [${x.type || '?'}] ${x.insight || JSON.stringify(x).slice(0, 80)}`));
