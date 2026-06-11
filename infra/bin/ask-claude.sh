#!/usr/bin/env bash
# 조기 종료 진단: set -e 이전에 invocation 기록 (exit 0 + 빈 출력 재발 시 추적용)
# task-runner.jsonl에 "start" 항목이 없는데 이 파일에 기록이 있으면 set -e 트리거 확인 필요

# --- HOME 보증 (cron에서 HOME 누락 가능성) ---
export HOME="${HOME:-$(eval echo ~$(whoami))}"

_EARLY_LOG="${BOT_HOME:-${HOME}/jarvis/runtime}/logs/ask-claude-invocations.log"
printf '[%s] PID=%d TASK=%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" "$$" "${1:-?}" >> "$_EARLY_LOG" 2>/dev/null || true
unset _EARLY_LOG
# --- PATH 강화 (cron 환경에서 경로 누락 방지) ---
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}/lib/compat.sh" 2>/dev/null || true
set -euo pipefail

# ask-claude.sh - Core wrapper around `claude -p` for AI task execution
# Usage: ask-claude.sh TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET]

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_FILE="${BOT_HOME}/logs/task-runner.jsonl"

# --- Batch mode (토큰 절감) ---
# === 배치 모드 vs 대화형 모드 ===
#
# [배치 모드 (JARVIS_BATCH_MODE=1, 기본값)]
#   - claude -p CLI에 --disable-slash-commands, --no-session-persistence 플래그 추가
#   - 효과: 세션 파일 (~/.cache/claude-cli/sessions/)에 저장 안 함
#           → 메모리 누적 방지, 토큰 절감 (매 호출마다 깔끔한 새 세션)
#   - 부작용: /file, /read 등 슬래시 명령 불가능 → 대신 전체 파일 내용을 프롬프트에 포함
#   - 용도: 크론 태스크, batch 스크립트 (ask-claude.sh의 기본값)
#
# [대화형 모드 (JARVIS_BATCH_MODE=0)]
#   - claude -p CLI가 세션 파일을 사용하여 컨텍스트 유지
#   - 효과: 동일 사용자/채널이 연속 호출 시 마지막 대화 기억
#   - 문제점: tokenCount 누적 위험 (위의 세션 좀비 청소 메커니즘 필요)
#   - 용도: Discord 봇의 messageCreate (단일 스레드 대화)
#
# [주의사항]
#   ❌ "배치 모드면 항상 비용이 적다" → 틀림
#   ✓ 옳은 것: "배치 모드는 세션 누적을 방지하므로 예측 가능한 비용"
#             "대화형 모드는 컨텍스트가 계속 커져서 후반부 호출이 비쌈"
#
# ask-claude.sh는 크론/배치 태스크 전용 진입점이므로 기본값 1.
# llm-gateway.sh의 _llm_claude_cli가 이 값을 보고 claude -p에 다음 플래그 추가:
#   --disable-slash-commands, --no-session-persistence,
#   --setting-sources ""
# NOTE: --exclude-dynamic-system-prompt-sections는 2026-05-15에 제거됨 (Claude CLI 미지원)
# 호출자가 대화형 용도로 전환하고 싶으면 JARVIS_BATCH_MODE=0 명시 export.
export JARVIS_BATCH_MODE="${JARVIS_BATCH_MODE:-1}"

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
trap cleanup EXIT INT TERM HUP

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

# --- Circuit breaker (Phase 3, 2026-05-23): OAuth race + 연속 실패 방어 ---
# 출처: 2026-05-23 새벽 9건 LA가 OAuth 회전 race로 동시에 invalid_grant → recovery 4단계 모두 실패.
# 차단 시 호출 자체 skip (exit 99) → 호출자가 graceful 처리 가능.
source "${BOT_HOME}/lib/circuit-ask-claude.sh" 2>/dev/null || true

# --- Execute LLM call (claude -p with multi-provider fallback) ---
# Prevent nested claude detection (but preserve CLAUDECODE for OAuth credential inheritance)
# NOTE: Unsetting CLAUDECODE breaks OAuth authentication in cron environments
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
cd "$WORK_DIR"

# Source LLM Gateway (ADR-006)
source "${BOT_HOME}/lib/llm-gateway.sh"

# --- Model routing integration (ADR-011: Multi-model orchestration) ---
# 비핵심 태스크를 Gemini 3.5 Flash로 라우팅하여 비용 절감
source "${BOT_HOME}/lib/model-routing-integration.sh" 2>/dev/null || true
ROUTED_MODEL=$(select_model_for_task "$TASK_ID" "$MODEL" "${ALLOWED_TOOLS:-}" 2>/dev/null || echo "$MODEL")
if [[ -n "$ROUTED_MODEL" && "$ROUTED_MODEL" != "$MODEL" ]]; then
    log_jsonl "info" "Model routing: $MODEL → $ROUTED_MODEL (task=$TASK_ID)" "0"
    MODEL="$ROUTED_MODEL"
    export ROUTED_MODEL_SOURCE="ask-claude.sh"
fi

CLAUDE_OUTPUT_TMP="${WORK_DIR}/claude-output.json"

# --- Circuit check (Phase 3): open 상태면 claude 호출 자체 skip ---
if command -v circuit_check >/dev/null 2>&1; then
    if ! circuit_check "$TASK_ID"; then
        log_jsonl "skip" "circuit open — claude call skipped" "0"
        record_outcome "$TASK_ID" "false" "0" "0" 2>/dev/null || true
        exit 99
    fi
fi

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
    --mcp-config "${JARVIS_MCP_CONFIG:-${BOT_HOME}/config/empty-mcp.json}" \
    ${MAX_BUDGET:+--max-budget "$MAX_BUDGET"} \
    ${MODEL:+--model "$MODEL"} \
    2>&9 || CLAUDE_EXIT=$?
exec 9>&-  # tee에 EOF 전송
# caffeinate 먼저 종료 (교착 방지: caffeinate -w $$ 는 스크립트 종료까지 대기하므로
# wait 호출 시 caffeinate ↔ wait 무한 교착 발생)
[[ -z "${CAFFEINATE_PID:-}" ]] || kill "${CAFFEINATE_PID}" 2>/dev/null || true
CAFFEINATE_PID=""
wait       # tee 완전 종료 대기 → stderr 유실 없음

# --- Circuit update (Phase 3): 결과 반영 (성공 = closed 복귀 / 실패 = open 차단) ---
if command -v circuit_update >/dev/null 2>&1; then
    STDERR_SAMPLE=$(tail -20 "$STDERR_LOG" 2>/dev/null | head -c 2000 || true)
    circuit_update "$TASK_ID" "$CLAUDE_EXIT" "$STDERR_SAMPLE" 2>/dev/null || true
fi

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

    # Sprint Contract #1: Rate limit 에러 명확히 감지 및 전파
    # SUBTYPE: error_rate_limit_exceeded, error_overloaded 등을 stderr에 명시
    if [[ "$SUBTYPE" == *"rate_limit"* ]] || [[ "$SUBTYPE" == *"overload"* ]]; then
        printf '[%s] RATE_LIMIT_ERROR: subtype=%s\n' "$(date '+%F %H:%M:%S')" "$SUBTYPE" >&2
        # Record rate limit detection for circuit-breaker and graceful degradation
        _RATE_LIMIT_MARKER="${BOT_HOME}/state/rate-limit-detected.json"
        mkdir -p "$(dirname "$_RATE_LIMIT_MARKER")"
        jq -cn --arg ts "$(date -u +%FT%TZ)" --arg task "$TASK_ID" --arg subtype "$SUBTYPE" \
            '{timestamp: $ts, task: $task, subtype: $subtype, attempts: 1}' > "$_RATE_LIMIT_MARKER" 2>/dev/null || true
    fi

    # retry-wrapper.sh의 classify_error가 인증/rate-limit 오류를 감지할 수 있도록
    # result 필드를 stdout으로 출력 (빈 RESULT_TMP로 인한 UNKNOWN 분류 방지)
    _error_msg=$(echo "$RAW_OUTPUT" | jq -r '.result // ""' 2>/dev/null || true)
    if [[ -n "$_error_msg" ]]; then
        echo "$_error_msg"
    fi
    # Subtype도 stderr로 출력 (continue-sites.sh가 감지 용이)
    printf '[SUBTYPE] %s\n' "$SUBTYPE" >&2
    exit 1
fi

RESULT=$(echo "$RAW_OUTPUT" | jq -r '.result // empty')
if [[ -z "$RESULT" ]]; then
    log_jsonl "error" "Empty result from claude" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-raw.txt"
    record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
    exit 1
fi

# --- Tier 1: 독립 평가자 (evaluator.sh) ---
# pass=통과 / warn=통과하지만 ledger에 경고 기록 / fail=재시도 또는 실패 처리
EVALUATOR_VERDICT="pass"
EVALUATOR_REASON=""
EVALUATOR_LIB="${BOT_HOME}/lib/evaluator.sh"
if [[ -f "$EVALUATOR_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$EVALUATOR_LIB"
    evaluate_result "$TASK_ID" "$RESULT" "$PROMPT" || true
    if [[ "$EVALUATOR_VERDICT" == "fail" ]]; then
        log_jsonl "error" "evaluator_fail: ${EVALUATOR_REASON}" "$DURATION"
        echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-evaluator-fail.json"
        record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
        # stdout으로 에러 메시지 (retry-wrapper가 분류에 사용)
        echo "EVALUATOR_FAIL: ${EVALUATOR_REASON}"
        exit 1
    elif [[ "$EVALUATOR_VERDICT" == "warn" ]]; then
        log_jsonl "warn" "evaluator_warn: ${EVALUATOR_REASON}" "$DURATION"
    fi
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

# --- Agent Self-Note hook (Dreaming) ---
# 태스크 성공 완료 후 에이전트가 패턴/실수/제안을 ~/jarvis/runtime/agent-notes/에 저장.
# 다음 세션의 context-loader.sh가 read-agent-note.sh로 주입하여 반복 실수 감소.
# TODO: AGENT_NOTE_JSON 변수는 각 태스크별 에이전트 스크립트에서 export하면
#       자동으로 이 훅이 노트를 저장함. 미설정 시 silently skip.
_AGENT_NOTE_WRITER="${BOT_HOME}/lib/write-agent-note.sh"
if [[ -n "${AGENT_NOTE_JSON:-}" && -f "$_AGENT_NOTE_WRITER" ]]; then
    _AGENT_ROLE="${AGENT_ROLE:-ask-claude}"
    bash "$_AGENT_NOTE_WRITER" "$TASK_ID" "$_AGENT_ROLE" "$AGENT_NOTE_JSON" 2>/dev/null || true
fi

# --- Token ledger (Tier 0 observability) ---
# === 토큰 레져 개념 정리 ===
#
# [토큰 레져 (Token Ledger)]
#   - 파일: ~/jarvis/runtime/state/token-ledger.jsonl
#   - 목적: 모든 LLM 호출의 "Single Source of Truth" (SSoT) 레져
#   - 형식: 라인 단위 JSON (JSONL), 각 호출마다 1라인 추가
#   - 용도:
#     1. 일일 $50 한도 체크 (downstream: daily-cap.sh)
#     2. 80% 경고 알림 (supervisor 체크)
#     3. 중복 호출 감지 (result_hash로 멱등성 확인)
#     4. 비용 분석 (task별, model별 집계)
#
# [입력 토큰 vs 출력 토큰 vs 비용]
#   - input_tokens: 프롬프트에 포함된 토큰 수
#     (예: 10KB 문서 = ~2,500 input tokens)
#   - output_tokens: 모델이 생성한 응답 토큰 수
#     (예: 1KB 응답 = ~250 output tokens)
#   - cost_usd: 실제 청구액
#     Claude Opus: $0.003/1M input + $0.015/1M output
#     예) 1000 input + 500 output = ($0.003 + $0.0075) = $0.0105 정도
#
# [세션 토큰 카운트 vs 토큰 레져의 차이점]
#   ❌ 혼동: "토큰 레져의 input+output = sessionStore의 tokenCount"
#   ✓ 정확: sessionStore.addTokens(threadId, input+output)를 호출하여
#          별도로 누적 추적. 둘은 동시에 업데이트되지만 목적이 다름:
#     - sessionStore.tokenCount: 세션별 메모리 폭발 감지 (7일+5000 임계)
#     - token-ledger: 비용 추적 (일일 한도, 알림)
#
# [레져 기록 주기]
#   - 매 ask-claude.sh 호출 후 즉시 1라인 추가
#   - 크론 태스크마다 기록되므로 매 시간 수십~수백 줄 추가 가능
#   - 7일 보관 후 자동 rotation (downstream: archive-ledger.sh)
#
# SSoT ledger for all LLM spending. Downstream: daily cap, 80% alert, dedup detection.
LEDGER_FILE="${BOT_HOME}/state/token-ledger.jsonl"
mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || true
LEDGER_RESULT_BYTES=$(wc -c < "$RESULT_FILE" 2>/dev/null | tr -d ' ' || echo 0)
LEDGER_RESULT_HASH=$(shasum -a 256 "$RESULT_FILE" 2>/dev/null | cut -c1-16 || echo "")
LEDGER_MODEL="${MODEL:-default}"
jq -cn --arg ts "$(date -u +%FT%TZ)" \
       --arg task "$TASK_ID" \
       --arg model "$LEDGER_MODEL" \
       --arg status "success" \
       --arg result_hash "$LEDGER_RESULT_HASH" \
       --argjson input "${INPUT_TOKENS:-0}" \
       --argjson output "${OUTPUT_TOKENS:-0}" \
       --argjson cost_usd "${COST_USD:-0}" \
       --argjson duration_ms "$(( DURATION * 1000 ))" \
       --argjson result_bytes "${LEDGER_RESULT_BYTES:-0}" \
       --argjson max_budget_usd "${MAX_BUDGET:-0}" \
       '{ts:$ts, task:$task, model:$model, status:$status, input:$input, output:$output, cost_usd:$cost_usd, duration_ms:$duration_ms, result_bytes:$result_bytes, result_hash:$result_hash, max_budget_usd:$max_budget_usd}' \
    >> "$LEDGER_FILE" 2>/dev/null || true

# --- Mark board reactions as processed ---
if [[ -n "${_board_pending_json:-}" ]]; then
    board_mark_reactions_processed "$_board_pending_json" || true
    log_jsonl "info" "Board reactions marked as processed" "0"
fi

# --- Output result to stdout ---
echo "$RESULT"