#!/usr/bin/env bash
# macro-briefing.sh — 시장 매크로 분석 스크립트
# 이 스크립트는 Jarvis bot-cron.sh의 macro-briefing 태스크를 독립적으로 실행합니다.
# 일정: 월~금 23:30 KST (UTC 14:30)
# 실행: ./macro-briefing.sh

set -euo pipefail

# === Environment Setup ===
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

# Claude Max subscription mode
unset ANTHROPIC_API_KEY 2>/dev/null || true

# Batch mode for cron tasks
export JARVIS_BATCH_MODE="${JARVIS_BATCH_MODE:-1}"

# Working directories
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
RUNTIME_HOME="${HOME}/.openclaw-data/jarvis/runtime"

# Use RUNTIME_HOME for logs when available
if [[ -d "$RUNTIME_HOME" ]]; then
    LOG_DIR="${RUNTIME_HOME}/logs"
    BOT_HOME="${RUNTIME_HOME}"
    export BOT_HOME
else
    LOG_DIR="${BOT_HOME}/logs"
fi

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
for cmd in jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "$cmd not found in PATH"
    fi
done

ASK_CLAUDE_SCRIPT="${HOME}/.openclaw-data/jarvis/infra/bin/ask-claude.sh"
[[ -f "$ASK_CLAUDE_SCRIPT" ]] || error_exit "ask-claude.sh not found at $ASK_CLAUDE_SCRIPT"

# === Task Execution ===

log "START"

# Load task configuration
TASKS_FILE=""
for candidate in \
    "${BOT_HOME}/config/effective-tasks.json" \
    "${BOT_HOME}/config/tasks.json"; do
    if [[ -f "$candidate" ]]; then
        TASKS_FILE="$candidate"
        log "Using tasks file: $TASKS_FILE"
        break
    fi
done

[[ -n "$TASKS_FILE" ]] || error_exit "tasks.json not found"

# Extract task parameters
PROMPT=$(jq -r '.tasks[] | select(.id == "macro-briefing") | .prompt' "$TASKS_FILE" 2>/dev/null)
[[ -n "$PROMPT" ]] || error_exit "No prompt found for macro-briefing"

ALLOWED_TOOLS=$(jq -r '.tasks[] | select(.id == "macro-briefing") | .allowedTools // "Read"' "$TASKS_FILE" 2>/dev/null)
MAX_BUDGET=$(jq -r '.tasks[] | select(.id == "macro-briefing") | .maxBudget // ""' "$TASKS_FILE" 2>/dev/null)
MODEL=$(jq -r '.tasks[] | select(.id == "macro-briefing") | .model // ""' "$TASKS_FILE" 2>/dev/null)

log "Executing macro-briefing via ask-claude.sh"
log "Task: macro-briefing | Tools: $ALLOWED_TOOLS | Model: $MODEL | Budget: $MAX_BUDGET"
log "ASK_CLAUDE_SCRIPT: $ASK_CLAUDE_SCRIPT"
log "Prompt length: ${#PROMPT} chars"

# Debug: write args to temp file for inspection
DEBUG_ARGS="/tmp/macro-briefing-args-debug-$$.txt"
cat > "$DEBUG_ARGS" << 'EOF'
Task ID: macro-briefing
ALLOWED_TOOLS:
EOF
echo "$ALLOWED_TOOLS" >> "$DEBUG_ARGS"
cat >> "$DEBUG_ARGS" << 'EOF'
TIMEOUT: 600
MAX_BUDGET:
EOF
echo "$MAX_BUDGET" >> "$DEBUG_ARGS"
cat >> "$DEBUG_ARGS" << 'EOF'
RESULT_RETENTION: 7
MODEL:
EOF
echo "$MODEL" >> "$DEBUG_ARGS"
log "Debug args saved to: $DEBUG_ARGS"

# Call ask-claude.sh with task parameters (with retry)
# Usage: ask-claude.sh TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET] [RESULT_RETENTION] [MODEL]
log "Starting ask-claude.sh call..."
log "Environment: BOT_HOME=$BOT_HOME, PATH=$PATH"
log "ASK_CLAUDE_SCRIPT exists: $(test -f "$ASK_CLAUDE_SCRIPT" && echo yes || echo no)"
log "ASK_CLAUDE_SCRIPT executable: $(test -x "$ASK_CLAUDE_SCRIPT" && echo yes || echo no)"
MAX_RETRIES=3
RETRY_COUNT=0
while (( RETRY_COUNT < MAX_RETRIES )); do
    if BOT_HOME="$BOT_HOME" "$ASK_CLAUDE_SCRIPT" "macro-briefing" "$PROMPT" "$ALLOWED_TOOLS" "600" "$MAX_BUDGET" "7" "$MODEL" >> "${LOG_DIR}/macro-briefing.log" 2>&1; then
        log "ask-claude.sh completed successfully"
        break
    else
        EXIT_CODE=$?
        (( RETRY_COUNT++ ))
        if (( RETRY_COUNT < MAX_RETRIES )); then
            log "ask-claude.sh failed (attempt $RETRY_COUNT/$MAX_RETRIES), retrying in 10s..."
            sleep 10
        else
            log "ask-claude.sh failed after $MAX_RETRIES attempts with exit code $EXIT_CODE"
            # Results may still be saved even on evaluator failure - continue instead of exiting
            log "Proceeding despite ask-claude.sh failure (results may be available)"
        fi
    fi
done

# Results are automatically saved to ${BOT_HOME}/results/macro-briefing/ by ask-claude.sh
log "SUCCESS"
exit 0
