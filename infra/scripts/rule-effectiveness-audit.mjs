#!/usr/bin/env node
/**
 * rule-effectiveness-audit.mjs — 자가개선 실측 지표: "승격된 룰이 실제로 그 오답을 줄였나?"
 *
 * 문제의식(2026-07-13): 기존 mistake-recurrence-audit는 "같은 클러스터 3회/7일" 임계만 봐서
 *   매일 "재발 0건"을 찍지만, 같은 행동 패턴이 조금씩 다른 형태로 재발하면 임계를 피해간다.
 *   cluster-recurrence-tracker.sh(cluster_id 매칭)는 6/24 이후 데이터 피드가 끊겨 방치됨.
 *   → 이 스크립트는 "룰 도입 전/후, 의미가 유사한 오답의 발생률" 변화를 임베딩으로 실측한다.
 *
 * 데이터:
 *   - 승격 룰: runtime/ledger/promoter-ledger.jsonl (type:cluster, seed, ts, size)
 *   - 개별 오답: runtime/state/mistake-ledger.jsonl (ts, titles) — cluster_id 없음, title 텍스트로 매칭
 *   - 임베딩: Ollama snowflake-arctic-embed2 (localhost:11434), 파일 캐시로 재실행 저렴
 *
 * 지표: 룰마다 effectiveness = (before_rate - after_rate) / before_rate.
 *   +1.0 = 도입 후 완전 소멸, 0 = 변화 없음, 음수 = 오히려 늘어남.
 *
 * 사용: node rule-effectiveness-audit.mjs [--window N] [--sim 0.7] [--max R] [--notify]
 */
import { readFileSync, existsSync, writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname } from 'node:path';

const HOME = homedir();
const PROMOTER = `${HOME}/jarvis/runtime/ledger/promoter-ledger.jsonl`;
const MISTAKES = `${HOME}/jarvis/runtime/state/mistake-ledger.jsonl`;
const OUT_LEDGER = `${HOME}/jarvis/runtime/state/rule-effectiveness.jsonl`;
// 게이트 제안 큐 (2026-07-13): 텍스트 룰이 무효(여전히 재발)인 오답을 "코드 게이트 필요"로 뽑아
//   주인님 검토로 보낸다. promoter의 cluster_id 기반 escalation이 semantic drift로 0건 발동한 걸 대체.
//   ⚠️ 자율 코드생성 안 함 — 제안만. 게이트 구현은 주인님 승인 후.
const GATE_PROPOSALS = `${HOME}/jarvis/runtime/state/gate-proposals.jsonl`;
const EMBED_CACHE = `${HOME}/jarvis/runtime/state/rule-eff-embed-cache.json`;
const MONITORING = `${HOME}/jarvis/runtime/config/monitoring.json`;

const argv = process.argv.slice(2);
const argVal = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
const WINDOW_D = Number(argVal('--window', 10));   // 전/후 관측 창 (일)
const SIM_TH = Number(argVal('--sim', 0.70));      // 의미 유사 임계 (cosine)
const MAX_RULES = Number(argVal('--max', 40));     // 최근 룰 최대 측정 수
const NOTIFY = argv.includes('--notify');
const NOW = Date.now();
const DAY = 86400000;

function loadJSONL(p) {
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8').split('\n').filter((l) => l.trim())
    .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}

// mistake-ledger의 titles는 "['제목']" 파이썬 리스트 문자열 → 텍스트만 추출
function cleanTitle(t) {
  if (Array.isArray(t)) return t.join(' ');
  return String(t || '').replace(/^\[['"]?/, '').replace(/['"]?\]$/, '').replace(/['"]/g, '').trim();
}

// --- 임베딩 (파일 캐시) ---
const cache = existsSync(EMBED_CACHE) ? JSON.parse(readFileSync(EMBED_CACHE, 'utf8')) : {};
let embedCalls = 0;
async function embed(text) {
  const key = text.slice(0, 200);
  if (cache[key]) return cache[key];
  const res = await fetch('http://localhost:11434/api/embeddings', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'snowflake-arctic-embed2', prompt: key }),
  });
  const j = await res.json();
  if (!j.embedding) throw new Error('임베딩 실패');
  cache[key] = j.embedding; embedCalls++;
  return j.embedding;
}
function cosine(a, b) {
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
}

async function main() {
  // 1. 승격 룰: 측정 가능한 것만 (도입 후 창이 지난 것 = ts <= now - WINDOW)
  const proms = loadJSONL(PROMOTER)
    .filter((r) => r.type === 'cluster' && r.seed)
    .filter((r) => new Date(r.ts).getTime() <= NOW - WINDOW_D * DAY)
    .sort((a, b) => new Date(b.ts) - new Date(a.ts))
    .slice(0, MAX_RULES);
  if (!proms.length) { console.log('측정 대상 룰 없음(도입 후 창 미경과)'); return; }

  // 2. 오답 (ts + clean title)
  const mistakes = loadJSONL(MISTAKES).map((m) => ({
    t: new Date(m.ts).getTime(), title: cleanTitle(m.titles),
  })).filter((m) => m.title && !Number.isNaN(m.t));

  console.log(`# 룰 효과 실측 (창 ±${WINDOW_D}일 · 유사임계 ${SIM_TH} · 대상 룰 ${proms.length}건 · 오답 ${mistakes.length}건)`);

  // v2(2026-07-13): 창 방식(도입±N일)은 before 수가 1~3건이라 1→0 노이즈로 "효과" 과대.
  //   올바른 측정 = "도입 시점 발생률 vs 지금(최근 RECENT일) 발생률" → 패턴이 지금도 재발하나.
  const RECENT_D = Number(argVal('--recent', 14));
  const results = [];
  for (const r of proms) {
    const pt = new Date(r.ts).getTime();
    const seedEmb = await embed(r.seed);
    const beforeWin = mistakes.filter((m) => m.t >= pt - WINDOW_D * DAY && m.t < pt);
    const recentWin = mistakes.filter((m) => m.t >= NOW - RECENT_D * DAY);
    let bMatch = 0, rMatch = 0;
    for (const m of beforeWin) if (cosine(seedEmb, await embed(m.title)) >= SIM_TH) bMatch++;
    for (const m of recentWin) if (cosine(seedEmb, await embed(m.title)) >= SIM_TH) rMatch++;
    const bRate = bMatch / WINDOW_D, rRate = rMatch / RECENT_D; // 일당 발생률로 정규화
    const eff = bRate > 0 ? (bRate - rRate) / bRate : null;     // +면 최근 발생률 감소
    results.push({ cluster_id: r.cluster_id, promoted: r.ts.slice(0, 10), seed: r.seed.slice(0, 50), before: bMatch, recent: rMatch, before_rate: +bRate.toFixed(2), recent_rate: +rRate.toFixed(2), effectiveness: eff });
  }

  // 캐시 저장 (재실행 저렴)
  mkdirSync(dirname(EMBED_CACHE), { recursive: true });
  writeFileSync(EMBED_CACHE, JSON.stringify(cache));

  // 3. 집계
  const measurable = results.filter((r) => r.effectiveness !== null);
  const improved = measurable.filter((r) => r.effectiveness >= 0.5);   // 절반 이상 감소 = 효과
  const noEffect = measurable.filter((r) => r.effectiveness > -0.5 && r.effectiveness < 0.5);
  const worse = measurable.filter((r) => r.effectiveness <= -0.5);      // 오히려 늘어남
  const effs = measurable.map((r) => r.effectiveness).sort((a, b) => a - b);
  const median = effs.length ? effs[Math.floor(effs.length / 2)] : null;

  // ── 게이트화 분기 (2026-07-13 · 자기비판 반영 v2): 무효 룰(효과<0.3 + 최근 3건+)을 처리 ──
  const gateNeeded = measurable.filter((r) => r.effectiveness < 0.3 && r.recent >= 3);
  // [Rec3 v2, 2026-07-13] 분류기 정정 — 허구 게이트 방지.
  //   행동(추상)을 먼저·우선 판정: '검증 없이/미확인/단언/선언/추정'은 "내가 확인 안 하고 단정"한 행동이라
  //   파일·경로를 언급해도 결정론 게이트 불가(기존 stop-unverified-assertion-guard.sh도 못 막음이 실증).
  //   진짜 결정론 = 파이프라인의 구체 산출물 무결성(0바이트·손상·유실·첨부 누락)만.
  const classify = (seed) => {
    if (/검증\s*없|미확인|미검증|확인\s*없|확인\s*안|단언|단정|추정|섣부/i.test(seed))
      return { type: 'abstract', hint: '검증-전-단정 행동 — 룰·훅 모두 실패 실증(6/4 guard도 못 막음). 사람+측정 영역, 게이트 불가' };
    if (/0\s*바이트|빈\s*파일|손상|유실|첨부.*누락|업로드\s*실패|전송\s*실패|비어있/i.test(seed))
      return { type: 'deterministic', hint: '파이프라인 산출물 무결성 게이트(전송 전 파일 검증)' };
    return { type: 'review', hint: '수동 검토 — 결정론/추상 판별 애매' };
  };
  // [Rec1] 뿌리 패턴(hint)별로 묶기 — 6개 제안이 실은 2~3 뿌리
  const roots = {};
  for (const g of gateNeeded) {
    const c = classify(g.seed);
    (roots[c.hint] = roots[c.hint] || { type: c.type, hint: c.hint, members: [], recur: 0 });
    roots[c.hint].members.push(g.seed.slice(0, 50));
    roots[c.hint].recur += g.recent;
  }
  const rootList = Object.values(roots).sort((a, b) => b.recur - a.recur);
  const buildable = rootList.filter((r) => r.type === 'deterministic'); // 실제 게이트화 가능한 것만
  const abstractN = rootList.filter((r) => r.type === 'abstract').length;
  // 제안 적재 (뿌리 단위 · hint dedup)
  if (rootList.length) {
    mkdirSync(dirname(GATE_PROPOSALS), { recursive: true });
    const seenHints = new Set(loadJSONL(GATE_PROPOSALS).filter((p) => p.status === 'proposed').map((p) => p.root_hint));
    for (const r of rootList) {
      if (seenHints.has(r.hint)) continue;
      appendFileSync(GATE_PROPOSALS, JSON.stringify({
        ts: new Date().toISOString(), root_hint: r.hint, gateable: r.type === 'deterministic',
        total_recurrence: r.recur, members: r.members, status: 'proposed',
      }) + '\n');
    }
  }

  console.log('─'.repeat(70));
  console.log('cluster        도입일   도입전 최근14d  효과   seed');
  for (const r of results.slice(0, 20)) {
    const e = r.effectiveness === null ? ' N/A ' : (r.effectiveness >= 0 ? '+' : '') + (r.effectiveness * 100).toFixed(0) + '%';
    console.log(`${(r.cluster_id || '').slice(0, 12).padEnd(13)} ${r.promoted} ${String(r.before).padStart(5)} ${String(r.recent).padStart(6)} ${e.padStart(7)}  ${r.seed}`);
  }
  console.log('─'.repeat(70));
  // [Rec2] 큐가 아니라 매주 '하나의 결정'으로 — 최우선 게이트 1개만 강제 제시 (쌓여 죽는 것 방지)
  let gateLine = '';
  if (buildable.length) {
    const top = buildable[0];
    gateLine += `\n🔨 [이번 주 결정] 최우선 게이트: ${top.hint} — 뿌리 재발 ${top.recur}건(${top.members.length}개 룰). 만들까요? (y/n)`;
  }
  if (abstractN) gateLine += `\n⚠️ 추상 패턴 ${abstractN}종은 결정론 게이트 불가 — 사람이 잡는 영역으로 인정(허구 게이트 안 만듦).`;
  const summary = measurable.length
    ? `📊 룰 효과 실측: 측정가능 ${measurable.length}건 중 실제 감소 ${improved.length}건(${(improved.length / measurable.length * 100).toFixed(0)}%) · 무효과 ${noEffect.length} · 악화 ${worse.length} · 중앙값 ${(median * 100).toFixed(0)}%` + gateLine
    : `📊 룰 효과 실측: before 발생 0이라 측정 가능 룰 없음 (임계·창 조정 필요)`;
  console.log(summary);
  console.log(`(임베딩 신규 호출 ${embedCalls}회 · 캐시 ${Object.keys(cache).length}개)`);

  // 4. 원장 append
  mkdirSync(dirname(OUT_LEDGER), { recursive: true });
  appendFileSync(OUT_LEDGER, JSON.stringify({
    ts: new Date().toISOString(), window_d: WINDOW_D, sim: SIM_TH,
    measured: measurable.length, improved: improved.length, no_effect: noEffect.length, worse: worse.length,
    median_effectiveness: median, results,
  }) + '\n');

  // 5. 알림 (jarvis 채널)
  if (NOTIFY && measurable.length) {
    try {
      const url = JSON.parse(readFileSync(MONITORING, 'utf8')).webhooks?.jarvis;
      if (url) await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ content: summary.slice(0, 1990) }) });
    } catch { /* 알림 실패 비차단 */ }
  }
}
// [Rec4] 실패 시 #jarvis 알림 — 자가개선 측정 도구가 cron에서 조용히 죽는 것 방지(memory-sync 교훈)
main().catch(async (e) => {
  console.error('오류:', e.message);
  try {
    const url = JSON.parse(readFileSync(MONITORING, 'utf8')).webhooks?.jarvis;
    if (url) await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ content: `🔴 rule-effectiveness-audit 실패: ${String(e.message).slice(0, 300)} — 자가개선 측정 도구가 죽었습니다. Ollama·경로 확인 필요.` }) });
  } catch { /* 알림 실패는 무시 */ }
  process.exit(1);
});
