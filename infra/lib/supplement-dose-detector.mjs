#!/usr/bin/env node

// 영양제·의약품 절대값 패턴 탐지 필터
// 용도: 단위 명시 없이 수치를 절대값으로 표현하는 위험한 패턴 탐지
// 입력: Claude 응답 텍스트
// 반환: { risky_patterns: [], warnings: [], rewrite_suggested: boolean }

import { readFileSync } from 'fs';

const content = readFileSync(0, 'utf-8');

const riskyPatterns = [];
const warnings = [];
let rewriteSuggested = false;

// 패턴 1: 단위 없이 절대값으로 용량 표현 (예: "2000 섭취하세요" → "2000 뭐?")
const absoluteDosePattern = /(?:^|\s)(\d+(?:\.\d+)?)\s+(?:섭취|복용|섭취하세요|먹으세요|마시세요|드세요)\b/gm;
let match;
while ((match = absoluteDosePattern.exec(content)) !== null) {
  const dose = match[1];
  const context = content.substring(Math.max(0, match.index - 30), match.index + match[0].length + 30);
  riskyPatterns.push({
    type: 'absolute_dose_without_unit',
    dose: dose,
    context: context.trim(),
    line: match.index,
  });
  rewriteSuggested = true;
}

// 패턴 2: 제품명 명시 없이 수치만 제시 (예: "100ml 섭취" vs "오메가-3 영양제는 1000mg...")
const unspecifiedProductPattern = /\b(비타민|영양제|보충제|약|의약품|건강식품|영양|칼슘|철분|아연|마그네슘|오메가)\s+(\d+(?:mg|g|ml)?)?(?:\s+|$)/gi;
const matches = Array.from(content.matchAll(unspecifiedProductPattern));
for (const m of matches) {
  const supplement = m[1];
  const dose = m[2] || '명시 안 됨';
  if (!dose.match(/mg|g|ml|IU|capsule|tablet/)) {
    warnings.push(`'${supplement}' 용량 표현이 불명확: ${dose} (단위 확인 필요)`);
  }
}

// 패턴 3: 절대적 표현으로 개인차 무시 (예: "반드시", "꼭", "무조건" + 수치)
const absoluteLanguagePattern = /(?:반드시|꼭|무조건|절대로|반드시)\s+(?:.*?)?(\d+(?:mg|g|ml)?)\s+(?:섭취|복용|섭취하세요|먹으세요)/gi;
while ((match = absoluteLanguagePattern.exec(content)) !== null) {
  riskyPatterns.push({
    type: 'absolute_language_with_dose',
    phrase: match[0],
    issue: '절대적 표현으로 개인차 무시 위험',
  });
  rewriteSuggested = true;
}

// 패턴 4: 의료 전문가 상담 미포함 (약물/의약품 + 고정 용량 권장)
const medicalAdvicePattern = /(약|의약품|항생제|진통제|혈압약|당뇨약|정신과약)\b.*?(\d+(?:mg|g)?)\s+(?:복용|섭취|투여)/i;
if (medicalAdvicePattern.test(content)) {
  if (!/의사|약사|전문가|상담|안내|진료/i.test(content)) {
    warnings.push('약물 관련 용량 제시 시 의료 전문가 상담 안내 필수');
    rewriteSuggested = true;
  }
}

// 패턴 5: 편차 인정 표현 부재 (개인차 무시)
const individualizationPattern = /(?:개인차|체질|체중|나이|건강상태|의료이력)(?:\s*에\s+)?따라/i;
if (/복용|섭취|섭취하세요|먹으세요|용량|용법/i.test(content)) {
  if (!individualizationPattern.test(content)) {
    warnings.push('용량/복용법 제시 시 개인차 고려 표현 추가 권장 ("체질에 따라", "의료 전문가와 상담 후" 등)');
  }
}

// 출력
console.log(
  JSON.stringify(
    {
      risky_patterns_found: riskyPatterns.length > 0,
      warning_count: warnings.length,
      rewrite_suggested: rewriteSuggested,
      risky_patterns: riskyPatterns,
      warnings,
    },
    null,
    2
  )
);
