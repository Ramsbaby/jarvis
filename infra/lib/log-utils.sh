#!/usr/bin/env bash
# log-utils.sh — Structured logging for Jarvis bash scripts
#
# Usage:
#   source "$BOT_HOME/lib/log-utils.sh"
#   log_info "Starting task"
#   log_warn "Retrying..."
#   log_error "Failed to parse JSON"
#   result=$(log_capture "jq parse" jq -r '.key' file.json)
#
# Environment:
#   LOG_LEVEL  — debug|info|warn|error (default: info)
#   LOG_FILE   — path to log file (default: stderr only)

LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"

_log_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_log_caller() {
    # Return the script name that called the log function
    local src="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-unknown}}"
    basename "$src" .sh
}

_log_level_num() {
    case "$1" in
        debug) echo 0 ;; info) echo 1 ;; warn) echo 2 ;; error) echo 3 ;; *) echo 1 ;;
    esac
}

_log_emit() {
    local level="$1"; shift
    local threshold
    threshold=$(_log_level_num "$LOG_LEVEL")
    local current
    current=$(_log_level_num "$level")
    (( current < threshold )) && return 0

    local upper
    upper=$(echo "$level" | tr '[:lower:]' '[:upper:]')
    local msg
    msg="[$(_log_ts)] ${upper} [$(_log_caller)] $*"

    # Always write warn/error to stderr
    if [[ "$level" == "warn" || "$level" == "error" ]]; then
        echo "$msg" >&2
    fi

    # Write to log file if configured
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    elif [[ "$level" != "warn" && "$level" != "error" ]]; then
        # info/debug without LOG_FILE → stderr
        echo "$msg" >&2
    fi
}

log_debug() { _log_emit debug "$@"; }
log_info()  { _log_emit info "$@"; }
log_warn()  { _log_emit warn "$@"; }
log_error() { _log_emit error "$@"; }

# compat alias — 기존 스크립트들이 log() 를 사용. log_info 로 라우팅.
log() { _log_emit info "$@"; }

# Run a command, capture stderr. If it fails, log the stderr as a warning.
# stdout passes through normally.
# Usage: result=$(log_capture "label" some_command args...)
log_capture() {
    local label="$1"; shift
    local stderr_tmp
    stderr_tmp=$(mktemp)
    "$@" 2>"$stderr_tmp"
    local rc=$?
    if [[ $rc -ne 0 && -s "$stderr_tmp" ]]; then
        log_warn "${label}: $(head -3 "$stderr_tmp" | tr '\n' ' ')"
    fi
    rm -f "$stderr_tmp"
    return $rc
}

# Quiet version: suppress stderr but log on failure (replaces 2>/dev/null pattern)
# Usage: qrun "label" command args...
qrun() {
    local label="$1"; shift
    local stderr_tmp
    stderr_tmp=$(mktemp)
    "$@" 2>"$stderr_tmp"
    local rc=$?
    if [[ $rc -ne 0 && -s "$stderr_tmp" ]]; then
        log_debug "${label}: exit=$rc $(head -1 "$stderr_tmp")"
    fi
    rm -f "$stderr_tmp"
    return $rc
}
