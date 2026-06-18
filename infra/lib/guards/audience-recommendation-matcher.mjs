#!/usr/bin/env node
/**
 * Audience-Recommendation Matcher Guard
 *
 * Validates that health/nutritional recommendations match the recipient's attributes:
 * - Age compatibility (pregnancy recommendations only for eligible age groups)
 * - Gender specificity
 * - Health condition applicability
 *
 * Returns: { isMatched: boolean, mismatches: Array<{issue, severity}> }
 */

/**
 * Define audience conditions for common recommendation types
 */
const RECOMMENDATION_CONDITIONS = {
  pregnancy: {
    applicableAgeRange: [15, 50],
    applicableGender: ['female', 'pregnant_person'],
    keywords: [
      '임신',
      'pregnant',
      '출산',
      '산후',
      '태아',
      'fetal',
      '엽산',
      'folic acid',
    ],
  },
  postpartum: {
    applicableAgeRange: [15, 60],
    applicableGender: ['female', 'pregnant_person', 'postpartum_person'],
    keywords: ['산후', 'postpartum', '수유', 'breastfeeding', '모유'],
  },
  menopause: {
    applicableAgeRange: [40, 70],
    applicableGender: ['female'],
    keywords: ['폐경', 'menopause', '갱년기', 'perimenopause'],
  },
  prostate: {
    applicableAgeRange: [40, 100],
    applicableGender: ['male'],
    keywords: ['전립선', 'prostate', 'PSA'],
  },
  pediatric: {
    applicableAgeRange: [0, 18],
    applicableGender: ['all'],
    keywords: ['영아', 'infant', '아이', 'child', '어린이', 'kids'],
  },
  elderly: {
    applicableAgeRange: [65, 150],
    applicableGender: ['all'],
    keywords: ['노인', 'elderly', '고령', 'senior', '나이가 많은'],
  },
};

/**
 * Extract audience attributes from response text
 * @param {string} text - Response text to analyze
 * @returns {Object} Extracted attributes
 */
export function extractAudienceAttributes(text) {
  if (!text || typeof text !== 'string') {
    return { age: null, gender: null, healthConditions: [], confidence: 0 };
  }

  const attributes = {
    age: extractAge(text),
    gender: extractGender(text),
    healthConditions: extractHealthConditions(text),
    confidence: 0,
  };

  // Calculate confidence score
  let confidencePoints = 0;
  if (attributes.age !== null) confidencePoints += 40;
  if (attributes.gender) confidencePoints += 30;
  if (attributes.healthConditions.length > 0) confidencePoints += 30;
  attributes.confidence = Math.min(100, confidencePoints);

  return attributes;
}

/**
 * Extract age information from text
 * @param {string} text - Text to analyze
 * @returns {number|null} Extracted age or null
 */
function extractAge(text) {
  // Look for explicit age mentions
  const agePatterns = [
    /(\d{1,2})\s*(?:세|살|years old|year-old|yo|개월)/,
    /age[:\s]+(\d{1,2})/i,
    /(\d{1,2})\s*대(?:초|중|후)?/,
  ];

  for (const pattern of agePatterns) {
    const match = text.match(pattern);
    if (match) {
      const age = parseInt(match[1], 10);
      if (age >= 0 && age <= 150) {
        return age;
      }
    }
  }

  return null;
}

/**
 * Extract gender information from text
 * @param {string} text - Text to analyze
 * @returns {string|null} Extracted gender or null
 */
function extractGender(text) {
  const genderPatterns = {
    female: [
      '여성',
      'female',
      '여자',
      '임산부',
      'pregnant woman',
      '산모',
      'mother',
    ],
    male: ['남성', 'male', '남자', 'man'],
  };

  for (const [gender, keywords] of Object.entries(genderPatterns)) {
    for (const keyword of keywords) {
      if (text.toLowerCase().includes(keyword.toLowerCase())) {
        return gender;
      }
    }
  }

  return null;
}

/**
 * Extract health conditions from text
 * @param {string} text - Text to analyze
 * @returns {Array<string>} List of detected health conditions
 */
function extractHealthConditions(text) {
  const conditions = [];
  const healthKeywords = {
    diabetes: ['당뇨', 'diabetes'],
    hypertension: ['고혈압', 'hypertension', '혈압'],
    pregnancy: ['임신', 'pregnant'],
    breastfeeding: ['수유', 'breastfeeding'],
    allergy: ['알레르기', 'allergy'],
    cardiovascular: ['심장', 'cardiac', 'cardiovascular'],
  };

  for (const [condition, keywords] of Object.entries(healthKeywords)) {
    for (const keyword of keywords) {
      if (text.toLowerCase().includes(keyword.toLowerCase())) {
        conditions.push(condition);
        break;
      }
    }
  }

  return conditions;
}

/**
 * Detect recommendation types in response
 * @param {string} text - Response text to analyze
 * @returns {Array<string>} List of detected recommendation types
 */
export function detectRecommendationTypes(text) {
  const types = [];

  for (const [type, conditions] of Object.entries(RECOMMENDATION_CONDITIONS)) {
    for (const keyword of conditions.keywords) {
      if (text.toLowerCase().includes(keyword.toLowerCase())) {
        types.push(type);
        break;
      }
    }
  }

  return types;
}

/**
 * Validate audience-recommendation match
 * @param {string} responseText - Full response text
 * @param {Object} audienceAttributes - Optional pre-extracted attributes
 * @returns {Object} Validation results with mismatches
 */
export function validateAudienceMatch(responseText, audienceAttributes = null) {
  if (!responseText || typeof responseText !== 'string') {
    return { isMatched: true, mismatches: [], recommendations: [] };
  }

  const attributes =
    audienceAttributes || extractAudienceAttributes(responseText);
  const recommendationTypes = detectRecommendationTypes(responseText);
  const mismatches = [];

  for (const recType of recommendationTypes) {
    const conditions = RECOMMENDATION_CONDITIONS[recType];
    if (!conditions) continue;

    // Check age compatibility
    if (attributes.age !== null) {
      const [minAge, maxAge] = conditions.applicableAgeRange;
      if (attributes.age < minAge || attributes.age > maxAge) {
        mismatches.push({
          type: 'age_mismatch',
          recommendation: recType,
          issue: `Recommendation "${recType}" is for ages ${minAge}-${maxAge}, but recipient is ${attributes.age}`,
          severity: 'high',
          receiverAge: attributes.age,
          applicableRange: [minAge, maxAge],
        });
      }
    }

    // Check gender compatibility
    if (
      attributes.gender &&
      !conditions.applicableGender.includes('all')
    ) {
      if (!conditions.applicableGender.includes(attributes.gender)) {
        mismatches.push({
          type: 'gender_mismatch',
          recommendation: recType,
          issue: `Recommendation "${recType}" is for ${conditions.applicableGender.join('/')}, but recipient is ${attributes.gender}`,
          severity: 'high',
          receiverGender: attributes.gender,
          applicableGenders: conditions.applicableGender,
        });
      }
    }
  }

  return {
    isMatched: mismatches.length === 0,
    mismatches,
    audience: attributes,
    recommendations: recommendationTypes,
    validatedAt: new Date().toISOString(),
  };
}

// CLI usage
if (import.meta.url === `file://${process.argv[1]}`) {
  const text = process.argv[2] || '';
  const command = process.argv[3] || 'validate';

  if (command === 'validate') {
    const result = validateAudienceMatch(text);
    console.log(JSON.stringify(result, null, 2));
  } else if (command === 'extract') {
    const result = extractAudienceAttributes(text);
    console.log(JSON.stringify(result, null, 2));
  } else if (command === 'detect') {
    const result = detectRecommendationTypes(text);
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.error(
      'Usage: audience-recommendation-matcher.mjs <text> [validate|extract|detect]'
    );
    process.exit(1);
  }
}

export default { validateAudienceMatch, extractAudienceAttributes, detectRecommendationTypes };
