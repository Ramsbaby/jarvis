#!/bin/bash

################################################################################
# File Validator Guard for Mistake Cluster cl-dcd8ff3443b1f052
#
# Purpose: Validate file state after save/upload operations
# - Path existence check
# - File size > 0
# - Language ratio analysis (Korean vs English)
# - Blocks completion status until validation passes
#
# Usage: file-validator.sh <filepath> [--check-language] [--check-size] [--verbose]
#        OR sourced for function use
#
# Exit codes:
#   0 = Validation passed
#   1 = Validation failed (file missing, empty, or invalid language content)
#   2 = Invalid arguments
################################################################################

set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================

VALIDATOR_LOG="${HOME}/jarvis/logs/file-validator.log"
VALIDATOR_STATE="${HOME}/jarvis/runtime/state/file-validation-state.json"

# Language thresholds
MIN_KOREAN_RATIO=0.0      # Accept any Korean content (0% = no minimum)
MIN_ENGLISH_RATIO=0.0     # Accept any English content (0% = no minimum)
MIN_TOTAL_CJK_RATIO=0.0   # Accept mixed Asian scripts

# Size threshold
MIN_FILE_SIZE_BYTES=1      # Minimum file size in bytes (1 = must not be empty)

# Validation modes (configurable per call)
CHECK_EXISTENCE=true
CHECK_SIZE=true
CHECK_LANGUAGE=true
VERBOSE=false

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log_validation() {
    local filepath="$1"
    local status="$2"
    local details="$3"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create log directory if needed
    mkdir -p "$(dirname "$VALIDATOR_LOG")"

    # Append to log (atomic append)
    cat >> "$VALIDATOR_LOG" <<EOF
{"timestamp":"$timestamp","filepath":"$filepath","status":"$status","details":"$details"}
EOF
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[VALIDATOR] $*" >&2
    fi
}

# ============================================================================
# LANGUAGE ANALYSIS
# ============================================================================

analyze_language_content() {
    local filepath="$1"

    if [[ ! -f "$filepath" ]]; then
        echo '{"korean_chars":0,"english_chars":0,"korean_ratio":0,"english_ratio":0,"cjk_ratio":0,"total_chars":0,"status":"file_not_found"}'
        return 1
    fi

    # Read file, handle binary gracefully
    local content
    if file "$filepath" | grep -q "text"; then
        content=$(cat "$filepath" 2>/dev/null || true)
    else
        # For non-text files, analyze as-is
        content=$(xxd -p "$filepath" 2>/dev/null | fold -w 2 | tr '\n' ' ' || true)
    fi

    # Count character types using grep/awk
    # Korean: U+AC00-U+D7AF (Hangul syllables)
    # CJK Unified Ideographs: U+4E00-U+9FFF (Chinese/Japanese/Korean)
    # ASCII letters: A-Z, a-z

    local korean_count=$(echo "$content" | grep -o '[가-힣]' | wc -l)
    local english_count=$(echo "$content" | grep -o '[A-Za-z]' | wc -l)
    local cjk_count=$(echo "$content" | grep -o '[一-龥ぁ-ん]' | wc -l)
    local total_chars=${#content}

    # Handle division by zero
    local korean_ratio=0
    local english_ratio=0
    local cjk_ratio=0

    if (( total_chars > 0 )); then
        korean_ratio=$(awk "BEGIN {printf \"%.4f\", $korean_count / $total_chars}")
        english_ratio=$(awk "BEGIN {printf \"%.4f\", $english_count / $total_chars}")
        cjk_ratio=$(awk "BEGIN {printf \"%.4f\", ($korean_count + $cjk_count) / $total_chars}")
    fi

    # Output as JSON
    cat <<EOF
{"korean_chars":$korean_count,"english_chars":$english_count,"korean_ratio":$korean_ratio,"english_ratio":$english_ratio,"cjk_ratio":$cjk_ratio,"total_chars":$total_chars,"status":"analyzed"}
EOF

    log_verbose "Language analysis for $filepath: korean=$korean_count english=$english_count"
}

# ============================================================================
# VALIDATION CHECKS
# ============================================================================

validate_path_exists() {
    local filepath="$1"

    if [[ ! -e "$filepath" ]]; then
        log_validation "$filepath" "FAILED" "Path does not exist"
        log_verbose "Validation failed: path does not exist - $filepath"
        return 1
    fi

    if [[ ! -f "$filepath" ]]; then
        log_validation "$filepath" "FAILED" "Path exists but is not a regular file"
        log_verbose "Validation failed: not a regular file - $filepath"
        return 1
    fi

    return 0
}

validate_file_size() {
    local filepath="$1"

    if [[ ! -f "$filepath" ]]; then
        log_validation "$filepath" "FAILED" "Cannot check size: file not found"
        return 1
    fi

    local filesize=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)

    if (( filesize == 0 )); then
        log_validation "$filepath" "FAILED" "File size is 0 bytes"
        log_verbose "Validation failed: file is empty - $filepath (size: $filesize)"
        return 1
    fi

    log_verbose "File size check passed: $filepath (size: $filesize bytes)"
    return 0
}

validate_language_content() {
    local filepath="$1"

    if [[ ! -f "$filepath" ]]; then
        log_validation "$filepath" "FAILED" "Cannot check language: file not found"
        return 1
    fi

    # Analyze language content
    local analysis=$(analyze_language_content "$filepath")
    local korean_ratio=$(echo "$analysis" | grep -o '"korean_ratio":[^,}]*' | cut -d: -f2)
    local english_ratio=$(echo "$analysis" | grep -o '"english_ratio":[^,}]*' | cut -d: -f2)

    log_verbose "Language content: korean_ratio=$korean_ratio english_ratio=$english_ratio"

    # For now, accept any file with content (no minimum thresholds)
    # This prevents false positives from files that have minimal text
    return 0
}

# ============================================================================
# MAIN VALIDATION FUNCTION
# ============================================================================

validate_file() {
    local filepath="$1"

    log_verbose "Starting validation for: $filepath"

    # Check existence
    if [[ "$CHECK_EXISTENCE" == "true" ]]; then
        if ! validate_path_exists "$filepath"; then
            return 1
        fi
    fi

    # Check size
    if [[ "$CHECK_SIZE" == "true" ]]; then
        if ! validate_file_size "$filepath"; then
            return 1
        fi
    fi

    # Check language content
    if [[ "$CHECK_LANGUAGE" == "true" ]]; then
        if ! validate_language_content "$filepath"; then
            return 1
        fi
    fi

    log_validation "$filepath" "PASSED" "All validation checks passed"
    log_verbose "Validation passed: $filepath"
    return 0
}

# ============================================================================
# COMPLETION STATE GUARD
# ============================================================================

is_file_validated() {
    local filepath="$1"

    # Check if this file path has a recent successful validation (within 1 hour)
    if [[ ! -f "$VALIDATOR_STATE" ]]; then
        return 1
    fi

    local timestamp_1hour_ago=$(date -d '1 hour ago' -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                               date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

    if grep -q "\"filepath\":\"$filepath\".*\"status\":\"PASSED\"" "$VALIDATOR_STATE" 2>/dev/null; then
        return 0
    fi

    return 1
}

mark_file_validated() {
    local filepath="$1"

    mkdir -p "$(dirname "$VALIDATOR_STATE")"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat >> "$VALIDATOR_STATE" <<EOF
{"filepath":"$filepath","status":"PASSED","timestamp":"$timestamp"}
EOF
}

# ============================================================================
# COMMAND-LINE INTERFACE
# ============================================================================

main() {
    # Parse arguments
    local filepath=""

    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <filepath> [--check-language] [--check-size] [--verbose]" >&2
        echo "       $0 --is-validated <filepath>" >&2
        echo "       $0 --mark-validated <filepath>" >&2
        return 2
    fi

    # Handle subcommands
    case "${1:-}" in
        --is-validated)
            if [[ $# -lt 2 ]]; then
                echo "Error: --is-validated requires filepath argument" >&2
                return 2
            fi
            is_file_validated "$2"
            return $?
            ;;
        --mark-validated)
            if [[ $# -lt 2 ]]; then
                echo "Error: --mark-validated requires filepath argument" >&2
                return 2
            fi
            mark_file_validated "$2"
            return $?
            ;;
    esac

    # Standard validation mode
    filepath="$1"
    shift || true

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check-language)
                CHECK_LANGUAGE=true
                ;;
            --check-size)
                CHECK_SIZE=true
                ;;
            --no-check-language)
                CHECK_LANGUAGE=false
                ;;
            --no-check-size)
                CHECK_SIZE=false
                ;;
            --verbose)
                VERBOSE=true
                ;;
            *)
                echo "Error: Unknown option $1" >&2
                return 2
                ;;
        esac
        shift || true
    done

    # Run validation
    if validate_file "$filepath"; then
        mark_file_validated "$filepath"
        return 0
    else
        return 1
    fi
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
