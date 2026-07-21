#!/usr/bin/env bash
# exit-code-first-wrapper.sh — 표준 명령 실행 결과 판정 (exit code 우선순위)
#
# 문제 분석:
#   반복 실수 클러스터 cl-e30aee511af89e13에서 로그 에러(stderr)를 API 실패로 오판
#   → 불필요한 재시도, 무한 루프, 상태 오염
#
# 해결책:
#   - exit code를 1순위 판정 기준으로 하고, stderr는 참고용으로만 사용
#   - 모든 명령 실행 후 exit code를 먼저 검사하는 표준 래퍼 제공
#   - stderr 로그는 추적용으로만 기록하고, 판정에 영향 주지 않음
#
# 판정 규칙:
#   - exit code == 0     → SUCCESS (stderr 무시)
#   - exit code != 0     → FAILURE (stderr 내용 무관)
#   - stderr 존재 여부   → 판정 기준 아님, 로그만 기록
#
# 사용 방법:
#   # 기본 형태
#   evaluate_command_result <exit_code> [<task_id>] [<stderr_log_path>]
#
#   # 예시 1: 직접 exit code 전달
#   command some-task.sh
#   local exit_code=$?
#   evaluate_command_result $exit_code "task-id"
#
#   # 예시 2: 표준 명령 실행 후 판정
#   run_command_with_guard "task-id" /path/to/command arg1 arg2
#
# 반환값:
#   0 — 명령 성공 (exit code == 0)
#   1 — 명령 실패 (exit code != 0)
#   255 — 판정 함수 자체 오류 (예: 매개변수 누락)

set -euo pipefail

# ───────────────────────────────────────────────────────────────────────────
# 함수 1: 일반 exit code 판정
# ───────────────────────────────────────────────────────────────────────────
# 매개변수:
#   $1 — exit code (필수)
#   $2 — task_id (선택사항, 로그용)
#   $3 — stderr_log_path (선택사항, stderr 기록 파일)
#
# 반환값:
#   0 — exit code가 0인 경우 성공
#   1 — exit code가 0이 아닌 경우 실패
#
evaluate_command_result() {
    local exit_code="${1:?evaluate_command_result: exit_code required}"
    local task_id="${2:-unknown}"
    local stderr_log="${3:-}"

    local result_status
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # exit code가 0이면 성공, 아니면 실패 (stderr 무시)
    if [[ $exit_code -eq 0 ]]; then
        result_status="SUCCESS"
        if [[ -n "$stderr_log" ]]; then
            # stderr 로그 파일이 제공되면 INFO 레벨로 기록만 (판정에 영향 없음)
            local stderr_content=""
            if [[ -f "$stderr_log" ]]; then
                stderr_content=$(head -c 500 "$stderr_log" 2>/dev/null || echo "")
            fi
            printf '[%s] %s task=%s exit_code=%d stderr_sample="%s"\n' \
                "$timestamp" "$result_status" "$task_id" "$exit_code" "$stderr_content" >> \
                "${JARVIS_HOME:-${HOME}/jarvis/runtime}/logs/exit-code-wrapper.log" 2>/dev/null || true
        fi
        return 0
    else
        result_status="FAILURE"
        if [[ -n "$stderr_log" ]]; then
            # 실패한 경우 stderr 로그 기록
            local stderr_content=""
            if [[ -f "$stderr_log" ]]; then
                stderr_content=$(cat "$stderr_log" 2>/dev/null || echo "")
            fi
            printf '[%s] %s task=%s exit_code=%d stderr="%s"\n' \
                "$timestamp" "$result_status" "$task_id" "$exit_code" "$stderr_content" >> \
                "${JARVIS_HOME:-${HOME}/jarvis/runtime}/logs/exit-code-wrapper.log" 2>/dev/null || true
        fi
        return 1
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# 함수 2: 명령 실행 후 자동 판정 (편의 래퍼)
# ───────────────────────────────────────────────────────────────────────────
# 매개변수:
#   $1 — task_id (필수, 로그용)
#   $2+ — 실행할 명령 및 인자들
#
# 동작:
#   - 명령을 실행하고 stderr를 임시 파일에 캡처
#   - exit code로 판정
#   - stderr는 로그에만 기록
#   - 판정 결과 반환
#
# 반환값:
#   0 — 명령 성공
#   1 — 명령 실패
#
run_command_with_guard() {
    local task_id="${1:?run_command_with_guard: task_id required}"
    shift  # task_id 제거

    if [[ $# -eq 0 ]]; then
        printf '[%s] ERROR run_command_with_guard: command required\n' "$(date -u +%s)" >&2
        return 255
    fi

    local stderr_temp
    stderr_temp=$(mktemp) || return 255
    trap "rm -f '$stderr_temp'" RETURN

    # 명령 실행, stderr를 임시 파일에 리다이렉트
    local exit_code=0
    "$@" 2>"$stderr_temp" || exit_code=$?

    # exit code로 판정 (stderr는 로그만)
    evaluate_command_result $exit_code "$task_id" "$stderr_temp"
}

# ───────────────────────────────────────────────────────────────────────────
# 함수 3: 판정 결과를 읽을 수 있는 형태로 로깅
# ───────────────────────────────────────────────────────────────────────────
# 매개변수:
#   $1 — task_id
#   $2 — decision (SUCCESS|FAILURE)
#   $3 — exit_code
#   $4 — stderr_snippet (선택사항)
#   $5 — action_taken (선택사항, 로그 용도)
#
log_decision() {
    local task_id="${1:?log_decision: task_id required}"
    local decision="${2:?log_decision: decision required (SUCCESS|FAILURE)}"
    local exit_code="${3:?log_decision: exit_code required}"
    local stderr_snippet="${4:-}"
    local action_taken="${5:-}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local log_dir="${JARVIS_HOME:-${HOME}/jarvis/runtime}/logs"
    mkdir -p "$log_dir" 2>/dev/null || true

    local log_entry="{\"ts\":\"$timestamp\",\"task\":\"$task_id\",\"decision\":\"$decision\",\"exit_code\":$exit_code"
    [[ -n "$stderr_snippet" ]] && log_entry="$log_entry,\"stderr\":\"$stderr_snippet\""
    [[ -n "$action_taken" ]] && log_entry="$log_entry,\"action\":\"$action_taken\""
    log_entry="$log_entry}"

    echo "$log_entry" >> "$log_dir/exit-code-wrapper.jsonl" 2>/dev/null || true
}

# ───────────────────────────────────────────────────────────────────────────
# Export 함수들
# ───────────────────────────────────────────────────────────────────────────
export -f evaluate_command_result
export -f run_command_with_guard
export -f log_decision
