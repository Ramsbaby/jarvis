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

// 한국어+영어 혼합 텍스트의 토큰 추정: 한국어 ~0.7토큰/자, 영어 ~0.25토큰/자
// 70% 한국어 기준 가중 평균 → ~1.5자/토큰 (보수적 추정, 과소평가보다 과대평가가 안전)
const CHARS_PER_TOKEN = 1.5;

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
    const { budgetMode = 'normal', excludeSections = [] } = opts;
    const _excludeSet = new Set(excludeSections);
    const parts = [];
    const loaded = [];

    for (const [name, section] of this._sections) {
      if (section.tier === Tier.REFERENCE) continue; // Tier 2는 절대 프롬프트에 안 넣음
      if (_excludeSet.has(name)) continue; // 명시 제외 (예: jarvis-career에서 format-core 빼기)

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

// ---------------------------------------------------------------------------
// Budget Enforcement (2026-05-28 — 비대화 구조적 차단)
// ---------------------------------------------------------------------------

/**
 * 토큰 예산 cap 모드별 정의.
 * 발화 카테고리별로 다른 cap을 적용해 비대화를 자동 차단.
 */
export const TOKEN_BUDGETS = Object.freeze({
  emotional: 3000,   // 감정 턴: 위로에 필요한 핵심만 (~12KB)
  casual:    4000,   // 잡담: 가볍게 (~16KB)
  analytical: 7000,  // 분석/판단: 깊은 컨텍스트 허용 (~28KB)
  code:      6000,   // 코드 작업: serena·SSoT 필요 (~24KB)
  default:   5000,   // 분류 안 됐을 때 (~20KB)
});

/**
 * 섹션 우선순위 (1~10). 예산 초과 시 낮은 점수부터 drop.
 * 섹션 이름은 register 시 또는 systemParts에 push할 때 메타에 명시.
 *
 * 점수 가이드:
 *   10: identity / language / persona-core (자비스 정체성 — 절대 drop 금지)
 *   9:  safety / channel-persona / time-context
 *   8:  user-context / memory / hot-events / persona-emotional
 *   7:  preferences / persona-rules / format
 *   6:  RAG (분석 채널) / facts-keyword / wiki-keyword
 *   5:  skill-guard / chronic-patterns / evidence-mandate
 *   4:  channel-feed / handoff / anger-section / harness-section
 *   3:  visualization / family-briefing
 *   2:  usage-summary / emotion-injection
 *   1:  attached-image / debug
 */
export const SECTION_PRIORITY = Object.freeze({
  // Tier 10 — 절대 drop 금지
  'identity': 10, 'language': 10, 'persona-core': 10, 'persona-emotional': 10,
  // Tier 9
  'safety': 9, 'channel-persona': 9, 'time-context': 9, 'principles': 9, 'format-core': 9,
  // Tier 8
  'user-context': 8, 'memory': 8, 'hot-events': 8, 'owner-context': 8,
  // Tier 7
  'preferences': 7, 'persona-rules': 7,
  // Tier 6
  'rag-prefetch': 6, 'facts-keyword': 6, 'wiki-keyword': 6,
  // Tier 5
  'skill-guard': 5, 'chronic-patterns': 5, 'evidence-mandate': 5,
  // Tier 4
  'channel-feed': 4, 'handoff': 4, 'anger-section': 4, 'harness-section': 4,
  // Tier 3
  'visualization': 3, 'family-briefing': 3,
  // Tier 2
  'usage-summary': 2, 'emotion-injection': 2,
  // Tier 1
  'attached-image': 1, 'sap-text': 1,
});

/**
 * systemParts 배열에 budget cap 적용 + drop ledger 기록.
 *
 * @param {Array<string | { content: string, name?: string, score?: number }>} systemParts
 * @param {{ mode?: keyof TOKEN_BUDGETS, budget?: number, ledgerPath?: string, channelId?: string }} opts
 * @returns {{ finalPrompt: string, droppedSections: string[], tokenEstimate: number, originalTokens: number }}
 */
export function enforceBudget(systemParts, opts = {}) {
  const { mode = 'default', budget: budgetOverride, ledgerPath, channelId } = opts;
  const budget = budgetOverride || TOKEN_BUDGETS[mode] || TOKEN_BUDGETS.default;

  // Normalize: string → { content, name: 'unknown', score: 5 (default median) }
  const sections = systemParts.map((s, idx) => {
    if (typeof s === 'string') {
      // 섹션 헤더 추출: "--- X ---" 패턴
      const headerMatch = s.match(/---\s*([^-\n]+?)\s*---/);
      const headerText = headerMatch ? headerMatch[1].trim() : '';
      const inferredName = inferSectionName(headerText);
      // [2026-05-29 #10] 추론 실패 시 unknown ledger 적재 — 점진적 발견
      if (!inferredName && headerText && s.length > 200) {
        _recordUnknownSection(headerText, ledgerPath);
      }
      const score = SECTION_PRIORITY[inferredName] ?? 5;
      return { content: s, name: inferredName || `unnamed-${idx}`, score, idx };
    }
    return {
      content: s.content,
      name: s.name || `unnamed-${idx}`,
      score: s.score ?? SECTION_PRIORITY[s.name] ?? 5,
      idx,
    };
  });

  // 원본 토큰
  const originalChars = sections.reduce((sum, s) => sum + (s.content || '').length, 0);
  const originalTokens = Math.ceil(originalChars / CHARS_PER_TOKEN);

  if (originalTokens <= budget) {
    // 예산 내 — drop 없이 통과
    return {
      finalPrompt: sections.map(s => s.content).join('\n'),
      droppedSections: [],
      tokenEstimate: originalTokens,
      originalTokens,
    };
  }

  // 예산 초과 — score 낮은 순으로 drop (동점이면 idx 큰 것부터, 즉 나중에 추가된 dynamic)
  const sorted = [...sections].sort((a, b) => {
    if (a.score !== b.score) return a.score - b.score;
    return b.idx - a.idx;
  });

  const dropped = [];
  let currentTokens = originalTokens;
  const droppedIdxSet = new Set();

  for (const s of sorted) {
    if (currentTokens <= budget) break;
    if (s.score >= 10) continue; // 절대 drop 금지
    const tokensCost = Math.ceil((s.content || '').length / CHARS_PER_TOKEN);
    droppedIdxSet.add(s.idx);
    const _rec = { name: s.name, score: s.score, tokens: tokensCost };
    // [2026-06-04] 관측성: 거대(>5000tok) unnamed 섹션은 내용 미리보기를 남겨 정체 추적 가능하게.
    //   unnamed = 헤더 추론 실패 → 정체 불명 비대화의 근본 추적 불가 문제 해결.
    if (tokensCost > 5000 && /^unnamed-/.test(s.name)) {
      _rec.preview = String(s.content || '').slice(0, 200).replace(/\s+/g, ' ');
    }
    dropped.push(_rec);
    currentTokens -= tokensCost;
  }

  // drop ledger 기록 (best-effort, 실패 무시)
  if (ledgerPath && dropped.length) {
    try {
      // dynamic import to avoid hoisting issues
      import('node:fs').then(fs => {
        const entry = JSON.stringify({
          ts: new Date().toISOString(),
          mode, budget, originalTokens, finalTokens: currentTokens,
          channelId: channelId || null,
          dropped,
        }) + '\n';
        fs.appendFileSync(ledgerPath, entry);
      }).catch(() => {});
    } catch { /* best-effort */ }
  }

  const finalSections = sections.filter(s => !droppedIdxSet.has(s.idx));
  return {
    finalPrompt: finalSections.map(s => s.content).join('\n'),
    droppedSections: dropped.map(d => d.name),
    tokenEstimate: currentTokens,
    originalTokens,
  };
}

/**
 * 섹션 헤더 텍스트에서 정규화된 이름 추론.
 * 예: "Owner Context" → "owner-context", "🔔 최근 주요 이벤트" → "hot-events"
 */
function inferSectionName(headerText) {
  if (!headerText) return null;
  const lower = headerText.toLowerCase();
  // 한국어/이모지 패턴 매핑 — 2026-05-29 결함 수리 #10: 패턴 보강
  if (/owner context/.test(lower)) return 'owner-context';
  if (/owner persona|persona & behaviour/.test(lower)) return 'persona-rules';
  if (/owner system preferences|preferences/.test(lower)) return 'preferences';
  if (/visual.*policy|visualization/.test(lower)) return 'visualization';
  if (/스킬 활성화|skill activated/.test(headerText)) return 'skill-guard';
  if (/만성 패턴|chronic.*pattern/i.test(headerText)) return 'chronic-patterns';
  if (/최근 주요 이벤트|hot.events|🔔/.test(headerText)) return 'hot-events';
  if (/rag 사전 주입|rag prefetch/.test(headerText)) return 'rag-prefetch';
  if (/사용자 기억|user memory/.test(headerText)) return 'memory';
  if (/_facts|facts 발췌|facts.keyword|키워드 매칭 발췌/.test(headerText)) return 'facts-keyword';
  if (/오너 시간|time.context|시간 컨텍스트/.test(headerText)) return 'time-context';
  if (/channel.*상담|channel.*career|channel.*ceo|channel.*market|channel.*boram|channel.*dev/.test(lower)) return 'channel-persona';
  if (/첨부 이미지|attached image/.test(headerText)) return 'attached-image';
  if (/usage|토큰 사용|token usage/.test(headerText)) return 'usage-summary';
  if (/family|가족|보람|brief/.test(headerText)) return 'family-briefing';
  if (/channel feed|채널 피드/.test(headerText)) return 'channel-feed';
  if (/handoff|핸드오프|이전 세션/.test(headerText)) return 'handoff';
  if (/anger|분노|직전 정정/.test(headerText)) return 'anger-section';
  if (/harness/i.test(headerText)) return 'harness-section';
  if (/evidence|실측 의무|evidence mandate/.test(headerText)) return 'evidence-mandate';
  if (/wiki/.test(headerText)) return 'wiki-keyword';
  if (/emotion injection|감정 주입|감정 가이드/.test(headerText)) return 'emotion-injection';
  if (/family.*owner|owner.*family/.test(lower)) return 'family-briefing';
  if (/sap|aif|saa/i.test(headerText)) return 'sap-text';
  return null;
}

/**
 * Unknown 섹션 감지 ledger — 어떤 섹션이 명시 등록 안 됐는지 데이터 누적.
 * [2026-05-29 결함 수리 #10] 24개 push 모두 객체화 대신 점진적 발견.
 */
function _recordUnknownSection(headerText, ledgerPath) {
  if (!ledgerPath || !headerText) return;
  try {
    import('node:fs').then(fs => {
      const entry = JSON.stringify({
        ts: new Date().toISOString(),
        header: headerText.slice(0, 100),
        suggestion: 'inferSectionName 또는 systemParts.push 객체화 필요',
      }) + '\n';
      const unknownPath = ledgerPath.replace('budget-drops', 'budget-unknown');
      fs.appendFileSync(unknownPath, entry);
    }).catch(() => {});
  } catch { /* best-effort */ }
}
