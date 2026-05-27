// fast-path-classify.test.js — classifyQuestionFormat 회귀 테스트
//
// 실행: node infra/discord/test/fast-path-classify.test.js
// 목적: 방법론/기준/원칙 질문이 'concept'으로 분류되어 detailConceptInstructions
//       (용어 정의 → 동작 원리 → 사례 → 트레이드오프 4단)을 받도록 회귀 가드.
//
// 사고 배경 (2026-05-05):
//   "DB 인덱싱은 어떻게 잡나요? 기준이 있나요?" → 'story' 폴백 → [COMPANY] 케이스 폭주.
//   분류기에 방법론·기준·원칙·설계 패턴이 통째로 누락되어 있었음.

import { strict as assert } from 'node:assert';
import { classifyQuestionFormat } from '../lib/interview-fast-path.js';

let pass = 0, fail = 0;
function t(label, fn) {
  try { fn(); pass++; console.log(`✅ ${label}`); }
  catch (e) { fail++; console.log(`❌ ${label}\n   ${e.message}`); }
}

// ── concept (방법론·기준·원칙·설계 가이드) ─────────────────────────
const CONCEPT_CASES = [
  // v4.79 신규: 방법론·기준·원칙
  'DB 인덱싱은 어떻게 잡나요? 기준이 있나요?',
  '인덱스 어떻게 잡나요?',
  '테스트 코드는 어떻게 짜세요?',
  '코드 리뷰 원칙이 있나요?',
  '장애 대응 원칙이 뭔가요?',
  'MSA 설계 어떻게 하나요?',
  '어떤 기준으로 기술 스택을 선택하시나요?',
  '무슨 원칙으로 캐시 전략을 짜나요?',
  '베스트 프랙티스가 있나요?',
  // 기존 패턴 (회귀 방지)
  'Redis란 무엇인가요?',
  'CAP이 뭐예요?',
  'JWT를 설명해 주세요',
  'Redis와 Memcached 차이가 뭐죠?',
  'GC 동작 방식이 어떻게 돼요?',
  // NOTE: "왜 NoSQL을 사용하나요?" 는 기존 정규식 결함 (v4.79 외 사고).
  //   /왜\s*(?:사용|...)/ 가 명사 끼면 미매칭. 별도 후속 작업.
];

// ── story (경험·사례) — STORY_SIGNALS 우선 매칭 ─────────────────────
// "어떻게 X" 패턴이 있어도 STORY 명시어("경험·사례·해결")가 있으면 story 우선
const STORY_CASES = [
  '인덱스 잡는 게 어려웠던 경험이 있나요?',
  '데드락을 어떻게 해결했나요?',
  '가장 어려웠던 프로젝트는?',
  '갈등을 해결한 사례가 있나요?',
  '인상 깊었던 장애 대응 경험 말씀해 주세요',
];

// ── self-intro ─────────────────────────────────────────────────────
const SELF_INTRO_CASES = [
  '자기소개 해주세요',
  '간단하게 소개 부탁드립니다',
  '본인 소개를 해주세요',
];

console.log('━━━ concept (방법론·기준·원칙·설계) ━━━');
for (const q of CONCEPT_CASES) {
  t(`concept: "${q}"`, () => {
    const got = classifyQuestionFormat(q);
    assert.equal(got, 'concept', `expected concept, got ${got}`);
  });
}

console.log('\n━━━ story (경험·사례) ━━━');
for (const q of STORY_CASES) {
  t(`story: "${q}"`, () => {
    const got = classifyQuestionFormat(q);
    assert.equal(got, 'story', `expected story, got ${got}`);
  });
}

console.log('\n━━━ self-intro ━━━');
for (const q of SELF_INTRO_CASES) {
  t(`self-intro: "${q}"`, () => {
    const got = classifyQuestionFormat(q);
    assert.equal(got, 'self-intro', `expected self-intro, got ${got}`);
  });
}

console.log(`\n━━━ 결과: ${pass} pass / ${fail} fail ━━━`);
process.exit(fail > 0 ? 1 : 0);
