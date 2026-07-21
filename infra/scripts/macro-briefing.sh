#!/usr/bin/env bash
# macro-briefing.sh — 시장 매크로 분석 스크립트
# 이 스크립트는 Jarvis bot-cron.sh의 macro-briefing 태스크를 독립적으로 실행합니다.
# 일정: 월~금 23:30 KST (UTC 14:30)
# 실행: claude -p macro-briefing

# Early error handling
trap 'echo "[ERROR] Script failed at line $LINENO (exit: $?)" >&2' ERR

set -euo pipefail

# === Environment Setup ===
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

# Claude Max subscription mode — no API key needed
unset ANTHROPIC_API_KEY 2>/dev/null || true

# Batch mode optimization for cron tasks
export JARVIS_BATCH_MODE="${JARVIS_BATCH_MODE:-1}"

# Working directories - match bot-cron.sh path convention
# bot-cron.sh uses: BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
# Runtime data is stored in separate ~/jarvis/runtime by plugin-loader.sh
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
RUNTIME_HOME="${HOME}/jarvis/runtime"

# Use RUNTIME_HOME for logs when available, fallback to BOT_HOME
if [[ -d "$RUNTIME_HOME" ]]; then
    LOG_DIR="${RUNTIME_HOME}/logs"
else
    LOG_DIR="${BOT_HOME}/logs"
fi
RESULT_FILE="${LOG_DIR}/macro-briefing-result.json"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# === Functions ===

log() {
    local msg="$1"
    printf '[%s] [macro-briefing] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "${LOG_DIR}/macro-briefing.log"
}

error_exit() {
    local msg="$1"
    log "ERROR: $msg"
    exit 1
}

# === Dependency check ===
for cmd in claude jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "$cmd not found in PATH"
    fi
done

# === Task Execution ===

log "START"

# Load task configuration from multiple search paths
# Priority: BOT_HOME effective-tasks.json → BOT_HOME tasks.json → RUNTIME_HOME configs
TASKS_FILE=""
for candidate in \
    "${BOT_HOME}/config/effective-tasks.json" \
    "${BOT_HOME}/config/tasks.json" \
    "${RUNTIME_HOME}/config/effective-tasks.json" \
    "${RUNTIME_HOME}/config/tasks.json"; do
    if [[ -f "$candidate" ]]; then
        TASKS_FILE="$candidate"
        log "Using tasks file: $TASKS_FILE"
        break
    fi
done

if [[ -z "$TASKS_FILE" ]]; then
    error_exit "tasks.json not found in any config path"
fi

# Extract prompt and other settings from tasks.json
PROMPT=$(jq -r '.tasks[] | select(.id == "macro-briefing") | .prompt' "$TASKS_FILE" 2>/dev/null)
if [[ -z "$PROMPT" ]]; then
    error_exit "Failed to extract macro-briefing prompt from tasks.json"
fi

log "Executing claude with Bash,Read,Write tool support"

# Create temporary files
TMP_OUTPUT=$(mktemp) || error_exit "Failed to create temp output file"
trap "rm -f \"$TMP_OUTPUT\"" EXIT

# Execute Claude and capture output with timeout
log "Running: claude -p (prompt size: $(echo -n "$PROMPT" | wc -c) bytes)"

# Set 540s timeout (90% of 600s task timeout to allow cleanup)
CLAUDE_TIMEOUT=540

# Use gtimeout (GNU timeout) if available, fall back to timeout
TIMEOUT_CMD="timeout"
if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi

# Execute Claude with stdin for better special character handling
# Use printf to ensure proper encoding (no trailing newline issues with echo)
PROMPT_FILE=$(mktemp) || error_exit "Failed to create temp prompt file"
printf '%s' "$PROMPT" > "$PROMPT_FILE" || error_exit "Failed to write prompt to temp file"
trap "rm -f \"$PROMPT_FILE\" \"$TMP_OUTPUT\"" EXIT

if $TIMEOUT_CMD "$CLAUDE_TIMEOUT" claude -p < "$PROMPT_FILE" > "$TMP_OUTPUT" 2>&1; then
    log "Claude execution succeeded"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        log "Claude execution timeout (${CLAUDE_TIMEOUT}s exceeded)"
        error_exit "Claude timeout after ${CLAUDE_TIMEOUT}s"
    fi
    log "Claude execution failed with exit code $rc"
    if [[ -s "$TMP_OUTPUT" ]]; then
        log "Claude stderr/output (first 100 lines):"
        head -100 "$TMP_OUTPUT" | while IFS= read -r line; do
            log "  $line"
        done
    fi
    error_exit "Claude execution failed with exit code $rc"
fi

# Verify output is not empty
if [[ ! -s "$TMP_OUTPUT" ]]; then
    error_exit "Claude produced empty output"
fi

log "Claude output received ($(wc -c < "$TMP_OUTPUT" | tr -d ' ') bytes, $(wc -l < "$TMP_OUTPUT" | tr -d ' ') lines)"

# Log full output
cat "$TMP_OUTPUT" >> "${LOG_DIR}/macro-briefing.log" || log "WARN: Failed to append output to log file"

# Try to extract and validate JSON from output
JSON_SAVED=false
if jq '.' "$TMP_OUTPUT" >/dev/null 2>&1; then
    # Whole file is valid JSON
    cp "$TMP_OUTPUT" "$RESULT_FILE" && {
        log "Successfully saved JSON result to $RESULT_FILE"
        JSON_SAVED=true
    } || log "WARN: Failed to copy JSON result file"
else
    # Try to find JSON object in output
    if grep -q '{' "$TMP_OUTPUT"; then
        # Extract potential JSON line(s)
        while IFS= read -r line; do
            if echo "$line" | jq '.' >/dev/null 2>&1; then
                echo "$line" > "$RESULT_FILE" && {
                    log "Extracted and saved JSON result to $RESULT_FILE"
                    JSON_SAVED=true
                }
                break
            fi
        done < <(grep '{' "$TMP_OUTPUT")
    fi

    if [[ "$JSON_SAVED" == "false" ]]; then
        log "WARN: No valid JSON found in output, saving full output to result file"
        cp "$TMP_OUTPUT" "$RESULT_FILE" || log "WARN: Failed to save result file"
    fi
fi

log "SUCCESS"
exit 0
