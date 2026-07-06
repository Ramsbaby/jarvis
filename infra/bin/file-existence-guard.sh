#!/usr/bin/env bash
# file-existence-guard.sh
# Purpose: Guard against file existence assertion contradictions (cluster cl-3dbad2477e65b7b7)
#
# This script:
# 1. Proactively scans specified paths for file existence
# 2. Outputs results in JSON format for post-processing validation
# 3. Prevents blind assertions about file states without prior exploration
#
# Usage:
#   file-existence-guard.sh [--paths "path1:path2:..." | --context-file FILE] [--output-file FILE]
#   file-existence-guard.sh --scan-prompt "PROMPT_TEXT"
#
# Environment:
#   GUARD_SCAN_PATHS      - Colon-separated paths to scan (default: current directory)
#   GUARD_OUTPUT_FILE     - Where to write JSON results (default: stdout)
#   GUARD_CONTEXT_FILE    - Optional: read paths from context markdown file
#
# Output format (JSON):
#   {
#     "guard_id": "file-existence-guard",
#     "timestamp": "2026-07-05T04:30:00Z",
#     "scan_paths": ["path1", "path2"],
#     "results": {
#       "path1": {"exists": true, "type": "file", "readable": true},
#       "path2": {"exists": false, "type": "none", "readable": false}
#     },
#     "error": null
#   }

set -euo pipefail

# Configuration with sensible defaults
GUARD_ID="file-existence-guard"
GUARD_SCAN_PATHS="${GUARD_SCAN_PATHS:-}"
GUARD_OUTPUT_FILE="${GUARD_OUTPUT_FILE:-}"
GUARD_CONTEXT_FILE="${GUARD_CONTEXT_FILE:-}"
GUARD_MAX_PATHS=50
GUARD_TIMEOUT=30

# Helper: Output JSON with proper escaping
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g; s/\\n$//'
}

# Helper: Output result to file or stdout
output_result() {
    local json="$1"
    if [[ -n "$GUARD_OUTPUT_FILE" ]]; then
        echo "$json" > "$GUARD_OUTPUT_FILE"
    else
        echo "$json"
    fi
}

# Helper: Extract potential file paths from prompt/context
extract_paths_from_text() {
    local text="$1"
    # Look for patterns like: /path/to/file, ~/path, ./relative, $VAR/path
    # Returns lines that look like paths
    echo "$text" | grep -oE '([/~.][^ "]+|[$][A-Za-z_][A-Za-z0-9_]*[^ "]*)' | sort -u | head -n "$GUARD_MAX_PATHS" || true
}

# Helper: Extract paths from context markdown file
extract_paths_from_context_file() {
    local context_file="$1"
    if [[ ! -f "$context_file" ]]; then
        return 1
    fi
    # Extract file paths mentioned in context markdown
    # Patterns: - `/path` or - `~/path` or code blocks with paths
    grep -oE '(`[^`]*[/~][^`]*`|path[: ]*[/~][^ ]+)' "$context_file" 2>/dev/null | sed 's/[`]//g; s/path[: ]*//' | sort -u | head -n "$GUARD_MAX_PATHS" || true
}

# Helper: Check single path existence and properties
check_path_existence() {
    local path="$1"

    # Expand variables and home directory
    path="${path/#\~/$HOME}"
    path="${path/#.\//$PWD/}"

    local exists="false"
    local type_result="none"
    local readable="false"

    if [[ -e "$path" ]]; then
        exists="true"
        readable="true"  # If it exists, we were able to check it

        if [[ -f "$path" ]]; then
            type_result="file"
        elif [[ -d "$path" ]]; then
            type_result="directory"
        elif [[ -L "$path" ]]; then
            type_result="symlink"
        else
            type_result="other"
        fi
    elif [[ -L "$path" ]]; then
        # Broken symlink
        exists="true"
        type_result="symlink"
        readable="false"
    fi

    # Test actual readability
    if [[ -r "$path" ]]; then
        readable="true"
    fi

    # Output JSON object for this path
    printf '"%s": {"exists": %s, "type": "%s", "readable": %s}' \
        "$(json_escape "$path")" "$exists" "$type_result" "$readable"
}

# Main execution
main() {
    local paths_to_scan=()
    local scan_source="auto"

    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --paths)
                shift
                IFS=':' read -ra PATHS_ARRAY <<< "${1:-}"
                paths_to_scan=("${PATHS_ARRAY[@]}")
                scan_source="manual"
                ;;
            --context-file)
                shift
                GUARD_CONTEXT_FILE="${1:-}"
                scan_source="context"
                ;;
            --scan-prompt)
                shift
                local prompt_text="${1:-}"
                mapfile -t extracted < <(extract_paths_from_text "$prompt_text")
                paths_to_scan=("${extracted[@]}")
                scan_source="prompt"
                ;;
            --output-file)
                shift
                GUARD_OUTPUT_FILE="${1:-}"
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
        shift
    done

    # Auto-detect paths if none provided
    if [[ ${#paths_to_scan[@]} -eq 0 ]]; then
        if [[ -n "$GUARD_CONTEXT_FILE" ]]; then
            mapfile -t extracted < <(extract_paths_from_context_file "$GUARD_CONTEXT_FILE")
            paths_to_scan=("${extracted[@]}")
            scan_source="context"
        fi
    fi

    # Prepare results JSON
    local timestamp=$(date -u +%FT%TZ)
    local error_msg="null"
    local results_json="{"

    # Scan all collected paths
    local first=true
    for path in "${paths_to_scan[@]}"; do
        if [[ -z "$path" ]]; then
            continue
        fi

        if [[ "$first" == false ]]; then
            results_json="$results_json,"
        fi
        first=false

        results_json="$results_json$(check_path_existence "$path")"
    done
    results_json="$results_json}"

    # Build final JSON output
    local final_json=$(cat <<EOF
{
  "guard_id": "$GUARD_ID",
  "timestamp": "$timestamp",
  "scan_source": "$scan_source",
  "scan_count": ${#paths_to_scan[@]},
  "results": $results_json,
  "error": $error_msg
}
EOF
)

    output_result "$final_json"
    return 0
}

# Execute if run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
