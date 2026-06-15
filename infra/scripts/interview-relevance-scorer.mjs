#!/usr/bin/env node
/**
 * interview-relevance-scorer.mjs — 질문 정조준(relevance) 독립 스코어링 모듈
 *
 * 클러스터 cl-1c2b189b1bc5dd3e 가드 (최근 7일 재발 4건 — 2026-06-16 등록)
 *
 * 근본 원인:
 *   채점 시스템(interview-verifier-server.mjs)의 overallScore가 human·ssot·detail
 *   3축 단순 평균이었을 때, 동문서답(질문 핵심 회피·인접 강점으로 부정조준)이
 *   3축 고득점으로 통과하는 구조적 맹점이 있었음.
 *
 *   대표 패턴:
 *   - "왜 커스터머(회원·고객 식별 도메인) 1지망?" → 정산 강점 나열 (질문 미정조준)
 *   - 추측 후 의존성 질문 — 즉각 판단 회피
 *   - 동문서답으로 인접 강점 고득점 통과
 *
 * 해결:
 *   relevanceScore 축을 4번째 채점 축으로 명시 추가.
 *   relevanceScore < 5 → overallScore ceiling 4.0 (FAIL 강제)
 *   relevanceScore 5~6 → overallScore ceiling 6.0 (REVISE 강제)
 *   이 모듈은 verifier-server와 독립적으로 relevance 판정 로직을 캡슐화.
 *
 * 참조:
 *   - interview-verifier-server.mjs v2.0 (2026-06-09): relevance 축 채점 통합
 *   - interview-harness-audit.mjs C8: 이 모듈의 코드 패턴 가드
 *
 * 사용:
 *   import { computeRelevanceCeiling, RELEVANCE_WEIGHT, applyRelevanceCeiling } from './interview-relevance-scorer.mjs';
 *   node interview-relevance-scorer.mjs --self-test
 */

// ─── 상수 ────────────────────────────────────────────────────────────────────

/**
 * relevanceScore가 overallScore 계산에 참여하는 축 수 (4축 평균).
 * human(1) + ssot(1) + detail(1) + relevance(1) = 4
 */
export const RELEVANCE_WEIGHT = 1 / 4; // 25% 가중치 (4축 동등 가중치)

/**
 * relevanceScore 구간별 overallScore ceiling 값.
 *   < 5  → FAIL  강제 (ceiling 4.0)
 *   5~6  → REVISE 강제 (ceiling 6.0)
 *   >= 7 → ceiling 없음 (4축 평균 그대로)
 */
export const RELEVANCE_CEILING = Object.freeze({
  FAIL:   { threshold: 5, ceiling: 4.0 },   // relevance < 5
  REVISE: { threshold: 7, ceiling: 6.0 },   // relevance < 7
  NONE:   { ceiling: null },                  // relevance >= 7
});

// ─── 핵심 로직 ───────────────────────────────────────────────────────────────

/**
 * relevanceScore 기반 overallScore ceiling 값을 반환한다.
 *
 * @param {number|undefined} relevanceScore — Claude 채점 결과의 relevanceScore (0-10)
 * @returns {{ ceiling: number|null, zone: 'FAIL'|'REVISE'|'NONE', penaltyApplied: boolean }}
 */
export function computeRelevanceCeiling(relevanceScore) {
  if (typeof relevanceScore !== 'number' || isNaN(relevanceScore)) {
    // 하위호환: relevanceScore 없으면 ceiling 없음 (3축 모드)
    return { ceiling: null, zone: 'NONE', penaltyApplied: false };
  }

  const rel = Math.max(0, Math.min(10, relevanceScore)); // clamp 0-10

  if (rel < RELEVANCE_CEILING.FAIL.threshold) {
    return { ceiling: RELEVANCE_CEILING.FAIL.ceiling, zone: 'FAIL', penaltyApplied: true };
  }
  if (rel < RELEVANCE_CEILING.REVISE.threshold) {
    return { ceiling: RELEVANCE_CEILING.REVISE.ceiling, zone: 'REVISE', penaltyApplied: true };
  }
  return { ceiling: RELEVANCE_CEILING.NONE.ceiling, zone: 'NONE', penaltyApplied: false };
}

/**
 * 4축 평균 overallScore를 계산하고 relevance ceiling을 적용한다.
 *
 * @param {{ humanScore: number, ssotScore: number, detailScore: number, relevanceScore?: number }} scores
 * @returns {{ overallScore: number, verdict: 'PASS'|'REVISE'|'FAIL', relevanceCeiling: ReturnType<computeRelevanceCeiling> }}
 */
export function applyRelevanceCeiling(scores) {
  const { humanScore: h = 0, ssotScore: s = 0, detailScore: d = 0, relevanceScore: rel } = scores;

  const hasRelevance = typeof rel === 'number' && !isNaN(rel);
  const rawAvg = hasRelevance
    ? Math.round(((h + s + d + rel) / 4) * 10) / 10
    : Math.round(((h + s + d) / 3) * 10) / 10;

  const relevanceCeiling = computeRelevanceCeiling(rel);
  const overallScore = relevanceCeiling.ceiling !== null
    ? Math.min(rawAvg, relevanceCeiling.ceiling)
    : rawAvg;

  const verdict = overallScore >= 8 ? 'PASS' : overallScore >= 5 ? 'REVISE' : 'FAIL';

  return { overallScore, verdict, relevanceCeiling, rawAvg };
}

// ─── 자기 테스트 (--self-test 플래그) ────────────────────────────────────────

if (process.argv.includes('--self-test')) {
  let pass = 0, fail = 0;
  function t(label, fn) {
    try { fn(); pass++; console.log(`✅ ${label}`); }
    catch (e) { fail++; console.error(`❌ ${label}\n   ${e.message}`); }
  }

  // computeRelevanceCeiling
  t('relevance 3 → FAIL ceiling 4.0', () => {
    const r = computeRelevanceCeiling(3);
    if (r.zone !== 'FAIL' || r.ceiling !== 4.0) throw new Error(JSON.stringify(r));
  });
  t('relevance 5 → REVISE ceiling 6.0', () => {
    const r = computeRelevanceCeiling(5);
    if (r.zone !== 'REVISE' || r.ceiling !== 6.0) throw new Error(JSON.stringify(r));
  });
  t('relevance 6 → REVISE ceiling 6.0', () => {
    const r = computeRelevanceCeiling(6);
    if (r.zone !== 'REVISE' || r.ceiling !== 6.0) throw new Error(JSON.stringify(r));
  });
  t('relevance 7 → NONE (no ceiling)', () => {
    const r = computeRelevanceCeiling(7);
    if (r.zone !== 'NONE' || r.ceiling !== null) throw new Error(JSON.stringify(r));
  });
  t('relevance 10 → NONE (no ceiling)', () => {
    const r = computeRelevanceCeiling(10);
    if (r.zone !== 'NONE' || r.ceiling !== null) throw new Error(JSON.stringify(r));
  });
  t('relevance undefined → NONE (하위호환)', () => {
    const r = computeRelevanceCeiling(undefined);
    if (r.zone !== 'NONE' || r.penaltyApplied !== false) throw new Error(JSON.stringify(r));
  });

  // applyRelevanceCeiling
  t('4축 평균: h=9,s=9,d=9,rel=9 → overallScore 9.0 PASS', () => {
    const r = applyRelevanceCeiling({ humanScore: 9, ssotScore: 9, detailScore: 9, relevanceScore: 9 });
    if (r.overallScore !== 9.0 || r.verdict !== 'PASS') throw new Error(JSON.stringify(r));
  });
  t('동문서답(rel=2) → ceiling 4.0 FAIL (raw 8.7이어도)', () => {
    const r = applyRelevanceCeiling({ humanScore: 9, ssotScore: 9, detailScore: 9, relevanceScore: 2 });
    if (r.overallScore !== 4.0 || r.verdict !== 'FAIL') throw new Error(JSON.stringify(r));
  });
  t('부분 정조준 실패(rel=6) → ceiling 6.0 REVISE', () => {
    const r = applyRelevanceCeiling({ humanScore: 9, ssotScore: 9, detailScore: 9, relevanceScore: 6 });
    if (r.overallScore !== 6.0 || r.verdict !== 'REVISE') throw new Error(JSON.stringify(r));
  });
  t('rel 없으면 3축 평균 하위호환', () => {
    const r = applyRelevanceCeiling({ humanScore: 9, ssotScore: 6, detailScore: 6 });
    if (r.overallScore !== 7.0 || r.verdict !== 'REVISE') throw new Error(JSON.stringify(r));
  });
  t('RELEVANCE_WEIGHT = 0.25', () => {
    if (Math.abs(RELEVANCE_WEIGHT - 0.25) > 1e-9) throw new Error(`RELEVANCE_WEIGHT=${RELEVANCE_WEIGHT}`);
  });

  console.log(`\n━━━ relevance-scorer self-test: ${pass} pass / ${fail} fail ━━━`);
  if (fail > 0) process.exit(1);
}
