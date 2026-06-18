#!/bin/bash

###############################################################################
# Cluster-Specific Guard Runner for cl-fd25ae4c34818568
#
# Integrates cluster guard validation with the existing guard pipeline.
# Runs AFTER standard guard-pipeline.mjs validation.
#
# Usage:
#   run-cluster-guard.sh <response_text> [response_id]
#
# Output: JSON with validation result, remediation plan, and recurrence stats
# Exit codes:
#   0 = Valid (no blocking issues)
#   1 = Should block (critical/high severity issues with high recurrence)
#   2 = Should rewrite (critical issues only)
###############################################################################

set -euo pipefail

# Configuration
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_GUARD="${GUARD_DIR}/cluster-cl-fd25ae4c34818568-guard.mjs"
OUTPUT_DIR="${HOME}/.jarvis/logs/cluster-detections"

# Input validation
if [[ $# -lt 1 ]]; then
    echo '{"error": "Missing response_text argument"}' >&2
    exit 1
fi

RESPONSE_TEXT="$1"
RESPONSE_ID="${2:-unknown-$(date +%s)}"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Run cluster guard validation
if [[ ! -f "$CLUSTER_GUARD" ]]; then
    echo "{\"error\": \"Guard file not found: $CLUSTER_GUARD\"}" >&2
    exit 1
fi

RESULT=$(node "$CLUSTER_GUARD" "$RESPONSE_TEXT" "validate" "$RESPONSE_ID" 2>&1)

# Parse validation result
SHOULD_REWRITE=$(echo "$RESULT" | jq -r '.shouldRewrite // false')
SHOULD_BLOCK=$(echo "$RESULT" | jq -r '.shouldBlock // false')
HAS_CRITICAL=$(echo "$RESULT" | jq -r '.detection.hasCritical // false')

# Log the validation
echo "$RESULT" | jq . >> "${OUTPUT_DIR}/validation-log.jsonl"

# Determine exit code
if [[ "$SHOULD_BLOCK" == "true" ]]; then
    echo "$RESULT" | jq .
    exit 1
elif [[ "$SHOULD_REWRITE" == "true" ]]; then
    echo "$RESULT" | jq .
    exit 2
else
    echo "$RESULT" | jq .
    exit 0
fi
