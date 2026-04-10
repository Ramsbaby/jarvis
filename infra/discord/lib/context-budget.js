/**
 * Context budget classification — determines how much compute budget to
 * allocate based on prompt content, length, and presence of images.
 *
 * Exports:
 *   LARGE_KEYWORDS    — RegExp for prompts needing large budget
 *   ANALYSIS_KEYWORDS — RegExp for analysis-type prompts
 *   ACTION_KEYWORDS   — RegExp for action-type prompts
 *   classifyBudget(prompt, hasImages) — returns 'small' | 'medium' | 'large' | 'opusplan'
 *   stripOpusPlanPrefix(prompt)       — strips 'opusplan:' prefix if present
 */

export const LARGE_KEYWORDS = /코드 작성|구현해|리팩터|버그 수정|에러 .{0,10}(고쳐|잡아|수정)|파일 .{0,10}(분석|수정|추가)|클래스|디버그|implement|refactor|debug|fix .{0,10}(bug|error)/i;
export const ANALYSIS_KEYWORDS = /분석|비교|설명|왜|어떻게|원리|차이|무슨|뭔|뭘|무엇|어디|어째서|review|explain|analyze|what|why|how/i;
export const ACTION_KEYWORDS = /해줘|고쳐|바꿔|만들어|삭제|수정|추가|작성|구현|확인|점검|보고|상태|알려|브리핑|요약|정리|현황|진행|처리|실행/;

/** opusplan 명시 접두사 — 계획 Opus, 실행 Sonnet 이중 모델 모드 */
const OPUSPLAN_PREFIX = /^opusplan[:\s]+/i;

/**
 * 'opusplan:' 접두사를 제거한 프롬프트 반환.
 * 접두사가 없으면 원본 그대로 반환.
 *
 * @param {string} prompt
 * @returns {string}
 */
export function stripOpusPlanPrefix(prompt) {
  return prompt.replace(OPUSPLAN_PREFIX, '').trim();
}

/**
 * Classify the compute budget for a prompt.
 *
 * @param {string} prompt - The original user prompt (before RAG/summary injection)
 * @param {boolean} hasImages - Whether the message includes image attachments
 * @returns {'small' | 'medium' | 'large' | 'opusplan'} The budget tier
 */
export function classifyBudget(prompt, hasImages) {
  const trimmed = prompt.trim();

  // 명시적 opusplan 트리거 — 계획 Opus, 실행 Sonnet
  if (OPUSPLAN_PREFIX.test(trimmed)) return 'opusplan';

  const hasLarge = LARGE_KEYWORDS.test(prompt);
  const hasAction = ACTION_KEYWORDS.test(prompt);
  const hasAnalysis = ANALYSIS_KEYWORDS.test(prompt);

  // 코드 작업·이미지·장문 → Opus
  if (hasImages || hasLarge || prompt.length > 200) return 'large';
  // 그 외 전부 medium(Sonnet) — Haiku(small)는 품질 차이가 체감되므로 폐지
  return 'medium';
}
