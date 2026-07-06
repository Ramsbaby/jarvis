#!/usr/bin/env bash
# file-guard-wrapper.sh
# Purpose: Integration wrapper for file existence guard in ask-claude.sh workflow
#
# This wrapper can be sourced or called to:
# 1. Extract file paths from a prompt
# 2. Run the file existence guard
# 3. Attach results to Claude input
# 4. Validate Claude output against guard results
#
# Usage (as sourced library):
#   source ~/jarvis/infra/lib/file-guard-wrapper.sh
#   guard_scan_prompt "$PROMPT" > guard_results.json
#   guard_validate_response response.txt guard_results.json > validation.json
#
# Usage (direct invocation):
#   ./file-guard-wrapper.sh scan-prompt "PROMPT_TEXT" > results.json
#   ./file-guard-wrapper.sh validate response.txt results.json > validation.json

set -euo pipefail

GUARD_SCRIPT="${GUARD_SCRIPT:-${JARVIS_HOME:-${HOME}/jarvis}/infra/bin/file-existence-guard.sh}"
VALIDATOR_SCRIPT="${VALIDATOR_SCRIPT:-${JARVIS_HOME:-${HOME}/jarvis}/infra/bin/claude-assertion-validator.mjs}"

# === Guard Wrapper Functions ===

# Extract potential file paths from prompt text
guard_extract_paths() {
    local text="$1"
    # Find paths that start with /, ~, ., or $
    echo "$text" | grep -oE '([/~\.][^\s]*|[$][A-Za-z_][A-Za-z0-9_]*[^\s]*)' | sort -u | head -n 50 || true
}

# Scan files mentioned in prompt
guard_scan_prompt() {
    local prompt="$1"
    local output_file="${2:-}"

    if ! command -v "$GUARD_SCRIPT" >/dev/null 2>&1; then
        if [ ! -x "$GUARD_SCRIPT" ]; then
            echo '{"error":"guard_script_not_found"}' >&2
            return 1
        fi
    fi

    "$GUARD_SCRIPT" --scan-prompt "$prompt" ${output_file:+--output-file "$output_file"}
    return 0
}

# Scan specific paths
guard_scan_paths() {
    local paths_colon_separated="$1"
    local output_file="${2:-}"

    "$GUARD_SCRIPT" --paths "$paths_colon_separated" ${output_file:+--output-file "$output_file"}
    return 0
}

# Validate Claude response against guard results
guard_validate_response() {
    local response_file="$1"
    local guard_results_file="$2"
    local output_file="${3:-}"
    local strict_mode="${GUARD_STRICT_MODE:-0}"

    if [ ! -f "$response_file" ]; then
        echo '{"error":"response_file_not_found"}' >&2
        return 1
    fi

    if [ ! -f "$guard_results_file" ]; then
        echo '{"error":"guard_results_file_not_found"}' >&2
        return 1
    fi

    VALIDATOR_STRICT_MODE="$strict_mode" \
    "$VALIDATOR_SCRIPT" \
        --claude-response "$response_file" \
        --guard-results "$guard_results_file" \
        ${output_file:+--output "$output_file"}

    return 0
}

# Check if response has contradictions
guard_has_contradictions() {
    local validation_json="$1"

    # Check if validation report has contradictions
    jq -e '.contradictions | length > 0' "$validation_json" >/dev/null 2>&1 && return 0 || return 1
}

# === CLI Entry Point ===

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-help}" in
        scan-prompt)
            guard_scan_prompt "${2:?Missing prompt text}"
            ;;
        scan-paths)
            guard_scan_paths "${2:?Missing paths (colon-separated)}"
            ;;
        validate)
            guard_validate_response "${2:?Missing response file}" "${3:?Missing guard results file}"
            ;;
        help|--help|-h)
            cat <<EOF
file-guard-wrapper.sh - Guard wrapper for file existence assertions

Usage:
  $0 scan-prompt "PROMPT_TEXT"          - Scan files mentioned in prompt
  $0 scan-paths "path1:path2:path3"     - Scan specific paths (colon-separated)
  $0 validate RESPONSE_FILE GUARD_FILE  - Validate response against guard results

Environment:
  GUARD_SCRIPT        - Path to file-existence-guard.sh (auto-detected)
  VALIDATOR_SCRIPT    - Path to claude-assertion-validator.mjs (auto-detected)
  GUARD_STRICT_MODE   - Set to 1 to block responses with contradictions (default: 0)
  JARVIS_HOME         - Jarvis home directory (default: \$HOME/jarvis)

Examples:
  # Scan a prompt
  $0 scan-prompt "Please check if \$HOME/.bashrc exists"

  # Scan specific paths
  $0 scan-paths "/etc/hosts:/etc/passwd:/nonexistent"

  # Validate a response
  $0 validate /tmp/response.txt /tmp/guard-results.json
EOF
            exit 0
            ;;
        *)
            echo "Unknown command: $1" >&2
            echo "Run with --help for usage information" >&2
            exit 1
            ;;
    esac
fi
