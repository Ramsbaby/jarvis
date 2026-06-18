#!/usr/bin/env node
/**
 * Sensitive Information Detector Guard
 *
 * Detects and flags potentially sensitive personal information in responses:
 * - Personal identification numbers (주민번호, passport, etc.)
 * - Financial information (card numbers, account numbers, phone numbers, emails)
 * - Health-related sensitive information
 *
 * Returns: { hasSensitiveInfo: boolean, issues: Array<{type, pattern, matches}> }
 */

const SENSITIVE_PATTERNS = {
  // Korean SSN (주민번호) - YYMMDD-NNNNNNN format with validation
  // More accurate: YYMMDD-NNNNNNN where MM is 01-12, DD is 01-31, last digit is 1-4
  koreanSSN: /\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])-[1-4]\d{6}/g,

  // Credit/Debit card patterns (13-19 digits)
  creditCard: /\b(?:\d{4}[-\s]?){3}\d{4}\b/g,

  // Bank account patterns (common formats)
  bankAccount: /\b\d{10,20}\b/g,

  // Korean phone number patterns
  koreanPhone: /(?:010|011|016|017|018|019)-\d{3,4}-\d{4}|\d{2,3}-\d{3,4}-\d{4}/g,

  // Email addresses (general pattern)
  email: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g,

  // Passport-like patterns
  passport: /[A-Z]{2}\d{6,9}/g,

  // Health insurance number patterns
  healthInsurance: /\d{3}-\d{2}-\d{7}/g,

  // Korean driver license pattern
  driverLicense: /\d{2}-\d{2}-\d{6}/g,

  // Social Security Number (US format)
  ssn: /\b\d{3}-\d{2}-\d{4}\b/g,

  // Credit card with extended format (with spaces/dashes)
  creditCardExtended: /\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b/g,

  // Korean name + Korean phone pattern (context-specific PII)
  namePhonePair: /(?:[가-힣]{2,4})\s+(?:(?:010|011|016|017|018|019)-\d{3,4}-\d{4})/g,

  // ABA routing number pattern
  abaRoutingNumber: /\b\d{9}\b/g,

  // IIN/BIN (Bank Identification Number)
  binIin: /\b\d{6}\b(?=[\s\-]?\d{12})/g,

  // IPv4 addresses (context: internal network)
  ipv4: /\b(?:192\.168|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)\d{1,3}\.\d{1,3}\b/g,
};

/**
 * Detect sensitive information in text
 * @param {string} text - Text to analyze
 * @returns {Object} Detection results
 */
export function detectSensitiveInfo(text) {
  if (!text || typeof text !== 'string') {
    return { hasSensitiveInfo: false, issues: [] };
  }

  const issues = [];

  for (const [infoType, pattern] of Object.entries(SENSITIVE_PATTERNS)) {
    const matches = text.match(pattern);
    if (matches && matches.length > 0) {
      issues.push({
        type: infoType,
        pattern: pattern.toString(),
        count: matches.length,
        samples: matches.slice(0, 3), // Show first 3 matches
        severity: getSeverity(infoType),
      });
    }
  }

  return {
    hasSensitiveInfo: issues.length > 0,
    issues,
    detectedAt: new Date().toISOString(),
  };
}

/**
 * Determine severity level based on information type
 * @param {string} infoType - Type of sensitive information
 * @returns {string} Severity level
 */
function getSeverity(infoType) {
  const severityMap = {
    koreanSSN: 'critical',
    creditCard: 'critical',
    creditCardExtended: 'critical',
    ssn: 'critical',
    bankAccount: 'high',
    koreanPhone: 'high',
    healthInsurance: 'high',
    driverLicense: 'high',
    namePhonePair: 'high',
    abaRoutingNumber: 'high',
    binIin: 'high',
    ipv4: 'high',
    email: 'medium',
    passport: 'medium',
  };
  return severityMap[infoType] || 'medium';
}

/**
 * Filter and mask sensitive information
 * @param {string} text - Text to filter
 * @returns {Object} Filtered text and replacement stats
 */
export function maskSensitiveInfo(text) {
  if (!text || typeof text !== 'string') {
    return { filtered: text, replacements: 0 };
  }

  let filtered = text;
  let replacements = 0;

  for (const [infoType, pattern] of Object.entries(SENSITIVE_PATTERNS)) {
    const matches = filtered.match(pattern);
    if (matches) {
      const mask = getMask(infoType);
      filtered = filtered.replace(pattern, mask);
      replacements += matches.length;
    }
  }

  return {
    filtered,
    replacements,
    maskedAt: new Date().toISOString(),
  };
}

/**
 * Get appropriate mask for information type
 * @param {string} infoType - Type of information to mask
 * @returns {string} Mask string
 */
function getMask(infoType) {
  const maskMap = {
    koreanSSN: '[주민번호]',
    creditCard: '[카드번호]',
    creditCardExtended: '[카드번호]',
    ssn: '[SSN]',
    bankAccount: '[계좌번호]',
    koreanPhone: '[휴대폰번호]',
    email: '[이메일]',
    passport: '[여권번호]',
    healthInsurance: '[건강보험번호]',
    driverLicense: '[운전면허번호]',
    namePhonePair: '[성명휴대폰]',
    abaRoutingNumber: '[라우팅번호]',
    binIin: '[카드발급사번호]',
    ipv4: '[내부IP주소]',
  };
  return maskMap[infoType] || '[민감정보]';
}

// CLI usage
if (import.meta.url === `file://${process.argv[1]}`) {
  const text = process.argv[2] || '';
  const command = process.argv[3] || 'detect';

  if (command === 'detect') {
    const result = detectSensitiveInfo(text);
    console.log(JSON.stringify(result, null, 2));
  } else if (command === 'mask') {
    const result = maskSensitiveInfo(text);
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.error('Usage: sensitive-info-detector.mjs <text> [detect|mask]');
    process.exit(1);
  }
}

export default { detectSensitiveInfo, maskSensitiveInfo };
