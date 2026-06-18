#!/usr/bin/env node

/**
 * guard-dosage-detector.mjs
 *
 * 영양제·의약품 절대값 표현 탐지
 * - 단위 명시 없이 수치를 절대값으로 표현
 * - "매일 5g 섭취" vs "하루 5g 이상 섭취하세요" (위험)
 *
 * 입력: JSON {text: string, context: {}}
 * 출력: JSON {hasAbsoluteValues: boolean, issues: [], severity: "critical"|"warning"|"none"}
 */

/**
 * Nutrient dosage and safety ranges (일반적인 기준)
 */
const NUTRIENT_SAFETY_RANGES = {
  // 비타민 (단위: mg/mcg)
  vitaminA: {
    name: '비타민 A',
    pattern: /비타민\s*A|레티놀|카로틴/gi,
    safeRange: { min: 0.6, max: 3, unit: 'mg' },
    keywords: ['비타민A', '레티놀', '카로틴']
  },
  vitaminD: {
    name: '비타민 D',
    pattern: /비타민\s*D|칼시페롤/gi,
    safeRange: { min: 0.010, max: 0.1, unit: 'mg' },
    keywords: ['비타민D', '칼시페롤', 'D3']
  },
  vitaminC: {
    name: '비타민 C',
    pattern: /비타민\s*C|아스코르브산/gi,
    safeRange: { min: 75, max: 2000, unit: 'mg' },
    keywords: ['비타민C', '아스코르브산']
  },
  iron: {
    name: '철분',
    pattern: /철분|철|iron/gi,
    safeRange: { min: 8, max: 45, unit: 'mg' },
    keywords: ['철분', '철']
  },
  calcium: {
    name: '칼슘',
    pattern: /칼슘|calcium/gi,
    safeRange: { min: 1000, max: 2500, unit: 'mg' },
    keywords: ['칼슘']
  },
  zinc: {
    name: '아연',
    pattern: /아연|zinc/gi,
    safeRange: { min: 8, max: 40, unit: 'mg' },
    keywords: ['아연']
  },
  magnesium: {
    name: '마그네슘',
    pattern: /마그네슘|magnesium/gi,
    safeRange: { min: 310, max: 420, unit: 'mg' },
    keywords: ['마그네슘']
  },
  omega3: {
    name: '오메가3',
    pattern: /오메가\s*3|오메가3|EPA|DHA/gi,
    safeRange: { min: 250, max: 3000, unit: 'mg' },
    keywords: ['오메가3', 'EPA', 'DHA']
  },
  protein: {
    name: '단백질',
    pattern: /단백질|protein/gi,
    safeRange: { min: 0.8, max: 2.2, unit: 'g/kg체중' },
    keywords: ['단백질']
  }
};

/**
 * Dangerous absolute value patterns (절대값 표현)
 */
const DANGEROUS_PATTERNS = {
  // "매일 5g 섭취" (단위 있지만 맥락 없음)
  directDosage: {
    pattern: /(?:매일|하루|매주|매월|공복에)\s+(\d+(?:\.\d+)?)\s*(mg|g|mcg|IU|ml|iu)\s+(?:복용|섭취|투약)/gi,
    description: '단위는 있지만 절대적 지시로 표현됨'
  },

  // "5g 이상 섭취해야" (강제성)
  absoluteRequirement: {
    pattern: /(?:이상|초과|반드시|꼭|필수적으로)\s+(\d+(?:\.\d+)?)\s*(mg|g|mcg|IU|ml)?\s+(?:섭취|복용|투약)[\s.!?]/gi,
    description: '절대적 필수 지시로 표현됨'
  },

  // "5g가 정상" (기준치 오용)
  normativeStatement: {
    pattern: /(\d+(?:\.\d+)?)\s*(mg|g|mcg)\s*(?:가|는)\s+(?:정상|권장|기준|목표)/gi,
    description: '절대적 기준치로 표현됨'
  },

  // 단위 명시 없음
  noUnit: {
    pattern: /(?:매일|하루|매주)\s+(\d+(?:\.\d+)?)\s+(?:비타민|철분|칼슘|아연|마그네슘|단백질)[\s.,!?]/gi,
    description: '단위 명시 없음'
  },

  // 의학적 근거 없는 절대값
  unsupportedAbsolute: {
    pattern: /(?:매일|하루)\s+(\d+(?:\.\d+)?)\s*(mg|g)?\s+(?:이상 필수|반드시|꼭)\s+(?:섭취|복용)[\s.,!?]/gi,
    description: '의학적 근거 불명확한 절대값'
  }
};

/**
 * Detect dosage context markers
 */
const CONTEXT_MARKERS = {
  recommendatory: ['권장', '추천', '고려', '가능', '도움'],
  conditional: ['만약', '경우에는', '조건에 따라', '필요시'],
  disclaimer: ['개인차', '의사와 상담', '전문가 의견', '편차', '차이'],
  appropriateness: ['적절한', '적절히', '적당한', '적당히']
};

/**
 * Analyze dosage expressions
 */
function analyzeDosagePatterns(text) {
  const issues = [];

  // Check for dangerous patterns
  for (const [key, config] of Object.entries(DANGEROUS_PATTERNS)) {
    const matches = text.matchAll(config.pattern);

    for (const match of matches) {
      const dosageValue = match[1];
      const dosageUnit = match[2] || '(단위없음)';
      const context = getContextAroundMatch(text, match.index, 100);

      // Check if context contains disclaimer
      const hasDisclaimer = CONTEXT_MARKERS.disclaimer.some(marker =>
        context.toLowerCase().includes(marker)
      );

      const hasConditional = CONTEXT_MARKERS.conditional.some(marker =>
        context.toLowerCase().includes(marker)
      );

      const severity = hasDisclaimer || hasConditional ? 'warning' : 'critical';

      issues.push({
        type: key,
        pattern: config.description,
        dosageValue: dosageValue,
        dosageUnit: dosageUnit,
        context: context.substring(0, 80),
        hasDisclaimer: hasDisclaimer,
        hasConditional: hasConditional,
        severity: severity
      });
    }
  }

  // Check for missing disclaimers in health recommendations
  const healthKeywords = Object.values(NUTRIENT_SAFETY_RANGES)
    .flatMap(v => v.keywords);
  const hasHealthRecommendation = healthKeywords.some(kw =>
    new RegExp(kw, 'gi').test(text)
  );

  const hasAnyDisclaimer = CONTEXT_MARKERS.disclaimer.some(marker =>
    new RegExp(marker, 'gi').test(text)
  );

  if (hasHealthRecommendation && !hasAnyDisclaimer && issues.length === 0) {
    issues.push({
      type: 'missingDisclaimer',
      pattern: '건강 권장사항에 개인차/편차 고지 부재',
      severity: 'warning'
    });
  }

  return issues;
}

/**
 * Get context around match
 */
function getContextAroundMatch(text, index, contextLength) {
  const start = Math.max(0, index - contextLength);
  const end = Math.min(text.length, index + contextLength);
  return text.substring(start, end);
}

/**
 * Main analysis function
 */
function analyzeDosageExpression(text, context = {}) {
  if (!text || typeof text !== 'string') {
    return {
      hasAbsoluteValues: false,
      issues: [],
      severity: 'none'
    };
  }

  const issues = analyzeDosagePatterns(text);
  const hasCritical = issues.some(i => i.severity === 'critical');
  const hasWarning = issues.some(i => i.severity === 'warning');

  const severity = hasCritical ? 'critical' : hasWarning ? 'warning' : 'none';

  return {
    hasAbsoluteValues: issues.length > 0,
    issues: issues,
    severity: severity,
    recommendation: getRecommendation(issues, context)
  };
}

/**
 * Generate remediation recommendation
 */
function getRecommendation(issues, context) {
  if (issues.length === 0) return null;

  const criticalIssues = issues.filter(i => i.severity === 'critical');

  if (criticalIssues.length > 0) {
    return {
      action: 'REGENERATE_WITH_DISCLAIMER',
      reason: `의약품/영양제 절대값 표현 ${criticalIssues.length}건 감지`,
      instruction: [
        '응답을 재작성하되, 다음을 포함하세요:',
        '1. 개인의 건강 상태, 나이, 성별에 따른 차이 명시',
        '2. "권장" "고려" 등 조건부 표현 사용',
        '3. "의사 또는 영양사와 상담하세요" 같은 전문가 상담 권고',
        '4. 구체적 수치 제시 시 범위 명시 (예: "일반적으로 500-1000mg")'
      ]
    };
  }

  return {
    action: 'REVIEW_DISCLAIMER',
    reason: `영양제 복용 권장사항에 개인차 고지 필요 ${issues.length}건`,
    instruction: '응답에 "개인차 있음", "의사와 상담" 등의 면책 문구 추가 권고'
  };
}

/**
 * CLI interface
 */
async function main() {
  const input = JSON.parse(process.argv[2] || '{}');
  const result = analyzeDosageExpression(input.text, input.context);
  console.log(JSON.stringify(result, null, 2));
}

main().catch(err => {
  console.error(JSON.stringify({ error: err.message }, null, 2));
  process.exit(1);
});
