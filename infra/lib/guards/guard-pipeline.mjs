#!/usr/bin/env node
/**
 * Integrated Guard Pipeline
 *
 * Chains all response guards together for comprehensive validation:
 * 1. Sensitive information detection
 * 2. Audience-recommendation attribute matching
 * 3. Nutrition/dosage validation
 *
 * Returns comprehensive validation report with warnings and auto-corrections
 */

import {
  detectSensitiveInfo,
  maskSensitiveInfo,
} from './sensitive-info-detector.mjs';
import { validateAudienceMatch } from './audience-recommendation-matcher.mjs';
import { validateNutritionDosage } from './nutrition-dosage-validator.mjs';

/**
 * Result severity levels
 */
const SEVERITY_LEVELS = {
  critical: 0,
  high: 1,
  medium: 2,
  low: 3,
  info: 4,
};

/**
 * Run all guards on a response text
 * @param {string} responseText - Response to validate
 * @param {Object} options - Validation options
 * @returns {Object} Comprehensive validation report
 */
export function validateResponse(responseText, options = {}) {
  const {
    autoMask = false,
    throwOnCritical = false,
    audienceAttributes = null,
  } = options;

  if (!responseText || typeof responseText !== 'string') {
    return {
      isValid: true,
      responseLength: 0,
      guards: {
        sensitiveInfo: { hasIssues: false, issues: [] },
        audienceMatch: { isMatched: true, mismatches: [] },
        dosageValidation: { isValid: true, totalIssues: 0 },
      },
      summary: 'Empty or invalid input',
      timestamp: new Date().toISOString(),
    };
  }

  // Run all guards
  const sensitiveInfoResult = detectSensitiveInfo(responseText);
  const audienceMatchResult = validateAudienceMatch(
    responseText,
    audienceAttributes
  );
  const dosageValidationResult = validateNutritionDosage(responseText);

  // Compile issues with severity
  const allIssues = [];

  // Add sensitive info issues
  for (const issue of sensitiveInfoResult.issues) {
    allIssues.push({
      guard: 'sensitive-info',
      type: issue.type,
      severity: issue.severity,
      message: `Detected ${issue.type}: ${issue.count} matches found`,
      details: issue,
    });
  }

  // Add audience mismatch issues
  for (const mismatch of audienceMatchResult.mismatches) {
    allIssues.push({
      guard: 'audience-recommendation',
      type: mismatch.type,
      severity: mismatch.severity,
      message: mismatch.issue,
      details: mismatch,
    });
  }

  // Add dosage validation issues
  for (const issue of dosageValidationResult.absolutePatterns.issues) {
    allIssues.push({
      guard: 'dosage-validation',
      type: 'absolute-dosage-no-unit',
      severity: issue.severity,
      message: `Dosage without unit for ${issue.product}: "${issue.value}"`,
      details: issue,
    });
  }

  for (const issue of dosageValidationResult.formatValidation.issues) {
    allIssues.push({
      guard: 'dosage-validation',
      type: 'missing-unit',
      severity: 'medium',
      message: `Missing unit for value: ${issue.value}`,
      details: issue,
    });
  }

  for (const issue of dosageValidationResult.overGeneralized.issues) {
    allIssues.push({
      guard: 'dosage-validation',
      type: issue.type,
      severity: issue.severity,
      message: issue.message,
      details: issue,
    });
  }

  // Sort issues by severity
  allIssues.sort(
    (a, b) => SEVERITY_LEVELS[a.severity] - SEVERITY_LEVELS[b.severity]
  );

  // Determine overall validity
  const criticalIssues = allIssues.filter((i) => i.severity === 'critical');
  const hasHighSeverityIssues =
    criticalIssues.length > 0 ||
    allIssues.filter((i) => i.severity === 'high').length > 0;

  // Auto-mask sensitive info if requested
  let processedText = responseText;
  let maskingApplied = false;
  if (autoMask && sensitiveInfoResult.hasSensitiveInfo) {
    const maskResult = maskSensitiveInfo(responseText);
    processedText = maskResult.filtered;
    maskingApplied = true;
  }

  if (throwOnCritical && criticalIssues.length > 0) {
    const error = new Error(
      `Validation failed with ${criticalIssues.length} critical issue(s)`
    );
    error.validationReport = {
      isValid: false,
      issues: allIssues,
      processedText,
      maskingApplied,
    };
    throw error;
  }

  return {
    isValid: allIssues.length === 0,
    hasWarnings: allIssues.length > 0,
    hasCriticalIssues: criticalIssues.length > 0,
    responseLength: responseText.length,
    issues: allIssues,
    issueCount: {
      critical: criticalIssues.length,
      high: allIssues.filter((i) => i.severity === 'high').length,
      medium: allIssues.filter((i) => i.severity === 'medium').length,
      low: allIssues.filter((i) => i.severity === 'low').length,
    },
    guards: {
      sensitiveInfo: {
        hasIssues: sensitiveInfoResult.hasSensitiveInfo,
        issues: sensitiveInfoResult.issues.length,
      },
      audienceMatch: {
        isMatched: audienceMatchResult.isMatched,
        issues: audienceMatchResult.mismatches.length,
      },
      dosageValidation: {
        isValid: dosageValidationResult.isValid,
        issues: dosageValidationResult.totalIssues,
      },
    },
    processedText: maskingApplied ? processedText : responseText,
    maskingApplied,
    summary: generateSummary(allIssues),
    recommendations: generateRecommendations(allIssues),
    timestamp: new Date().toISOString(),
  };
}

/**
 * Generate human-readable summary of issues
 * @param {Array} issues - Array of issues
 * @returns {string} Summary text
 */
function generateSummary(issues) {
  if (issues.length === 0) {
    return '✓ Response passed all validation checks';
  }

  const criticalCount = issues.filter((i) => i.severity === 'critical').length;
  const highCount = issues.filter((i) => i.severity === 'high').length;
  const mediumCount = issues.filter((i) => i.severity === 'medium').length;

  let summary = `⚠ ${issues.length} issue(s) detected: `;
  const parts = [];
  if (criticalCount > 0) parts.push(`${criticalCount} critical`);
  if (highCount > 0) parts.push(`${highCount} high`);
  if (mediumCount > 0) parts.push(`${mediumCount} medium`);
  summary += parts.join(', ');

  return summary;
}

/**
 * Generate actionable recommendations
 * @param {Array} issues - Array of issues
 * @returns {Array<string>} Recommendations
 */
function generateRecommendations(issues) {
  const recommendations = new Set();

  for (const issue of issues) {
    if (issue.guard === 'sensitive-info') {
      recommendations.add(
        'Review response for sensitive personal information and mask or remove'
      );
    }
    if (issue.guard === 'audience-recommendation') {
      recommendations.add(
        'Verify recommendations match recipient demographics and health status'
      );
    }
    if (issue.guard === 'dosage-validation') {
      if (
        issue.type === 'absolute-dosage-no-unit' ||
        issue.type === 'missing-unit'
      ) {
        recommendations.add(
          'Add explicit units (mg, g, mcg, capsule, tablet) to all dosage values'
        );
      }
      if (issue.type.includes('_statement')) {
        recommendations.add(
          'Avoid absolute statements; include individual variability caveats'
        );
      }
    }
  }

  return Array.from(recommendations);
}

/**
 * Quick validation check - returns boolean only
 * @param {string} responseText - Response to validate
 * @returns {boolean} True if valid, false otherwise
 */
export function isResponseValid(responseText) {
  const result = validateResponse(responseText);
  return result.isValid;
}

/**
 * Export issues as structured report
 * @param {string} responseText - Response to validate
 * @returns {Object} Structured report for logging
 */
export function generateValidationReport(responseText) {
  const validation = validateResponse(responseText);

  return {
    timestamp: validation.timestamp,
    valid: validation.isValid,
    warnings: validation.hasWarnings,
    critical: validation.hasCriticalIssues,
    issueBreakdown: validation.issueCount,
    issues: validation.issues.map((issue) => ({
      guard: issue.guard,
      type: issue.type,
      severity: issue.severity,
      message: issue.message,
    })),
    recommendations: validation.recommendations,
    responseLength: validation.responseLength,
  };
}

// CLI usage
if (import.meta.url === `file://${process.argv[1]}`) {
  const text = process.argv[2] || '';
  const command = process.argv[3] || 'validate';

  if (command === 'validate') {
    const result = validateResponse(text);
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.isValid ? 0 : 1);
  } else if (command === 'check') {
    const result = isResponseValid(text);
    console.log(result ? 'VALID' : 'INVALID');
    process.exit(result ? 0 : 1);
  } else if (command === 'report') {
    const result = generateValidationReport(text);
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.error('Usage: guard-pipeline.mjs <text> [validate|check|report]');
    process.exit(1);
  }
}

export default { validateResponse, isResponseValid, generateValidationReport };
