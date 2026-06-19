#!/usr/bin/env node
/**
 * Product Recommendation Guard
 *
 * High-level guard for product recommendations
 * Integrates with:
 * - product-validator.js (ingredient/stock verification)
 * - cluster-cl-4cc5f6afa4de4e5d-guard.mjs (pattern detection)
 *
 * Usage:
 *   import { validateProductRecommendation } from './product-recommendation-guard.mjs';
 *   const result = await validateProductRecommendation(text, productId);
 */

import { fileURLToPath } from 'url';
import { dirname } from 'path';
import { createRequire } from 'module';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// Import cluster guard
import clusterGuard from './cluster-cl-4cc5f6afa4de4e5d-guard.mjs';

// Dynamic require for CommonJS modules (product-validator.js)
let ProductValidator;
try {
  const ProductValidatorPath = require.resolve('../product-validator.js');
  ProductValidator = require(ProductValidatorPath);
} catch (e) {
  console.warn('[ProductRecommendationGuard] ProductValidator not available:', e.message);
}

/**
 * Validate a product recommendation response
 * @param {string} responseText - The recommendation response text
 * @param {string} productId - Product ID to recommend
 * @param {Object} options - Guard options
 * @returns {Promise<Object>} Validation result
 */
export async function validateProductRecommendation(
  responseText,
  productId,
  options = {}
) {
  const result = {
    valid: true,
    productId,
    checks: {
      clusterPattern: null,
      productVerification: null,
    },
    issues: [],
    warnings: [],
    blocksRecommendation: false,
    requiresVerification: false,
    suggestions: [],
  };

  // Step 1: Cluster pattern detection
  const clusterValidation = clusterGuard.validateForCluster(
    responseText,
    options.responseId || `product-${productId}-${Date.now()}`
  );

  result.checks.clusterPattern = {
    detected: clusterValidation.detection.detected,
    score: clusterValidation.detection.score,
    patterns: clusterValidation.detection.patterns.map((p) => p.pattern),
    severity: clusterValidation.remediation.severity || 'none',
    requiresVerification: clusterValidation.remediation.required,
  };

  if (clusterValidation.remediation.required) {
    result.issues.push({
      type: 'cluster_pattern_detected',
      severity: clusterValidation.remediation.severity,
      message: `Cluster pattern detected: ${clusterValidation.detection.triggerCount} issue(s)`,
      requiredVerifications: clusterValidation.remediation.requiredVerifications,
    });
    result.requiresVerification = true;
  }

  // Step 2: Product verification (if ProductValidator available)
  if (ProductValidator && !options.skipProductVerification) {
    try {
      const validator = new ProductValidator(options.validatorOptions || {});
      const verification = await validator.canRecommend(productId, {
        skipCache: options.skipCache,
        skipIngredientCheck: options.skipIngredientCheck,
      });

      result.checks.productVerification = {
        canRecommend: verification.canRecommend,
        reason: verification.reason,
        validation: {
          success: verification.validation.success,
          ingredientUrl: verification.validation.ingredientUrl,
          ingredients: verification.validation.ingredients?.slice(0, 3) || [],
          stockStatus: verification.validation.stockStatus,
          warning: verification.validation.warning,
        },
      };

      if (!verification.canRecommend) {
        result.issues.push({
          type: 'product_verification_failed',
          severity: verification.validation.stockStatus === 'OUT_OF_STOCK'
            ? 'high'
            : 'medium',
          message: verification.reason,
          productId,
        });
        result.blocksRecommendation = true;
      }

      if (verification.validation.warning) {
        result.warnings.push({
          type: 'product_warning',
          message: verification.validation.warning,
          productId,
        });
      }
    } catch (err) {
      result.warnings.push({
        type: 'product_verification_error',
        message: `Failed to verify product: ${err.message}`,
        productId,
      });
    }
  }

  // Step 3: Determine final validity
  result.valid = !result.blocksRecommendation && result.issues.length === 0;

  // Step 4: Generate suggestions
  if (result.issues.length > 0) {
    for (const issue of result.issues) {
      if (issue.type === 'cluster_pattern_detected') {
        result.suggestions.push(
          'Before recommending, verify: ' +
          (issue.requiredVerifications || []).join(', ')
        );
      }
      if (issue.type === 'product_verification_failed') {
        if (issue.message.includes('성분표')) {
          result.suggestions.push(
            'Add ingredient table URL or screenshot to the response'
          );
        }
        if (issue.message.includes('품절') || issue.message.includes('OUT_OF_STOCK')) {
          result.suggestions.push(
            'Check current stock status before recommending this product'
          );
        }
      }
    }
  }

  return result;
}

/**
 * Check if recommendation text includes required verification evidence
 * @param {string} responseText - Response text to check
 * @returns {Object} Evidence check results
 */
export function checkVerificationEvidence(responseText) {
  const evidence = {
    ingredientTableMentioned: /(?:성분표|ingredient\s+table|성분|ingredient)/i.test(
      responseText
    ),
    ingredientUrlIncluded: /https?:\/\/[^\s]+(?:ingredient|product|detail)/i.test(
      responseText
    ),
    screenshotMentioned: /(?:스크린샷|screenshot|화면|screen|사진|image)/i.test(
      responseText
    ),
    stockStatusMentioned: /(?:재고|stock)\s+(?:상태|status|있음|있다|available)/i.test(
      responseText
    ),
    stockConfirmed: /(?:재고\s+(?:있음|충분|확인|가능)|in\s+stock|available|구매\s+가능)/i.test(
      responseText
    ),
  };

  return {
    ...evidence,
    sufficientEvidence:
      evidence.ingredientTableMentioned &&
      (evidence.ingredientUrlIncluded || evidence.screenshotMentioned) &&
      evidence.stockConfirmed,
  };
}

/**
 * Generate product recommendation report
 * @param {Object} validationResult - Result from validateProductRecommendation
 * @returns {Object} Human-readable report
 */
export function generateReport(validationResult) {
  const report = {
    status: validationResult.valid ? 'PASS' : 'FAIL',
    productId: validationResult.productId,
    summary: '',
    details: {
      clusterCheck: null,
      productCheck: null,
    },
    issues: [],
    warnings: [],
    suggestions: [],
  };

  // Cluster check report
  if (validationResult.checks.clusterPattern?.detected) {
    report.details.clusterCheck = {
      status: 'PATTERN_DETECTED',
      score: validationResult.checks.clusterPattern.score.toFixed(1),
      patterns: validationResult.checks.clusterPattern.patterns.join(', '),
      severity: validationResult.checks.clusterPattern.severity,
    };
  }

  // Product check report
  if (validationResult.checks.productVerification) {
    const pv = validationResult.checks.productVerification;
    report.details.productCheck = {
      status: pv.canRecommend ? 'VERIFIED' : 'VERIFICATION_FAILED',
      canRecommend: pv.canRecommend,
      ingredientUrl: pv.validation.ingredientUrl || 'Not found',
      stockStatus: pv.validation.stockStatus,
      warning: pv.validation.warning,
    };
  }

  // Issues and suggestions
  report.issues = validationResult.issues;
  report.warnings = validationResult.warnings;
  report.suggestions = validationResult.suggestions;

  // Summary
  if (!validationResult.valid) {
    const issueTypes = validationResult.issues.map((i) => i.type).join(', ');
    report.summary = `Recommendation BLOCKED: ${issueTypes}`;
  } else if (validationResult.requiresVerification) {
    report.summary = 'Recommendation allowed but requires verification';
  } else {
    report.summary = 'Recommendation PASSED all checks';
  }

  return report;
}

// CLI usage
if (import.meta.url === `file://${process.argv[1]}`) {
  const responseText = process.argv[2] || '';
  const productId = process.argv[3] || 'UNKNOWN';
  const command = process.argv[4] || 'validate';

  (async () => {
    if (command === 'validate') {
      const result = await validateProductRecommendation(responseText, productId);
      console.log(JSON.stringify(generateReport(result), null, 2));
      process.exit(result.valid && !result.blocksRecommendation ? 0 : 1);
    } else if (command === 'check-evidence') {
      const evidence = checkVerificationEvidence(responseText);
      console.log(JSON.stringify(evidence, null, 2));
      process.exit(evidence.sufficientEvidence ? 0 : 1);
    } else {
      console.error(
        'Usage: product-recommendation-guard.mjs <text> <productId> [validate|check-evidence]'
      );
      process.exit(1);
    }
  })().catch((err) => {
    console.error('Error:', err);
    process.exit(1);
  });
}

export default {
  validateProductRecommendation,
  checkVerificationEvidence,
  generateReport,
};
