#!/usr/bin/env node
/**
 * claude-assertion-validator.mjs
 * Purpose: Validate Claude responses for file existence assertions (cluster cl-3dbad2477e65b7b7)
 *
 * This validator:
 * 1. Extracts file existence assertions from Claude responses
 * 2. Compares assertions against actual file scan results
 * 3. Detects contradictions and unsupported assertions
 * 4. Produces validation report with findings
 *
 * Usage:
 *   node claude-assertion-validator.mjs \
 *     --claude-response FILE \
 *     --guard-results FILE \
 *     --output FILE
 *
 * Environment:
 *   VALIDATOR_STRICT_MODE - If 1, block responses with unsupported assertions
 *   VALIDATOR_LOG_LEVEL   - log|warn|error (default: warn)
 */

import fs from "fs";
import path from "path";

const VALIDATOR_ID = "claude-assertion-validator";
const STRICT_MODE = process.env.VALIDATOR_STRICT_MODE === "1";
const LOG_LEVEL = process.env.VALIDATOR_LOG_LEVEL || "warn";

/**
 * Logging helper
 */
const logger = {
  log: (...args) => {
    if (["log", "warn", "error"].includes(LOG_LEVEL)) {
      console.error(`[${VALIDATOR_ID}]`, ...args);
    }
  },
  warn: (...args) => {
    if (["warn", "error"].includes(LOG_LEVEL)) {
      console.error(`[${VALIDATOR_ID}] WARN:`, ...args);
    }
  },
  error: (...args) => {
    console.error(`[${VALIDATOR_ID}] ERROR:`, ...args);
  },
};

/**
 * Extract file existence assertions from text
 * Patterns:
 * - "file exists"
 * - "file does not exist"
 * - "path exists"
 * - "file not found"
 * - "file is missing"
 * - "found the file at /path"
 */
function extractFileAssertions(text) {
  const assertions = [];
  const seenPaths = new Set();

  // Helper to avoid duplicates
  function addAssertion(type, filePath, assertion, context) {
    if (isValidPath(filePath) && !seenPaths.has(filePath)) {
      seenPaths.add(filePath);
      assertions.push({
        type,
        path: filePath,
        assertion,
        context,
      });
    }
  }

  let match;

  // Pattern 1: "path/to/file exists"
  const existsPattern = /([\/~][^\s]*?)\s+(?:exists|is\s+present|found)/gi;
  while ((match = existsPattern.exec(text)) !== null) {
    const path = match[1].replace(/[.,;:!?]$/, ""); // Remove trailing punctuation
    addAssertion("exists", path, "file_exists", match[0]);
  }

  // Pattern 2: "path/to/file does not exist" or "missing"
  const notExistsPattern =
    /([\/~][^\s]*?)\s+(?:does\s+not\s+exist|is\s+missing|not\s+found|doesn't\s+exist)/gi;
  while ((match = notExistsPattern.exec(text)) !== null) {
    const path = match[1].replace(/[.,;:!?]$/, "");
    addAssertion("not_exists", path, "file_not_exists", match[0]);
  }

  // Pattern 3: "I ... verified/confirmed/checked /path"
  const verifiedPattern =
    /(?:verified|confirmed|checked|examined|found)\s+(?:the\s+)?(?:file\s+)?(?:at\s+)?([\/~][^\s,;:)]+)/gi;
  while ((match = verifiedPattern.exec(text)) !== null) {
    const path = match[1].replace(/[.,;:!?]$/, "");
    addAssertion("verified", path, "file_verified", match[0]);
  }

  // Pattern 4: "file at /path" in existence context
  const fileAtPattern = /file\s+at\s+([\/~][^\s,;:)]+)/gi;
  while ((match = fileAtPattern.exec(text)) !== null) {
    const path = match[1].replace(/[.,;:!?]$/, "");
    const context = text.substring(
      Math.max(0, match.index - 50),
      Math.min(text.length, match.index + match[0].length + 50)
    );
    if (!/not|missing|doesn't|no\s+file/i.test(context)) {
      addAssertion("exists", path, "file_exists", context);
    } else {
      addAssertion("not_exists", path, "file_not_exists", context);
    }
  }

  return assertions;
}

/**
 * Check if string looks like a valid path
 */
function isValidPath(str) {
  if (!str) return false;
  // Reject obviously invalid patterns
  if (str.length > 500) return false;
  if (/^[^a-zA-Z0-9./_~$-]/.test(str)) return false;
  // Must contain at least one path separator or known directory marker
  return /[/.~$]/.test(str);
}

/**
 * Match assertion paths against guard results
 */
function validateAssertions(assertions, guardResults) {
  const validationReport = {
    total_assertions: assertions.length,
    validated: [],
    contradictions: [],
    unsupported: [],
  };

  if (!guardResults || !guardResults.results) {
    return {
      ...validationReport,
      error: "No guard results provided",
      unsupported: assertions.map((a) => ({
        assertion: a,
        reason: "no_scan_data",
      })),
    };
  }

  for (const assertion of assertions) {
    const expandedPath = expandPath(assertion.path);
    const scanResult = guardResults.results[expandedPath];

    if (!scanResult) {
      // Path was not scanned
      validationReport.unsupported.push({
        assertion,
        reason: "path_not_scanned",
        expected_in_results: Object.keys(guardResults.results),
      });
      continue;
    }

    // Check for contradictions
    if (assertion.type === "exists" && !scanResult.exists) {
      validationReport.contradictions.push({
        assertion,
        scanResult,
        reason: "existence_mismatch",
        detail: `Asserted file exists but scan found: ${scanResult.type}`,
      });
    } else if (assertion.type === "not_exists" && scanResult.exists) {
      validationReport.contradictions.push({
        assertion,
        scanResult,
        reason: "existence_mismatch",
        detail: `Asserted file does not exist but scan found: ${scanResult.type}`,
      });
    } else if (assertion.type === "verified" && !scanResult.exists) {
      validationReport.contradictions.push({
        assertion,
        scanResult,
        reason: "verification_failed",
        detail: "Claimed file verification but file does not exist",
      });
    } else {
      // Valid assertion
      validationReport.validated.push({
        assertion,
        scanResult,
        status: "ok",
      });
    }
  }

  return validationReport;
}

/**
 * Expand path variables and home directory
 */
function expandPath(filepath) {
  if (filepath.startsWith("~")) {
    return filepath.replace("~", process.env.HOME || "/root");
  }
  if (filepath.startsWith("$")) {
    const match = filepath.match(/\$([A-Za-z_][A-Za-z0-9_]*)/);
    if (match) {
      const varName = match[1];
      const varValue = process.env[varName] || "";
      return filepath.replace(`$${varName}`, varValue);
    }
  }
  return filepath;
}

/**
 * Read JSON file safely
 */
function readJsonFile(filepath) {
  try {
    const content = fs.readFileSync(filepath, "utf-8");
    return JSON.parse(content);
  } catch (err) {
    logger.error(`Failed to read ${filepath}:`, err.message);
    return null;
  }
}

/**
 * Main validation function
 */
function validateResponse(claudeResponseText, guardResultsObj) {
  const timestamp = new Date().toISOString();
  const assertions = extractFileAssertions(claudeResponseText);
  const validationReport = validateAssertions(assertions, guardResultsObj);

  return {
    validator_id: VALIDATOR_ID,
    timestamp,
    status:
      validationReport.contradictions.length === 0 &&
      validationReport.unsupported.length === 0
        ? "pass"
        : "fail",
    severity:
      validationReport.contradictions.length > 0 ? "blocking" : "warning",
    assertions_found: assertions.length,
    ...validationReport,
    strict_mode: STRICT_MODE,
  };
}

/**
 * CLI entry point
 */
async function main() {
  const args = process.argv.slice(2);
  let claudeResponseFile = null;
  let guardResultsFile = null;
  let outputFile = null;

  // Parse arguments
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--claude-response") {
      claudeResponseFile = args[++i];
    } else if (args[i] === "--guard-results") {
      guardResultsFile = args[++i];
    } else if (args[i] === "--output") {
      outputFile = args[++i];
    } else if (args[i] === "--claude-text") {
      // Accept raw text instead of file
      claudeResponseFile = args[++i];
    }
  }

  // Validate inputs
  if (!claudeResponseFile || !guardResultsFile) {
    console.error(
      "Usage: claude-assertion-validator.mjs --claude-response FILE --guard-results FILE [--output FILE]"
    );
    process.exit(1);
  }

  // Read guard results
  const guardResults = readJsonFile(guardResultsFile);
  if (!guardResults) {
    console.error("Failed to read guard results");
    process.exit(2);
  }

  // Read Claude response
  let claudeText;
  if (fs.existsSync(claudeResponseFile)) {
    claudeText = fs.readFileSync(claudeResponseFile, "utf-8");
  } else {
    // Treat as raw text
    claudeText = claudeResponseFile;
  }

  // Run validation
  const report = validateResponse(claudeText, guardResults);

  // Output results
  const output = JSON.stringify(report, null, 2);
  if (outputFile) {
    fs.writeFileSync(outputFile, output, "utf-8");
    logger.log(`Validation report written to ${outputFile}`);
  } else {
    console.log(output);
  }

  // Exit with code based on strictness
  if (report.status === "fail") {
    if (STRICT_MODE) {
      process.exit(3); // Assertion validation failure
    } else {
      logger.warn(`Validation found ${report.contradictions.length} issues`);
      process.exit(0);
    }
  }

  process.exit(0);
}

// Run if called directly
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    logger.error("Validation failed:", err);
    process.exit(2);
  });
}

export { validateResponse, extractFileAssertions, validateAssertions };
