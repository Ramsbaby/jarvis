#!/usr/bin/env node
/**
 * Cluster-Specific Guard for cl-fd25ae4c34818568
 *
 * Targets the 4 recurrence patterns detected in this cluster (7-day window):
 * 1. Sensitive info despite explicit context → auto-mask + rewrite
 * 2. Recipient attribute mismatch → validation + block
 * 3. Supplement dosage as absolute value → detection + warning
 * 4. Misclassification of owner across products → cross-check
 *
 * Integration: Run AFTER guard-pipeline.mjs validation
 * Behavior: Non-blocking for medium/low severity, critical → await rewrite
 */

import fs from 'fs';
import path from 'path';

/**
 * Cluster-specific recurrence patterns
 */
const CLUSTER_PATTERNS = {
  clusterId: 'cl-fd25ae4c34818568',
  description: 'Health/nutrition recommendation misclassification and PII leakage',
  recurrenceWindow: 7, // days
  maxRecurrenceInWindow: 4, // trigger if 4+ occurrences
  severity: 'structural',
};

/**
 * Pattern 1: PII despite context (명시적 용도 후에도 민감 정보 포함)
 */
const PII_DESPITE_CONTEXT_PATTERN = {
  id: 'pii-despite-context',
  description: 'Sensitive info included despite explicit purpose statement',
  triggers: [
    {
      regex: /이것은\s+(?:정보|조언|설명).*?(?:주민번호|카드번호|계좌번호|휴대폰)/is,
      weight: 1.0,
      message: 'PII found immediately after context statement',
    },
    {
      regex: /용도[:\s]+[^.]{0,100}(?:주민번호|주민등록|생년월일)/is,
      weight: 0.9,
      message: 'Birthdate or ID info appears near purpose declaration',
    },
  ],
  action: 'AUTO_MASK_AND_REWRITE',
  severity: 'critical',
};

/**
 * Pattern 2: Mismatched recipient attributes (여러 상품 분석 시 소유자 오분류)
 */
const RECIPIENT_MISMATCH_PATTERN = {
  id: 'recipient-mismatch',
  description: 'Recommendations applied to wrong recipient category',
  triggers: [
    {
      regex: /임신\s+.*?(?:영양제|약|복용).*?(?:임신|준비|관계자|권장)/is,
      weight: 1.0,
      message: 'Pregnancy recommendation applied to non-pregnant recipient',
    },
    {
      regex: /(?:아이|어린이|유아).*?(?:카페인|알코올|흡연)/is,
      weight: 1.0,
      message: 'Adult supplement applied to child',
    },
    {
      regex: /여러\s+(?:제품|상품).*?(?:분석|비교).*?소유자.*?오분류/is,
      weight: 0.95,
      message: 'Owner misclassification across multiple products',
    },
  ],
  action: 'VALIDATE_AND_BLOCK_IF_SEVERE',
  severity: 'high',
};

/**
 * Pattern 3: Absolute dosage values (제품명 명시 없이 영양제 복용량 절대값 표현)
 */
const ABSOLUTE_DOSAGE_PATTERN = {
  id: 'absolute-dosage',
  description: 'Supplement dosage expressed as absolute value without unit',
  triggers: [
    {
      regex: /(?:영양제|보충제|비타민|칼슘|철분).*?(?:복용|섭취|추천).*?(\d+)(?!\s*(?:mg|g|mcg|정|캡슐|ml|tab|tab))/is,
      weight: 1.0,
      message: 'Dosage value without explicit unit',
    },
    {
      regex: /하루\s*(\d+)\s*복용.*?(?!mg|g|mcg|정|캡슐)(?=[.!?\n]|$)/is,
      weight: 0.9,
      message: 'Daily intake specified without unit',
    },
    {
      regex: /절대적으로\s+(\d+)/is,
      weight: 0.95,
      message: 'Absolute expression of numeric value (반드시, 꼭, 무조건)',
    },
  ],
  action: 'WARN_AND_SUGGEST_REWRITE',
  severity: 'medium',
};

/**
 * Pattern 4: Multi-product owner confusion (여러 상품 분석 시 소유자 대상 오분류)
 */
const MULTI_PRODUCT_OWNER_CONFUSION = {
  id: 'multi-product-owner',
  description: 'Owner misclassification when analyzing multiple products',
  triggers: [
    {
      // Detect when multiple products are mentioned but owner attributes conflict
      regex: /(?:이[가]?|한국의|일본의)?\s*(?:A|B|C|제1|첫\s*번째|상품|제품)\s*[:\(].*?(?:적합|권장|용도)/is,
      weight: 0.8,
      message: 'Product analysis with potentially confused recipient',
    },
    {
      // Multi-product context without clear recipient delineation
      regex: /(?:비교|분석|추천).*?(?:상품|제품).*?(?:1번|2번|3번|다른).*?(?:대상|용도|누구)/is,
      weight: 0.85,
      message: 'Multi-product recommendation lacks clear recipient boundaries',
    },
  ],
  action: 'VALIDATE_RECIPIENT_MAPPING',
  severity: 'high',
};

/**
 * Detect cluster-specific patterns in response
 * @param {string} responseText - Response to analyze
 * @returns {Object} Detection results with severity scoring
 */
export function detectClusterPatterns(responseText) {
  if (!responseText || typeof responseText !== 'string') {
    return {
      clusterId: CLUSTER_PATTERNS.clusterId,
      detected: false,
      patterns: [],
      score: 0,
      recommendations: [],
    };
  }

  const detections = [];
  let totalScore = 0;

  // Check Pattern 1: PII despite context
  for (const trigger of PII_DESPITE_CONTEXT_PATTERN.triggers) {
    if (trigger.regex.test(responseText)) {
      detections.push({
        pattern: PII_DESPITE_CONTEXT_PATTERN.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: PII_DESPITE_CONTEXT_PATTERN.severity,
        action: PII_DESPITE_CONTEXT_PATTERN.action,
      });
      totalScore += trigger.weight;
    }
  }

  // Check Pattern 2: Recipient mismatch
  for (const trigger of RECIPIENT_MISMATCH_PATTERN.triggers) {
    if (trigger.regex.test(responseText)) {
      detections.push({
        pattern: RECIPIENT_MISMATCH_PATTERN.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: RECIPIENT_MISMATCH_PATTERN.severity,
        action: RECIPIENT_MISMATCH_PATTERN.action,
      });
      totalScore += trigger.weight;
    }
  }

  // Check Pattern 3: Absolute dosage
  for (const trigger of ABSOLUTE_DOSAGE_PATTERN.triggers) {
    if (trigger.regex.test(responseText)) {
      detections.push({
        pattern: ABSOLUTE_DOSAGE_PATTERN.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: ABSOLUTE_DOSAGE_PATTERN.severity,
        action: ABSOLUTE_DOSAGE_PATTERN.action,
      });
      totalScore += trigger.weight;
    }
  }

  // Check Pattern 4: Multi-product owner confusion
  for (const trigger of MULTI_PRODUCT_OWNER_CONFUSION.triggers) {
    if (trigger.regex.test(responseText)) {
      detections.push({
        pattern: MULTI_PRODUCT_OWNER_CONFUSION.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: MULTI_PRODUCT_OWNER_CONFUSION.severity,
        action: MULTI_PRODUCT_OWNER_CONFUSION.action,
      });
      totalScore += trigger.weight;
    }
  }

  // Normalize score to 0-10
  const normalizedScore = Math.min(10, (totalScore / 4) * 10);

  return {
    clusterId: CLUSTER_PATTERNS.clusterId,
    detected: detections.length > 0,
    patterns: detections,
    score: normalizedScore,
    triggerCount: detections.length,
    hasCritical: detections.some((d) => d.severity === 'critical'),
    hasHigh: detections.some((d) => d.severity === 'high'),
    detectedAt: new Date().toISOString(),
  };
}

/**
 * Generate remediation recommendations
 * @param {Object} detection - Detection result from detectClusterPatterns
 * @returns {Object} Remediation plan
 */
export function generateRemediationPlan(detection) {
  const remediations = [];

  if (!detection.detected) {
    return {
      required: false,
      remediations: [],
      actions: [],
    };
  }

  // Group by action type
  const byAction = {};
  for (const pattern of detection.patterns) {
    if (!byAction[pattern.action]) {
      byAction[pattern.action] = [];
    }
    byAction[pattern.action].push(pattern);
  }

  const actions = [];

  if (byAction['AUTO_MASK_AND_REWRITE']) {
    actions.push({
      type: 'AUTO_MASK_AND_REWRITE',
      priority: 'critical',
      count: byAction['AUTO_MASK_AND_REWRITE'].length,
      instruction:
        'Automatically mask PII patterns and rewrite response to remove sensitive information',
    });
  }

  if (byAction['VALIDATE_AND_BLOCK_IF_SEVERE']) {
    actions.push({
      type: 'VALIDATE_AND_BLOCK_IF_SEVERE',
      priority: 'high',
      count: byAction['VALIDATE_AND_BLOCK_IF_SEVERE'].length,
      instruction:
        'Validate recipient attributes; block response if severe mismatches detected',
    });
  }

  if (byAction['WARN_AND_SUGGEST_REWRITE']) {
    actions.push({
      type: 'WARN_AND_SUGGEST_REWRITE',
      priority: 'medium',
      count: byAction['WARN_AND_SUGGEST_REWRITE'].length,
      instruction: 'Flag issues with dosage format and suggest units/rewrite',
    });
  }

  if (byAction['VALIDATE_RECIPIENT_MAPPING']) {
    actions.push({
      type: 'VALIDATE_RECIPIENT_MAPPING',
      priority: 'high',
      count: byAction['VALIDATE_RECIPIENT_MAPPING'].length,
      instruction:
        'Verify that recipient-to-product mapping is accurate across all recommendations',
    });
  }

  return {
    required: detection.hasCritical || detection.hasHigh,
    severity: detection.hasCritical ? 'critical' : 'high',
    actions,
    recommendations: remediations,
  };
}

/**
 * Log detection for cluster tracking
 * @param {string} responseId - Unique response identifier
 * @param {Object} detection - Detection result
 * @returns {string} Log file path
 */
export function logClusterDetection(responseId, detection) {
  const logsDir = path.join(
    process.env.HOME || '/tmp',
    '.jarvis/logs/cluster-detections'
  );

  // Create directory if it doesn't exist
  if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir, { recursive: true });
  }

  const logEntry = {
    responseId,
    clusterId: CLUSTER_PATTERNS.clusterId,
    detected: detection.detected,
    patternCount: detection.triggerCount,
    score: detection.score,
    patterns: detection.patterns.map((p) => ({
      pattern: p.pattern,
      trigger: p.trigger,
      severity: p.severity,
    })),
    timestamp: new Date().toISOString(),
  };

  const dateStr = new Date().toISOString().split('T')[0];
  const logFile = path.join(logsDir, `${dateStr}-cl-fd25ae4c34818568.jsonl`);

  fs.appendFileSync(logFile, JSON.stringify(logEntry) + '\n');

  return logFile;
}

/**
 * Get cluster statistics from recent logs
 * @param {number} days - Look back N days
 * @returns {Object} Cluster recurrence statistics
 */
export function getClusterStats(days = 7) {
  const logsDir = path.join(
    process.env.HOME || '/tmp',
    '.jarvis/logs/cluster-detections'
  );

  if (!fs.existsSync(logsDir)) {
    return {
      clusterId: CLUSTER_PATTERNS.clusterId,
      window: days,
      totalDetections: 0,
      patterns: {},
    };
  }

  const now = new Date();
  const cutoff = new Date(now.getTime() - days * 24 * 60 * 60 * 1000);

  let totalDetections = 0;
  const patterns = {};

  // Read all recent log files
  const files = fs.readdirSync(logsDir);
  for (const file of files) {
    if (!file.includes('cl-fd25ae4c34818568')) continue;

    const filePath = path.join(logsDir, file);
    const content = fs.readFileSync(filePath, 'utf-8');
    const lines = content.split('\n').filter((l) => l.trim());

    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        const entryTime = new Date(entry.timestamp);

        if (entryTime > cutoff && entry.detected) {
          totalDetections++;

          // Track pattern frequencies
          for (const pattern of entry.patterns) {
            if (!patterns[pattern.pattern]) {
              patterns[pattern.pattern] = { count: 0, severity: pattern.severity };
            }
            patterns[pattern.pattern].count++;
          }
        }
      } catch (e) {
        // Skip malformed lines
      }
    }
  }

  return {
    clusterId: CLUSTER_PATTERNS.clusterId,
    window: days,
    windowEnd: now.toISOString(),
    totalDetections,
    recurrenceThreshold: CLUSTER_PATTERNS.maxRecurrenceInWindow,
    exceedsThreshold: totalDetections >= CLUSTER_PATTERNS.maxRecurrenceInWindow,
    patterns,
  };
}

/**
 * Comprehensive cluster validation
 * @param {string} responseText - Response to validate
 * @param {string} responseId - Unique response identifier
 * @returns {Object} Full validation report
 */
export function validateForCluster(responseText, responseId = 'unknown') {
  const detection = detectClusterPatterns(responseText);
  const remediation = generateRemediationPlan(detection);
  const logFile = logClusterDetection(responseId, detection);
  const stats = getClusterStats(CLUSTER_PATTERNS.recurrenceWindow);

  return {
    clusterId: CLUSTER_PATTERNS.clusterId,
    responseId,
    detection,
    remediation,
    stats,
    shouldRewrite:
      remediation.required && remediation.severity === 'critical',
    shouldBlock: detection.hasCritical || (detection.hasHigh && stats.exceedsThreshold),
    logFile,
    report: {
      summary:
        detection.detected
          ? `⚠ Cluster pattern detected: ${detection.triggerCount} issue(s) (score: ${detection.score.toFixed(1)}/10)`
          : '✓ No cluster patterns detected',
      recurrence:
        stats.totalDetections > 0
          ? `${stats.totalDetections}/${CLUSTER_PATTERNS.maxRecurrenceInWindow} detections in ${CLUSTER_PATTERNS.recurrenceWindow}-day window`
          : 'No recent detections',
    },
    timestamp: new Date().toISOString(),
  };
}

// CLI usage
if (import.meta.url === `file://${process.argv[1]}`) {
  const text = process.argv[2] || '';
  const command = process.argv[3] || 'validate';
  const responseId = process.argv[4] || `cli-${Date.now()}`;

  if (command === 'detect') {
    const result = detectClusterPatterns(text);
    console.log(JSON.stringify(result, null, 2));
  } else if (command === 'remediate') {
    const detection = detectClusterPatterns(text);
    const remediation = generateRemediationPlan(detection);
    console.log(JSON.stringify(remediation, null, 2));
  } else if (command === 'stats') {
    const stats = getClusterStats();
    console.log(JSON.stringify(stats, null, 2));
  } else if (command === 'validate') {
    const result = validateForCluster(text, responseId);
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.shouldBlock ? 1 : 0);
  } else {
    console.error(
      'Usage: cluster-cl-fd25ae4c34818568-guard.mjs <text> [detect|remediate|stats|validate] [responseId]'
    );
    process.exit(1);
  }
}

export default {
  detectClusterPatterns,
  generateRemediationPlan,
  logClusterDetection,
  getClusterStats,
  validateForCluster,
};
