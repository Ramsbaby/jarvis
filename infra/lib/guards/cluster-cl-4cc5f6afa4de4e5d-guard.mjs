#!/usr/bin/env node
/**
 * Cluster-Specific Guard for cl-4cc5f6afa4de4e5d
 *
 * Targets the 4 recurrence patterns detected in this cluster (7-day window):
 * 1. Product ingredient verification missing → detection + blocking
 * 2. Stock status not confirmed → detection + warning
 * 3. Product screen verification absent → detection + blocking
 * 4. Screen-based product misidentification → detection + blocking
 *
 * Prevention Strategy:
 * - Before recommending any product, verify:
 *   1. Ingredient table URL exists and is accessible
 *   2. Stock status is confirmed (IN_STOCK or LOW_STOCK)
 *   3. Screen/screenshot evidence of product verification
 * - If any check fails, block recommendation and request verification
 *
 * Integration: Run AFTER guard-pipeline.mjs validation
 * Behavior: Non-blocking warnings for missing data, but BLOCKING for actual recommendations
 */

import fs from 'fs';
import path from 'path';

/**
 * Cluster-specific recurrence patterns
 */
const CLUSTER_PATTERNS = {
  clusterId: 'cl-4cc5f6afa4de4e5d',
  description: 'Missing product verification (ingredient, stock, screen evidence)',
  recurrenceWindow: 7, // days
  maxRecurrenceInWindow: 4, // trigger if 4+ occurrences
  severity: 'structural',
};

/**
 * Pattern 1: Missing ingredient table verification (제품 성분표 미확인)
 */
const MISSING_INGREDIENT_VERIFICATION = {
  id: 'missing-ingredient-verification',
  description: 'Product recommendation without ingredient table confirmation',
  triggers: [
    {
      // Detect product recommendations without ingredient URL mention
      regex: /(?:제품|상품|영양제|비타민).*?(?:추천|권장|제시)|(?:추천|권장|제시).*?(?:제품|상품|영양제|비타민)/is,
      weight: 0.85,
      message: 'Product recommended without ingredient table reference',
      // But don't trigger if ingredient information is mentioned
      negativeRegex: /(?:성분표|성분|ingredient|url|링크|https?:\/\/)/is,
    },
    {
      // Detect assumption-based recommendations
      regex: /(?:것으로\s+추정|아마|짐작|대략|아마도).*?(?:추천|권장|제시).*?(?:제품|상품)/is,
      weight: 1.0,
      message: 'Recommendation based on assumption without verification',
    },
  ],
  action: 'REQUIRE_INGREDIENT_VERIFICATION',
  severity: 'high',
};

/**
 * Pattern 2: Missing stock status confirmation (재고 상태 미확인)
 */
const MISSING_STOCK_CONFIRMATION = {
  id: 'missing-stock-confirmation',
  description: 'Product recommendation without stock status verification',
  triggers: [
    {
      // Detect product recommendations without stock status mention
      regex: /(?:추천|권장).*?(?:제품|상품)(?!.*?(?:재고|품질|가능|구매가능|주문가능|출시))/is,
      weight: 0.85,
      message: 'Product recommended without stock status confirmation',
    },
    {
      // Detect potential out-of-stock discovery after recommendation
      regex: /(?:재주문|다시\s+확인|다시\s+체크).*?(?:품절|재고\s+없음|절판)/is,
      weight: 1.0,
      message: 'Product found out-of-stock after initial recommendation',
    },
  ],
  action: 'REQUIRE_STOCK_VERIFICATION',
  severity: 'high',
};

/**
 * Pattern 3: Missing screen/screenshot verification (화면 확인 없음)
 */
const MISSING_SCREEN_VERIFICATION = {
  id: 'missing-screen-verification',
  description: 'Product recommendation without screen or screenshot evidence',
  triggers: [
    {
      // Detect recommendations without evidence references
      regex: /(?:추천|권장).*?(?:제품|상품)(?!.*?(?:스크린샷|화면|사진|이미지|증거|사진으로|화면으로|보여|캡처|스크린))/is,
      weight: 0.8,
      message: 'Product recommended without screen/screenshot evidence',
    },
    {
      // Detect blind/unverified recommendations
      regex: /(?:종합|판단|결정).*?(?:기반|토대)(?!.*?(?:검토|검증|확인|분석|화면|스크린))/is,
      weight: 0.85,
      message: 'Recommendation without visual verification basis',
    },
  ],
  action: 'REQUIRE_SCREEN_VERIFICATION',
  severity: 'medium',
};

/**
 * Pattern 4: Product misidentification from screen (화면 기반 제품 식별 오류)
 */
const PRODUCT_MISIDENTIFICATION = {
  id: 'product-misidentification',
  description: 'Incorrect product identification based on screen information',
  triggers: [
    {
      // Detect product confusion in multi-product contexts
      regex: /(?:이|해당).*?(?:제품|상품).*?(?:이|가)\s+아(?:니|닐\s+수|마도)\s+있다|실은|사실은|아니라|다른/is,
      weight: 0.95,
      message: 'Product misidentification correction detected',
    },
    {
      // Detect similar product confusion
      regex: /(?:같은|유사한|비슷한)\s+(?:제품|상품).*?(?:착각|혼동|오류|실수|다름)/is,
      weight: 1.0,
      message: 'Product similarity confusion or misidentification',
    },
    {
      // Detect screen-based identification errors
      regex: /(?:화면|이미지|사진|스크린).*?(?:보이|표시|나타)(?!.*?(?:맞|정확|확인됨|정확함))/is,
      weight: 0.85,
      message: 'Visual identification without confirmation of accuracy',
    },
  ],
  action: 'REQUIRE_PRODUCT_CONFIRMATION',
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

  // Check Pattern 1: Missing ingredient verification
  for (const trigger of MISSING_INGREDIENT_VERIFICATION.triggers) {
    const matches = trigger.regex.test(responseText);
    const negative = trigger.negativeRegex ? trigger.negativeRegex.test(responseText) : false;

    if (matches && !negative) {
      detections.push({
        pattern: MISSING_INGREDIENT_VERIFICATION.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: MISSING_INGREDIENT_VERIFICATION.severity,
        action: MISSING_INGREDIENT_VERIFICATION.action,
      });
      totalScore += trigger.weight;
    }
  }

  // Check Pattern 2: Missing stock confirmation
  for (const trigger of MISSING_STOCK_CONFIRMATION.triggers) {
    if (trigger.regex.test(responseText)) {
      detections.push({
        pattern: MISSING_STOCK_CONFIRMATION.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: MISSING_STOCK_CONFIRMATION.severity,
        action: MISSING_STOCK_CONFIRMATION.action,
      });
      totalScore += trigger.weight;
    }
  }

  // Check Pattern 3: Missing screen verification
  for (const trigger of MISSING_SCREEN_VERIFICATION.triggers) {
    if (trigger.regex.test(responseText)) {
      detections.push({
        pattern: MISSING_SCREEN_VERIFICATION.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: MISSING_SCREEN_VERIFICATION.severity,
        action: MISSING_SCREEN_VERIFICATION.action,
      });
      totalScore += trigger.weight;
    }
  }

  // Check Pattern 4: Product misidentification
  for (const trigger of PRODUCT_MISIDENTIFICATION.triggers) {
    if (trigger.regex.test(responseText)) {
      detections.push({
        pattern: PRODUCT_MISIDENTIFICATION.id,
        trigger: trigger.message,
        weight: trigger.weight,
        severity: PRODUCT_MISIDENTIFICATION.severity,
        action: PRODUCT_MISIDENTIFICATION.action,
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
    hasHigh: detections.some((d) => d.severity === 'high'),
    hasMedium: detections.some((d) => d.severity === 'medium'),
    detectedAt: new Date().toISOString(),
  };
}

/**
 * Generate remediation recommendations based on detected patterns
 * @param {Object} detection - Detection result from detectClusterPatterns
 * @returns {Object} Remediation plan with specific requirements
 */
export function generateRemediationPlan(detection) {
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
  const requiredVerifications = [];

  if (byAction['REQUIRE_INGREDIENT_VERIFICATION']) {
    actions.push({
      type: 'REQUIRE_INGREDIENT_VERIFICATION',
      priority: 'high',
      count: byAction['REQUIRE_INGREDIENT_VERIFICATION'].length,
      instruction:
        'Obtain and verify product ingredient table URL. Screenshot or link required before recommendation.',
      requirement:
        'Must provide: (1) Ingredient URL or (2) Screenshot of ingredient table from product page',
    });
    requiredVerifications.push('ingredient_table');
  }

  if (byAction['REQUIRE_STOCK_VERIFICATION']) {
    actions.push({
      type: 'REQUIRE_STOCK_VERIFICATION',
      priority: 'high',
      count: byAction['REQUIRE_STOCK_VERIFICATION'].length,
      instruction:
        'Verify current stock status before recommendation. Must confirm in-stock or low-stock status.',
      requirement:
        'Must confirm: Product stock status is IN_STOCK or LOW_STOCK (NOT OUT_OF_STOCK or UNKNOWN)',
    });
    requiredVerifications.push('stock_status');
  }

  if (byAction['REQUIRE_SCREEN_VERIFICATION']) {
    actions.push({
      type: 'REQUIRE_SCREEN_VERIFICATION',
      priority: 'medium',
      count: byAction['REQUIRE_SCREEN_VERIFICATION'].length,
      instruction:
        'Provide visual evidence (screenshot) of product page showing ingredients, price, availability.',
      requirement:
        'Must provide: Screenshot(s) of product page with visible ingredient section and stock status',
    });
    requiredVerifications.push('screen_evidence');
  }

  if (byAction['REQUIRE_PRODUCT_CONFIRMATION']) {
    actions.push({
      type: 'REQUIRE_PRODUCT_CONFIRMATION',
      priority: 'high',
      count: byAction['REQUIRE_PRODUCT_CONFIRMATION'].length,
      instruction:
        'Confirm exact product identity. Cross-check against screen evidence to avoid misidentification.',
      requirement:
        'Must verify: Product name, SKU, or barcode matches exactly on product page screenshot',
    });
    requiredVerifications.push('product_identity');
  }

  return {
    required: true,
    severity: detection.hasHigh ? 'high' : 'medium',
    actions,
    requiredVerifications,
    blocksRecommendation: detection.hasHigh,
    recommendations: [
      {
        title: 'Pre-Recommendation Checklist',
        items: requiredVerifications.map((item) => `✓ ${item}`),
      },
    ],
  };
}

/**
 * Verify if response contains required verification evidence
 * @param {string} responseText - Response to verify
 * @param {string[]} requirements - Required verification types
 * @returns {Object} Verification results
 */
export function verifyRequirements(responseText, requirements = []) {
  const results = {};

  for (const req of requirements) {
    switch (req) {
      case 'ingredient_table':
        results.ingredient_table = {
          present: /(?:성분표\s+url|ingredient\s+url|성분표\s+링크|https?:\/\/.*ingredient|https?:\/\/.*product.*ingredient)/i.test(
            responseText
          ),
          mentioned:
            /(?:성분표|ingredient|성분|ingredient table)/i.test(responseText),
        };
        break;
      case 'stock_status':
        results.stock_status = {
          present: /(?:재고|stock)\s+(?:상태|status|있음|있다|in\s+stock|available)/i.test(
            responseText
          ),
          confirmed:
            /(?:재고\s+(?:있음|충분|가능)|in\s+stock|available|구매\s+가능)/i.test(
              responseText
            ),
        };
        break;
      case 'screen_evidence':
        results.screen_evidence = {
          mentioned: /(?:스크린샷|화면|screenshot|screen|사진|image|캡처|capture)/i.test(
            responseText
          ),
          explicit: /(?:첨부|attach|포함|included).*?(?:스크린샷|screenshot|화면|screen)/i.test(
            responseText
          ),
        };
        break;
      case 'product_identity':
        results.product_identity = {
          specific: /(?:제품명|product\s+name)[\s:]*[가-힣\w\s\-()]+/i.test(
            responseText
          ),
          confirmed:
            /(?:확인|verified|검증|confirmed).*?(?:제품명|product\s+name|정확)/i.test(
              responseText
            ),
        };
        break;
    }
  }

  return results;
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
      action: p.action,
    })),
    timestamp: new Date().toISOString(),
  };

  const dateStr = new Date().toISOString().split('T')[0];
  const logFile = path.join(logsDir, `${dateStr}-cl-4cc5f6afa4de4e5d.jsonl`);

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
    if (!file.includes('cl-4cc5f6afa4de4e5d')) continue;

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
  const requiredVerifications =
    remediation.requiredVerifications || [];
  const verification = verifyRequirements(responseText, requiredVerifications);
  const logFile = logClusterDetection(responseId, detection);
  const stats = getClusterStats(CLUSTER_PATTERNS.recurrenceWindow);

  return {
    clusterId: CLUSTER_PATTERNS.clusterId,
    responseId,
    detection,
    remediation,
    verification,
    stats,
    shouldBlock:
      detection.hasHigh &&
      stats.totalDetections >= CLUSTER_PATTERNS.maxRecurrenceInWindow,
    requiresVerification: remediation.required,
    logFile,
    report: {
      summary: detection.detected
        ? `⚠ Cluster pattern detected: ${detection.triggerCount} issue(s) (score: ${detection.score.toFixed(1)}/10)`
        : '✓ No cluster patterns detected',
      recurrence:
        stats.totalDetections > 0
          ? `${stats.totalDetections}/${CLUSTER_PATTERNS.maxRecurrenceInWindow} detections in ${CLUSTER_PATTERNS.recurrenceWindow}-day window`
          : 'No recent detections',
      verificationRequired: remediation.required
        ? `Must verify: ${requiredVerifications.join(', ')}`
        : 'No additional verification required',
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
  } else if (command === 'verify') {
    const detection = detectClusterPatterns(text);
    const remediation = generateRemediationPlan(detection);
    const verification = verifyRequirements(
      text,
      remediation.requiredVerifications
    );
    console.log(JSON.stringify(verification, null, 2));
  } else if (command === 'stats') {
    const stats = getClusterStats();
    console.log(JSON.stringify(stats, null, 2));
  } else if (command === 'validate') {
    const result = validateForCluster(text, responseId);
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.shouldBlock ? 1 : 0);
  } else {
    console.error(
      'Usage: cluster-cl-4cc5f6afa4de4e5d-guard.mjs <text> [detect|remediate|verify|stats|validate] [responseId]'
    );
    process.exit(1);
  }
}

export default {
  detectClusterPatterns,
  generateRemediationPlan,
  verifyRequirements,
  logClusterDetection,
  getClusterStats,
  validateForCluster,
};
