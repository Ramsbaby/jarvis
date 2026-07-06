#!/usr/bin/env bash
# retry-fallback.sh — API/명령 재시도 실패 시 대안 경로 제안 (클러스터 cl-733ea6d158b005b6)
#
# 목적:
#   - API 오류처럼 반복 실패 시 동일 명령 재시도 대신 대안 경로 자동 제안
#   - 2회 이상 동일 명령 실패 시 대안 메시지 출력
#   - "선행 피드백 미적용으로 동일 오류 재발" 방지
#
# 사용:
#   source ~/jarvis/infra/lib/retry-fallback.sh
#   retry_with_fallback "$command" "$max_attempts" "$error_type" "$fallback_fn"
#
# 반환값:
#   0 = 성공
#   1 = 재시도 실패, 대안 제시됨
#   2 = 대안도 실패

set -euo pipefail

# 재시도 통계 및 대안 제안 저장소
_RETRY_STATE_DIR="${HOME}/jarvis/runtime/state/retry-fallback"
_RETRY_LOG="${_RETRY_STATE_DIR}/retry-log.jsonl"
_FALLBACK_CACHE="${_RETRY_STATE_DIR}/fallback-cache.json"

_init_retry_state() {
    mkdir -p "$_RETRY_STATE_DIR" 2>/dev/null || return 0
}

# 명령어 해시 생성
_get_command_hash() {
    local cmd="$1"
    echo -n "$cmd" | shasum -a 256 | cut -c1-16
}

# 대안 제안 등록
register_fallback() {
    local original_cmd="$1"
    local fallback_cmd="$2"
    local reason="${3:-Fallback for repeated failures}"

    _init_retry_state

    local cmd_hash
    cmd_hash=$(_get_command_hash "$original_cmd")

    local timestamp
    timestamp=$(date -u +%FT%TZ)

    if command -v jq >/dev/null 2>&1; then
        local tmp_file
        tmp_file=$(mktemp)

        if [[ -f "$_FALLBACK_CACHE" ]]; then
            jq --arg hash "$cmd_hash" --arg fcmd "$fallback_cmd" --arg reason "$reason" --arg ts "$timestamp" \
                '.[$hash] = {fallback_cmd: $fcmd, reason: $reason, last_registered: $ts}' \
                "$_FALLBACK_CACHE" > "$tmp_file" 2>/dev/null || true
        else
            jq -cn --arg hash "$cmd_hash" --arg fcmd "$fallback_cmd" --arg reason "$reason" --arg ts "$timestamp" \
                '{($hash): {fallback_cmd: $fcmd, reason: $reason, last_registered: $ts}}' \
                > "$tmp_file" 2>/dev/null || true
        fi

        [[ -s "$tmp_file" ]] && mv "$tmp_file" "$_FALLBACK_CACHE"
        rm -f "$tmp_file"
    fi
}

# 대안 명령 조회
_get_fallback_cmd() {
    local original_cmd="$1"
    local cmd_hash
    cmd_hash=$(_get_command_hash "$original_cmd")

    if [[ -f "$_FALLBACK_CACHE" ]] && command -v jq >/dev/null 2>&1; then
        jq --arg hash "$cmd_hash" '.[$hash].fallback_cmd // empty' "$_FALLBACK_CACHE" 2>/dev/null || true
    fi
}

# 재시도 이력 기록
_record_retry() {
    local cmd_hash="$1"
    local attempt="$2"
    local exit_code="$3"
    local stdout="$4"
    local stderr="$5"

    _init_retry_state

    mkdir -p "$(dirname "$_RETRY_LOG")" 2>/dev/null || return 0

    local timestamp
    timestamp=$(date -u +%FT%TZ)

    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg hash "$cmd_hash" --arg attempt "$attempt" --arg code "$exit_code" \
            --arg out "$stdout" --arg err "$stderr" --arg ts "$timestamp" \
            '{cmd_hash: $hash, attempt: $attempt, exit_code: $code, stdout: $out, stderr: $err, timestamp: $ts}' \
            >> "$_RETRY_LOG" 2>/dev/null || true
    fi
}

# 명령어의 최근 재시도 횟수 조회
_get_retry_count() {
    local cmd_hash="$1"
    if [[ -f "$_RETRY_LOG" ]] && command -v jq >/dev/null 2>&1; then
        jq -s --arg hash "$cmd_hash" '[.[] | select(.cmd_hash == $hash)] | length' "$_RETRY_LOG" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# 메인: 재시도 및 대안 제시
retry_with_fallback() {
    local cmd="$1"
    local max_attempts="${2:-3}"
    local error_type="${3:-UNKNOWN}"
    local fallback_fn="${4:-}"

    _init_retry_state

    local cmd_hash
    cmd_hash=$(_get_command_hash "$cmd")

    local attempt=0
    local last_exit_code=0
    local last_stdout=""
    local last_stderr=""

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))

        printf '[retry-fallback] Attempt %d/%d: %s\n' "$attempt" "$max_attempts" "$cmd" >&2

        if last_stdout=$(eval "$cmd" 2>&1); then
            printf '[retry-fallback] SUCCESS on attempt %d\n' "$attempt" >&2
            _record_retry "$cmd_hash" "$attempt" "0" "$last_stdout" ""
            return 0
        else
            last_exit_code=$?
            last_stderr="$last_stdout"
            _record_retry "$cmd_hash" "$attempt" "$last_exit_code" "$last_stdout" "$last_stderr"

            printf '[retry-fallback] Failed (exit %d), retrying...\n' "$last_exit_code" >&2
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local wait_time=$((2 ** (attempt - 1)))
            sleep "$wait_time"
        fi
    done

    local retry_count
    retry_count=$(_get_retry_count "$cmd_hash")

    printf '[retry-fallback] All %d attempts failed (error_type=%s)\n' "$attempt" "$error_type" >&2

    if [[ $retry_count -ge 2 ]]; then
        local fallback_cmd
        fallback_cmd=$(_get_fallback_cmd "$cmd")

        if [[ -n "$fallback_cmd" ]]; then
            printf '[retry-fallback] FALLBACK_SUGGESTED: %s\n' "$fallback_cmd" >&2
            printf '[retry-fallback] Last error: exit %d\n' "$last_exit_code" >&2
            printf '[retry-fallback] Last output: %s\n' "${last_stderr:0:200}" >&2

            return 1
        elif [[ -n "$fallback_fn" && "$(type -t "$fallback_fn" 2>/dev/null)" == "function" ]]; then
            printf '[retry-fallback] FALLBACK_FN executing: %s\n' "$fallback_fn" >&2
            if $fallback_fn "$error_type" "$last_stderr"; then
                printf '[retry-fallback] Fallback function succeeded\n' >&2
                return 0
            else
                printf '[retry-fallback] Fallback function also failed\n' >&2
                return 2
            fi
        else
            printf '[retry-fallback] No fallback available\n' >&2
            return 1
        fi
    fi

    return 1
}

# 조건부 재시도
retry_on_exit() {
    local cmd="$1"
    local exit_codes="$2"
    local max_attempts="${3:-3}"

    local attempt=0
    local last_exit=0

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))

        printf '[retry-on-exit] Attempt %d/%d\n' "$attempt" "$max_attempts" >&2

        if eval "$cmd"; then
            return 0
        else
            last_exit=$?

            if echo "$exit_codes" | grep -qE "(^|,)${last_exit}(,|$)"; then
                printf '[retry-on-exit] Exit %d in retry list, retrying...\n' "$last_exit" >&2
                [[ $attempt -lt $max_attempts ]] && sleep $((2 ** (attempt - 1)))
            else
                printf '[retry-on-exit] Exit %d not in retry list, giving up\n' "$last_exit" >&2
                return "$last_exit"
            fi
        fi
    done

    printf '[retry-on-exit] All attempts exhausted\n' >&2
    return "$last_exit"
}

# 유틸: 대안 경로 목록 표시
show_registered_fallbacks() {
    if [[ -f "$_FALLBACK_CACHE" ]]; then
        echo "[Registered Fallbacks]"
        jq '.' "$_FALLBACK_CACHE" 2>/dev/null || cat "$_FALLBACK_CACHE"
    else
        echo "[No fallbacks registered]"
    fi
}

# 유틸: 재시도 통계 표시
show_retry_stats() {
    if [[ -f "$_RETRY_LOG" ]]; then
        echo "[Retry Statistics]"
        jq -s 'group_by(.cmd_hash) | map({cmd_hash: .[0].cmd_hash, attempts: length, last_attempt: .[-1].timestamp})' \
            "$_RETRY_LOG" 2>/dev/null || true
    else
        echo "[No retry history]"
    fi
}

# 유틸: 상태 초기화
clear_retry_state() {
    rm -rf "$_RETRY_STATE_DIR" 2>/dev/null || true
    echo "[Retry state cleared]"
}

export -f retry_with_fallback
export -f retry_on_exit
export -f register_fallback
export -f show_registered_fallbacks
export -f show_retry_stats
export -f clear_retry_state
