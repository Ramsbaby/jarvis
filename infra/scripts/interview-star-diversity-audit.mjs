#!/usr/bin/env node
// interview-star-diversity-audit.mjs — 면접봇 답변 STAR 분포·매몰 자율 감사
//
// Why 1줄: "어떤 질문이든 같은 STAR로 답하는 매몰"을 주인님이 실면접에서 처음 발견하는
//          사고(2026-06-12 O사 사례) 재발 방지 — 분포 결함은 답변 단건 채점으로는 안 보임.
// LLM 호출 0회 — 기존 채널 피드·채점 원장만 분석. DRYRUN 1주 후 자동 정식 전환.
//
// 검사 5종:
//   V1  매몰: 최근 답변 중 단일 STAR 점유율 > 40% (표본 ≥ 5)
//   V1b 훈련 매몰: ralph 훈련 답변 단일 STAR 점유율 > 40% (표본 ≥ 10)
//   V1c 메타 편중: 메타에이전트(STAR-13)가 2회 연속 — AI 답변이 단일 사례에 매몰 (노션 분석 약점 #5)
//   V2  게이트 위반: STAR-13(메타에이전트)이 허용 3유형(AI 도입/자산화/자기주도) 외 질문에 등장
//   V2b 메타 단일재료: AI 직무 질문 ≥2개에 메타에이전트만 동원 — 다른 AI STAR 0개
//   V3  연속 반복: 같은 STAR 본문이 3회 연속
// V1c·V2b 추가 배경(2026-06-23): 노션 면접 질답 23,000줄 분석 결과 "AI 직무 질문에 면접봇이
//   메타에이전트(사내 AI 비서) 1개로만 답하는 편중"이 V1(40% 임계)·V3(3연속)로는 안 잡힘 —
//   다른 비-AI STAR와 섞이면 점유율 40% 미만이고, AI 질문이 띄엄띄엄이면 3연속도 아님.
// 위반 시: Discord #jarvis-interview 경보 + dev-queue에 수리 제안 자동 등록(pending).

import { readFileSync, existsSync, appendFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { STAR_KEYWORDS, STAR13_META_RE, STAR13_ALLOWED_Q_RE } from '../discord/lib/interview-fast-path.js';

const HOME = homedir();
// 경로는 env로 덮어쓰기 가능 — 합성 픽스처로 V1~V2b 검증할 때 실제 코드 경로를 그대로 테스트하기 위함.
const FEED = process.env.DIVERSITY_FEED || join(HOME, 'jarvis/runtime/state/channel-feed/jarvis-interview.jsonl');
const SELF_LEDGER = process.env.DIVERSITY_LEDGER || join(HOME, 'jarvis/runtime/ledger/interview-diversity-audit.jsonl');
const WINDOW_DAYS = 14;
const DOMINANCE_THRESHOLD = 0.4;
const MIN_SAMPLE = 5;

// v1.1 (2026-06-12 독립 감사 적발 수리 #2·SSoT): 게이트 정규식을 fast-path에서 import — 두 곳 분기 불가.
const GATE_ALLOWED_Q = STAR13_ALLOWED_Q_RE;
const META_RE = STAR13_META_RE;

// v1.1 (수리 #2): 봇 메타태그([SHORT:FAIL chars=...] 등) 제거 후 분석 — 태그 오염 차단 (감사 적발).
const stripBotTags = (t) => (t || '')
  .replace(/\[(SHORT|DETAIL|CACHED|RAG_SKIP|CLASS)[^\]]*\]/g, '')
  .replace(/^[-—\s]+/, '')
  .trim();

function detectStars(text) {
  const found = [];
  for (const [id, kws] of Object.entries(STAR_KEYWORDS)) {
    if (kws.filter(k => text.includes(k)).length >= 2) found.push(id);
  }
  if (META_RE.test(text) && !found.includes('STAR-13')) found.push('STAR-13');
  return found;
}

// 피드 파싱: (질문 from!=fast-path) → (답변 from=fast-path) 쌍 구성
const rows = existsSync(FEED)
  ? readFileSync(FEED, 'utf8').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean)
  : [];
const cutoff = Date.now() - WINDOW_DAYS * 86400e3;
const recent = rows.filter(r => {
  const t = Date.parse((r.ts || '').replace(' KST', '+09:00').replace(' ', 'T'));
  return !isNaN(t) && t >= cutoff;
});

const pairs = [];
let lastQuestion = null;
for (const r of recent) {
  if (r.from === 'jarvis-fast-path') {
    if (r.text) pairs.push({ q: lastQuestion || '', a: stripBotTags(r.text) });
  } else if (r.text) {
    lastQuestion = r.text;
  }
}

// v1.1 (수리 #3): 훈련(ralph) 답변 보조 분포 — 채널 피드에 안 쌓이는 훈련 매몰 사각 보완.
const INSIGHTS = process.env.DIVERSITY_INSIGHTS || join(HOME, 'jarvis/runtime/state/ralph-insights.jsonl');
const ralphStarCount = {};
let ralphTotal = 0;
if (existsSync(INSIGHTS)) {
  for (const l of readFileSync(INSIGHTS, 'utf8').split('\n')) {
    if (!l.trim()) continue;
    let d; try { d = JSON.parse(l); } catch { continue; }
    const t = Date.parse(d.ts || '');
    if (isNaN(t) || t < cutoff) continue;
    const s = d.star;
    if (typeof s === 'string' && s.startsWith('STAR-')) { ralphStarCount[s] = (ralphStarCount[s] || 0) + 1; ralphTotal++; }
  }
}

const starCount = {};
let prev = null, maxRun = 0, run = 0;
let prev13 = false, meta13Run = 0, meta13MaxRun = 0;   // V1c: 메타에이전트(STAR-13) 연속 추적
const aiDomainStars = new Set();                        // V2b: AI 도메인 질문에 동원된 STAR 집합
let aiDomainPairs = 0;
const gateViolations = [];
for (const p of pairs) {
  const stars = detectStars(p.a);
  for (const s of stars) starCount[s] = (starCount[s] || 0) + 1;
  const main = stars[0] || null;
  run = (main && main === prev) ? run + 1 : 1;
  maxRun = Math.max(maxRun, run);
  prev = main;
  // V1c: STAR-13은 detectStars에서 마지막에 push되어 main(=stars[0])이 아닐 수 있음 → 위치 무관하게 등장 여부로 연속 추적.
  const has13 = stars.includes('STAR-13');
  meta13Run = has13 ? (prev13 ? meta13Run + 1 : 1) : 0;
  meta13MaxRun = Math.max(meta13MaxRun, meta13Run);
  prev13 = has13;
  // V2b: AI 도메인 질문(게이트 허용 유형)에 동원된 STAR 수집 — 메타 단일재료 탐지.
  if (GATE_ALLOWED_Q.test(p.q)) {
    aiDomainPairs++;
    for (const s of stars) aiDomainStars.add(s);
  }
  if (has13 && !GATE_ALLOWED_Q.test(p.q)) {
    gateViolations.push({ q: p.q.slice(0, 60), aHead: p.a.slice(0, 60) });
  }
}

const total = pairs.length;
const dominant = Object.entries(starCount).sort((a, b) => b[1] - a[1])[0] || null;
const dominanceRatio = dominant && total ? dominant[1] / total : 0;

const violations = [];
const warnings = [];
if (total < MIN_SAMPLE)
  warnings.push(`표본 부족 (${total}/${MIN_SAMPLE}) — 채널 답변 분포 판정 불가. 침묵 통과 아님 (수리 #3)`);
if (total >= MIN_SAMPLE && dominanceRatio > DOMINANCE_THRESHOLD)
  violations.push(`V1 매몰: ${dominant[0]}이 최근 ${total}개 답변 중 ${dominant[1]}개(${Math.round(dominanceRatio * 100)}%) — 임계 40% 초과`);
// v1.1 (수리 #3): 훈련 분포 매몰 검사 (V1b) — 표본 10 이상일 때만
const ralphDominant = Object.entries(ralphStarCount).sort((a, b) => b[1] - a[1])[0] || null;
const ralphRatio = ralphDominant && ralphTotal ? ralphDominant[1] / ralphTotal : 0;
if (ralphTotal >= 10 && ralphRatio > DOMINANCE_THRESHOLD)
  violations.push(`V1b 훈련 매몰: ${ralphDominant[0]}이 훈련 답변 ${ralphTotal}개 중 ${Math.round(ralphRatio * 100)}%`);
if (gateViolations.length)
  violations.push(`V2 게이트 위반 ${gateViolations.length}건: 비허용 질문에 메타에이전트 등장 — 첫 사례 질문: "${gateViolations[0].q}"`);
if (maxRun >= 3)
  violations.push(`V3 연속 반복: 같은 STAR ${maxRun}회 연속`);
// V1c (2026-06-23): 메타에이전트(STAR-13) 연속 ≥2회 — AI 직무 답변이 단일 사례에 매몰 (노션 분석 약점 #5)
if (meta13MaxRun >= 2)
  violations.push(`V1c 메타 편중: 메타에이전트(STAR-13)가 ${meta13MaxRun}회 연속 등장 — AI 답변 단일재료 매몰(다른 AI 경험 미동원 의심)`);
// V2b (2026-06-23): AI 도메인 질문 ≥2개인데 동원된 STAR가 메타에이전트뿐 — 다른 AI STAR 0개
if (aiDomainPairs >= 2 && aiDomainStars.size > 0 && [...aiDomainStars].every(s => s === 'STAR-13'))
  violations.push(`V2b 메타 단일재료: AI 직무 질문 ${aiDomainPairs}개에 메타에이전트(STAR-13)만 동원 — 다른 AI STAR 0개`);

const entry = {
  ts: new Date().toISOString(), windowDays: WINDOW_DAYS, samples: total,
  starCount, dominant: dominant ? dominant[0] : null, dominanceRatio: +dominanceRatio.toFixed(2),
  maxRun, meta13MaxRun, aiDomainPairs, aiDomainStars: [...aiDomainStars],
  gateViolations: gateViolations.length, violations,
  ralphSamples: ralphTotal, ralphStarCount, warnings,
  status: violations.length ? 'violation' : (warnings.length ? 'insufficient_sample' : 'ok'),
};
appendFileSync(SELF_LEDGER, JSON.stringify(entry) + '\n');

const all = readFileSync(SELF_LEDGER, 'utf8').split('\n').filter(Boolean);
const firstTs = Date.parse(JSON.parse(all[0]).ts);
const dryrun = process.env.DIVERSITY_AUDIT_DRYRUN === '1' || (Date.now() - firstTs) < 7 * 86400e3;

console.log(`🎭 면접봇 STAR 분포 감사 (최근 ${WINDOW_DAYS}일, 답변 ${total}건)`);
console.log(`   분포: ${JSON.stringify(starCount)}`);
console.log(`   최다: ${dominant ? `${dominant[0]} ${Math.round(dominanceRatio * 100)}%` : '없음'} · 최대 연속 ${maxRun}회 · 게이트 위반 ${gateViolations.length}건`);
console.log(`   훈련(ralph) 분포: 표본 ${ralphTotal}건 ${ralphDominant ? `최다 ${ralphDominant[0]} ${Math.round(ralphRatio * 100)}%` : ''}`);
console.log(`   메타 편중: STAR-13 최대 연속 ${meta13MaxRun}회 / AI 직무질문 ${aiDomainPairs}건 동원 STAR [${[...aiDomainStars].join(', ') || '없음'}]`);
for (const w of warnings) console.log(`   ⚠️ ${w}`);
console.log(violations.length ? `   🚨 위반 ${violations.length}건:\n   - ${violations.join('\n   - ')}` : (warnings.length ? '   ⚠️ 판정 보류 (표본 부족)' : '   ✅ 위반 없음'));
if (dryrun) console.log('   [DRYRUN — 경보·큐 등록 생략]');

if (!dryrun && violations.length) {
  try {
    execFileSync('node', [join(HOME, 'jarvis/infra/lib/task-store.mjs'), 'enqueue',
      '--id', `interview-diversity-fix-${new Date().toISOString().slice(0, 10)}`,
      '--title', '면접봇 STAR 분포 결함 자율 수리 제안',
      '--prompt', `interview-star-diversity-audit 적발: ${violations.join(' / ')} — interview-fast-path.js 게이트·회피블록·프로필 재료 점검 후 수리. 불변식 #13·#14 준수.`,
      '--source', 'interview-diversity-audit'], { timeout: 15000 });
  } catch (e) { console.error('dev-queue 등록 실패:', e.message); }
  try {
    const msg = `🚨 면접봇 STAR 분포 위반 감지\n${violations.join('\n')}\n→ dev-queue에 수리 제안 등록됨`;
    execFileSync('bash', [join(HOME, 'jarvis/infra/scripts/alert-send.sh'), 'warning', 'jarvis-interview', '면접봇 분포 감사', msg.slice(0, 1400)], { timeout: 15000 });
  } catch (e) { console.error('알림 전송 실패:', e.message); }
}
process.exit(0);
