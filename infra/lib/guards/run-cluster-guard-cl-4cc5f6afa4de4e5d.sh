#!/bin/bash
#
# Run cluster-specific guard for cl-4cc5f6afa4de4e5d
#
# Usage:
#   bash run-cluster-guard-cl-4cc5f6afa4de4e5d.sh <response_text> <response_id> [command]
#
# Commands: detect, remediate, verify, validate (default)
#

set -uo pipefail

RESPONSE_TEXT="${1:-}"
RESPONSE_ID="${2:-unknown-$(date +%s)}"
COMMAND="${3:-validate}"

GUARD_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cluster-cl-4cc5f6afa4de4e5d-guard.mjs"

if [ ! -f "$GUARD_FILE" ]; then
  echo "ERROR: Guard file not found: $GUARD_FILE" >&2
  exit 1
fi

# Run the guard
node "$GUARD_FILE" "$RESPONSE_TEXT" "$COMMAND" "$RESPONSE_ID"
EXIT_CODE=$?

exit "$EXIT_CODE"
