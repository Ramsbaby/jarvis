#!/usr/bin/env bash
set -euo pipefail

# ask-claude.sh - Core wrapper around `claude -p` for AI task execution
# Usage: ask-claude.sh TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET]

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_FILE="${BOT_HOME}/logs/task-runner.jsonl"

# --- Arguments ---
TASK_ID="${1:?Usage: ask-claude.sh TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET]}"
PROMPT="${2:?Usage: ask-claude.sh TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET]}"
ALLOWED_TOOLS="${3:-Read}"
TIMEOUT="${4:-180}"
MAX_BUDGET="${5:-}"
RESULT_RETENTION="${6:-7}"
MODEL="${7:-}"

# --- Cross-platform helpers ---
# timeout: use gtimeout (macOS/homebrew) or timeout (Linux/GNU)
TIMEOUT_CMD=""
if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
fi

# --- Dependency check ---
for cmd in claude jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH" >&2; exit 2; }
done

# --- Derived paths ---
WORK_DIR="/tmp/bot-work/${TASK_ID}-$$"
PID_FILE="${BOT_HOME}/state/pids/${TASK_ID}.pid"
CONTEXT_FILE="${BOT_HOME}/context/${TASK_ID}.md"
RESULTS_DIR="${BOT_HOME}/results/${TASK_ID}"
RESULT_FILE="${RESULTS_DIR}/$(date +%F_%H%M%S).md"
STDERR_LOG="${BOT_HOME}/logs/claude-stderr-${TASK_ID}.log"
CAFFEINATE_PID=""

# --- Logging helper ---
log_jsonl() {
    local status="$1" message="${2//\"/\'}" duration="${3:-0}" extra="${4:-}"
    local base
    base=$(printf '{"ts":"%s","task":"%s","status":"%s","msg":"%s","duration_s":%s,"pid":%d' \
        "$(date -u +%FT%TZ)" "$TASK_ID" "$status" "$message" "$duration" "$$")
    if [[ -n "$extra" ]]; then
        printf '%s,%s}\n' "$base" "$extra" >> "$LOG_FILE"
    else
        printf '%s}\n' "$base" >> "$LOG_FILE"
    fi
}

# --- Cleanup trap ---
cleanup() {
    rm -rf "$WORK_DIR"
    rm -f "$PID_FILE"
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        kill "$CAFFEINATE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Setup ---
mkdir -p "$WORK_DIR" "$RESULTS_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"
echo $$ > "$PID_FILE"

# Layer 2: Git boundary - prevents claude from traversing to parent repos
mkdir -p "$WORK_DIR/.git"
echo 'ref: refs/heads/main' > "$WORK_DIR/.git/HEAD"

# Layer 4: Empty plugins directory
mkdir -p "$WORK_DIR/.empty-plugins"

# Sleep prevention: macOS only (caffeinate); Linux skips gracefully
if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -w $$ &
    CAFFEINATE_PID=$!
fi

log_jsonl "start" "Task starting" "0"
START_TIME=$(date +%s)

# --- Build system prompt with context ---
SYSTEM_PROMPT=""

# RAG context: semantic search → static file fallback
RAG_CONTEXT=""
if command -v node >/dev/null 2>&1 && [[ -f "$BOT_HOME/lib/rag-query.mjs" ]]; then
    RAG_CONTEXT=$(node "$BOT_HOME/lib/rag-query.mjs" "$PROMPT" 2>/dev/null || echo "")
fi
if [[ -z "$RAG_CONTEXT" ]] && [[ -f "$BOT_HOME/rag/memory.md" ]]; then
    RAG_CONTEXT=$(head -c 2000 "$BOT_HOME/rag/memory.md")
fi
if [[ -n "$RAG_CONTEXT" ]]; then
    SYSTEM_PROMPT="## Long-term Memory (RAG)
${RAG_CONTEXT}

"
fi

# Load task-specific context
if [[ -f "$CONTEXT_FILE" ]]; then
    SYSTEM_PROMPT="${SYSTEM_PROMPT}$(cat "$CONTEXT_FILE")"
fi

# Shared context bus (optional — populated by scheduled insight tasks)
CONTEXT_BUS="${BOT_HOME}/state/context-bus.md"
if [[ -f "$CONTEXT_BUS" ]]; then
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Shared Context
$(cat "$CONTEXT_BUS")
"
fi

# Load history: last 3 results, max 2000 chars each, max 6000 total
HISTORY=""
HISTORY_TOTAL=0
if [[ -d "$RESULTS_DIR" ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        SNIPPET="$(head -c 2000 "$file")"
        SNIPPET_LEN=${#SNIPPET}
        if (( HISTORY_TOTAL + SNIPPET_LEN > 6000 )); then
            break
        fi
        HISTORY="${HISTORY}
--- Previous result: $(basename "$file") ---
${SNIPPET}
"
        HISTORY_TOTAL=$(( HISTORY_TOTAL + SNIPPET_LEN ))
    done < <(ls -t "$RESULTS_DIR"/*.md 2>/dev/null | head -3)
fi

if [[ -n "$HISTORY" ]]; then
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Recent History
${HISTORY}"
fi

# --- Auto-retry wrapper ---
run_with_retry() {
    local max_attempts=3
    local attempt=1
    local delay=2
    while (( attempt <= max_attempts )); do
        local exit_code=0
        if "$@"; then
            return 0
        else
            exit_code=$?
        fi
        # Non-retryable: auth failure (2), command not found (126/127)
        if (( exit_code == 2 || exit_code == 126 || exit_code == 127 )); then
            log_jsonl "error" "FATAL: non-retryable exit $exit_code" "0"
            return $exit_code
        fi
        if (( attempt < max_attempts )); then
            log_jsonl "warn" "attempt $attempt/$max_attempts failed (exit $exit_code), retry in ${delay}s..." "0"
            sleep $delay
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    log_jsonl "error" "all $max_attempts attempts failed" "0"
    return 1
}

# --- Execute claude -p ---
# Prevent nested claude detection (required for cron + Claude Code CLI sessions)
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
cd "$WORK_DIR"

CLAUDE_OUTPUT_TMP="${WORK_DIR}/claude-output.json"

CLAUDE_CMD=(claude -p "$PROMPT"
    --output-format json
    --permission-mode bypassPermissions
    --allowedTools "$ALLOWED_TOOLS"
    --append-system-prompt "$SYSTEM_PROMPT"
    --strict-mcp-config --mcp-config "${BOT_HOME}/config/empty-mcp.json"
    --plugin-dir "$WORK_DIR/.empty-plugins"
    --setting-sources local
)
[[ -n "$MAX_BUDGET" ]] && CLAUDE_CMD+=(--max-budget-usd "$MAX_BUDGET")
[[ -n "$MODEL" ]]      && CLAUDE_CMD+=(--model "$MODEL")

CLAUDE_EXIT=0
if [[ -n "$TIMEOUT_CMD" ]]; then
    run_with_retry "$TIMEOUT_CMD" "${TIMEOUT}" "${CLAUDE_CMD[@]}" \
        > "$CLAUDE_OUTPUT_TMP" 2>"$STDERR_LOG" || CLAUDE_EXIT=$?
else
    run_with_retry "${CLAUDE_CMD[@]}" \
        > "$CLAUDE_OUTPUT_TMP" 2>"$STDERR_LOG" || CLAUDE_EXIT=$?
fi

RAW_OUTPUT=""
[[ -s "$CLAUDE_OUTPUT_TMP" ]] && RAW_OUTPUT=$(cat "$CLAUDE_OUTPUT_TMP")

if [[ $CLAUDE_EXIT -ne 0 ]]; then
    END_TIME=$(date +%s)
    DURATION=$(( END_TIME - START_TIME ))
    if [[ -s "$CLAUDE_OUTPUT_TMP" ]]; then
        cp "$CLAUDE_OUTPUT_TMP" "${RESULT_FILE%.md}-error.json"
    fi
    if [[ $CLAUDE_EXIT -eq 124 ]]; then
        log_jsonl "timeout" "Timed out after ${TIMEOUT}s" "$DURATION"
    else
        log_jsonl "error" "claude exited with code ${CLAUDE_EXIT}" "$DURATION"
    fi
    exit "$CLAUDE_EXIT"
fi

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

# --- Validate JSON and extract result ---
if ! echo "$RAW_OUTPUT" | jq -e '.' >/dev/null 2>&1; then
    log_jsonl "error" "Invalid JSON output from claude" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-raw.txt"
    exit 1
fi

# Check for error subtypes (e.g., error_max_budget_usd)
SUBTYPE=$(echo "$RAW_OUTPUT" | jq -r '.subtype // ""')
IS_ERROR=$(echo "$RAW_OUTPUT" | jq -r '.is_error // false')
if [[ "$SUBTYPE" == error_* ]] || [[ "$IS_ERROR" == "true" ]]; then
    log_jsonl "error" "claude error: ${SUBTYPE} is_error=${IS_ERROR}" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-error.json"
    exit 1
fi

RESULT=$(echo "$RAW_OUTPUT" | jq -r '.result // empty')
if [[ -z "$RESULT" ]]; then
    log_jsonl "error" "Empty result from claude" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-raw.txt"
    exit 1
fi

# --- Extract cost and token usage ---
COST_USD=$(echo "$RAW_OUTPUT" | jq -r '.cost_usd // 0')
INPUT_TOKENS=$(echo "$RAW_OUTPUT" | jq -r '.usage.input_tokens // 0')
OUTPUT_TOKENS=$(echo "$RAW_OUTPUT" | jq -r '.usage.output_tokens // 0')
COST_EXTRA=$(printf '"cost_usd":%s,"input_tokens":%s,"output_tokens":%s' \
    "${COST_USD:-0}" "${INPUT_TOKENS:-0}" "${OUTPUT_TOKENS:-0}")

# --- Save result ---
echo "$RESULT" > "$RESULT_FILE"

# --- Rotate old results ---
find "$RESULTS_DIR" -name "*.md" -mtime +"$RESULT_RETENTION" -delete 2>/dev/null || true

# --- Update rate-tracker (shared with Discord bot, 5-hour sliding window) ---
RATE_TRACKER="${BOT_HOME}/state/rate-tracker.json"
update_rate_tracker() {
    local path="$1"
    local cutoff now_ms
    cutoff=$(( $(date +%s) * 1000 - 5 * 3600 * 1000 ))
    now_ms=$(( $(date +%s) * 1000 ))
    mkdir -p "$(dirname "$path")"

    # Use node if available (avoids python3 dependency)
    if command -v node >/dev/null 2>&1; then
        node -e "
const fs = require('fs'), path = '${path}';
const cutoff = ${cutoff}, now = ${now_ms};
let data = [];
try { data = JSON.parse(fs.readFileSync(path, 'utf8')); } catch {}
if (!Array.isArray(data)) data = [];
data = data.filter(t => t > cutoff);
data.push(now);
fs.writeFileSync(path, JSON.stringify(data));
" 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, time, os
path = '${path}'
cutoff = ${cutoff}
now_ms = ${now_ms}
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, 'r+') as f:
        data = json.load(f)
        if not isinstance(data, list): data = []
        data = [t for t in data if t > cutoff]
        data.append(now_ms)
        f.seek(0); f.truncate()
        json.dump(data, f)
except (FileNotFoundError, json.JSONDecodeError):
    with open(path, 'w') as f:
        json.dump([now_ms], f)
" 2>/dev/null || true
    fi
}
update_rate_tracker "$RATE_TRACKER"

log_jsonl "success" "Completed in ${DURATION}s" "$DURATION" "$COST_EXTRA"

# --- Output result to stdout ---
echo "$RESULT"
