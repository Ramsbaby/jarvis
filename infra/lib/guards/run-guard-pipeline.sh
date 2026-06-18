#!/bin/bash

# Guard Pipeline Bash Wrapper
# Executes the guard-pipeline.mjs Node.js script
# Used by Jarvis task runner for cluster cl-fd25ae4c34818568
#
# Usage: run-guard-pipeline.sh <response_text> [validate|check|report]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_PIPELINE="${SCRIPT_DIR}/guard-pipeline.mjs"

# Check if Node.js is available
if ! command -v node &> /dev/null; then
    echo '{"error": "Node.js not found in PATH"}' >&2
    exit 1
fi

# Check if guard-pipeline.mjs exists
if [[ ! -f "$GUARD_PIPELINE" ]]; then
    echo "{\"error\": \"Guard pipeline script not found: $GUARD_PIPELINE\"}" >&2
    exit 1
fi

# Execute guard pipeline with all arguments passed through
node "$GUARD_PIPELINE" "$@"
