#!/usr/bin/env bash
# file-state-contradiction-guard.sh — 파일 상태 모순 자동 감지 가드
#
# 클러스터 ID  : cl-6f0c8cc1df90e995 (최근 7일 재발 40건)
# 반복 패턴   : 동일 응답 내 파일 존재/부재 상태 모순 보고
# 목적        : ask-claude.sh 후처리 단계에서 응답 문본과 캐시된 파일 상태 자동 대조
#
# 사용법:
#   source "${BOT_HOME}/lib/file-state-contradiction-guard.sh"
#
#   # ask-claude.sh 실행 후:
#   guard_file_state_contradictions "$TASK_ID" "$RAW_OUTPUT" || {
#       # 모순 감지 시 처리
#   }
#
# 반환값:
#   0 = 모순 없음
#   1 = 모순 감지 (경고 기록, 기존 동작 차단 없음)

set -euo pipefail

export BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"

# ═════════════════════════════════════════════════════════════════════════════════
# [1] 정규식 패턴 정의
# ═════════════════════════════════════════════════════════════════════════════════

# 2026-10-08: `.*` 는 한 줄 끝까지 탐욕스럽게 먹어 한 줄 안의 여러 문장이 1회로 세졌다 → 문장 안으로 묶는다([^.?!]*).
#   `[다음]` 같은 한글 대괄호는 C 로케일에서 바이트 집합이라 '없어서'까지 맞았다 → (다|음) 교대로.
#   해요체·합니다체('있어요'·'있습니다')도 존재로 센다.
_FSCG_S='[^.?!]*'

# 파일 존재 긍정 표현
EXIST_PATTERNS=(
    "파일${_FSCG_S}존재"
    "파일${_FSCG_S}있(다|어|습)"
    "파일${_FSCG_S}생성"
    "파일${_FSCG_S}작성"
    "파일${_FSCG_S}저장"
    "파일이 ${_FSCG_S}생겼"
    "파일 ${_FSCG_S}생성"
    "이미 ${_FSCG_S}존재"
    "파일 ${_FSCG_S}있(다|음)"
)

# 파일 부재 표현
NOT_EXIST_PATTERNS=(
    "파일${_FSCG_S}없다"
    "파일${_FSCG_S}없(음|다)"
    "파일이 ${_FSCG_S}없(다|음)"
    "파일 ${_FSCG_S}부재"
    "파일 ${_FSCG_S}미존재"
    "파일이 없"
    "파일 ${_FSCG_S}없는"
    "파일 ${_FSCG_S}부족"
)
unset _FSCG_S

# ═════════════════════════════════════════════════════════════════════════════════
# [2] count_pattern_occurrences — 정규식 패턴 매칭 횟수 계산
# ═════════════════════════════════════════════════════════════════════════════════

count_pattern_occurrences() {
    local text="$1"
    local pattern="$2"

    # grep -o: 매칭 부분만 출력, wc -l: 라인 수
    # 매칭이 없으면 0 반환
    local count
    count=$(printf '%s' "$text" | grep -oiE "$pattern" 2>/dev/null | wc -l) || count=0
    printf '%s' "$count"
}

# ═════════════════════════════════════════════════════════════════════════════════
# [3] extract_file_state_assertions — 응답에서 파일 상태 단언 추출
# ═════════════════════════════════════════════════════════════════════════════════
#
# 반환: JSON 배열
# [
#   {
#     "type": "exist" | "not_exist" | "ambiguous",
#     "count": <숫자>,
#     "context": "..."
#   }
# ]

extract_file_state_assertions() {
    local output="$1"

    local exist_count=0
    local not_exist_count=0

    # 존재 패턴 검사
    for pattern in "${EXIST_PATTERNS[@]}"; do
        local count
        count=$(count_pattern_occurrences "$output" "$pattern") || count=0
        exist_count=$((exist_count + count))
    done

    # 부재 패턴 검사
    for pattern in "${NOT_EXIST_PATTERNS[@]}"; do
        local count
        count=$(count_pattern_occurrences "$output" "$pattern") || count=0
        not_exist_count=$((not_exist_count + count))
    done

    # JSON 출력
    local contradicted="false"
    if [[ $exist_count -gt 0 ]] && [[ $not_exist_count -gt 0 ]]; then
        contradicted="true"
    fi

    cat <<EOF
{
  "exist_assertions": $exist_count,
  "not_exist_assertions": $not_exist_count,
  "total_assertions": $((exist_count + not_exist_count)),
  "contradicted": $contradicted
}
EOF
}

# ═════════════════════════════════════════════════════════════════════════════════
# [4] guard_file_state_contradictions — 메인 가드 함수
# ═════════════════════════════════════════════════════════════════════════════════
#
# 사용법:
#   guard_file_state_contradictions "task-123" "$RAW_OUTPUT"
#
# 반환값:
#   0 = 모순 없음
#   1 = 모순 감지 (경고만 기록, 응답 차단 없음)

guard_file_state_contradictions() {
    local task_id="$1"
    local raw_output="$2"

    [[ -z "$task_id" ]] && {
        printf '[FSCG] ERROR: guard_file_state_contradictions called with empty task_id\n' >&2
        return 1
    }

    [[ -z "$raw_output" ]] && {
        printf '[FSCG] WARNING: raw_output is empty, skipping contradiction check\n' >&2
        return 0
    }

    # 파일 상태 단언 추출
    local assertions_json
    assertions_json=$(extract_file_state_assertions "$raw_output")

    # jq로 파싱
    local exist_count
    local not_exist_count
    local contradicted

    exist_count=$(printf '%s' "$assertions_json" | jq '.exist_assertions // 0')
    not_exist_count=$(printf '%s' "$assertions_json" | jq '.not_exist_assertions // 0')
    contradicted=$(printf '%s' "$assertions_json" | jq '.contradicted // false')

    # 모순 판정: 동시에 "존재한다"와 "없다"를 언급
    if [[ "$contradicted" == "true" ]] && \
       [[ $exist_count -gt 0 ]] && \
       [[ $not_exist_count -gt 0 ]]; then

        # 모순 감지!
        report_contradiction "$task_id" "$exist_count" "$not_exist_count" || true
        return 1
    fi

    # 동일 파일에 대해 여러 번 반복 언급하는 경우 (3회 이상)
    if [[ $((exist_count + not_exist_count)) -ge 3 ]]; then
        # 경고 수준: 파일 상태를 너무 많이 언급 (혼란 가능성)
        report_repetitive_assertion "$task_id" "$exist_count" "$not_exist_count" || true
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [5] report_contradiction — 모순 감지 보고
# ═════════════════════════════════════════════════════════════════════════════════

report_contradiction() {
    local task_id="$1"
    local exist_count="$2"
    local not_exist_count="$3"

    mkdir -p "$BOT_HOME/logs" || return 1

    # 한 줄 JSON(JSONL) — 여러 줄로 쓰면 줄 단위로 읽는 쪽(통계·시험)이 깨진다(2026-10-08).
    local report
    report=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task_id "$task_id" \
        --argjson e "$exist_count" --argjson n "$not_exist_count" \
        '{ts: $ts, task_id: $task_id, cluster_id: "cl-6f0c8cc1df90e995",
          violation_type: "FILE_STATE_CONTRADICTION", exist_assertions: $e, not_exist_assertions: $n,
          severity: "ERROR", message: "파일 존재/부재 상태 모순: 동일 응답에서 서로 모순되는 상태 보고"}') || return 1

    printf '%s\n' "$report" >> "$BOT_HOME/logs/file-state-contradictions.jsonl"

    printf '[FSCG] CONTRADICTION DETECTED: task=%s, exist=%d, not_exist=%d\n' \
        "$task_id" "$exist_count" "$not_exist_count" >&2

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [6] report_repetitive_assertion — 반복 언급 경고
# ═════════════════════════════════════════════════════════════════════════════════

report_repetitive_assertion() {
    local task_id="$1"
    local exist_count="$2"
    local not_exist_count="$3"

    mkdir -p "$BOT_HOME/logs" || return 1

    local report
    report=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task_id "$task_id" \
        --argjson e "$exist_count" --argjson n "$not_exist_count" \
        '{ts: $ts, task_id: $task_id, cluster_id: "cl-6f0c8cc1df90e995",
          violation_type: "FILE_STATE_REPETITIVE", exist_assertions: $e, not_exist_assertions: $n,
          severity: "WARN", message: "파일 상태를 과도하게 많이 언급 (혼동 가능성)"}') || return 1

    printf '%s\n' "$report" >> "$BOT_HOME/logs/file-state-contradictions.jsonl"

    printf '[FSCG] REPETITIVE ASSERTION: task=%s, total_mentions=%d\n' \
        "$task_id" "$((exist_count + not_exist_count))" >&2

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [7] get_contradiction_stats — 일일 통계 조회
# ═════════════════════════════════════════════════════════════════════════════════
#
# 사용법:
#   get_contradiction_stats  # 오늘의 모순 통계

get_contradiction_stats() {
    local log_file="$BOT_HOME/logs/file-state-contradictions.jsonl"

    [[ ! -f "$log_file" ]] && {
        printf '{"total": 0, "error": 0, "warn": 0, "details": []}\n'
        return 0
    }

    # 오늘 기록만 필터링
    local today_date
    today_date=$(date -u +%Y-%m-%d)

    local error_count
    local warn_count

    # 옛 여러 줄 기록은 날짜와 심각도가 다른 줄이라 원래도 0 으로 셌다 — 한 줄 기록만 센다.
    error_count=$(grep "$today_date" "$log_file" | grep -cE '"severity": ?"ERROR"') || error_count=0
    warn_count=$(grep "$today_date" "$log_file" | grep -cE '"severity": ?"WARN"') || warn_count=0

    cat <<EOF
{
  "date": "$today_date",
  "total": $((error_count + warn_count)),
  "error": $error_count,
  "warn": $warn_count,
  "log_file": "$log_file"
}
EOF
}

# ═════════════════════════════════════════════════════════════════════════════════
# Export
# ═════════════════════════════════════════════════════════════════════════════════

export -f guard_file_state_contradictions
export -f extract_file_state_assertions
export -f report_contradiction
export -f report_repetitive_assertion
export -f get_contradiction_stats

return 0 2>/dev/null || true
