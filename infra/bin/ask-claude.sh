#!/usr/bin/env bash
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/.local/share/jarvis}}/lib/compat.sh" 2>/dev/null || true
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

# --- Dependency check ---
for cmd in gtimeout claude jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH" >&2; exit 2; }
done

# --- Derived paths ---
WORK_DIR="/tmp/bot-work/${TASK_ID}-$$"
PID_FILE="${BOT_HOME}/state/pids/${TASK_ID}.pid"
CONTEXT_FILE="${BOT_HOME}/context/${TASK_ID}.md"
RESULTS_DIR="${BOT_HOME}/results/${TASK_ID}"
RESULT_FILE="${RESULTS_DIR}/$(date +%F_%H%M%S).md"
STDERR_LOG="${BOT_HOME}/logs/claude-stderr-${TASK_ID}.log"
# 실패 원인 추적을 위해 stderr를 날짜 포함 파일에도 누적 보존 (최근 7일)
STDERR_HIST="${BOT_HOME}/logs/claude-stderr-${TASK_ID}-$(date +%F).log"
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
    [[ -z "${CAFFEINATE_PID:-}" ]] || kill "${CAFFEINATE_PID}" 2>/dev/null || true
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

# Sleep prevention (double defense with launchd)
if $IS_MACOS; then
  caffeinate -i -w $$ &
  CAFFEINATE_PID=$!
fi

log_jsonl "start" "Task starting" "0"
START_TIME=$(date +%s)

# --- Build system prompt with context (sourced module) ---
source "${BOT_HOME}/lib/context-loader.sh"
load_context

# --- Board approval reactions removed (board system not included) ---

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

# --- Sourced modules: outcome instrumentation + insight recording ---
source "${BOT_HOME}/lib/insight-recorder.sh"

# --- Execute LLM call (claude -p with multi-provider fallback) ---
# Prevent nested claude detection (required for cron + Claude Code CLI sessions)
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
cd "$WORK_DIR"

# Source LLM Gateway (ADR-006)
source "${BOT_HOME}/lib/llm-gateway.sh"

CLAUDE_OUTPUT_TMP="${WORK_DIR}/claude-output.json"

CLAUDE_EXIT=0
# fd 9를 tee 프로세스에 연결 — 명시적 close/wait으로 race condition 방지
exec 9> >(tee -a "$STDERR_HIST" > "$STDERR_LOG")
run_with_retry llm_call \
    --prompt "$PROMPT" \
    --system "$SYSTEM_PROMPT" \
    --timeout "$TIMEOUT" \
    --allowed-tools "$ALLOWED_TOOLS" \
    --output "$CLAUDE_OUTPUT_TMP" \
    --work-dir "$WORK_DIR" \
    --mcp-config "${BOT_HOME}/config/empty-mcp.json" \
    ${MAX_BUDGET:+--max-budget "$MAX_BUDGET"} \
    ${MODEL:+--model "$MODEL"} \
    2>&9 || CLAUDE_EXIT=$?
exec 9>&-  # tee에 EOF 전송
# caffeinate 먼저 종료 (교착 방지: caffeinate -w $$ 는 스크립트 종료까지 대기하므로
# wait 호출 시 caffeinate ↔ wait 무한 교착 발생)
[[ -z "${CAFFEINATE_PID:-}" ]] || kill "${CAFFEINATE_PID}" 2>/dev/null || true
CAFFEINATE_PID=""
wait       # tee 완전 종료 대기 → stderr 유실 없음

RAW_OUTPUT=""
if [[ -s "$CLAUDE_OUTPUT_TMP" ]]; then RAW_OUTPUT=$(cat "$CLAUDE_OUTPUT_TMP"); fi

if [[ $CLAUDE_EXIT -ne 0 ]]; then
    END_TIME=$(date +%s)
    DURATION=$(( END_TIME - START_TIME ))
    # Save raw output even on error (for debugging)
    if [[ -s "$CLAUDE_OUTPUT_TMP" ]]; then
        cp "$CLAUDE_OUTPUT_TMP" "${RESULT_FILE%.md}-error.json"
    fi
    if [[ $CLAUDE_EXIT -eq 124 ]]; then
        log_jsonl "timeout" "Timed out after ${TIMEOUT}s" "$DURATION"
    else
        log_jsonl "error" "claude exited with code ${CLAUDE_EXIT}" "$DURATION"
    fi
    record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
    exit "$CLAUDE_EXIT"
fi

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

# --- Validate JSON and extract result ---
if ! echo "$RAW_OUTPUT" | jq -e '.' >/dev/null 2>&1; then
    log_jsonl "error" "Invalid JSON output from claude" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-raw.txt"
    record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
    exit 1
fi

# Check for error subtypes (e.g., error_max_budget_usd)
SUBTYPE=$(echo "$RAW_OUTPUT" | jq -r '.subtype // ""')
IS_ERROR=$(echo "$RAW_OUTPUT" | jq -r '.is_error // false')
if [[ "$SUBTYPE" == error_* ]] || [[ "$IS_ERROR" == "true" ]]; then
    log_jsonl "error" "claude error: ${SUBTYPE} is_error=${IS_ERROR}" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-error.json"
    record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
    # retry-wrapper.sh의 classify_error가 인증/rate-limit 오류를 감지할 수 있도록
    # result 필드를 stdout으로 출력 (빈 RESULT_TMP로 인한 UNKNOWN 분류 방지)
    echo "$RAW_OUTPUT" | jq -r '.result // ""' 2>/dev/null || true
    exit 1
fi

RESULT=$(echo "$RAW_OUTPUT" | jq -r '.result // empty')
if [[ -z "$RESULT" ]]; then
    log_jsonl "error" "Empty result from claude" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-raw.txt"
    record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
    exit 1
fi

# --- Extract cost and token usage ---
COST_USD=$(echo "$RAW_OUTPUT" | jq -r '.cost_usd // 0')
INPUT_TOKENS=$(echo "$RAW_OUTPUT" | jq -r '.usage.input_tokens // 0')
OUTPUT_TOKENS=$(echo "$RAW_OUTPUT" | jq -r '.usage.output_tokens // 0')
COST_EXTRA=$(printf '"cost_usd":%s,"input_tokens":%s,"output_tokens":%s' \
    "${COST_USD:-0}" "${INPUT_TOKENS:-0}" "${OUTPUT_TOKENS:-0}")

# --- Sanitize result: strip meta-text that pollutes future context ---
RESULT=$(printf '%s' "$RESULT" | sed '/^결과를 .*에 저장했습니다/d; /^Sources:$/,/^$/d')

# --- Save result (프롬프트 + 결과 — RAG 검색 품질 향상) ---
{
  printf '# Task: %s\nDate: %s\n\n## Prompt\n%s\n\n## Result\n%s\n' \
    "$TASK_ID" "$(date -u +%Y-%m-%d)" "$PROMPT" "$RESULT"
} > "$RESULT_FILE"

# --- Auto-insights: 결과에서 인사이트 추출 후 Vault에 저장 ---
record_insight "$TASK_ID" "$RESULT" || true

# --- Rotate old results (keep 7 days) ---
find "$RESULTS_DIR" -name "*.md" -mtime +"$RESULT_RETENTION" -delete 2>/dev/null || true

# --- Rotate old stderr history logs (keep 7 days) ---
find "${BOT_HOME}/logs" -name "claude-stderr-${TASK_ID}-*.log" -mtime +7 -delete 2>/dev/null || true

# --- Update rate-tracker (shared with Discord bot, 5-hour sliding window) ---
RATE_TRACKER="${BOT_HOME}/state/rate-tracker.json"
RATE_PATH="$RATE_TRACKER" python3 -c "
import json, time, fcntl, os, tempfile
path = os.environ['RATE_PATH']
cutoff = int(time.time() * 1000) - 5 * 3600 * 1000
now_ms = int(time.time() * 1000)
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        data = json.load(f)
        if not isinstance(data, list): data = []
        data = [t for t in data if t > cutoff]
        data.append(now_ms)
        # Atomic write: temp file + rename (POSIX atomic on same filesystem)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
        with os.fdopen(fd, 'w') as tf:
            json.dump(data, tf)
        os.replace(tmp, path)
except (FileNotFoundError, json.JSONDecodeError):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
    with os.fdopen(fd, 'w') as tf:
        json.dump([now_ms], tf)
    os.replace(tmp, path)
" 2>/dev/null || true

log_jsonl "success" "Completed in ${DURATION}s" "$DURATION" "$COST_EXTRA"
record_outcome "$TASK_ID" "true" "$(( DURATION * 1000 ))" "${COST_USD:-0}" || true

# --- Mark board reactions as processed ---
if [[ -n "${_board_pending_json:-}" ]]; then
    board_mark_reactions_processed "$_board_pending_json" || true
    log_jsonl "info" "Board reactions marked as processed" "0"
fi

# --- Output result to stdout ---
echo "$RESULT"
