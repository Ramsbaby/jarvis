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
source "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh" 2>/dev/null || true
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

# --- Runtime guards (Cluster cl-a1a431b0e672e736: assertion before verification) ---
# Source guard functions for pre-action verification (경로/프로세스/파일 미확인 후 단언 방지)
source "${BOT_HOME}/lib/guards.sh" 2>/dev/null || true
# Validate critical paths before proceeding
assert_directory_exists "$WORK_DIR" "work directory" -w || exit 1
assert_directory_exists "$RESULTS_DIR" "results directory" -w || exit 1
assert_directory_exists "$(dirname "$LOG_FILE")" "log directory" -w || exit 1
assert_directory_exists "$(dirname "$PID_FILE")" "pid directory" -w || exit 1
assert_variable_set "BOT_HOME" "bot home" || exit 1
assert_variable_set "TASK_ID" "task id" || exit 1

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

# --- Rule Guard PRE-EXECUTION (Cluster cl-e04e4028dd5db00f): 확정 규칙 체크리스트 주입 ---
# preply/tutor 태스크 시작 시 rule-registry에서 확정 규칙을 로드해 SYSTEM_PROMPT에 주입
# 목적: 새 세트 작업 전 '예문 3개 고정·문법1장·숙제3종세트' 등 확정 규칙 망각 방지
_CL_E04E_GUARD="${BOT_HOME}/lib/cluster-guard-cl-e04e4028dd5db00f.sh"
if [[ -f "$_CL_E04E_GUARD" ]] && [[ "$TASK_ID" =~ preply|tutor|card.news|카드뉴스 ]]; then
    _RULE_CHECKLIST=$(bash -c "source '${_CL_E04E_GUARD}' 2>/dev/null && guard_new_set_start" 2>/dev/null || true)
    if [[ -n "$_RULE_CHECKLIST" ]]; then
        SYSTEM_PROMPT="${SYSTEM_PROMPT}
<!-- SECTION:rule-guard-cl-e04e4028:DYNAMIC -->
${_RULE_CHECKLIST}
<!-- /SECTION:rule-guard-cl-e04e4028 -->"
    fi
fi

# --- Load Execution Verdict Wrapper (Cluster cl-e30aee511af89e13: prevent stderr-based missjudgment) ---
source "${BOT_HOME}/lib/execution-verdict-wrapper.sh" 2>/dev/null || true

# --- Load Pre-Execution Guard (Cluster cl-e30aee511af89e13: prevent unnecessary re-execution) ---
source "${BOT_HOME}/lib/pre-execution-guard.sh" 2>/dev/null || true

# --- Requirement check guard (Cluster cl-28e5202af0584c23): Extract and track requirements ---
# Pre-execution: Extract requirements from prompt
if [[ -f "${BOT_HOME}/lib/requirement-check-guard.sh" ]]; then
    source "${BOT_HOME}/lib/requirement-check-guard.sh" 2>/dev/null || true
    if command -v check_requirements_pre >/dev/null 2>&1; then
        check_requirements_pre "$TASK_ID" "$PROMPT" 2>/dev/null || true
    fi
fi

# --- Duplicate Request Guard (Cluster cl-3d5ba801bdad1df9): 중복 요청 방지 ---
# 반복 패턴: 2분 내 동일 요청 반복 실행으로 불필요한 비용 + 중복 결과 생성
# 방어: 동일 요청 감지 시 조기 종료, '이미 처리 중' 메시지 반환
# 특징:
#   - 요청 해싱: TASK_ID + PROMPT(처음 256자)의 SHA256
#   - 2분 내 중복 감지 시 차단
#   - 중복 감지 사건 로깅 및 통계 업데이트 (자동)
_DUPLICATE_GUARD="${BOT_HOME}/lib/duplicate-request-guard.mjs"
if command -v node >/dev/null 2>&1 && [[ -f "$_DUPLICATE_GUARD" ]]; then
    _DUP_RESULT=$(node "$_DUPLICATE_GUARD" check "$TASK_ID" "$PROMPT" 2>&1)
    _DUP_EXIT=$?
    if [[ $_DUP_EXIT -eq 1 ]]; then
        # 중복 요청 감지: 조기 종료
        _DUP_MSG=$(echo "$_DUP_RESULT" | jq -r '.message // "이미 처리 중인 요청입니다"' 2>/dev/null || echo "이미 처리 중인 요청입니다")
        _DUP_REQ_ID=$(echo "$_DUP_RESULT" | jq -r '.request_id // "unknown"' 2>/dev/null || echo 'unknown')
        _DUP_COUNT=$(echo "$_DUP_RESULT" | jq -r '.recent_count // 0' 2>/dev/null || echo '0')
        _DUP_HASH=$(echo "$_DUP_RESULT" | jq -r '.request_hash // "unknown"' 2>/dev/null || echo 'unknown')

        # JSONL 로깅 (with extra metadata)
        log_jsonl "blocked" "duplicate_request_guard: $_DUP_MSG" "0" "request_id=\"$_DUP_REQ_ID\",duplicate_count:$_DUP_COUNT,request_hash=\"$_DUP_HASH\""

        # stderr에 상세 정보 (모니터링 및 디버깅용)
        printf '[%s] DUPLICATE_REQUEST_GUARD BLOCKED task=%s request_id=%s duplicate_count=%s\n' \
            "$(date '+%F %H:%M:%S')" "$TASK_ID" "$_DUP_REQ_ID" "$_DUP_COUNT" >&2

        # 사용자에게 메시지 출력 (Discord 라우팅용)
        echo "$_DUP_MSG"

        # outcome 기록 (실패로 처리)
        record_outcome "$TASK_ID" "false" "0" "0" 2>/dev/null || true

        exit 98  # 중복 감지 exit code
    elif [[ $_DUP_EXIT -ne 0 ]]; then
        # 가드 자체 오류 — 실행 계속 (경고만 기록)
        _DUP_ERR=$(echo "$_DUP_RESULT" | head -1)
        log_jsonl "warn" "duplicate_request_guard: error (exit $_DUP_EXIT) — $_DUP_ERR — proceeding" "0"
    fi
    unset _DUP_RESULT _DUP_EXIT _DUP_MSG _DUP_REQ_ID _DUP_COUNT _DUP_HASH _DUP_ERR
fi
unset _DUPLICATE_GUARD

# --- Idempotency Guard (Cluster cl-3e0048f79eb206f9): 동일 명령 중복 처리 방지 ---
# 반복 실수: 동일 명령 중복 제출 시 각각 독립적으로 실행 → 상태 혼란 + 중복 결과
# 방어: SQLite에 명령 해시(task_id+prompt+allowed_tools)와 실행 상태 저장
#       중복 감지 시 이전 결과 반환 또는 재실행 경고
if [[ -f "${BOT_HOME}/lib/idempotency-guard.sh" ]]; then
    source "${BOT_HOME}/lib/idempotency-guard.sh" 2>/dev/null || true

    # 명령 해시 계산 및 상태 확인
    _IDEM_STATUS=$(check_command_status "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" 2>/dev/null || echo "NOT_FOUND")
    _IDEM_STATE="${_IDEM_STATUS%%|*}"  # |이전까지만 추출 (NOT_FOUND 또는 DUPLICATE_*)

    if [[ "$_IDEM_STATE" == "DUPLICATE_IN_PROGRESS" ]]; then
        # 진행 중인 명령 감지: 경고만 하고 계속 진행 (백그라운드 상태 미추적 방지)
        _IDEM_HASH="${_IDEM_STATUS#*|}"
        log_jsonl "warn" "idempotency_guard: DUPLICATE_IN_PROGRESS hash=$_IDEM_HASH — proceeding with caution" "0"
        printf '[%s] IDEMPOTENCY_GUARD WARNING: command already in progress (hash=%s). Be cautious of state confusion.\n' \
            "$(date '+%F %H:%M:%S')" "$_IDEM_HASH" >&2
    elif [[ "$_IDEM_STATE" == "DUPLICATE_COMPLETED" ]]; then
        # 완료된 명령 감지: 이전 결과 경로 추출 후 반환
        # Format: DUPLICATE_COMPLETED|hash|path|summary
        _IDEM_HASH=$(echo "$_IDEM_STATUS" | cut -d'|' -f2)
        _IDEM_RESULT_PATH=$(echo "$_IDEM_STATUS" | cut -d'|' -f3)
        _IDEM_RESULT_SUMMARY=$(echo "$_IDEM_STATUS" | cut -d'|' -f4-)

        if [[ -f "$_IDEM_RESULT_PATH" ]]; then
            # 이전 결과 파일이 존재: 내용 로드 및 반환
            PREV_RESULT=$(cat "$_IDEM_RESULT_PATH")
            log_jsonl "skip" "idempotency_guard: DUPLICATE_COMPLETED — returning previous result" "0" "path=\"$_IDEM_RESULT_PATH\""
            printf '[%s] IDEMPOTENCY_GUARD: Returning cached result from %s\n' "$(date '+%F %H:%M:%S')" "$_IDEM_RESULT_PATH" >&2
            echo "$PREV_RESULT"
            record_outcome "$TASK_ID" "true" "0" "0" 2>/dev/null || true
            exit 0
        else
            # 이전 결과 파일 누락: 경고하고 재실행
            log_jsonl "warn" "idempotency_guard: DUPLICATE_COMPLETED but result file missing — re-executing" "0" "path=\"$_IDEM_RESULT_PATH\""
            printf '[%s] IDEMPOTENCY_GUARD WARNING: Previous result not found — re-executing command\n' \
                "$(date '+%F %H:%M:%S')" >&2
        fi
    elif [[ "$_IDEM_STATE" == "DUPLICATE_FAILED" ]]; then
        # 실패한 명령 감지: 경고하고 재실행 (재시도 가치 있을 수 있음)
        _IDEM_HASH="${_IDEM_STATUS#*|}"
        log_jsonl "info" "idempotency_guard: DUPLICATE_FAILED hash=$_IDEM_HASH — re-executing" "0"
        printf '[%s] IDEMPOTENCY_GUARD: Previous execution failed — re-executing command\n' \
            "$(date '+%F %H:%M:%S')" >&2
    fi

    # 이번 실행 시작 상태 기록
    _IDEM_HASH=$(record_command_start "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" 2>/dev/null)

    unset _IDEM_STATUS _IDEM_STATE _IDEM_HASH _IDEM_RESULT_INFO _IDEM_RESULT_PATH _IDEM_RESULT_SUMMARY PREV_RESULT
fi

# --- Repository Path Guard (Cluster cl-5199fed7fdccfc50): Detect and validate repository paths ---
# 반복 패턴: 파일 읽은 후에도 저장소 판단 역전 / 저장소 구분 역순 오류
# 방어: 작업 시작 시 모든 관련 저장소를 자동 감지하고, 최신 커밋 타임스탐프 기준으로 정렬 표시
if [[ -f "${BOT_HOME}/lib/repo-path-guard.sh" ]]; then
    source "${BOT_HOME}/lib/repo-path-guard.sh" 2>/dev/null || true
    if command -v repo_guard_auto_detect >/dev/null 2>&1; then
        repo_guard_auto_detect "$TASK_ID" 2>/dev/null || true
    fi
fi

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

# --- Root Cause Analysis gate (Cluster cl-d8daa113f8bb5b30: 근본원인 분석 검증) ---
# 반복 실수 패턴 자동 감지: "초기 권고가 근본 해법이 아님" 클러스터 방어
# 차단 조건: problem-solving 태스크에서 "quick fix" 등 증상억제 표현만 있고
#           "root cause", "architecture" 등 근본 분석 증거 부재 시 차단
source "${BOT_HOME}/lib/rca-gate.sh" 2>/dev/null || true
if command -v rca_gate_check >/dev/null 2>&1; then
    if ! rca_gate_check "$TASK_ID" "$PROMPT"; then
        log_jsonl "blocked" "RCA gate: repeated mistake pattern detected" "0"
        record_outcome "$TASK_ID" "false" "0" "0" 2>/dev/null || true
        exit 1
    fi
fi

# --- Token Budget Guard (ADR-013): 누적 비용 상한 초과 시 조기 종료 ---
# 목적: 에이전틱 루프의 토큰 폭주 방지. 예산 초과 시 exit 2 (비정상 종료 없음).
# 체크 순서: 1) 태스크별 누적 예산, 2) 일일 전체 한도
_TOKEN_BUDGET_GUARD="${BOT_HOME}/lib/token-budget-guard.mjs"
if command -v node >/dev/null 2>&1 && [[ -f "$_TOKEN_BUDGET_GUARD" ]]; then
    _GUARD_ARGS=(--task "$TASK_ID")
    [[ -n "${MAX_BUDGET:-}" ]] && _GUARD_ARGS+=(--max-budget "$MAX_BUDGET")
    [[ -n "${JARVIS_DAILY_CAP_USD:-}" ]] && _GUARD_ARGS+=(--daily-cap "$JARVIS_DAILY_CAP_USD")
    _GUARD_RESULT=$(node "$_TOKEN_BUDGET_GUARD" check "${_GUARD_ARGS[@]}" 2>&1)
    _GUARD_EXIT=$?
    if [[ $_GUARD_EXIT -eq 2 ]]; then
        # 예산 초과: 경고 로그 + 조기 종료 (exit 2)
        log_jsonl "blocked" "token_budget_guard: budget exceeded — ${_GUARD_RESULT}" "0"
        printf '[%s] TOKEN_BUDGET_GUARD BLOCKED task=%s reason=%s\n' \
            "$(date '+%F %H:%M:%S')" "$TASK_ID" "$_GUARD_RESULT" >&2
        record_outcome "$TASK_ID" "false" "0" "0" 2>/dev/null || true
        exit 2
    elif [[ $_GUARD_EXIT -ne 0 ]]; then
        # 가드 자체 오류 — 실행 차단하지 않고 경고만 기록
        log_jsonl "warn" "token_budget_guard: guard error (exit $_GUARD_EXIT) — proceeding" "0"
    fi
    unset _GUARD_ARGS _GUARD_RESULT _GUARD_EXIT
fi
unset _TOKEN_BUDGET_GUARD

# --- Task state transition: queued → running (begin execution) ---
# Ensure task is in 'running' state before claude execution
# This prevents FSM validation errors in task-completion-workflow.sh
if command -v node >/dev/null 2>&1 && [[ -f "${BOT_HOME}/lib/task-store.mjs" ]]; then
    node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
        transition "$TASK_ID" running "ask-claude/execution-start" '{}' >/dev/null 2>&1 || true
fi

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
if [[ -s "$CLAUDE_OUTPUT_TMP" ]]; then
    # claude -p --output-format json은 JSONL 형식을 반환할 수 있음 — 마지막 라인이 최종 result
    RAW_OUTPUT=$(tail -1 "$CLAUDE_OUTPUT_TMP")
fi

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
    # Mark task failure (Cluster cl-e30aee511af89e13: track execution status)
    if command -v mark_task_failure >/dev/null 2>&1; then
        mark_task_failure "$TASK_ID" "$CLAUDE_EXIT" 2>/dev/null || true
    fi

    # Idempotency guard: Record command failure (Cluster cl-3e0048f79eb206f9)
    if [[ -n "${_IDEM_HASH:-}" ]] && command -v record_command_end >/dev/null 2>&1; then
        _ERROR_SUMMARY="claude exit code: $CLAUDE_EXIT"
        record_command_end "$TASK_ID" "$_IDEM_HASH" "failed" "" "$_ERROR_SUMMARY" 2>/dev/null || true
        unset _IDEM_HASH _ERROR_SUMMARY
    fi

    record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
    exit "$CLAUDE_EXIT"
fi

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

# --- Validate JSON and extract result ---
if [[ -z "$RAW_OUTPUT" ]] || ! echo "$RAW_OUTPUT" | jq -e '.' >/dev/null 2>&1; then
    log_jsonl "error" "Invalid JSON output from claude (exit=$CLAUDE_EXIT)" "$DURATION"
    if [[ -s "$CLAUDE_OUTPUT_TMP" ]]; then
        cp "$CLAUDE_OUTPUT_TMP" "${RESULT_FILE%.md}-raw.txt"
    fi

    # Idempotency guard: Record command failure (Cluster cl-3e0048f79eb206f9)
    if [[ -n "${_IDEM_HASH:-}" ]] && command -v record_command_end >/dev/null 2>&1; then
        record_command_end "$TASK_ID" "$_IDEM_HASH" "failed" "" "Invalid JSON output from claude" 2>/dev/null || true
        unset _IDEM_HASH
    fi

    record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
    exit 1
fi

# Check for error subtypes (e.g., error_max_budget_usd)
SUBTYPE=$(echo "$RAW_OUTPUT" | jq -r '.subtype // ""')
IS_ERROR=$(echo "$RAW_OUTPUT" | jq -r '.is_error // false')
if [[ "$SUBTYPE" == error_* ]] || [[ "$IS_ERROR" == "true" ]]; then
    log_jsonl "error" "claude error: ${SUBTYPE} is_error=${IS_ERROR}" "$DURATION"
    echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-error.json"

    # Idempotency guard: Record command failure (Cluster cl-3e0048f79eb206f9)
    if [[ -n "${_IDEM_HASH:-}" ]] && command -v record_command_end >/dev/null 2>&1; then
        record_command_end "$TASK_ID" "$_IDEM_HASH" "failed" "" "claude error: ${SUBTYPE}" 2>/dev/null || true
        unset _IDEM_HASH
    fi

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

    # Idempotency guard: Record command failure (Cluster cl-3e0048f79eb206f9)
    if [[ -n "${_IDEM_HASH:-}" ]] && command -v record_command_end >/dev/null 2>&1; then
        record_command_end "$TASK_ID" "$_IDEM_HASH" "failed" "" "Empty result from claude" 2>/dev/null || true
        unset _IDEM_HASH
    fi

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

        # Idempotency guard: Record command failure (Cluster cl-3e0048f79eb206f9)
        if [[ -n "${_IDEM_HASH:-}" ]] && command -v record_command_end >/dev/null 2>&1; then
            record_command_end "$TASK_ID" "$_IDEM_HASH" "failed" "" "evaluator_fail: ${EVALUATOR_REASON}" 2>/dev/null || true
            unset _IDEM_HASH
        fi

        record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
        # stdout으로 에러 메시지 (retry-wrapper가 분류에 사용)
        echo "EVALUATOR_FAIL: ${EVALUATOR_REASON}"
        exit 1
    elif [[ "$EVALUATOR_VERDICT" == "warn" ]]; then
        log_jsonl "warn" "evaluator_warn: ${EVALUATOR_REASON}" "$DURATION"
    fi
fi

# --- Tier 1.5: 근본원인 분석 검증 가드 (root-cause-validator.sh) ---
# 클러스터 cl-d8daa113f8bb5b30 대응: 초기 권고가 근본 해법이 아니었음 패턴 방지
# pass=근본해결 / warn=부분분석 / block=근본미분석(차단)
ROOT_CAUSE_VERDICT="pass"
ROOT_CAUSE_REASON=""
ROOT_CAUSE_BLOCKED=false
ROOT_CAUSE_LIB="${BOT_HOME}/lib/root-cause-validator.sh"
# NOTE: root-cause-validator.sh uses bash 4.3+ features (nameref) not available in macOS bash 3.2
# Skip validation if not supported in current shell (compatibility mode)
if [[ -f "$ROOT_CAUSE_LIB" && ${BASH_VERSINFO[0]:-0} -ge 4 ]]; then
    # shellcheck source=/dev/null
    source "$ROOT_CAUSE_LIB" 2>/dev/null || true
    if command -v validate_root_cause_analysis >/dev/null 2>&1; then
        validate_root_cause_analysis "$TASK_ID" "$RESULT" "$PROMPT" 2>/dev/null || true
        if [[ "$ROOT_CAUSE_BLOCKED" == "true" ]]; then
            log_jsonl "error" "root_cause_analysis_blocked: ${ROOT_CAUSE_REASON}" "$DURATION"
            echo "$RAW_OUTPUT" > "${RESULT_FILE%.md}-root-cause-fail.json"
            record_outcome "$TASK_ID" "false" "$(( DURATION * 1000 ))" "0" || true
            # stdout으로 에러 메시지 (retry-wrapper가 분류에 사용)
            echo "ROOT_CAUSE_ANALYSIS_REQUIRED: ${ROOT_CAUSE_REASON}"
            exit 1
        elif [[ "$ROOT_CAUSE_VERDICT" == "warn" ]]; then
            log_jsonl "warn" "root_cause_analysis_warn: ${ROOT_CAUSE_REASON}" "$DURATION"
        fi
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

# --- Post-save file validation (Cluster cl-dcd8ff3443b1f052: 파일 저장 후 자동 검증) ---
# 파일 저장/업로드 후 경로, 크기, 내용을 자동으로 검증하는 가드
if [[ -f "${BOT_HOME}/lib/post-save-file-guard.sh" ]]; then
  source "${BOT_HOME}/lib/post-save-file-guard.sh" 2>/dev/null || true
  # 결과 파일 검증 (실패해도 진행 계속 — graceful)
  if command -v validate_and_report_file >/dev/null 2>&1; then
    validate_and_report_file "$RESULT_FILE" "" "ask-claude-result-$TASK_ID" 2>/dev/null || true
  fi
fi

# --- Requirement check guard (Cluster cl-28e5202af0584c23): Validate output meets requirements ---
# Post-execution: Check if generated output meets extracted requirements
if command -v check_requirements_post >/dev/null 2>&1; then
    check_requirements_post "$TASK_ID" "$RESULT_FILE" 2>/dev/null || true
fi

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
# Mark task success (Cluster cl-e30aee511af89e13: track execution status)
if command -v mark_task_success >/dev/null 2>&1; then
    mark_task_success "$TASK_ID" 0 2>/dev/null || true
fi

# Idempotency guard: Record command completion (Cluster cl-3e0048f79eb206f9)
if [[ -n "${_IDEM_HASH:-}" ]] && command -v record_command_end >/dev/null 2>&1; then
    _RESULT_SUMMARY=$(printf '%s' "$RESULT" | head -c 200)  # 처음 200자만 요약
    record_command_end "$TASK_ID" "$_IDEM_HASH" "completed" "$RESULT_FILE" "$_RESULT_SUMMARY" 2>/dev/null || true
    unset _IDEM_HASH _RESULT_SUMMARY
fi

record_outcome "$TASK_ID" "true" "$(( DURATION * 1000 ))" "${COST_USD:-0}" || true

# --- Task Completion Workflow (Cluster cl-a823cc27fbf689ff) ---
# 태스크 완료 시 검증→업로드→레지스트리 갱신 3단계 워크플로우 (결과 필드 필수 검증)
_WORKFLOW_SCRIPT="${BOT_HOME}/scripts/task-completion-workflow.sh"
if [[ -f "$_WORKFLOW_SCRIPT" && -f "$RESULT_FILE" ]]; then
    _WORKFLOW_RESULT=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    if [[ -z "$_WORKFLOW_RESULT" ]] || [[ -z "$(echo "$_WORKFLOW_RESULT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]]; then
        # 결과 파일이 비어있음: queued 재시도
        log_jsonl "error" "Result file is empty — queuing for retry (RESULT_REQUIRED)" "$DURATION"
        node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
            transition "$TASK_ID" queued "ask-claude/empty-result" '{}' >/dev/null 2>&1 || true
        exit 1
    fi

    if _WORKFLOW_OUTPUT=$("$_WORKFLOW_SCRIPT" "$TASK_ID" "$_WORKFLOW_RESULT" "ask-claude" 2>&1); then
        log_jsonl "info" "Task completion workflow succeeded (3-stage: validate→upload→registry)" "$DURATION"
    else
        _WORKFLOW_EXIT=$?
        if [[ $_WORKFLOW_EXIT -eq 100 ]]; then
            log_jsonl "error" "Completion workflow validation failed (RESULT_REQUIRED, exit 100) — queuing for retry" "$DURATION"
            node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
                transition "$TASK_ID" queued "ask-claude/workflow-validation-failed" '{"lastError":"workflow_result_validation_failed"}' >/dev/null 2>&1 || true
            exit 1
        elif [[ $_WORKFLOW_EXIT -eq 101 ]]; then
            log_jsonl "error" "Completion workflow upload failed (exit 101) — queuing for retry" "$DURATION"
            node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
                transition "$TASK_ID" queued "ask-claude/workflow-upload-failed" '{"lastError":"workflow_upload_failed"}' >/dev/null 2>&1 || true
            exit 1
        elif [[ $_WORKFLOW_EXIT -eq 102 ]]; then
            log_jsonl "error" "Completion workflow registry update failed (exit 102) — marking as failed (max retries exhausted)" "$DURATION"
            node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
                transition "$TASK_ID" failed "ask-claude/workflow-registry-failed" '{"lastError":"workflow_registry_update_failed"}' >/dev/null 2>&1 || true
            exit 1
        else
            log_jsonl "error" "Completion workflow failed with unexpected exit code $_WORKFLOW_EXIT" "$DURATION"
            node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
                transition "$TASK_ID" failed "ask-claude/workflow-unexpected-error" '{"lastError":"workflow_unexpected_error"}' >/dev/null 2>&1 || true
            exit 1
        fi
    fi
fi

# --- Guard: File state cache & contradiction detection (Cluster cl-6f0c8cc1df90e995) ---
# 파일 상태 혼동 및 일관성 부재 방어: 파일 조작 전 상태를 1회만 조회하여 응답 전체에 고정
# 동일 응답 내 파일 존재/부재 모순 감지 시 Tier 2 경고 자동 로깅
if [[ -f "${BOT_HOME}/lib/file-state-cache.sh" && -f "${BOT_HOME}/lib/file-state-contradiction-guard.sh" ]]; then
    source "${BOT_HOME}/lib/file-state-cache.sh" 2>/dev/null || true
    source "${BOT_HOME}/lib/file-state-contradiction-guard.sh" 2>/dev/null || true

    # [1] 응답 시작: 파일 상태 캐시 초기화 (RESPONSE_ID 설정)
    export RESPONSE_ID="${TASK_ID}-$(date -u +%s)-$$"
    init_file_state_cache "$RESPONSE_ID" 2>/dev/null || true

    # [2] 응답 종료: 파일 상태 모순 감지
    if [[ -n "$RAW_OUTPUT" ]]; then
        # 파일 상태 모순 검사
        if ! guard_file_state_contradictions "$TASK_ID" "$RAW_OUTPUT" 2>/dev/null; then
            # 모순 감지 시 dev-queue에 자동 Tier 2 작업 등록
            if [[ -f "${BOT_HOME}/lib/file-state-dev-queue-bridge.sh" ]]; then
                source "${BOT_HOME}/lib/file-state-dev-queue-bridge.sh" 2>/dev/null || true
                enqueue_file_state_contradiction_task "$TASK_ID" "파일 상태 모순 감지: 응답 내 존재/부재 상태 불일치" "ERROR" 2>/dev/null || true
            fi
            log_jsonl "warn" "File state contradiction detected — Tier 2 analysis task enqueued (cluster=cl-6f0c8cc1df90e995)" "0"
        fi

        # 캐시된 상태와 응답 내용 최종 검증
        if ! validate_file_state_consistency "$RESPONSE_ID" "$RAW_OUTPUT" 2>/dev/null; then
            log_jsonl "warn" "File state cache consistency check: potential mismatch in cached vs reported states" "0"
        fi
    fi

    # [3] 캐시 정리 (응답 종료 후 7일 이상 된 캐시 제거)
    cleanup_old_caches 7 2>/dev/null || true
fi

# --- Guard: Completion safety check (Cluster cl-d062d5d4b813f265) ---
# 완료 선언 키워드 감지 시 도구 호출 히스토리 검증 (파일 미열람 후 단언 방지)
# Source guard library for completion safety verification
if [[ -f "${BOT_HOME}/lib/guard-completion-check.sh" ]]; then
    source "${BOT_HOME}/lib/guard-completion-check.sh" 2>/dev/null || true

    # Extract PROMPT from context if available (fallback to empty if not in scope)
    GUARD_USER_MESSAGE="${PROMPT:-}"

    # Extract tool_calls from RAW_OUTPUT and run safety check
    if [[ -n "$RAW_OUTPUT" ]]; then
        if ! check_completion_safety_from_claude_output "$GUARD_USER_MESSAGE" "$RAW_OUTPUT" "$TASK_ID" 2>/dev/null; then
            # Guard check failed — log alert but don't block output (soft warning)
            log_jsonl "warn" "Completion safety check FAILED — potential file/path verification issue detected" "0"
        fi
    fi
fi

# --- Guard: File existence assertion validator (Cluster cl-3dbad2477e65b7b7) ---
# 파일 존재 판단 오류 클러스터 방어: 응답의 파일 단언과 실제 존재 여부 대조
# 후처리 검증 로직 — 기존 동작 차단 없음 (경고 로깅만)
if [[ -f "${BOT_HOME}/lib/file-existence-validator.sh" ]]; then
    source "${BOT_HOME}/lib/file-existence-validator.sh" 2>/dev/null || true

    if command -v validate_file_assertions >/dev/null 2>&1; then
        # RESULT 텍스트에서 파일 단언 검증
        if ! validate_file_assertions "$RESULT" "$WORK_DIR" 2>/dev/null; then
            log_jsonl "warn" "File existence assertion validation: potential mismatch detected" "0"
        fi
    fi
fi

# --- Guard: File validation after completion (Cluster cl-dcd8ff3443b1f052) ---
# 파일 저장/업로드 직후 경로 존재, 크기, 언어 비율을 자동 검증
# 검증 실패 시 경고 로그 및 상세 보고서 생성 (기존 동작 차단 없음)
if [[ -f "${BOT_HOME}/lib/file-validator.sh" ]] && command -v jq >/dev/null 2>&1; then
    source "${BOT_HOME}/lib/file-validator.sh" 2>/dev/null || true

    # RAW_OUTPUT에서 저장된 파일 경로 추출 (Write, Edit, Bash 도구 결과)
    # 형식 예: {"saved_to": "/path/to/file", ...} 또는 기타 파일 경로 언급
    if [[ -n "$RAW_OUTPUT" ]]; then
        # jq를 사용하여 저장된 파일 경로 추출 시도
        SAVED_FILES=$(echo "$RAW_OUTPUT" | jq -r '.saved_files[]? // .file_path // empty' 2>/dev/null || echo "")

        # 경로가 없으면 출력 텍스트에서 간단히 추출 시도
        if [[ -z "$SAVED_FILES" ]]; then
            # 안전 문자만 허용 (세미콜론·싱글쿼트·백틱 등 셸 메타문자 제거)
            # [^ "]*가 메타문자를 허용하는 취약점 방어: grep 후 화이트리스트 재검증
            SAVED_FILES=$(echo "$RAW_OUTPUT" | grep -oE '/(tmp|home|Users|jarvis)[^ "]*\.(pdf|txt|md|json|html|csv)' 2>/dev/null \
                | grep -E '^[a-zA-Z0-9/_.\-]+$' || true)
        fi

        # 저장된 파일이 있으면 검증 수행
        if [[ -n "$SAVED_FILES" ]]; then
            while IFS= read -r file_path; do
                [[ -z "$file_path" ]] && continue
                [[ ! -e "$file_path" ]] && continue  # 존재하지 않으면 스킵

                # 파일 검증 실행 (경로 존재, 크기 > 0 확인)
                if ! validate_file "$file_path" 2>/dev/null; then
                    log_jsonl "warn" "File validation FAILED — file might be corrupted or incomplete: $file_path" "0"
                fi
            done <<< "$SAVED_FILES"
        fi
    fi

    # Cluster guard integration (cl-dcd8ff3443b1f052)
    if [[ -f "${BOT_HOME}/lib/cluster-guard-cl-dcd8ff3443b1f052.sh" ]]; then
        bash "${BOT_HOME}/lib/cluster-guard-cl-dcd8ff3443b1f052.sh" "$RAW_OUTPUT" "$TASK_ID" 2>/dev/null || true
    fi

    # Cluster guard integration (cl-45670404fa7eb40c): 완료 선언 검증
    # 검증 실패: PDF 페이지 수 미검증, 파일 응답 본문 미검증, 중복 파일 미감지
    if [[ -f "${BOT_HOME}/lib/cluster-guard-cl-45670404fa7eb40c.sh" ]]; then
        bash "${BOT_HOME}/lib/cluster-guard-cl-45670404fa7eb40c.sh" "$RAW_OUTPUT" "$TASK_ID" 2>/dev/null || true
    fi

    # Cluster guard integration (cl-e04e4028dd5db00f): 확정 규칙 검증 (HTML 세트 저장 후)
    # 규칙 편차 방지: 예문 개수, 문법 슬라이드 장 수, 동반 파일 자동 검증
    _CL_E04E_GUARD="${BOT_HOME}/lib/cluster-guard-cl-e04e4028dd5db00f.sh"
    if [[ -f "$_CL_E04E_GUARD" ]] && [[ -n "${SAVED_FILES:-}" ]]; then
        while IFS= read -r _e04e_file; do
            [[ -z "$_e04e_file" ]] && continue
            # 안전 문자 재검증: bash -c 내 싱글쿼트 이스케이프 불가 → 메타문자 포함 경로 차단
            if ! echo "$_e04e_file" | grep -qE '^[a-zA-Z0-9/_.\-]+$'; then
                log_jsonl "warn" "Skipping unsafe path from LLM output (metachar detected): $_e04e_file" "0"
                continue
            fi
            if echo "$_e04e_file" | grep -qE '\.(html|pdf)$'; then
                # bash -c 문자열 보간 대신 subshell + 변수 전달로 인젝션 방어
                (source "$_CL_E04E_GUARD" 2>/dev/null && guard_validate_set "$_e04e_file") 2>/dev/null || true
            fi
        done <<< "$SAVED_FILES"
    fi
fi

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