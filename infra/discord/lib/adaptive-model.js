/**
 * adaptive-model.js — 프롬프트 특성 기반 모델 티어 자동 조정
 *
 * 채널 오버라이드(ex. jarvis-dev=power)는 "최대 허용 티어"로만 해석하고,
 * 짧고 단순한 질문은 Haiku로 **다운그레이드**하여 비용·지연 최적화.
 * 복잡도가 오르면 업그레이드는 하지 않는다(채널 오너 의도 존중).
 *
 * 활성화: process.env.ADAPTIVE_MODEL_ENABLED === '1' (기본 비활성)
 *
 * 티어 서열: fast(Haiku) < sonnet(Sonnet) < power(Opus) < opusplan(Opus+Sonnet)
 *
 * 분류 규칙 (우선순위 순):
 *   1. deep   — 코드 블록 포함 / 면접·리뷰·설계·비교·분석 키워드 → 다운그레이드 금지
 *   2. trivial — 20자 미만 + (yes/no, 숫자, 상태 요약 질문)    → fast로 다운
 *   3. normal — 그 외 → 채널 티어 그대로
 *
 * Opus 4.7 전용 라우팅 (2026-05-24 추가):
 *   태스크 타입 'rag-debug' | 'complex-code' 에 한정 적용.
 *   resolveModelTier()의 taskType 파라미터로 전달; 해당 타입이면 tier='opus47' 반환.
 *   models.json의 "opus47" 키로 실제 모델 ID 매핑.
 */

const TIER_RANK = { fast: 0, sonnet: 1, power: 2, opusplan: 2, opus47: 2 };
const TIER_NAME = ['fast', 'sonnet', 'power']; // rank 0,1,2 → 티어 키

/**
 * Opus 4.7 라우팅이 적용되는 태스크 타입 집합.
 * 이 목록 이외의 태스크 타입에는 Opus 4.7이 사용되지 않는다.
 */
export const OPUS47_TASK_TYPES = new Set(['rag-debug', 'complex-code']);

// 코드 블록 / fenced code
const CODE_BLOCK_RE = /```[\s\S]*?```|^\s{4}\S/m;
// deep 키워드 (백엔드·커리어 도메인 위주)
const DEEP_KEYWORDS = /리뷰|설계|아키텍처|비교|트레이드오프|분석|왜\s|이유|원인|depth|deep|explain|디버그|디버깅|최적화|성능|장애|크래시|버그|스키마|migration|마이그레이션|rollback|롤백|면접|이력서|포트폴리오|설명해/;
// trivial 키워드
const TRIVIAL_KEYWORDS = /^(네|예|응|ㅇ|ㄴ|아니|맞아|그래|ok|yes|no)[\s.?!]*$|^\d+[\s.?!]*$|상태\s*알려|얼마|몇\s?개|언제|어디/;

/**
 * 프롬프트를 trivial | normal | deep 로 분류.
 * @param {string} text 사용자 프롬프트
 */
export function classifyPrompt(text) {
  if (!text || typeof text !== 'string') return 'normal';
  const t = text.trim();
  if (CODE_BLOCK_RE.test(t)) return 'deep';
  if (DEEP_KEYWORDS.test(t)) return 'deep';
  if (t.length < 20 && TRIVIAL_KEYWORDS.test(t)) return 'trivial';
  // 초단문(10자 미만) 질문은 trivial
  if (t.length < 10) return 'trivial';
  return 'normal';
}

/**
 * 채널 티어 + 프롬프트 분류 → 최종 티어 결정.
 * @param {string} channelTier 'fast'|'sonnet'|'power'|'opusplan' 또는 undefined
 * @param {string} prompt
 * @param {string} [taskType] 태스크 타입 식별자 (예: 'rag-debug', 'complex-code')
 * @returns {{ tier: string, downgraded: boolean, reason: string }}
 */
export function resolveModelTier(channelTier, prompt, taskType) {
  // Opus 4.7 전용 라우팅: rag-debug / complex-code 태스크에 한정 적용
  if (taskType && OPUS47_TASK_TYPES.has(taskType)) {
    return { tier: 'opus47', downgraded: false, reason: `opus47-tasktype:${taskType}` };
  }
  const baseTier = channelTier || 'sonnet';
  if (process.env.ADAPTIVE_MODEL_ENABLED !== '1') {
    return { tier: baseTier, downgraded: false, reason: 'adaptive-disabled' };
  }
  const kind = classifyPrompt(prompt);
  if (kind === 'deep') {
    return { tier: baseTier, downgraded: false, reason: 'deep-keep' };
  }
  if (kind === 'trivial') {
    // fast가 baseTier보다 높으면 안 내림 (TIER_RANK 0 ≤ baseRank)
    const baseRank = TIER_RANK[baseTier] ?? 1;
    if (baseRank > 0) {
      return { tier: 'fast', downgraded: true, reason: 'trivial-to-fast' };
    }
    return { tier: baseTier, downgraded: false, reason: 'already-fast' };
  }
  // normal — 채널 오너가 명시한 power/opusplan은 의도 존중 (다운 금지).
  // 사고 2026-05-21: jarvis-career(opusplan)에서 감정 메시지 → sonnet 강제 다운 → 응답 품질 급락.
  // 사고 2026-05-22: 5/21 패치가 opusplan만 가드. power(=raw Opus)는 여전히 sonnet 다운 → jarvis-career(power) 짧고 얕은 응답 재발.
  // → power도 가드에 포함. "채널 명시 = 최대치이자 최소치" 원칙으로 통일.
  const baseRank = TIER_RANK[baseTier] ?? 1;
  if (baseRank > 1 && baseTier !== 'opusplan' && baseTier !== 'power') {
    return { tier: 'sonnet', downgraded: true, reason: 'normal-to-sonnet' };
  }
  return { tier: baseTier, downgraded: false, reason: 'normal-keep' };
}

// 테스트용 export
export const _internals = { TIER_RANK, TIER_NAME, CODE_BLOCK_RE, DEEP_KEYWORDS, TRIVIAL_KEYWORDS, OPUS47_TASK_TYPES };
