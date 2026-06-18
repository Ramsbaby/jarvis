#!/usr/bin/env node

/**
 * guard-recipient-matcher.mjs
 *
 * 수신자 속성과 권장사항의 적용 대상이 일치하는지 검증
 * - 수신자: 연령대, 성별, 건강상태, 상황
 * - 권장사항: 이 조건을 만족하는 누구를 위한 것인가?
 *
 * 입력: JSON {text: string, context: {userId, recipientProfile}}
 * 출력: JSON {matched: boolean, mismatches: [], severity: "critical"|"warning"|"none"}
 */

/**
 * Recipient attribute extraction patterns
 */
const RECIPIENT_PATTERNS = {
  age: {
    pattern: /(?:영아|어린이|아동|소아|청소년|20대|30대|40대|50대|60대|노인|고령자|나이|세|살|age)/gi,
    categories: {
      infant: ['영아', '0~1세', '12개월'],
      toddler: ['유아', '1~3세', '영유아'],
      child: ['어린이', '아동', '소아', '3~12세', '초등학생'],
      teen: ['청소년', '10대', '13~19세'],
      youngAdult: ['20대', '청년'],
      midAdult: ['30대', '40대', '중년'],
      senior: ['50대', '60대', '70대', '노인', '고령자', '백세인']
    }
  },

  gender: {
    pattern: /(?:남성|여성|남자|여자|임산부|임신부|수유부|mother|father)/gi,
    categories: {
      male: ['남성', '남자', 'male'],
      female: ['여성', '여자', 'female'],
      pregnant: ['임산부', '임신부', '임신 중'],
      nursing: ['수유부', '모유수유'],
      postpartum: ['산후', '출산 후']
    }
  },

  healthCondition: {
    pattern: /(?:당뇨|고혈압|심장|신장|간|폐|암|알레르기|천식|불내증|부작용|약물민감|저혈당|고혈당)/gi,
    categories: {
      diabetes: ['당뇨', '당뇨병', '혈당'],
      hypertension: ['고혈압', '혈압'],
      cardiac: ['심장', '심장병', '관상동맥'],
      renal: ['신장', '신부전', '신장병'],
      hepatic: ['간', '간경변', '간염'],
      respiratory: ['폐', '천식', '폐렴'],
      cancer: ['암', '종양'],
      allergy: ['알레르기', '알러지', '부작용'],
      gastrointestinal: ['위', '장', '소화', '불내증', 'IBS'],
      immunocompromised: ['면역', '면역저하', '에이즈'],
      pregnant: ['임신', '임산']
    }
  },

  situation: {
    pattern: /(?:다이어트|운동|피로|스트레스|수면|회복|재활|예방|건강검진|체중감량)/gi,
    categories: {
      weightManagement: ['다이어트', '체중감량', '비만'],
      exercise: ['운동', '피트니스', '근력'],
      fatigue: ['피로', '무기력'],
      stress: ['스트레스', '불안', '우울'],
      sleep: ['수면', '불면증'],
      recovery: ['회복', '재활'],
      prevention: ['예방', '예방적'],
      checkup: ['검진', '건강검진']
    }
  }
};

/**
 * Recommendation requirement patterns
 */
const RECOMMENDATION_REQUIREMENTS = {
  infantOnly: {
    pattern: /(?:영아용|신생아용|0~1세|12개월 이하)\s+(?:권장|필수|추천)/gi,
    targets: ['infant'],
    blockOthers: true
  },

  childrenOnly: {
    pattern: /(?:아동용|소아용|어린이용|3~12세)\s+(?:권장|필수|추천)/gi,
    targets: ['child', 'toddler'],
    blockOthers: true
  },

  adultOnly: {
    pattern: /(?:성인용|18세 이상)\s+(?:권장|필수|추천)/gi,
    targets: ['youngAdult', 'midAdult', 'senior'],
    blockOthers: true
  },

  seniorOnly: {
    pattern: /(?:노인용|60세 이상|고령자)\s+(?:권장|필수|추천)/gi,
    targets: ['senior'],
    blockOthers: true
  },

  femaleOnly: {
    pattern: /(?:여성용|여성만|산모용|수유부)\s+(?:권장|필수|추천)/gi,
    targets: ['female', 'pregnant', 'nursing'],
    blockOthers: true
  },

  maleOnly: {
    pattern: /(?:남성용|남성만)\s+(?:권장|필수|추천)/gi,
    targets: ['male'],
    blockOthers: true
  },

  pregnantOnly: {
    pattern: /(?:임산부|임신 중)\s+(?:권장|필수|추천|피해야|금지|절대 금지)/gi,
    targets: ['pregnant'],
    blockOthers: true
  }
};

/**
 * Extract recipient profile from text
 */
function extractRecipientProfile(text) {
  const profile = {
    ages: [],
    genders: [],
    healthConditions: [],
    situations: []
  };

  // Extract ages
  const ageMatches = text.match(RECIPIENT_PATTERNS.age.pattern) || [];
  ageMatches.forEach(match => {
    for (const [cat, terms] of Object.entries(RECIPIENT_PATTERNS.age.categories)) {
      if (terms.some(t => match.toLowerCase().includes(t.toLowerCase()))) {
        profile.ages.push(cat);
      }
    }
  });

  // Extract genders
  const genderMatches = text.match(RECIPIENT_PATTERNS.gender.pattern) || [];
  genderMatches.forEach(match => {
    for (const [cat, terms] of Object.entries(RECIPIENT_PATTERNS.gender.categories)) {
      if (terms.some(t => match.toLowerCase().includes(t.toLowerCase()))) {
        profile.genders.push(cat);
      }
    }
  });

  // Extract health conditions
  const healthMatches = text.match(RECIPIENT_PATTERNS.healthCondition.pattern) || [];
  healthMatches.forEach(match => {
    for (const [cat, terms] of Object.entries(RECIPIENT_PATTERNS.healthCondition.categories)) {
      if (terms.some(t => match.toLowerCase().includes(t.toLowerCase()))) {
        profile.healthConditions.push(cat);
      }
    }
  });

  // Extract situations
  const situationMatches = text.match(RECIPIENT_PATTERNS.situation.pattern) || [];
  situationMatches.forEach(match => {
    for (const [cat, terms] of Object.entries(RECIPIENT_PATTERNS.situation.categories)) {
      if (terms.some(t => match.toLowerCase().includes(t.toLowerCase()))) {
        profile.situations.push(cat);
      }
    }
  });

  // Deduplicate
  profile.ages = [...new Set(profile.ages)];
  profile.genders = [...new Set(profile.genders)];
  profile.healthConditions = [...new Set(profile.healthConditions)];
  profile.situations = [...new Set(profile.situations)];

  return profile;
}

/**
 * Validate recommendation matching
 */
function validateRecommendationMatching(text, recipientProfile) {
  const mismatches = [];

  for (const [key, req] of Object.entries(RECOMMENDATION_REQUIREMENTS)) {
    const matches = text.match(req.pattern);
    if (!matches) continue;

    // Check if recipient profile matches the requirement
    const targetsMatch = req.targets.some(target =>
      (recipientProfile.ages.includes(target) ||
       recipientProfile.genders.includes(target) ||
       recipientProfile.healthConditions.includes(target))
    );

    if (!targetsMatch && req.blockOthers) {
      mismatches.push({
        requirement: key,
        targets: req.targets,
        issue: `권장 대상(${req.targets.join(', ')})이 명시되었으나 수신자 속성과 불일치`,
        severity: 'warning'
      });
    }
  }

  return mismatches;
}

/**
 * Main validation function
 */
function analyzeRecipientMatching(text, context = {}) {
  if (!text || typeof text !== 'string') {
    return {
      matched: true,
      mismatches: [],
      severity: 'none'
    };
  }

  const recipientProfile = extractRecipientProfile(text);
  const mismatches = validateRecommendationMatching(text, recipientProfile);

  const hasMismatch = mismatches.length > 0;

  return {
    matched: !hasMismatch,
    recipientProfile: recipientProfile,
    mismatches: mismatches,
    severity: hasMismatch ? 'warning' : 'none'
  };
}

/**
 * Main entry point
 */
const input = JSON.parse(process.argv[2] || '{}');
const result = analyzeRecipientMatching(input.text, input.context);
console.log(JSON.stringify(result, null, 2));
