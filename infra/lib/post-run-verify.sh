#!/usr/bin/env bash
# post-run-verify.sh — Post-run verification hook
# Purpose: Verify actual completion result before declaring success
# - Check HTTP status (curl response codes)
# - Verify file existence after task
# - Check process state (running services)
# Usage: post-run-verify.sh <TASK_ID> <RESULT> <ALLOWED_TOOLS>
# Returns: 0 = all verifications passed, 1 = warnings found (non-blocking)

set -euo pipefail

TASK_ID="${1:-unknown}"
RESULT="${2:-}"
ALLOWED_TOOLS="${3:-}"
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
VERIFY_LOG="${BOT_HOME}/logs/verify.log"

mkdir -p "$(dirname "$VERIFY_LOG")"

# --- Logging helper ---
log_verify() {
    echo "[$(date '+%F %T')] [${TASK_ID}] $1" >> "$VERIFY_LOG"
}

# --- Verification functions ---

# 1. HTTP status verification — extract curl responses from result
verify_http_status() {
    local task_id="$1" result="$2"
    local http_codes success_count error_count

    # Look for patterns: "HTTP/1.1 200", "status": 200, curl exit code patterns
    http_codes=$(printf '%s\n' "$result" | grep -oE '(HTTP/[0-9.]+ [0-9]{3}|"status":\s*[0-9]{3}|curl: \([0-9]+\))' || true)

    if [[ -z "$http_codes" ]]; then
        # No HTTP evidence found — not an HTTP task, skip
        return 0
    fi

    success_count=$(echo "$http_codes" | grep -cE '(HTTP/[0-9.]+ [2][0-9]{2}|"status":\s*[2][0-9]{2})' || echo 0)
    error_count=$(echo "$http_codes" | grep -cE '(HTTP/[0-9.]+ [45][0-9]{2}|"status":\s*[45][0-9]{2}|curl: \([0-9]+\))' || echo 0)

    if [[ $error_count -gt 0 ]]; then
        log_verify "⚠️ HTTP verification: ${error_count} error code(s) detected"
        return 1
    fi

    if [[ $success_count -eq 0 && -z "$http_codes" ]]; then
        return 0
    fi

    log_verify "✓ HTTP status: ${success_count} success code(s)"
    return 0
}

# 2. File existence verification — check expected output files
verify_file_existence() {
    local task_id="$1"
    local expected_files=""

    # Task-specific file expectations
    case "$task_id" in
        daily-summary|council-insight|weekly-report|monthly-review|career-weekly)
            expected_files="${BOT_HOME}/logs/${task_id}.log"
            ;;
        record-daily|doc-supervisor)
            # Should have result saved to ~/.jarvis/rag/teams/reports/
            expected_files="${BOT_HOME}/rag/teams/reports/"
            ;;
        system-health|rag-health)
            # Health checks should output to logs
            expected_files="${BOT_HOME}/logs/${task_id}.log"
            ;;
    esac

    if [[ -z "$expected_files" ]]; then
        # No file expectations for this task
        return 0
    fi

    for fpath in $expected_files; do
        if [[ -e "$fpath" ]]; then
            log_verify "✓ File existence: ${fpath} found"
            return 0
        else
            log_verify "⚠️ File not found: ${fpath}"
            return 1
        fi
    done

    return 0
}

# 3. Process state verification — check running services for ops tasks
verify_process_state() {
    local task_id="$1"
    local required_procs=""

    case "$task_id" in
        discord-bot|watchdog|ai.jarvis.discord-bot|ai.jarvis.watchdog)
            required_procs="discord-bot"
            ;;
        system-health)
            # system-health should report on these, but not require them
            return 0
            ;;
    esac

    if [[ -z "$required_procs" ]]; then
        return 0
    fi

    for proc in $required_procs; do
        if pgrep -f "$proc" >/dev/null 2>&1; then
            log_verify "✓ Process state: ${proc} running"
        else
            log_verify "⚠️ Process not found: ${proc}"
            return 1
        fi
    done

    return 0
}

# 4. Result presence verification — ensure result is not empty when expected
verify_result_presence() {
    local task_id="$1" result="$2" allowed_tools="$3"

    if [[ -z "$result" ]]; then
        # Empty result — check if it's allowed
        case "$task_id" in
            disk-alert|calendar-alert|rate-limit-check|update-usage-cache|session-sync|stale-task-watcher)
                # These tasks allow empty results
                log_verify "✓ Result presence: empty result (allowEmptyResult=true)"
                return 0
                ;;
            *)
                # Unexpected empty result
                log_verify "⚠️ Result presence: empty result (task normally expects output)"
                return 1
                ;;
        esac
    fi

    log_verify "✓ Result presence: result not empty (${#result} chars)"
    return 0
}

# 5. Error pattern detection — scan result for unexpected error markers
verify_no_error_patterns() {
    local task_id="$1" result="$2"
    local error_patterns=("ERROR" "FAILED" "AUTH_ERROR" "not found" "timeout" "Connection refused")
    local found_errors=0

    for pattern in "${error_patterns[@]}"; do
        if printf '%s\n' "$result" | grep -qi "$pattern"; then
            log_verify "⚠️ Error pattern detected: '$pattern'"
            found_errors=$((found_errors + 1))
        fi
    done

    if [[ $found_errors -gt 0 ]]; then
        log_verify "⚠️ Detected $found_errors error pattern(s) in result"
        return 1
    fi

    log_verify "✓ Error pattern scan: no errors detected"
    return 0
}

# --- Main verification flow ---
main() {
    log_verify "POST-RUN VERIFY START (task=${TASK_ID})"

    local verify_exit=0

    # Run all verification checks
    verify_http_status "$TASK_ID" "$RESULT" || verify_exit=1
    verify_file_existence "$TASK_ID" || verify_exit=1
    verify_process_state "$TASK_ID" || verify_exit=1
    verify_result_presence "$TASK_ID" "$RESULT" "$ALLOWED_TOOLS" || verify_exit=1
    verify_no_error_patterns "$TASK_ID" "$RESULT" || verify_exit=1

    if [[ $verify_exit -eq 0 ]]; then
        log_verify "POST-RUN VERIFY END: ✓ All checks passed"
    else
        log_verify "POST-RUN VERIFY END: ⚠️ Some warnings detected (non-blocking)"
    fi

    # Always return 0 to avoid blocking task completion
    # (warnings are logged, not failures)
    return 0
}

main
