// adaptive-model.test.js — resolveModelTier 회귀 테스트
//
// 실행: ADAPTIVE_MODEL_ENABLED=1 node infra/discord/test/adaptive-model.test.js
//
// 2026-05-25 비용 재산정 변경 반영:
//   이전: power/opusplan normal → 채널 티어 유지 (sonnet 다운 금지 가드)
//   이후: deep → 채널 티어 유지 / normal → sonnet 합리적 다운 (비용 최적화)
//   근거: normal 쿼리에서 Sonnet 4.6은 Opus 4.7 대비 60% 비용 절감이며 품질 차이 미미.
//
// 사고 이력:
//   2026-05-21: jarvis-career(opusplan) 감정 메시지 → sonnet 강제 다운 → 품질 급락.
//   2026-05-22: power 채널에서도 sonnet 다운 재발.
//   2026-05-25: 비용 재산정으로 normal 쿼리 sonnet 다운을 정책적으로 채택.
//               deep 분류 쿼리는 채널 티어 유지하여 품질 보장.

import { strict as assert } from 'node:assert';
import { resolveModelTier, classifyPrompt, TIER_PRICING } from '../lib/adaptive-model.js';

process.env.ADAPTIVE_MODEL_ENABLED = '1';

let pass = 0, fail = 0;
function t(label, fn) {
  try { fn(); pass++; console.log(`✅ ${label}`); }
  catch (e) { fail++; console.log(`❌ ${label}\n   ${e.message}`); }
}

const TRIVIAL = '네';            // <20자 + trivial keyword → trivial
const NORMAL  = '오늘 점심 메뉴 추천해줘 한식으로 부탁드립니다'; // normal
const DEEP    = '이 코드 아키텍처 리뷰 부탁합니다';  // deep keyword

// ── classifyPrompt sanity ──
t('classifyPrompt: trivial', () => assert.equal(classifyPrompt(TRIVIAL), 'trivial'));
t('classifyPrompt: normal',  () => assert.equal(classifyPrompt(NORMAL),  'normal'));
t('classifyPrompt: deep',    () => assert.equal(classifyPrompt(DEEP),    'deep'));

// ── 12조합: 4 tier × 3 kind ──
const cases = [
  // [baseTier, prompt, expectedTier, expectedDowngraded, label]
  ['fast',     TRIVIAL, 'fast',     false, 'fast+trivial → keep'],
  ['fast',     NORMAL,  'fast',     false, 'fast+normal  → keep'],
  ['fast',     DEEP,    'fast',     false, 'fast+deep    → keep'],

  ['sonnet',   TRIVIAL, 'fast',     true,  'sonnet+trivial → fast'],
  ['sonnet',   NORMAL,  'sonnet',   false, 'sonnet+normal → keep'],
  ['sonnet',   DEEP,    'sonnet',   false, 'sonnet+deep → keep'],

  // power: trivial→fast, normal→sonnet(비용최적화), deep→power(채널 티어 유지)
  ['power',    TRIVIAL, 'fast',   true,  'power+trivial → fast (비용 절감)'],
  ['power',    NORMAL,  'sonnet', true,  'power+normal → sonnet (비용 최적화, 2026-05-25)'],
  ['power',    DEEP,    'power',  false, 'power+deep → keep (채널 티어 유지)'],

  // opusplan: trivial→fast, normal→sonnet(비용최적화), deep→opusplan(채널 티어 유지)
  ['opusplan', TRIVIAL, 'fast',   true,  'opusplan+trivial → fast'],
  ['opusplan', NORMAL,  'sonnet', true,  'opusplan+normal → sonnet (비용 최적화, 2026-05-25)'],
  ['opusplan', DEEP,    'opusplan', false, 'opusplan+deep → keep (채널 티어 유지)'],
];

for (const [tier, prompt, expTier, expDown, label] of cases) {
  t(label, () => {
    const r = resolveModelTier(tier, prompt);
    assert.equal(r.tier, expTier, `tier: got=${r.tier} want=${expTier} reason=${r.reason}`);
    assert.equal(r.downgraded, expDown, `downgraded: got=${r.downgraded} want=${expDown}`);
  });
}

// ── 회귀: 2026-05-25 비용 재산정 — normal 쿼리는 sonnet으로 합리적 다운 ──
t('비용최적화: jarvis-career(power) + 감정 발화 normal → sonnet (비용 절감)', () => {
  const r = resolveModelTier('power', '오늘 정말 떨려요 발표일까지 너무 불안해서 잠도 안 와요');
  assert.equal(r.tier, 'sonnet', `normal 쿼리는 sonnet으로 합리적 다운 — got=${r.tier} reason=${r.reason}`);
  assert.equal(r.downgraded, true);
});

// ── deep 쿼리는 채널 티어 유지 (품질 보장) ──
t('품질보장: jarvis-career(opusplan) + 아키텍처 리뷰 deep → opusplan 유지', () => {
  const r = resolveModelTier('opusplan', '이 마이크로서비스 아키텍처 리뷰 부탁합니다 트레이드오프 포함해서');
  assert.equal(r.tier, 'opusplan', `deep 쿼리는 채널 티어 유지 — got=${r.tier} reason=${r.reason}`);
  assert.equal(r.downgraded, false);
});

// ── TIER_PRICING export 검증 ──
t('TIER_PRICING: 단가 구조 유효성', () => {
  for (const [tier, p] of Object.entries(TIER_PRICING)) {
    assert.ok(typeof p.input === 'number' && p.input > 0, `${tier}.input 유효해야 함`);
    assert.ok(typeof p.output === 'number' && p.output > 0, `${tier}.output 유효해야 함`);
    assert.ok(p.output > p.input, `${tier}: output 단가 > input 단가여야 함`);
  }
});

// ── ADAPTIVE_MODEL_ENABLED=0이면 비활성 ──
t('adaptive 비활성 시 baseTier 그대로 반환', () => {
  delete process.env.ADAPTIVE_MODEL_ENABLED;
  const r = resolveModelTier('power', NORMAL);
  assert.equal(r.reason, 'adaptive-disabled');
  process.env.ADAPTIVE_MODEL_ENABLED = '1';
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
