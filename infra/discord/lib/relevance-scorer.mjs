// relevance-scorer.mjs
// 클러스터 가드: cl-1c2b189b1bc5dd3e — "질문 정조준 부재 / 동문서답 고득점 통과" 반복 결함 방지.
//
// 역할: 면접 답변이 질문 핵심에 직접 답했는지(relevance) 평가.
//       채점 시스템의 relevance 축 부재로 동문서답이 고득점을 받던 구조적 결함을 차단.
//
// 2026-06-16 신설 — mistake-promoter sprint cl-1c2b189b1bc5dd3e
//
// 설계 원칙:
//   1. LLM 호출 없는 결정적(deterministic) 평가 — 지연·비용 0
//   2. 기존 게이트(ssot-coverage-gate, pre-send-gate) 파괴 금지 — 독립 모듈
//   3. 점수는 0.0 ~ 1.0 (높을수록 질문 정조준)
//   4. RELEVANCE_WEIGHT = 0.30 — 전체 답변 품질 중 30% 가중치

// ─────────────────────────────────────────────────────────────
// 상수 — 가중치 및 임계값
// ─────────────────────────────────────────────────────────────

/**
 * relevance 축의 전체 품질 평가 내 가중치 (0.0 ~ 1.0).
 * 채점 시스템에 명시적으로 반영되어야 하는 핵심 가중치.
 * - 기존 축: creative 수(창작/허위) + outOfScope(SSoT 범위)
 * - 신규 축: relevance(질문 핵심 정조준) ← 이 파일이 담당
 */
export const RELEVANCE_WEIGHT = 0.30;

/**
 * 동문서답 차단 임계값. relevance 점수가 이 값 미만이면 WARN 또는 BLOCK.
 */
export const RELEVANCE_WARN_THRESHOLD = 0.40;   // 경고 (답변에 힌트 주입)
export const RELEVANCE_BLOCK_THRESHOLD = 0.20;  // 차단 (재생성 요청)

// ─────────────────────────────────────────────────────────────
// 질문 핵심 키워드 추출
// ─────────────────────────────────────────────────────────────

/**
 * 질문에서 핵심 의미 단위(명사구·동사구)를 추출.
 * 불용어(조사·어미)는 제거.
 *
 * @param {string} question
 * @returns {string[]} 핵심 토큰 배열 (소문자 정규화)
 */
export function extractQuestionKeywords(question) {
  if (!question || typeof question !== 'string') return [];

  const text = question.toLowerCase();

  // 한글 불용어 (조사·어미·접속사)
  const STOPWORDS_KR = new Set([
    '은', '는', '이', '가', '을', '를', '의', '에', '에서', '으로', '로',
    '와', '과', '하고', '이고', '이며', '이나', '나', '도', '만', '까지',
    '부터', '에게', '한테', '으로서', '로서', '에서는', '에서도', '에게서',
    '이란', '란', '라는', '이라는', '에는', '에도', '에만', '에서만',
    '어떻게', '어떤', '무엇', '왜', '언제', '어디', '누가', '무슨',
    '했나요', '하나요', '셨나요', '있나요', '없나요', '인가요', '건가요',
    '하셨', '있으', '없으', '주세요', '해주세요', '알려주세요', '말씀해주세요',
    '것', '수', '때', '거', '점', '등', '및', '또한', '그리고', '하지만',
  ]);

  // 영문 불용어
  const STOPWORDS_EN = new Set([
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could',
    'should', 'may', 'might', 'must', 'can', 'to', 'of', 'in', 'for',
    'on', 'with', 'at', 'by', 'from', 'as', 'into', 'through', 'about',
    'what', 'how', 'why', 'when', 'where', 'who', 'which', 'that', 'this',
  ]);

  const tokens = [];

  // 영문 단어 추출 (2자 이상)
  const enTokens = text.match(/[a-z][a-z0-9_-]{1,}/g) || [];
  for (const t of enTokens) {
    if (!STOPWORDS_EN.has(t) && t.length >= 2) tokens.push(t);
  }

  // 한글 명사구 추출 (2자 이상)
  const krTokens = text.match(/[가-힣]{2,}/g) || [];
  for (const t of krTokens) {
    if (!STOPWORDS_KR.has(t)) tokens.push(t);
  }

  return [...new Set(tokens)];
}

// ─────────────────────────────────────────────────────────────
// 동문서답 패턴 감지 — 강점으로 부정조준하는 패턴
// ─────────────────────────────────────────────────────────────

/**
 * 질문과 무관하게 강점·경험만 나열하는 "부정조준" 패턴.
 * 클러스터 cl-1c2b189b1bc5dd3e 멤버 사례에서 추출.
 */
const OFF_TARGET_PATTERNS = [
  // 질문 무시 후 STAR 경험 자동 삽입 패턴
  /제가\s*(?:경험|진행|참여|주도|담당)한\s*(?:것|사례|프로젝트)/,
  /당시\s*(?:저는|제가)\s*.*(?:했습니다|했고|했으며)/,

  // 힌트 무시 후 주제 전환 패턴
  /(?:그보다|그것보다|그것은|그건|이보다)\s*(?:더|먼저|중요)/,
  /(?:사실|실제로는|정확히는)\s*(?:이\s*질문은|이건|이것은)/,

  // 의존성 추측 패턴 (즉각 판단 회피)
  /(?:어떤|어느)\s*(?:환경|상황|맥락|컨텍스트|스택|버전)\s*(?:인지|인가요|인지에)/,
  /(?:더\s*)?정확한\s*(?:답변|판단|분석|검토)\s*(?:을|를|은|는)?\s*(?:위해|하려면|드리려면)/,
  /(?:구체적인|세부적인|자세한)\s*(?:정보|내용|사항)\s*(?:가|이)\s*(?:있어야|필요)/,
];

/**
 * 답변이 질문 회피 패턴을 포함하는지 검사.
 *
 * @param {string} answer
 * @returns {{ matched: boolean, patterns: string[] }}
 */
export function detectOffTargetPatterns(answer) {
  if (!answer || typeof answer !== 'string') return { matched: false, patterns: [] };

  const matched = [];
  for (const re of OFF_TARGET_PATTERNS) {
    if (re.test(answer)) matched.push(re.source.slice(0, 60));
  }

  return { matched: matched.length > 0, patterns: matched };
}

// ─────────────────────────────────────────────────────────────
// 핵심 API — relevance 점수 산출
// ─────────────────────────────────────────────────────────────

/**
 * 면접 답변의 relevance(질문 정조준) 점수를 계산.
 *
 * 점수 산출 방식:
 *   1. 질문 핵심 키워드 추출 → 답변 내 포함 비율 (0~1)
 *   2. 동문서답 패턴 감지 → 패턴 1건당 -0.15 페널티
 *   3. 첫 2문장 핵심 키워드 조기 등장 보너스 (+0.10)
 *   4. 최종 클램프: 0.0 ~ 1.0
 *
 * @param {Object} args
 * @param {string} args.question — 면접 질문
 * @param {string} args.answer — 모델 답변 (short 또는 detail 본문)
 * @param {string} [args.questionIntent] — 선택: 질문 의도 힌트 ('story'|'concept'|'how-to'|...)
 * @returns {{
 *   score: number,           // 0.0 ~ 1.0 (높을수록 정조준)
 *   verdict: 'PASS'|'WARN'|'BLOCK',
 *   keywordHitRate: number,  // 질문 키워드 답변 포함률
 *   offTargetCount: number,  // 동문서답 패턴 감지 수
 *   earlyHit: boolean,       // 첫 2문장 핵심 키워드 등장 여부
 *   reasons: string[],       // 판단 근거
 *   weight: number,          // RELEVANCE_WEIGHT (채점 시스템 참조용)
 * }}
 */
export function scoreRelevance({ question, answer, questionIntent = null }) {
  const reasons = [];

  if (!question || !answer) {
    return {
      score: 0.5, verdict: 'PASS', keywordHitRate: 0.5,
      offTargetCount: 0, earlyHit: false,
      reasons: ['question 또는 answer 없음 — 중립 점수'],
      weight: RELEVANCE_WEIGHT,
    };
  }

  // 1. 질문 키워드 추출
  const qKeywords = extractQuestionKeywords(question);
  if (qKeywords.length === 0) {
    return {
      score: 0.6, verdict: 'PASS', keywordHitRate: 1.0,
      offTargetCount: 0, earlyHit: false,
      reasons: ['질문 키워드 추출 불가 — 기본 PASS'],
      weight: RELEVANCE_WEIGHT,
    };
  }

  const answerLower = answer.toLowerCase();

  // 2. 키워드 답변 내 포함률
  const hitKeywords = qKeywords.filter(kw => answerLower.includes(kw));
  const keywordHitRate = hitKeywords.length / qKeywords.length;

  reasons.push(`질문 키워드 ${qKeywords.length}개 중 ${hitKeywords.length}개 답변에서 발견 (${(keywordHitRate * 100).toFixed(0)}%)`);

  // 3. 동문서답 패턴 감지
  const offTarget = detectOffTargetPatterns(answer);
  if (offTarget.matched) {
    reasons.push(`동문서답 패턴 ${offTarget.patterns.length}건 감지: ${offTarget.patterns[0]}`);
  }

  // 4. 첫 2문장 조기 등장 보너스
  const firstTwoSentences = answer.split(/[.。!?！？\n]/).slice(0, 2).join(' ').toLowerCase();
  const earlyHit = qKeywords.slice(0, 3).some(kw => firstTwoSentences.includes(kw));
  if (earlyHit) {
    reasons.push('첫 2문장에서 핵심 키워드 조기 등장 (+보너스)');
  }

  // 5. 점수 합산
  let score = keywordHitRate;
  score -= offTarget.patterns.length * 0.15;  // 동문서답 패턴 페널티
  if (earlyHit) score += 0.10;               // 조기 등장 보너스

  // concept 질문은 키워드 hit 기준 완화 (개념 설명 특성상 질문어 반복 적음)
  if (questionIntent === 'concept' && score < 0.3) {
    score += 0.15;
    reasons.push('concept 질문 완화 보정 (+0.15)');
  }

  score = Math.max(0.0, Math.min(1.0, score));

  // 6. verdict 결정
  let verdict;
  if (score < RELEVANCE_BLOCK_THRESHOLD) {
    verdict = 'BLOCK';
    reasons.push(`BLOCK: relevance ${score.toFixed(2)} < 차단임계 ${RELEVANCE_BLOCK_THRESHOLD}`);
  } else if (score < RELEVANCE_WARN_THRESHOLD) {
    verdict = 'WARN';
    reasons.push(`WARN: relevance ${score.toFixed(2)} < 경고임계 ${RELEVANCE_WARN_THRESHOLD}`);
  } else {
    verdict = 'PASS';
  }

  return {
    score: Math.round(score * 100) / 100,
    verdict,
    keywordHitRate: Math.round(keywordHitRate * 100) / 100,
    offTargetCount: offTarget.patterns.length,
    earlyHit,
    reasons,
    weight: RELEVANCE_WEIGHT,
  };
}

// ─────────────────────────────────────────────────────────────
// 통합 채점 헬퍼 — 기존 채점 결과에 relevance 축 병합
// ─────────────────────────────────────────────────────────────

/**
 * 기존 채점 결과(creative, outOfScope 등)에 relevance 축을 추가해 통합 품질 점수 반환.
 *
 * 통합 품질 점수 = relevance(30%) + (1 - creativeRate)(40%) + ssotCoverage(30%)
 *
 * @param {Object} args
 * @param {Object} args.relevanceResult — scoreRelevance() 반환값
 * @param {number} args.creativeCount — verifier 적발 creative 수
 * @param {boolean} args.isOutOfScope — Coverage Gate 결과
 * @param {number} [args.maxCreative=10] — creative 수 정규화 상한
 * @returns {{
 *   compositeScore: number,   // 0.0 ~ 1.0 통합 점수
 *   breakdown: Object,        // 축별 점수 상세
 *   dominantIssue: string|null // 가장 낮은 축 이름
 * }}
 */
export function computeCompositeScore({ relevanceResult, creativeCount = 0, isOutOfScope = false, maxCreative = 10 }) {
  // relevance 축 (30%)
  const relevanceScore = relevanceResult?.score ?? 0.5;
  const relevanceContrib = relevanceScore * RELEVANCE_WEIGHT;

  // creative 축 (40%) — 창작/허위 정보 없을수록 높음
  const creativeRate = Math.min(creativeCount / maxCreative, 1.0);
  const creativeScore = 1.0 - creativeRate;
  const creativeContrib = creativeScore * 0.40;

  // SSoT 커버리지 축 (30%) — inScope일수록 높음
  const ssotScore = isOutOfScope ? 0.0 : 1.0;
  const ssotContrib = ssotScore * 0.30;

  const compositeScore = Math.round((relevanceContrib + creativeContrib + ssotContrib) * 100) / 100;

  const breakdown = {
    relevance: { score: relevanceScore, weight: RELEVANCE_WEIGHT, contrib: Math.round(relevanceContrib * 100) / 100 },
    creative: { score: creativeScore, weight: 0.40, contrib: Math.round(creativeContrib * 100) / 100, rawCount: creativeCount },
    ssotCoverage: { score: ssotScore, weight: 0.30, contrib: Math.round(ssotContrib * 100) / 100, isOutOfScope },
  };

  // 가장 낮은 축 식별
  const axes = [
    { name: 'relevance', score: relevanceScore },
    { name: 'creative', score: creativeScore },
    { name: 'ssotCoverage', score: ssotScore },
  ];
  const lowest = axes.sort((a, b) => a.score - b.score)[0];
  const dominantIssue = lowest.score < 0.5 ? lowest.name : null;

  return { compositeScore, breakdown, dominantIssue };
}
