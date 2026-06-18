#!/usr/bin/env node

/**
 * guard-response-validator.mjs
 *
 * 통합 응답 검증 파이프라인
 * 세 가지 가드를 체이닝하여 응답의 안전성을 검증:
 * 1. 민감 정보 탐지 (guard-sensitive-detector.mjs)
 * 2. 수신자-권장사항 매칭 (guard-recipient-matcher.mjs)
 * 3. 의약품/영양제 절대값 (guard-dosage-detector.mjs)
 *
 * 입력: JSON {text: string, context: {userId, channelId, recipientProfile}}
 * 출력: JSON {
 *   passed: boolean,
 *   filters: {sensitive, recipient, dosage},
 *   severity: "critical"|"warning"|"none",
 *   recommendations: [],
 *   action: "PASS"|"WARN"|"BLOCK_AND_REGENERATE"
 * }
 */

// Import guard modules
const path = require('path');
const sensitiveModule = require('./guard-sensitive-detector.mjs');
const recipientModule = require('./guard-recipient-matcher.mjs');
const dosageModule = require('./guard-dosage-detector.mjs');

const { analyzeSensitiveData } = sensitiveModule;
const { analyzeRecipientMatching } = recipientModule;
const { analyzeDosageExpression } = dosageModule;

/**
 * Run all guards in sequence and aggregate results
 */
async function validateResponse(text, context = {}) {
  if (!text || typeof text !== 'string') {
    return {
      passed: true,
      filters: {},
      severity: 'none',
      recommendations: [],
      action: 'PASS'
    };
  }

  const results = {
    text: text,
    context: context,
    filters: {},
    allPassed: true,
    criticalIssues: [],
    warnings: [],
    recommendations: []
  };

  // Guard 1: Sensitive Information
  const sensitiveResult = analyzeSensitiveData(text, context);
  results.filters.sensitive = sensitiveResult;

  if (sensitiveResult.detected) {
    results.allPassed = false;
    if (sensitiveResult.severity === 'critical') {
      results.criticalIssues.push({
        guard: '민감정보탐지',
        issues: sensitiveResult.issues,
        recommendation: sensitiveResult.recommendation
      });
    } else {
      results.warnings.push({
        guard: '민감정보탐지',
        issues: sensitiveResult.issues,
        recommendation: sensitiveResult.recommendation
      });
    }
  }

  // Guard 2: Recipient-Recommendation Matching
  const recipientResult = analyzeRecipientMatching(text, context);
  results.filters.recipient = recipientResult;

  if (!recipientResult.matched) {
    results.allPassed = false;
    if (recipientResult.severity === 'critical') {
      results.criticalIssues.push({
        guard: '수신자매칭검증',
        mismatches: recipientResult.mismatches,
        recommendation: recipientResult.recommendation
      });
    } else {
      results.warnings.push({
        guard: '수신자매칭검증',
        mismatches: recipientResult.mismatches,
        recommendation: recipientResult.recommendation
      });
    }
  }

  // Guard 3: Dosage Expression
  const dosageResult = analyzeDosageExpression(text, context);
  results.filters.dosage = dosageResult;

  if (dosageResult.hasAbsoluteValues) {
    results.allPassed = false;
    if (dosageResult.severity === 'critical') {
      results.criticalIssues.push({
        guard: '절대값표현탐지',
        issues: dosageResult.issues,
        recommendation: dosageResult.recommendation
      });
    } else {
      results.warnings.push({
        guard: '절대값표현탐지',
        issues: dosageResult.issues,
        recommendation: dosageResult.recommendation
      });
    }
  }

  // Determine overall severity and action
  const hasCritical = results.criticalIssues.length > 0;
  const hasWarning = results.warnings.length > 0;

  const severity = hasCritical ? 'critical' : hasWarning ? 'warning' : 'none';
  const action = hasCritical ? 'BLOCK_AND_REGENERATE' : hasWarning ? 'WARN' : 'PASS';

  return {
    passed: results.allPassed,
    severity: severity,
    action: action,
    filters: results.filters,
    criticalIssues: results.criticalIssues,
    warnings: results.warnings,
    summary: {
      totalIssues: results.criticalIssues.length + results.warnings.length,
      criticalCount: results.criticalIssues.length,
      warningCount: results.warnings.length
    }
  };
}

/**
 * Format results for logging/reporting
 */
function formatValidationReport(validationResult) {
  const lines = [];
  lines.push(`검증 결과: ${validationResult.action}`);
  lines.push(`심각도: ${validationResult.severity}`);
  lines.push(`문제 수: ${validationResult.summary.totalIssues} (치명 ${validationResult.summary.criticalCount}, 경고 ${validationResult.summary.warningCount})`);

  if (validationResult.criticalIssues.length > 0) {
    lines.push('\n[치명적 문제]');
    validationResult.criticalIssues.forEach(issue => {
      lines.push(`  - ${issue.guard}`);
      if (issue.recommendation) {
        lines.push(`    권장: ${issue.recommendation.action}`);
      }
    });
  }

  if (validationResult.warnings.length > 0) {
    lines.push('\n[경고]');
    validationResult.warnings.forEach(warning => {
      lines.push(`  - ${warning.guard}`);
      if (warning.recommendation) {
        lines.push(`    권장: ${warning.recommendation.action}`);
      }
    });
  }

  return lines.join('\n');
}

/**
 * CLI interface
 */
async function main() {
  try {
    const input = JSON.parse(process.argv[2] || '{}');
    const result = await validateResponse(input.text, input.context);

    // Output in structured format for task runner integration
    console.log(JSON.stringify(result, null, 2));

    // Exit code based on validation result
    process.exit(result.passed ? 0 : 1);
  } catch (err) {
    console.error(JSON.stringify({
      error: err.message,
      stack: err.stack
    }, null, 2));
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}

export { validateResponse, formatValidationReport };
