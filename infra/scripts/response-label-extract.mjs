#!/usr/bin/env node
/**
 * response-label-extract.mjs — 실패 라벨 원장 생성기
 *
 * 왜 있나 (2026-08-05):
 *   응답 품질을 텍스트 룰로 7번 고쳤고 7번 다 실패했다. 실패한 이유는 룰이 나빠서가 아니라
 *   "고쳤는데 나아졌는지"를 잴 수단이 한 번도 없었기 때문이다. 매번 감으로 고치고 감으로 끝났다.
 *
 *   형태 계측기(stop-format-meter)를 만들어 242건을 쌓았으나 개선 0건이었다.
 *   응답의 '형태'만 재고 '실패했는지'를 안 쟀기 때문이다. 라벨 없는 특성은 학습에 못 쓴다.
 *
 *   라벨은 이미 존재한다 — 주인님의 지적 발화다. 실측: 오너 발화 1,783건 중 167건(9.4%).
 *   이 도구는 그 지적 발화를 찾아 **직전 자비스 응답**과 짝지어 원장에 적재한다.
 *   그래야 "어떤 응답이 지적을 받았나"가 비로소 데이터가 된다.
 *
 * 설계 원칙
 *   - 라벨은 주인님 발화에서만 나온다. 자비스가 자기 응답을 스스로 채점하지 않는다
 *     (자기 진단은 자기 편향의 재확인이다 — jarvis-ethos).
 *   - LLM 심판을 쓰지 않는다. 재현 불가·diff 불가이고, 같은 입력에 판정이 흔들린다.
 *     정규식은 틀려도 재현되고 git diff가 된다.
 *   - 강/약 두 등급으로 나눈다. "제대로 해"는 지시일 수도 지적일 수도 있다.
 *     강한 신호만으로 먼저 통계를 내고, 약한 신호는 후보로만 남긴다.
 *
 * 사용법:
 *   node response-label-extract.mjs            # 원장 생성
 *   node response-label-extract.mjs --stats    # 원장 기반 상관 분석
 *   node response-label-extract.mjs --since 2026-07-01
 */

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const PROJECTS = join(HOME, '.claude', 'projects');
const BOT_HOME = process.env.BOT_HOME || join(HOME, '.openclaw-data/runtime');
const LEDGER = join(BOT_HOME, 'ledger', 'response-labels.jsonl');

const args = process.argv.slice(2);
const STATS_ONLY = args.includes('--stats');
const SINCE = (args.find((a) => a.startsWith('--since=')) || '').split('=')[1]
  || (args.includes('--since') ? args[args.indexOf('--since') + 1] : '');

// ── 라벨 패턴 ────────────────────────────────────────────────────────────────
// 2026-08-05 정제: 1차 원장에서 두 종류가 섞여 신호가 희석됐다.
//   "84자냐"는 응답 자체가 부실하다는 뜻이고,
//   "땜질 아니냐"·"니가 결정 못하냐"는 응답은 충실했으나 방향이 틀렸다는 뜻이다.
//   후자는 도구 10~13회를 쓴 응답에도 붙었다. 한 통에 넣으면 도구 신호가 죽는다.

// 품질 실패 — 응답이라는 산출물 자체가 부실하다
//
// ⚠️ 2026-08-05 2차 정제: `뭐야?` 단독은 쓰지 않는다.
//    "CL2등급이 뭐야?" "orca의 장점이뭐야?" 같은 **평범한 질문**을 지적으로 오분류했다.
//    33건 중 약 10건이 이 오탐이었다. 불만 문맥이 함께 있는 형태만 받는다.
const QUALITY = /이게\s*뭐야|이거\s*뭐야|저따구|이딴|개소리|헛소리|뭔\s*소리|뭔소리|멍청|병신|틀렸|잘못\s*(했|봤|짚|알)|아무것도\s*모|그것도\s*모르|나에\s*대해\s*모|모르냐\?|무료\s*버전|gpt\s*.{0,8}보다|싸가지|짧게\s*(답|왔)|왜\s*이렇게\s*(짧|길)|확인\s*안\s*했|찾아보지도|하지\s*말고\s*니가|필요없지\s*않/i;

// 방향 지적 — 산출물은 있으나 접근·태도가 틀렸다
const DIRECTION = /땜질|떔질|임시\s*방편|근본적|편향|결정\s*못하냐|니가\s*결정|여쭙지\s*말|물어보지\s*말|그게\s*아니|아니라고|답답/;

// 약 — 재작업 요구. 지적일 수도, 그냥 다음 지시일 수도 있다.
const WEAK = /제대로|다시\s*(해|봐|확인)|말고|하지\s*마|더\s*자세|간단히/;

/** 어느 문구가 라벨을 발화시켰는지 남긴다. 라벨을 사람이 검수할 수 있어야 한다. */
function matchedSpan(re, s) {
  const m = re.exec(s);
  if (!m) return '';
  const i = Math.max(0, m.index - 12);
  return s.slice(i, Math.min(s.length, m.index + m[0].length + 28)).replace(/\n/g, ' ');
}

const SKIP_PREFIX = ['<local-command', '<command-name>', '<command-message>',
  '<command-args>', '[Request interrupted', '<system-reminder>', '다음 [상태]'];

/** 응답 텍스트의 형태 특성. 형태가 원인이라는 뜻이 아니라, 라벨과 붙여봐야 알 수 있다는 뜻이다. */
function shape(text) {
  const lines = text.split('\n');
  return {
    chars: text.length,
    heads: lines.filter((l) => /^#{1,6}\s/.test(l)).length,
    tables: lines.filter((l) => l.trimStart().startsWith('|')).length,
    bold: Math.floor((text.match(/\*\*/g) || []).length / 2),
    bullets: lines.filter((l) => /^\s*[-*+]\s/.test(l)).length,
  };
}

function textOf(msg) {
  const c = msg?.content;
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) {
    return c.filter((b) => b && b.type === 'text').map((b) => b.text || '').join('');
  }
  return '';
}

function isOwnerUtterance(ev) {
  if (ev.type !== 'user') return false;
  const c = ev.message?.content;
  if (typeof c !== 'string') return false;           // 배열 = 도구 결과
  const t = c.trim();
  if (!t || t.length > 600) return false;
  return !SKIP_PREFIX.some((p) => t.startsWith(p));
}

function walk(dir, out = []) {
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = join(dir, e.name);
    // 서브에이전트 트랜스크립트는 제외 — 주인님과의 대화가 아니다
    if (e.isDirectory()) { if (e.name !== 'subagents') walk(p, out); }
    else if (e.name.endsWith('.jsonl')) out.push(p);
  }
  return out;
}

function extract() {
  const files = walk(PROJECTS).filter((f) => f.includes('-Users-ramsbaby'));
  const rows = [];
  for (const f of files) {
    let lines;
    try { lines = readFileSync(f, 'utf-8').split('\n'); } catch { continue; }
    let lastAssistant = null;   // { text, ts, tools }
    let toolsSinceTurn = 0;
    let recallSinceTurn = 0;
    for (const ln of lines) {
      if (!ln.trim()) continue;
      let ev; try { ev = JSON.parse(ln); } catch { continue; }
      const ts = ev.timestamp || '';
      if (SINCE && ts && ts.slice(0, 10) < SINCE) continue;

      if (ev.type === 'assistant') {
        const t = textOf(ev.message);
        const blocks = ev.message?.content;
        if (Array.isArray(blocks)) {
          for (const b of blocks) {
            if (b?.type !== 'tool_use') continue;
            toolsSinceTurn += 1;
            // 기억 조회인가 — 이게 도구 '총량'보다 정확한 축이라는 것이
            // 2026-08-05 품질실패 29건 독해에서 나왔다. 최대 덩어리가 '기억 미사용'이었고
            // 그 사례들이 도구 0회 구간에 몰려 있었다. 총량은 대리 지표일 뿐이다.
            const n = String(b.name || '');
            const inp = JSON.stringify(b.input || {});
            if (/rag_search|get_memory|wiki/i.test(n)
              || /session-recall|rag_search|runtime\/wiki|runtime\/context|user-profile|_facts|learned-mistakes/i.test(inp)) {
              recallSinceTurn += 1;
            }
          }
        }
        if (t.trim()) lastAssistant = { text: t, ts, tools: toolsSinceTurn, recalls: recallSinceTurn };
        continue;
      }
      if (!isOwnerUtterance(ev)) continue;

      const utt = ev.message.content.trim();
      const isQ = QUALITY.test(utt);
      const isD = !isQ && DIRECTION.test(utt);
      const isW = !isQ && !isD && WEAK.test(utt);
      const label = isQ ? 'quality' : isD ? 'direction' : isW ? 'maybe' : 'ok';
      // 라벨이 붙으려면 직전 응답이 있어야 한다. 세션 첫 발화는 대상이 아니다.
      if (lastAssistant) {
        rows.push({
          ts: lastAssistant.ts,
          session: basename(f).slice(0, 8),
          label,
          span: isQ ? matchedSpan(QUALITY, utt) : isD ? matchedSpan(DIRECTION, utt) : '',
          qchars: utt.length,
          tools: lastAssistant.tools,
          recalls: lastAssistant.recalls,
          ...shape(lastAssistant.text),
          head: lastAssistant.text.slice(0, 50).replace(/\n/g, ' '),
        });
      }
      lastAssistant = null;
      toolsSinceTurn = 0;
      recallSinceTurn = 0;
    }
  }
  rows.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
  return rows;
}

function stats(rows) {
  const g = { quality: [], direction: [], maybe: [], ok: [] };
  for (const r of rows) g[r.label]?.push(r);
  const med = (a) => { if (!a.length) return 0; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
  const pct = (n, d) => (d ? (n / d * 100).toFixed(1) : '0.0');

  console.log(`\n라벨 — 품질실패 ${g.quality.length} · 방향지적 ${g.direction.length} · 모호 ${g.maybe.length} · 정상 ${g.ok.length} (총 ${rows.length})`);

  // ── 핵심 검정: 도구 호출 수 구간별 품질실패율 ─────────────────────────────
  // 1차 원장에서 형태 지표는 전부 노이즈였고 도구 수만 신호를 보였다.
  // 중앙값 비교가 아니라 조건부 확률로 직접 검정한다.
  console.log('\n■ 가설 검정 — 도구를 안 쓰고 낸 응답이 더 지적받는가');
  const BUCKETS = [[0, 0, '0회'], [1, 2, '1~2회'], [3, 5, '3~5회'], [6, 999, '6회+']];
  console.log('도구'.padEnd(9) + '응답수'.padStart(8) + '품질실패'.padStart(9) + '실패율'.padStart(9));
  for (const [lo, hi, name] of BUCKETS) {
    const inB = rows.filter((r) => r.tools >= lo && r.tools <= hi);
    const q = inB.filter((r) => r.label === 'quality').length;
    console.log(name.padEnd(9) + String(inB.length).padStart(8) + String(q).padStart(9) + `${pct(q, inB.length)}%`.padStart(9));
  }

  console.log('\n■ 본 검정 — 기억을 조회하고 냈는가 (도구 총량이 아니라 기억 조회 여부)');
  console.log('기억조회'.padEnd(11) + '응답수'.padStart(8) + '품질실패'.padStart(9) + '실패율'.padStart(9));
  for (const [has, name] of [[false, '안 함'], [true, '함']]) {
    const inB = rows.filter((r) => (Number(r.recalls) > 0) === has);
    const q = inB.filter((r) => r.label === 'quality').length;
    console.log(name.padEnd(11) + String(inB.length).padStart(8) + String(q).padStart(9) + `${pct(q, inB.length)}%`.padStart(9));
  }

  // ── 대조: 형태 지표는 여전히 무의미한가 ───────────────────────────────────
  console.log('\n■ 대조 — 형태 지표 (품질실패 vs 정상, 중앙값)');
  console.log('지표'.padEnd(10) + '품질실패'.padStart(10) + '정상'.padStart(9) + '차이'.padStart(10));
  for (const m of ['chars', 'heads', 'tables', 'bold', 'bullets']) {
    const f = med(g.quality.map((r) => r[m])), o = med(g.ok.map((r) => r[m]));
    const diff = o === 0 ? (f === 0 ? '—' : '+∞') : `${((f / o - 1) * 100).toFixed(0)}%`;
    console.log(m.padEnd(10) + String(f).padStart(10) + String(o).padStart(9) + String(diff).padStart(10));
  }

  console.log('\n■ 품질실패 라벨 검수 — 무엇이 라벨을 발화시켰나 (최근 8건)');
  for (const r of g.quality.slice(-8)) {
    console.log(`  ${String(r.ts).slice(0, 16)} ${String(r.chars).padStart(5)}자 도구${String(r.tools).padStart(2)}  ← "${r.span.slice(0, 46)}"`);
  }
  console.log('\n■ 방향지적 라벨 검수 (최근 5건)');
  for (const r of g.direction.slice(-5)) {
    console.log(`  ${String(r.ts).slice(0, 16)} ${String(r.chars).padStart(5)}자 도구${String(r.tools).padStart(2)}  ← "${r.span.slice(0, 46)}"`);
  }
  console.log('\n⚠️ 상관이지 인과가 아니다. 역인과(어려운 질문일수록 도구를 많이 쓰고 만족도가 높다)를');
  console.log('   배제하지 못한다. 이 표는 가설을 고르는 용도지 조치를 정당화하는 근거가 아니다.\n');
}

const rows = extract();
if (!STATS_ONLY) {
  mkdirSync(dirname(LEDGER), { recursive: true });
  writeFileSync(LEDGER, rows.map((r) => JSON.stringify(r)).join('\n') + '\n', 'utf-8');
  console.log(`적재: ${LEDGER} — ${rows.length}행`);
}
stats(rows);
