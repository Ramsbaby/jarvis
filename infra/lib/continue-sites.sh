#!/usr/bin/env bash
# continue-sites.sh — 다단계 에러 복구 라이브러리 (Continue Sites 패턴)
#
# Claude Code의 Continue Sites 패턴을 Jarvis 크론 시스템에 적용.
# 실패 시 단순히 fail하지 않고, 컨텍스트 축소 → 모델 다운그레이드 → 프롬프트 단순화
# 순서로 단계적 복구를 시도한다.
#
# 사용법:
#   source "${BOT_HOME}/lib/continue-sites.sh"
#   RESULT=$(run_with_recovery "$TASK_ID" "$BOT_HOME/bin/retry-wrapper.sh" ARGS...) || EXIT_CODE=$?
#
# 복구 단계:
#   Stage 1: 원래 설정으로 실행
#   Stage 2: 컨텍스트 축소 (JARVIS_CONTEXT_MODE=minimal)
#   Stage 3: 모델 다운그레이드
#   Stage 4: 프롬프트 단순화 (JARVIS_CONTEXT_MODE=none)
#   Stage 5: 포기 → circuit-breaker 위임
#
# 환경변수:
#   JARVIS_RECOVERY_STAGE  — 현재 복구 단계 (1~5)
#   JARVIS_CONTEXT_MODE    — minimal | none (Stage 2, 4에서 설정)
#
# 통계:
#   ~/.jarvis/state/continue-sites-stats.json

set -euo pipefail

_CS_STATS_FILE="${BOT_HOME:-${HOME}/.jarvis}/state/continue-sites-stats.json"
_CS_STAGE_DELAY=5

# --- 로그 헬퍼 ---
_cs_log() {
    local task_id="$1" stage="$2" action="$3"
    printf '[%s] [%s] RECOVERY stage %d: %s\n' \
        "$(date '+%F %H:%M:%S')" "$task_id" "$stage" "$action" >&2
}

# --- 통계 기록 ---
_cs_record_stat() {
    local task_id="$1" stage="$2" result="$3"
    local stats_dir
    stats_dir="$(dirname "$_CS_STATS_FILE")"
    mkdir -p "$stats_dir"

    python3 - "$task_id" "$stage" "$result" "$_CS_STATS_FILE" <<'PYEOF' 2>/dev/null || true
import json, os, sys, time

task_id, stage, result, stats_file = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

try:
    data = json.load(open(stats_file)) if os.path.exists(stats_file) else {}
except Exception:
    data = {}

# 구조: { "summary": { "stage_2_recovered": N, ... }, "history": [...] }
if "summary" not in data:
    data["summary"] = {}
if "history" not in data:
    data["history"] = []

# 요약 카운터 갱신
key = f"stage_{stage}_{result}"
data["summary"][key] = data["summary"].get(key, 0) + 1

# 히스토리 추가 (최근 200건 유지)
data["history"].append({
    "ts": int(time.time()),
    "task_id": task_id,
    "stage": stage,
    "result": result
})
data["history"] = data["history"][-200:]

with open(stats_file, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# --- 모델 다운그레이드 매핑 ---
_cs_downgrade_model() {
    local current_model="$1"
    case "$current_model" in
        *opus*)   echo "claude-sonnet-4-6" ;;
        *sonnet*) echo "claude-haiku-4-5-20251001" ;;
        *haiku*)  echo "$current_model" ;;  # 더 이상 다운그레이드 불가
        "")       echo "claude-haiku-4-5-20251001" ;;  # 기본값 → haiku
        *)        echo "claude-haiku-4-5-20251001" ;;  # 알 수 없는 모델 → haiku
    esac
}

# --- 모델 다운그레이드 가능 여부 ---
_cs_can_downgrade_model() {
    local current_model="$1"
    local downgraded
    downgraded=$(_cs_downgrade_model "$current_model")
    [[ "$downgraded" != "$current_model" ]]
}

# --- 메인 함수: run_with_recovery ---
# Usage: run_with_recovery TASK_ID COMMAND [ARGS...]
#
# retry-wrapper.sh의 인자 순서:
#   $1=TASK_ID $2=PROMPT $3=ALLOWED_TOOLS $4=TIMEOUT $5=MAX_BUDGET $6=RETENTION $7=MODEL $8=MAX_RETRIES
#
# stdout: 실행 결과 (성공한 stage의 출력)
# exit code: 0=성공, 비0=모든 stage 실패
run_with_recovery() {
    local task_id="$1"
    shift
    # 나머지 인자: COMMAND [ARGS...]
    # retry-wrapper.sh TASK_ID PROMPT ALLOWED_TOOLS TIMEOUT MAX_BUDGET RETENTION MODEL MAX_RETRIES
    local cmd="$1"
    shift
    local args=("$@")

    # args 배열에서 MODEL 위치 파악 (retry-wrapper.sh 인자 순서 기준: index 6 = MODEL)
    # args[0]=TASK_ID, [1]=PROMPT, [2]=TOOLS, [3]=TIMEOUT, [4]=BUDGET, [5]=RETENTION, [6]=MODEL, [7]=MAX_RETRIES
    local original_model="${args[6]:-}"
    local original_context_mode="${JARVIS_CONTEXT_MODE:-}"

    local result_tmp="/tmp/cs-recovery-${task_id}-$$.out"
    local exit_code=0

    # ========================================
    # Stage 1: 원래 설정으로 실행
    # ========================================
    export JARVIS_RECOVERY_STAGE=1
    _cs_log "$task_id" 1 "original_settings → RUNNING"

    exit_code=0
    "$cmd" "${args[@]}" > "$result_tmp" 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        _cs_log "$task_id" 1 "original_settings → SUCCESS"
        _cs_record_stat "$task_id" 1 "success"
        cat "$result_tmp"
        rm -f "$result_tmp"
        return 0
    fi

    _cs_log "$task_id" 1 "original_settings → FAILED (exit=$exit_code)"
    _cs_record_stat "$task_id" 1 "failed"

    # ========================================
    # Stage 2: 컨텍스트 축소 재시도
    # ========================================
    sleep "$_CS_STAGE_DELAY"
    export JARVIS_RECOVERY_STAGE=2
    export JARVIS_CONTEXT_MODE="minimal"
    _cs_log "$task_id" 2 "context_minimal → RUNNING"

    exit_code=0
    "$cmd" "${args[@]}" > "$result_tmp" 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        _cs_log "$task_id" 2 "context_minimal → SUCCESS"
        _cs_record_stat "$task_id" 2 "recovered"
        cat "$result_tmp"
        rm -f "$result_tmp"
        # 원래 환경 복원
        export JARVIS_CONTEXT_MODE="$original_context_mode"
        return 0
    fi

    _cs_log "$task_id" 2 "context_minimal → FAILED (exit=$exit_code)"
    _cs_record_stat "$task_id" 2 "failed"

    # ========================================
    # Stage 3: 모델 다운그레이드 재시도
    # ========================================
    local downgraded_model
    downgraded_model=$(_cs_downgrade_model "$original_model")

    if [[ "$downgraded_model" != "$original_model" ]]; then
        sleep "$_CS_STAGE_DELAY"
        export JARVIS_RECOVERY_STAGE=3
        # JARVIS_CONTEXT_MODE는 minimal 유지 (Stage 2 설정 계승)

        # retry-wrapper args에서 MODEL 위치(index 6) 교체
        local stage3_args=("${args[@]}")
        stage3_args[6]="$downgraded_model"

        _cs_log "$task_id" 3 "model_downgrade(${original_model:-default}→${downgraded_model}) → RUNNING"

        exit_code=0
        "$cmd" "${stage3_args[@]}" > "$result_tmp" 2>&1 || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            _cs_log "$task_id" 3 "model_downgrade → SUCCESS"
            _cs_record_stat "$task_id" 3 "recovered"
            cat "$result_tmp"
            rm -f "$result_tmp"
            export JARVIS_CONTEXT_MODE="$original_context_mode"
            return 0
        fi

        _cs_log "$task_id" 3 "model_downgrade → FAILED (exit=$exit_code)"
        _cs_record_stat "$task_id" 3 "failed"
    else
        _cs_log "$task_id" 3 "model_downgrade → SKIPPED (already lowest: ${original_model})"
        _cs_record_stat "$task_id" 3 "skipped"
    fi

    # ========================================
    # Stage 4: 프롬프트 단순화 재시도
    # ========================================
    sleep "$_CS_STAGE_DELAY"
    export JARVIS_RECOVERY_STAGE=4
    export JARVIS_CONTEXT_MODE="none"

    # Stage 4에서도 다운그레이드 모델 사용
    local stage4_args=("${args[@]}")
    stage4_args[6]="$downgraded_model"

    _cs_log "$task_id" 4 "prompt_simplified(context=none,model=${downgraded_model}) → RUNNING"

    exit_code=0
    "$cmd" "${stage4_args[@]}" > "$result_tmp" 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        _cs_log "$task_id" 4 "prompt_simplified → SUCCESS"
        _cs_record_stat "$task_id" 4 "recovered"
        cat "$result_tmp"
        rm -f "$result_tmp"
        export JARVIS_CONTEXT_MODE="$original_context_mode"
        return 0
    fi

    _cs_log "$task_id" 4 "prompt_simplified → FAILED (exit=$exit_code)"
    _cs_record_stat "$task_id" 4 "failed"

    # ========================================
    # Stage 5: 포기 → circuit-breaker 위임
    # ========================================
    export JARVIS_RECOVERY_STAGE=5
    _cs_log "$task_id" 5 "all_stages_exhausted → DELEGATING to circuit-breaker"
    _cs_record_stat "$task_id" 5 "exhausted"

    # 환경 복원
    export JARVIS_CONTEXT_MODE="$original_context_mode"
    unset JARVIS_RECOVERY_STAGE

    # 마지막 실패 출력 전달 (circuit-breaker가 내용 분석에 사용할 수 있도록)
    cat "$result_tmp" 2>/dev/null || true
    rm -f "$result_tmp"
    return "$exit_code"
}
