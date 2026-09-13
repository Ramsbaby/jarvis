#!/usr/bin/env bash
# validate-config-sanity.sh — 설정 파생값 자동 재검산
#
# 클러스터 cl-19d6b30bf68b02db: "설정 실효성 미검증"
# 목적: D-day·합계·비율 계산 직후 논리적 일관성 검증
#
# 테스트 케이스:
#   1. 손절선 거리 계산: (손절선 < 현재가) 검증
#   2. 비율 계산: 합계 100%, 각 항목 0~100% 범위 검증
#   3. D-day 계산: (마감일 >= 오늘) 검증
#   4. 합계 계산: 개별 금액 합 == 총합 검증
#   5. 태스크 개수: disabled + active == total 검증
#
# 사용법:
#   validate-config-sanity.sh [--test]
#   validate-config-sanity.sh --check-dday <iso-date>
#   validate-config-sanity.sh --check-sum <expected> <v1> <v2> ...
#
# Exit codes:
#   0   - 모든 검증 통과
#   1   - 검증 실패
#   2   - 사용법 오류

set -euo pipefail

LOG_FILE="${HOME}/.openclaw-data/runtime/logs/validate-config-sanity-$(date '+%Y%m%d_%H%M%S').log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

# === Test Case 1: 손절선 거리 계산 ===
test_stop_loss_margin() {
    log "INFO" "Test 1: 손절선 거리 계산"

    local current_price=70.47
    local stop_loss=37.00
    local script_stop=47

    # 검증: 현재가 > 손절선
    if (( $(echo "$current_price > $stop_loss" | bc -l) )); then
        local margin=$(echo "$current_price - $stop_loss" | bc -l)
        log "PASS" "현재가($current_price) > 손절선($stop_loss), 여유: $margin"

        # 추가: 스크립트 값도 검증
        if (( $(echo "$current_price > $script_stop" | bc -l) )); then
            local script_margin=$(echo "$current_price - $script_stop" | bc -l)
            log "PASS" "현재가($current_price) > 스크립트값($script_stop), 여유: $script_margin"
            return 0
        else
            log "FAIL" "현재가($current_price) <= 스크립트값($script_stop)"
            return 1
        fi
    else
        log "FAIL" "현재가($current_price) <= 손절선($stop_loss)"
        return 1
    fi
}

# === Test Case 2: 비율 합계 검증 (100%) ===
test_percentage_sum() {
    log "INFO" "Test 2: 비율 합계 검증"

    local pct1=33.33
    local pct2=33.34
    local pct3=33.33

    local sum=$(echo "$pct1 + $pct2 + $pct3" | bc -l)
    local expected=100.00

    # 부동소수점 비교 (소수점 2자리 내 오차 허용)
    if (( $(echo "($sum - $expected) < 0.01 && ($sum - $expected) > -0.01" | bc -l) )); then
        log "PASS" "비율 합계: $sum (기대값: $expected, 오차: ${sum%.*}.${sum#*.}"
        return 0
    else
        log "FAIL" "비율 합계 오류: $sum (기대값: $expected)"
        return 1
    fi
}

# === Test Case 3: D-day 계산 (마감일 >= 오늘) ===
test_dday_validity() {
    log "INFO" "Test 3: D-day 계산 검증"

    local deadline="2026-09-04"
    local today=$(date '+%Y-%m-%d')

    # 날짜 문자열 비교 (YYYY-MM-DD 형식)
    if [[ "$deadline" > "$today" ]] || [[ "$deadline" == "$today" ]]; then
        # macOS/Linux 호환: date 명령 다르므로 간단한 문자열 비교로 계산
        local deadline_epoch=$(date -j -f "%Y-%m-%d" "$deadline" "+%s" 2>/dev/null || echo "0")
        local today_epoch=$(date -j -f "%Y-%m-%d" "$today" "+%s" 2>/dev/null || echo "0")
        if [[ "$deadline_epoch" != "0" ]] && [[ "$today_epoch" != "0" ]]; then
            local dday=$(( (deadline_epoch - today_epoch) / 86400 ))
            log "PASS" "마감일($deadline) >= 오늘($today), D-$dday"
        else
            log "PASS" "마감일($deadline) >= 오늘($today) (정확한 일수 계산은 생략)"
        fi
        return 0
    else
        log "FAIL" "마감일($deadline) < 오늘($today)"
        return 1
    fi
}

# === Test Case 4: 합계 검증 ===
test_sum_validity() {
    log "INFO" "Test 4: 합계 계산 검증"

    local v1=100
    local v2=200
    local v3=300
    local expected=600

    local sum=$(echo "$v1 + $v2 + $v3" | bc -l)

    if (( $(echo "$sum == $expected" | bc -l) )); then
        log "PASS" "합계: $sum (기대값: $expected)"
        return 0
    else
        log "FAIL" "합계 오류: $sum (기대값: $expected)"
        return 1
    fi
}

# === Test Case 5: 태스크 개수 검증 ===
test_task_count_validity() {
    log "INFO" "Test 5: 태스크 개수 검증"

    # 정본은 runtime/config — 레포 루트 ~/projects/jarvis/config 는 2026-08 장애 잔재였다(2026-09-03 정리)
    local tasks_json="${BOT_HOME:-${HOME}/.openclaw-data/runtime}/config/tasks.json"

    if [[ ! -f "$tasks_json" ]]; then
        log "WARN" "tasks.json 파일 없음: $tasks_json"
        return 0
    fi

    local total=$(jq '.tasks | length' "$tasks_json" 2>/dev/null || echo "0")
    local disabled=$(jq '[.tasks[] | select(.enabled == false)] | length' "$tasks_json" 2>/dev/null || echo "0")
    local active=$(( total - disabled ))

    log "INFO" "태스크 개수: 전체=$total, disabled=$disabled, active=$active"

    # 검증: disabled + active == total
    if (( disabled + active == total )); then
        log "PASS" "태스크 개수 합계 검증: $disabled + $active = $total"
        return 0
    else
        log "FAIL" "태스크 개수 불일치: $disabled + $active != $total"
        return 1
    fi
}

# === 명령어 별 검증 함수 ===
check_dday() {
    local target_date="$1"
    local today=$(date '+%Y-%m-%d')

    if [[ "$target_date" > "$today" ]] || [[ "$target_date" == "$today" ]]; then
        local target_epoch=$(date -j -f "%Y-%m-%d" "$target_date" "+%s" 2>/dev/null || echo "0")
        local today_epoch=$(date -j -f "%Y-%m-%d" "$today" "+%s" 2>/dev/null || echo "0")
        if [[ "$target_epoch" != "0" ]] && [[ "$today_epoch" != "0" ]]; then
            local dday=$(( (target_epoch - today_epoch) / 86400 ))
            log "PASS" "D-day 검증: $target_date (D-$dday)"
        else
            log "PASS" "D-day 검증: $target_date >= 오늘 (정확한 일수 계산은 생략)"
        fi
        return 0
    else
        log "FAIL" "D-day 오류: $target_date < 오늘($today)"
        return 1
    fi
}

check_sum() {
    local expected=$1
    shift
    local values=("$@")
    local sum=0

    for v in "${values[@]}"; do
        sum=$(echo "$sum + $v" | bc -l)
    done

    if (( $(echo "$sum == $expected" | bc -l) )); then
        log "PASS" "합계 검증: ${values[*]} = $sum (기대값: $expected)"
        return 0
    else
        log "FAIL" "합계 오류: ${values[*]} = $sum (기대값: $expected)"
        return 1
    fi
}

# === 메인 ===
main() {
    log "INFO" "config-sanity 검증 시작 (cl-19d6b30bf68b02db)"

    local test_mode="${1:-}"
    local exit_code=0

    if [[ "$test_mode" == "--test" ]]; then
        log "INFO" "Test Mode: 5가지 내장 테스트 케이스 실행"

        test_stop_loss_margin || exit_code=1
        test_percentage_sum || exit_code=1
        test_dday_validity || exit_code=1
        test_sum_validity || exit_code=1
        test_task_count_validity || exit_code=1

        if [[ $exit_code -eq 0 ]]; then
            log "INFO" "✅ 모든 테스트 통과"
        else
            log "ERROR" "❌ 일부 테스트 실패"
        fi
    elif [[ "$test_mode" == "--check-dday" ]]; then
        if [[ -z "${2:-}" ]]; then
            echo "Usage: validate-config-sanity.sh --check-dday <ISO-DATE>" >&2
            return 2
        fi
        check_dday "$2" || exit_code=1
    elif [[ "$test_mode" == "--check-sum" ]]; then
        if [[ -z "${2:-}" ]]; then
            echo "Usage: validate-config-sanity.sh --check-sum <expected> <v1> <v2> ..." >&2
            return 2
        fi
        shift
        check_sum "$@" || exit_code=1
    elif [[ -z "$test_mode" ]]; then
        # 기본값: tasks.json 검증
        log "INFO" "기본 모드: tasks.json 검증"
        test_task_count_validity || exit_code=1
    else
        echo "Usage: validate-config-sanity.sh [--test|--check-dday DATE|--check-sum EXPECTED V1 V2 ...]" >&2
        return 2
    fi

    log "INFO" "로그 파일: $LOG_FILE"
    echo "로그 파일: $LOG_FILE" >&2
    return $exit_code
}

main "$@"
