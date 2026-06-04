/**
 * adaptive-model.js — 프롬프트 특성 기반 모델 티어 자동 조정
 *
 * 채널 오버라이드(ex. jarvis-dev=opusplan)는 "최대 허용 티어"로 해석.
 * 분류 결과와 비용-품질 임계값을 함께 고려하여 최적 티어를 결정한다.
 *
 * 활성화: process.env.ADAPTIVE_MODEL_ENABLED === '1' (기본 비활성)
 *
 * 티어 서열: fast(Haiku) < sonnet(Sonnet) < power/opusplan/opus47(Opus급)
 *
 * 분류 규칙 (우선순위 순):
 *   1. deep   — 코드 블록 포함 / 면접·리뷰·설계·비교·분석 키워드 → 채널 티어 유지
 *   2. trivial — 20자 미만 + (yes/no, 숫자, 상태 요약 질문)    → fast로 다운
 *   3. normal — 예상 비용이 COST_THRESHOLD_USD 미만 → sonnet 으로 합리적 다운
 *              예상 비용이 임계값 이상 → 채널 티어 유지
 *
 * 비용 임계값 (2026-05-25 공시가 기준):
 *   normal 쿼리의 예상 출력 토큰: 약 512tok (평균 응답 ~400 단어)
 *   sonnet 기준 예상 비용: 512 × $15/MTok ≈ $0.0000077 per 응답
 *   Opus  기준 예상 비용: 512 × $25/MTok ≈ $0.0000128 per 응답
 *   → Opus 전용이 필요한 작업(deep)이 아니면 sonnet으로 충분.
 *
 * Opus 4.7 전용 라우팅 (2026-05-24 추가):
 *   태스크 타입 'rag-debug' | 'complex-code' 에 한정 적용.
 *   resolveModelTier()의 taskType 파라미터로 전달; 해당 타입이면 tier='opus47' 반환.
 *   models.json의 "opus47" 키로 실제 모델 ID 매핑.
 *
 * 2026-05-25 비용 재산정 변경 내용:
 *   이전: power/opusplan normal 쿼리 → 채널 티어 무조건 유지 (sonnet 다운 금지 가드)
 *   이후: deep → 채널 티어 유지 / normal → sonnet으로 합리적 다운 (비용 최적화)
 *         trivial → fast 유지
 *   근거: Sonnet 4.6은 Opus 4.7 대비 비용 60% 절감이며 일상 대화·요약·단순 답변에서
 *         품질 차이 미미. Opus급은 deep(코드·아키텍처·면접) 작업에 집중.
 */

const TIER_RANK = { fast: 0, sonnet: 1, power: 2, opusplan: 2, opus47: 2 };
const TIER_NAME = ['fast', 'sonnet', 'power']; // rank 0,1,2 → 티어 키

/**
 * 2026-05-25 공시가 기준 (USD per 1M tokens, platform.claude.com).
 * models.json pricing 섹션과 동기화 유지.
 */
export const TIER_PRICING = {
  fast:     { input: 1.00, output: 5.00  },  // Haiku 4.5
  sonnet:   { input: 3.00, output: 15.00 },  // Sonnet 4.6
  power:    { input: 5.00, output: 25.00 },  // Opus 4.7
  opusplan: { input: 5.00, output: 25.00 },  // Opus 4.7 (보수 계상)
  opus47:   { input: 5.00, output: 25.00 },  // Opus 4.7
};

/**
 * Opus 4.7 라우팅이 적용되는 태스크 타입 집합.
 * 이 목록 이외의 태스크 타입에는 Opus 4.7이 사용되지 않는다.
 */
export const OPUS47_TASK_TYPES = new Set(['rag-debug', 'complex-code']);

// 코드 블록 / fenced code
const CODE_BLOCK_RE = /```[\s\S]*?```|^\s{4}\S/m;
// deep 키워드 (백엔드·커리어 도메인 위주)
// 2026-05-25 A 롤백: 예측·결과·통보 키워드 추가 시도했으나 본질이 "Opus 라우팅 유도 = 스케일업 의존"임이 확인되어 롤백.
// 진짜 해법은 persona-discord.md의 BLOCKING 가드 (B) — sonnet으로도 깊이 답변 충분히 가능 (V2 측정 입증, 2,023자).
// 모델 깊이 가드 원칙: 답변 깊이 문제는 시스템 프롬프트 가드 + 컨텍스트 합성으로 해결. 모델 업그레이드 의존 금지.
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
  // normal — 비용-품질 임계값 기반 라우팅 (2026-05-25 재산정).
  //
  // 이전 로직: power/opusplan 채널에서 normal 입력 → 채널 티어 무조건 유지 (sonnet 다운 금지 가드).
  //            문제: 일상 대화·짧은 답변 요청에도 Opus가 호출 → 불필요한 비용.
  //
  // 새 로직: deep 분류 → 채널 티어 유지 (위 deep 분기에서 이미 처리됨)
  //           normal 분류 → sonnet으로 합리적 다운.
  //           근거: normal 쿼리(일상 대화·요약·단순 답변)에서 Sonnet 4.6은
  //                 Opus 4.7 대비 비용 60% 절감이며 품질 차이 미미.
  //                 Opus급 품질이 필요한 작업은 deep 키워드 분류로 자동 라우팅됨.
  //
  // 비용 비교 (normal 쿼리 예상 512 output tokens 기준):
  //   Sonnet: 512 × $15/MTok ≈ $0.0000077/응답
  //   Opus:   512 × $25/MTok ≈ $0.0000128/응답  → Sonnet 대비 66% 비용
  const baseRank = TIER_RANK[baseTier] ?? 1;
  if (baseRank > 1) {
    return { tier: 'sonnet', downgraded: true, reason: 'normal-cost-optimized-to-sonnet' };
  }
  return { tier: baseTier, downgraded: false, reason: 'normal-keep' };
}

// 테스트용 export
export const _internals = { TIER_RANK, TIER_NAME, CODE_BLOCK_RE, DEEP_KEYWORDS, TRIVIAL_KEYWORDS, OPUS47_TASK_TYPES };
