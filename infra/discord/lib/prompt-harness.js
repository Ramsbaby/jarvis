/**
 * prompt-harness.js — Tiered System Prompt Management
 *
 * 업계 권고(Anthropic, OpenAI, LangChain, Microsoft Research) 기반:
 *   1. Lazy Loading — 필요한 섹션만 로드
 *   2. Tiered Sections — Core(항상) / Contextual(키워드) / Reference(도구)
 *   3. Token Budget — 추정치 기반 로드 결정
 *
 * Tier 0 — CORE (항상 로드, 합계 <3KB)
 *   identity, language, persona-core, principles, safety, format-core, tools-core
 *
 * Tier 1 — CONTEXTUAL (쿼리 키워드 매칭 시만 로드)
 *   format-detail, tools-detail, channel-persona-detail
 *
 * Tier 2 — REFERENCE (프롬프트에 안 넣음, 에이전트가 Read로 조회)
 *   owner-profile, detailed docs, cron config
 */

// Rough chars-to-tokens ratio for Korean+English mixed content
const CHARS_PER_TOKEN = 3.5;

export const Tier = Object.freeze({
  CORE: 0,        // 항상 로드
  CONTEXTUAL: 1,  // 키워드 매칭 시 로드
  REFERENCE: 2,   // 프롬프트에 안 넣음
});

export class PromptHarness {
  constructor() {
    /** @type {Map<string, { tier: number, builder: Function, keywords: RegExp|null }>} */
    this._sections = new Map();
  }

  /**
   * 섹션 등록.
   * @param {string} name — 고유 이름
   * @param {number} tier — Tier.CORE | Tier.CONTEXTUAL | Tier.REFERENCE
   * @param {Function} builder — () => string (섹션 내용 반환)
   * @param {RegExp|null} [keywords] — Tier 1 전용: 이 패턴이 쿼리에 매칭되면 로드
   */
  register(name, tier, builder, keywords = null) {
    this._sections.set(name, { tier, builder, keywords });
  }

  /**
   * 시스템 프롬프트 조립.
   * @param {string} userQuery — 사용자 쿼리 (키워드 매칭용)
   * @param {{ budgetMode?: 'normal'|'lean' }} [opts]
   * @returns {{ prompt: string, tokenEstimate: number, loadedSections: string[] }}
   */
  assemble(userQuery, opts = {}) {
    const { budgetMode = 'normal' } = opts;
    const parts = [];
    const loaded = [];

    for (const [name, section] of this._sections) {
      if (section.tier === Tier.REFERENCE) continue; // Tier 2는 절대 프롬프트에 안 넣음

      if (section.tier === Tier.CORE) {
        // Tier 0: 항상 로드
        const content = section.builder();
        if (content) { parts.push(content); loaded.push(name); }
        continue;
      }

      if (section.tier === Tier.CONTEXTUAL) {
        // Tier 1: budgetMode=lean이면 스킵 (Progressive Compaction 40K 단계)
        if (budgetMode === 'lean') continue;

        // 키워드 매칭 체크
        if (section.keywords && !section.keywords.test(userQuery || '')) continue;

        const content = section.builder();
        if (content) { parts.push(content); loaded.push(name); }
      }
    }

    const prompt = parts.join('\n');
    const tokenEstimate = Math.ceil(prompt.length / CHARS_PER_TOKEN);

    return { prompt, tokenEstimate, loadedSections: loaded };
  }

  /**
   * Tier 0 섹션만 조립 (session hash 계산용).
   * @returns {string}
   */
  assembleCoreOnly() {
    const parts = [];
    for (const [, section] of this._sections) {
      if (section.tier !== Tier.CORE) continue;
      const content = section.builder();
      if (content) parts.push(content);
    }
    return parts.join('\n');
  }

  /**
   * 등록된 섹션 목록 (디버그용).
   * @returns {Array<{ name: string, tier: number, hasKeywords: boolean }>}
   */
  listSections() {
    return Array.from(this._sections.entries()).map(([name, s]) => ({
      name,
      tier: s.tier,
      hasKeywords: !!s.keywords,
    }));
  }
}

// ---------------------------------------------------------------------------
// Singleton factory — 한 번 초기화하면 재사용
// ---------------------------------------------------------------------------

let _instance = null;

/**
 * 하네스 싱글톤 반환. 첫 호출 시 초기화 필요.
 * @returns {PromptHarness}
 */
export function getPromptHarness() {
  if (!_instance) _instance = new PromptHarness();
  return _instance;
}

/**
 * 하네스 리셋 (테스트용).
 */
export function resetPromptHarness() {
  _instance = null;
}
