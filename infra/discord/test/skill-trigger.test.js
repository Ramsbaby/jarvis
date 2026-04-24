// skill-trigger.test.js — Discord 스킬 트리거 엔진 회귀 테스트
//
// 실행: node infra/discord/test/skill-trigger.test.js
// CI 또는 수동 검증용. assert 실패 시 exit 1.

import { strict as assert } from 'node:assert';
import { detectSkillTrigger, SKILLS } from '../lib/skill-trigger.js';

let pass = 0, fail = 0;
function t(label, fn) {
  try { fn(); pass++; console.log(`✅ ${label}`); }
  catch (e) { fail++; console.log(`❌ ${label}\n   ${e.message}`); }
}

// ── Positive: 9 스킬 자연어 매칭 ──────────────────────────────────
const POSITIVE = [
  // doctor
  ['뭐 문제 없어?', 'doctor'],
  ['점검 해줘', 'doctor'],
  ['점검 좀', 'doctor'],
  ['/doctor', 'doctor'],
  // status
  ['서비스 상태 어때', 'status'],
  ['다 돌아가나?', 'status'],
  // brief
  ['오늘 뭐 있어?', 'brief'],
  ['브리핑 해줘', 'brief'],
  // tqqq
  ['TQQQ 상태', 'tqqq'],
  ['주식 모니터링', 'tqqq'],
  // retro
  ['회고 해줘', 'retro'],
  ['회고하자', 'retro'],
  ['작업 정리 해줘', 'retro'],
  // oops
  ['오답노트에 추가', 'oops'],
  ['이건 오답노트로', 'oops'],
  // autoplan
  ['플랜 세워봐', 'autoplan'],
  ['자동 계획 수립', 'autoplan'],
  // crisis
  ['긴급 상황', 'crisis'],
  ['봇이 죽었어', 'crisis'],
  // deploy
  ['배포 해줘', 'deploy'],
  ['최신화 해줘', 'deploy'],
];
for (const [input, expected] of POSITIVE) {
  t(`Positive: "${input}" → ${expected}`, () => {
    const r = detectSkillTrigger(input);
    assert.equal(r?.skill, expected);
  });
}

// ── Negative: 일상 대화 오탐 방지 ─────────────────────────────────
const NEGATIVE = [
  // 가족·사람 건강
  '아이들 건강 체크 했어?',
  '애들 건강 체크',
  '우리 딸 상태 어때',
  '엄마 건강 점검',
  // 반려동물
  '강아지 건강 체크하고 왔어',
  '고양이 병원 상태',
  '댕댕이 건강 확인',
  // 사물·장소
  '화분 건강 상태',
  '카페 상태 확인',
  '여행 상태 점검',
  // 메타 대화
  '예를 들어 점검 해줘',
  '만약에 봇이 죽었어',
  '가령 배포 해줘',
  // 인용문
  '"뭐 문제 없어"',
  '일반 대화 점심 뭐 먹지',
];
for (const input of NEGATIVE) {
  t(`Negative: "${input}" → null`, () => {
    const r = detectSkillTrigger(input);
    assert.equal(r, null);
  });
}

// ── Explicit slash: 최고 신뢰도 ─────────────────────────────────────
for (const s of SKILLS) {
  t(`Slash explicit: "/${s}" → confidence=1.0`, () => {
    const r = detectSkillTrigger(`/${s}`);
    assert.equal(r?.skill, s);
    assert.equal(r?.confidence, 1.0);
    assert.equal(r?.via, 'explicit-slash');
  });
}

// ── Kill switch 동작 ───────────────────────────────────────────────
t('Kill switch: DISCORD_SKILL_TRIGGER_ENABLED=0 → null', () => {
  const prev = process.env.DISCORD_SKILL_TRIGGER_ENABLED;
  process.env.DISCORD_SKILL_TRIGGER_ENABLED = '0';
  try {
    const r = detectSkillTrigger('점검 해줘');
    assert.equal(r, null);
  } finally {
    if (prev === undefined) delete process.env.DISCORD_SKILL_TRIGGER_ENABLED;
    else process.env.DISCORD_SKILL_TRIGGER_ENABLED = prev;
  }
});

// ── Edge cases ────────────────────────────────────────────────────
t('Edge: null/undefined/empty → null', () => {
  assert.equal(detectSkillTrigger(null), null);
  assert.equal(detectSkillTrigger(undefined), null);
  assert.equal(detectSkillTrigger(''), null);
  assert.equal(detectSkillTrigger('   '), null);
});
t('Edge: non-string → null', () => {
  assert.equal(detectSkillTrigger(123), null);
  assert.equal(detectSkillTrigger({}), null);
});

console.log(`\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
console.log(`📊 ${pass}/${pass+fail} PASS`);
process.exit(fail === 0 ? 0 : 1);
