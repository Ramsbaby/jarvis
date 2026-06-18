#!/usr/bin/env node

// 수신자-권장사항 속성 매칭 검증 가드
// 용도: 응답의 대상자 속성과 권장사항 적용 조건 일치 여부 검증
// 입력: Claude 응답 JSON { content, recipient_age?, recipient_gender?, recipient_health_status? }
// 반환: { valid: boolean, issues: string[], warnings: string[] }

import { readFileSync } from 'fs';

const input = JSON.parse(readFileSync(0, 'utf-8'));
const { content = '', recipient_age, recipient_gender, recipient_health_status } = input;

const issues = [];
const warnings = [];

// 나이 대상 검증
const agePatterns = {
  '10-20': { regex: /청소년|10대|20대/, min: 10, max: 29 },
  '30-40': { regex: /중년|30대|40대/, min: 30, max: 49 },
  '50+': { regex: /노년|50대|60대|고령/, min: 50, max: 150 },
  '임산부': { regex: /임신|임신부|산모/, min: 18, max: 55, special: 'pregnant' },
  '어린이': { regex: /어린이|유아|아동/, min: 1, max: 12 },
};

if (recipient_age) {
  let matched = false;
  for (const [ageGroup, rule] of Object.entries(agePatterns)) {
    if (rule.regex.test(content)) {
      const age = parseInt(recipient_age);
      if (age < rule.min || age > rule.max) {
        issues.push(`나이 불일치: 응답은 ${ageGroup}(${rule.min}-${rule.max}세) 대상이나 수신자는 ${age}세`);
      }
      matched = true;
      break;
    }
  }
}

// 성별 대상 검증
const genderPatterns = {
  'male': /남성|남자|아버지|형|오빠/,
  'female': /여성|여자|어머니|언니|누나/,
  'pregnancy_related': /임신|산모|유산|유산후|임신테스트|불임/,
};

if (recipient_gender) {
  if (recipient_gender === 'male') {
    if (genderPatterns.pregnancy_related.test(content)) {
      issues.push('성별 불일치: 임신/산모 관련 조언을 남성에게 제공');
    }
  }
}

// 건강 상태 검증
const healthStatePatterns = {
  'diabetes': /당뇨|혈당|인슐린/,
  'hypertension': /고혈압|혈압|혈압약/,
  'kidney_disease': /신장|신부전|신질환/,
  'liver_disease': /간|간질환|간염/,
  'allergy': /알레르기|음식불내증/,
  'pregnancy': /임신|산모|임신부/,
};

if (recipient_health_status) {
  const hasRelevantCondition = Object.entries(healthStatePatterns).some(([condition, regex]) =>
    regex.test(content)
  );
  if (!hasRelevantCondition && /약|복용|용량|섭취|주의|피해야|금지/.test(content)) {
    warnings.push('건강 상태 맥락 부재: 건강 조언이나 약물 관련 내용이 있으나 수신자의 건강 상태가 명확하지 않음');
  }
}

// 절대 권장 금지 조합
const absoluteForbidden = [
  {
    pattern: /어린이.*커피|카페인/i,
    issue: '어린이에게 카페인 섭취 권장 금지',
  },
  {
    pattern: /임신.*약물|진통제|항생제/i,
    issue: '임신 중 특정 약물 자가 처방 금지 (의료 전문가 상담 필수)',
  },
  {
    pattern: /신장질환.*칼륨|나트륨.*고함유/i,
    issue: '신장질환자에게 고칼륨/고나트륨 음식 권장 금지',
  },
];

for (const { pattern, issue } of absoluteForbidden) {
  if (pattern.test(content)) {
    issues.push(issue);
  }
}

// 출력
console.log(
  JSON.stringify(
    {
      valid: issues.length === 0,
      issues_count: issues.length,
      warnings_count: warnings.length,
      issues,
      warnings,
    },
    null,
    2
  )
);
