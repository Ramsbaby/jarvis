#!/usr/bin/env bash
# cron-monitoring-orchestrator.sh — Cron failure detection and monitoring orchestrator
#
# Handles two main command modes:
# 1. pipeline [auto]     — Full pipeline monitoring (delegates to cron-master.sh)
# 2. component [component_name] [auto] — Component-specific proactive_monitoring
#
# 2026-04-20 Restored: Replaced stub with functional orchestrator
# Routes cron tasks through bot-cron.sh pipeline with proper error logging

set -euo pipefail

# Environment setup
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_DIR="${BOT_HOME}/logs"
mkdir -p "$LOG_DIR"

# Script context
SCRIPT_NAME="$(basename "$0")"
LOGFILE="${LOG_DIR}/cron-monitoring-orchestrator.log"

# Logging helper
log_entry() {
    local level="$1" msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${SCRIPT_NAME}] [${level}] ${msg}" | tee -a "$LOGFILE"
}

log_entry "INFO" "START (PID=$$, args=$@)"

# Command routing
COMMAND="${1:-component}"
MODE="${2:-auto}"

case "${COMMAND}" in
    pipeline)
        # Full pipeline monitoring — delegates to cron-master.sh
        log_entry "INFO" "Mode: pipeline (${MODE})"
        if [[ -x "${BOT_HOME}/bin/cron-master.sh" ]]; then
            "${BOT_HOME}/bin/cron-master.sh" 2>&1 || {
                exit_code=$?
                log_entry "ERROR" "cron-master.sh exited with code ${exit_code}"
                exit "${exit_code}"
            }
            log_entry "INFO" "Pipeline monitoring completed successfully"
        else
            log_entry "ERROR" "cron-master.sh not found or not executable at ${BOT_HOME}/bin/cron-master.sh"
            exit 127
        fi
        ;;

    component|proactive_monitoring)
        # Component-specific proactive monitoring
        # Routes through cron-master.sh for comprehensive monitoring
        log_entry "INFO" "Mode: component/${COMMAND} (${MODE})"

        if [[ -x "${BOT_HOME}/bin/cron-master.sh" ]]; then
            "${BOT_HOME}/bin/cron-master.sh" 2>&1 || {
                exit_code=$?
                log_entry "ERROR" "cron-master.sh exited with code ${exit_code}"
                exit "${exit_code}"
            }
            log_entry "INFO" "Component monitoring task completed successfully"
        else
            log_entry "ERROR" "cron-master.sh not found or not executable at ${BOT_HOME}/bin/cron-master.sh"
            exit 127
        fi
        ;;

    *)
        log_entry "WARN" "Unknown command: '${COMMAND}'. Usage: ${SCRIPT_NAME} {pipeline|component|proactive_monitoring} [auto]"
        exit 1
        ;;
esac

log_entry "INFO" "DONE"
exit 0
