#!/usr/bin/env node
/**
 * Nutrition/Dosage Validator Guard
 *
 * Detects and flags absolute value dosage recommendations without units.
 * Prevents misinterpretation of supplement/medication dosages.
 *
 * Returns: { isValid: boolean, issues: Array<{type, pattern, context}> }
 */

/**
 * Nutrition/supplement products that commonly appear in recommendations
 */
const NUTRITION_PRODUCTS = {
  vitaminGeneral: ['비타민', 'vitamin'],  // General vitamin reference
  folicAcid: ['엽산', 'folic acid', 'folate'],
  calcium: ['칼슘', 'calcium'],
  iron: ['철분', 'iron'],
  vitaminD: ['비타민D', 'vitamin d', 'vitamin d3'],
  vitaminB: ['비타민B', 'vitamin b', 'b12', 'b6'],
  magnesium: ['마그네슘', 'magnesium'],
  zinc: ['아연', 'zinc'],
  omega3: ['오메가3', 'omega-3', 'fish oil'],
  probiotics: ['프로바이오틱스', 'probiotics'],
  collagen: ['콜라겐', 'collagen'],
  protein: ['단백질', 'protein'],
  carnitine: ['카르니틴', 'carnitine', 'l-carnitine'],
  supplement: ['영양제', 'supplement', '보충제', '의약품'],
};

/**
 * Common dosage units
 */
const VALID_UNITS = [
  'mg',
  'g',
  'mcg',
  'μg',
  'iu',
  'ml',
  '밀리그램',
  '그램',
  '마이크로그램',
  'microgram',
  'gram',
  'milligram',
  'capsule',
  'tablet',
  'cap',
  'tab',
  '정',
  '캡슐',
  'mmol',
  'unit',
  'iu',
];

/**
 * Common pattern indicators that context is medical/dosage
 */
const DOSAGE_CONTEXT_KEYWORDS = [
  '복용',
  '섭취',
  '추천',
  'recommend',
  'take',
  'consume',
  'dose',
  'dosage',
  '하루',
  '일일',
  '매일',
  'daily',
  'per day',
];

/**
 * Detect absolute value dosage patterns without units
 * @param {string} text - Text to analyze
 * @returns {Object} Detection results
 */
export function detectAbsoluteDosagePatterns(text) {
  if (!text || typeof text !== 'string') {
    return { hasIssues: false, issues: [], products: [] };
  }

  const issues = [];
  const productsFound = new Set();
  const sentences = text.split(/[.!?\n]/);

  for (const sentence of sentences) {
    // Check if sentence contains nutrition-related keywords
    const nutritionMatch = matchNutritionProduct(sentence);
    if (!nutritionMatch) continue;

    productsFound.add(nutritionMatch.product);

    // Check for dosage context indicators
    const hasDosageContext = DOSAGE_CONTEXT_KEYWORDS.some((keyword) =>
      sentence.toLowerCase().includes(keyword.toLowerCase())
    );

    if (!hasDosageContext) continue;

    // Look for numbers without units
    const numberPatterns = sentence.match(/(\d+(?:[,\.]\d+)?)\s*(?=[^a-zA-Z]|$)/g);

    if (!numberPatterns) continue;

    for (const numStr of numberPatterns) {
      const num = numStr.trim().replace(/[,.]/, '');

      // Check if this number is followed by a valid unit
      const nextText = sentence.substring(sentence.indexOf(numStr) + numStr.length);
      const hasValidUnit = VALID_UNITS.some((unit) =>
        new RegExp(`\\s*${unit}\\b`, 'i').test(nextText)
      );

      if (!hasValidUnit && num.length > 0) {
        // Extract surrounding context
        const contextStart = Math.max(0, sentence.indexOf(numStr) - 30);
        const contextEnd = Math.min(
          sentence.length,
          sentence.indexOf(numStr) + numStr.length + 30
        );
        const context = sentence.substring(contextStart, contextEnd).trim();

        issues.push({
          type: 'absolute_dosage_no_unit',
          product: nutritionMatch.product,
          value: num,
          context,
          severity: 'medium',
          recommendedFix:
            'Specify unit (mg, g, mcg, capsule, tablet) explicitly',
        });
      }
    }
  }

  return {
    hasIssues: issues.length > 0,
    issues,
    productsFound: Array.from(productsFound),
    detectedAt: new Date().toISOString(),
  };
}

/**
 * Match nutrition product name in text
 * @param {string} sentence - Sentence to analyze
 * @returns {Object|null} Matched product info or null
 */
function matchNutritionProduct(sentence) {
  for (const [product, keywords] of Object.entries(NUTRITION_PRODUCTS)) {
    for (const keyword of keywords) {
      if (sentence.toLowerCase().includes(keyword.toLowerCase())) {
        return { product, keyword };
      }
    }
  }
  return null;
}

/**
 * Validate dosage format consistency
 * @param {string} text - Text to validate
 * @returns {Object} Validation results
 */
export function validateDosageFormat(text) {
  if (!text || typeof text !== 'string') {
    return { isValid: true, issues: [], suggestions: [] };
  }

  const issues = [];
  const suggestions = [];

  // Pattern 1: Find numbers that look like dosages
  const dosageNumberPattern = /(\d+(?:[,\.]\d+)?)\s*(?:(mg|g|mcg|μg|iu|ml|정|캡슐|tablet|capsule|tab|cap))?/gi;
  const matches = [...text.matchAll(dosageNumberPattern)];

  for (const match of matches) {
    const value = match[1];
    const unit = match[2];

    if (!unit || unit.trim() === '') {
      // Check if this looks like a dosage context
      const surroundingText = text.substring(
        Math.max(0, match.index - 50),
        Math.min(text.length, match.index + match[0].length + 50)
      );

      if (
        DOSAGE_CONTEXT_KEYWORDS.some((kw) =>
          surroundingText.toLowerCase().includes(kw.toLowerCase())
        )
      ) {
        issues.push({
          type: 'missing_unit',
          value,
          position: match.index,
          context: surroundingText.trim(),
        });

        suggestions.push({
          original: match[0],
          suggested: `${value} mg`,
          note: 'Please specify the appropriate unit for this dosage',
        });
      }
    }
  }

  return {
    isValid: issues.length === 0,
    issues,
    suggestions,
    validatedAt: new Date().toISOString(),
  };
}

/**
 * Check for over-generalized absolute statements
 * @param {string} text - Text to analyze
 * @returns {Object} Detection results
 */
export function detectOverGeneralizedStatements(text) {
  if (!text || typeof text !== 'string') {
    return { hasIssues: false, issues: [] };
  }

  const issues = [];

  // Patterns like "everyone should take X", "you must take X"
  const overGeneralPatterns = [
    {
      pattern: /everyone\s+should\s+take\s+(\d+)/gi,
      type: 'over_generalized_everyone',
      message: 'Recommendation applies to "everyone" - should be conditional',
    },
    {
      pattern: /must\s+take\s+(\d+)/gi,
      type: 'absolute_must_statement',
      message: 'Absolute "must" statement - should include individual variability',
    },
    {
      pattern: /always\s+consume\s+(\d+)/gi,
      type: 'absolute_always_statement',
      message: 'Absolute "always" statement - should mention exceptions',
    },
  ];

  for (const { pattern, type, message } of overGeneralPatterns) {
    const matches = text.matchAll(pattern);
    for (const match of matches) {
      issues.push({
        type,
        value: match[1],
        context: text.substring(
          Math.max(0, match.index - 30),
          Math.min(text.length, match.index + match[0].length + 30)
        ),
        severity: 'medium',
        message,
      });
    }
  }

  return {
    hasIssues: issues.length > 0,
    issues,
    detectedAt: new Date().toISOString(),
  };
}

/**
 * Comprehensive validation of nutrition/dosage section
 * @param {string} text - Response text to validate
 * @returns {Object} Complete validation results
 */
export function validateNutritionDosage(text) {
  if (!text || typeof text !== 'string') {
    return {
      isValid: true,
      absolutePatterns: { hasIssues: false, issues: [] },
      formatValidation: { isValid: true, issues: [], suggestions: [] },
      overGeneralized: { hasIssues: false, issues: [] },
      summary: 'No issues detected',
    };
  }

  const absolutePatterns = detectAbsoluteDosagePatterns(text);
  const formatValidation = validateDosageFormat(text);
  const overGeneralized = detectOverGeneralizedStatements(text);

  const totalIssues =
    absolutePatterns.issues.length +
    formatValidation.issues.length +
    overGeneralized.issues.length;

  return {
    isValid: totalIssues === 0,
    absolutePatterns,
    formatValidation,
    overGeneralized,
    totalIssues,
    validatedAt: new Date().toISOString(),
  };
}

// CLI usage
if (import.meta.url === `file://${process.argv[1]}`) {
  const text = process.argv[2] || '';
  const command = process.argv[3] || 'validate';

  if (command === 'validate') {
    const result = validateNutritionDosage(text);
    console.log(JSON.stringify(result, null, 2));
  } else if (command === 'detect') {
    const result = detectAbsoluteDosagePatterns(text);
    console.log(JSON.stringify(result, null, 2));
  } else if (command === 'format') {
    const result = validateDosageFormat(text);
    console.log(JSON.stringify(result, null, 2));
  } else if (command === 'generalize') {
    const result = detectOverGeneralizedStatements(text);
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.error(
      'Usage: nutrition-dosage-validator.mjs <text> [validate|detect|format|generalize]'
    );
    process.exit(1);
  }
}

export default { validateNutritionDosage, detectAbsoluteDosagePatterns, validateDosageFormat };
