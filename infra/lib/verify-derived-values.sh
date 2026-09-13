#!/usr/bin/env bash
# verify-derived-values.sh — cl-19d6b30bf68b02db 파생값 검증 가드
# 목적: D-day, 합계, 비율 계산 후 자동 재검산 및 검증
# 사용: source ~/projects/jarvis/infra/lib/verify-derived-values.sh
#       verify_dday "2026-09-04" "2026-08-28" "hanwha_first_day"
#       verify_sum "100 200 300" "600" "trip_costs"
#       verify_ratio "150" "600" "0.25" "hotel_ratio"

set -euo pipefail

# 로그 파일
DERIVE_VERIFY_LOG="${HOME}/.jarvis/logs/verify-derived-values-$$.log"
mkdir -p "$(dirname "$DERIVE_VERIFY_LOG")"

# 검증 결과 원장 (JSONL)
VERIFY_RECORD="${HOME}/.jarvis/logs/verify-derived-values.jsonl"

log_verify() {
    local type="$1" result="$2" expected="$3" actual="$4" label="$5"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $type ($label): $result | 예상=$expected | 실제=$actual" >> "$DERIVE_VERIFY_LOG"

    # JSONL 원장 기록
    {
        echo "{\"ts\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"type\":\"$type\",\"label\":\"$label\",\"result\":\"$result\",\"expected\":\"$expected\",\"actual\":\"$actual\"}"
    } >> "$VERIFY_RECORD"
}

# 검증 함수 1: D-day 검증
# 기준: target_date - base_date = expected_days
verify_dday() {
    local target_date="$1" base_date="$2" expected_days="$3" label="${4:-dday}"

    # 날짜 파싱 (YYYY-MM-DD 형식)
    if ! [[ "$target_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || \
       ! [[ "$base_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log_verify "DDAY" "PARSE_ERROR" "$expected_days" "invalid_format" "$label"
        echo "[ERROR] 날짜 형식 오류: $target_date vs $base_date (YYYY-MM-DD 필수)" >&2
        return 1
    fi

    # 날짜 차이 계산 (초 단위 → 일 단위)
    local target_ts=$(date -j -f "%Y-%m-%d" "$target_date" "+%s" 2>/dev/null || echo "0")
    local base_ts=$(date -j -f "%Y-%m-%d" "$base_date" "+%s" 2>/dev/null || echo "0")

    if [[ "$target_ts" == "0" ]] || [[ "$base_ts" == "0" ]]; then
        log_verify "DDAY" "DATE_PARSE_ERROR" "$expected_days" "date_parse_failed" "$label"
        return 1
    fi

    local diff_secs=$((target_ts - base_ts))
    local calculated_days=$((diff_secs / 86400))  # 86400초 = 1일

    # 음수 처리 (과거 날짜)
    if [[ "$diff_secs" -lt 0 ]]; then
        calculated_days=$((-calculated_days))
    fi

    # 검증
    if [[ "$calculated_days" == "$expected_days" ]]; then
        log_verify "DDAY" "PASS" "$expected_days" "$calculated_days" "$label"
        echo "✓ D-day 검증 PASS: $label = $calculated_days일 (기준: $base_date, 목표: $target_date)"
        return 0
    else
        log_verify "DDAY" "FAIL" "$expected_days" "$calculated_days" "$label"
        echo "✗ D-day 검증 FAIL: $label | 예상=$expected_days일, 실제=$calculated_days일" >&2
        return 1
    fi
}

# 검증 함수 2: 합계 검증
# 기준: item1 + item2 + ... + itemN = expected_sum
verify_sum() {
    local items_str="$1" expected_sum="$2" label="${3:-sum}"

    # 숫자 검증
    if ! [[ "$expected_sum" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_verify "SUM" "PARSE_ERROR" "$expected_sum" "invalid_number" "$label"
        echo "[ERROR] 합계 숫자 형식 오류: $expected_sum" >&2
        return 1
    fi

    # 개별 항목 파싱 및 합산
    local calculated_sum=0
    local item_count=0

    for item in $items_str; do
        if [[ "$item" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            calculated_sum=$(echo "$calculated_sum + $item" | bc)
            ((item_count++))
        else
            log_verify "SUM" "ITEM_PARSE_ERROR" "$expected_sum" "$item" "$label"
            echo "[ERROR] 항목 숫자 형식 오류: $item" >&2
            return 1
        fi
    done

    # 소수점 정규화 (bc 결과가 trailing 0을 붙을 수 있음)
    calculated_sum=$(echo "$calculated_sum" | xargs printf '%.2f')
    expected_normalized=$(printf '%.2f' "$expected_sum")

    # 검증
    if [[ "$calculated_sum" == "$expected_normalized" ]] || \
       [[ $(echo "$calculated_sum - $expected_normalized" | bc | tr -d '-') < "0.01" ]]; then
        log_verify "SUM" "PASS" "$expected_sum" "$calculated_sum" "$label"
        echo "✓ 합계 검증 PASS: $label = $calculated_sum (항목 $item_count개)"
        return 0
    else
        log_verify "SUM" "FAIL" "$expected_sum" "$calculated_sum" "$label"
        echo "✗ 합계 검증 FAIL: $label | 예상=$expected_normalized, 실제=$calculated_sum" >&2
        return 1
    fi
}

# 검증 함수 3: 비율 검증
# 기준: part / whole = expected_ratio (오차범위 ±0.01)
verify_ratio() {
    local part="$1" whole="$2" expected_ratio="$3" label="${4:-ratio}"

    # 숫자 검증
    if ! [[ "$part" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
       ! [[ "$whole" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
       ! [[ "$expected_ratio" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_verify "RATIO" "PARSE_ERROR" "$expected_ratio" "invalid_numbers" "$label"
        echo "[ERROR] 비율 숫자 형식 오류: part=$part, whole=$whole, expected=$expected_ratio" >&2
        return 1
    fi

    # 0으로 나누기 체크
    if [[ $(echo "$whole == 0" | bc) == "1" ]]; then
        log_verify "RATIO" "DIVIDE_BY_ZERO" "$expected_ratio" "0" "$label"
        echo "[ERROR] 전체값이 0: $label" >&2
        return 1
    fi

    # 비율 계산
    local calculated_ratio=$(echo "scale=4; $part / $whole" | bc)

    # 소수점 정규화
    expected_normalized=$(printf '%.4f' "$expected_ratio")
    calculated_normalized=$(printf '%.4f' "$calculated_ratio")

    # 오차범위 검증 (±1%)
    local diff=$(echo "$calculated_ratio - $expected_ratio" | bc | tr -d '-')
    local tolerance="0.0100"

    if [[ $(echo "$diff < $tolerance" | bc) == "1" ]]; then
        log_verify "RATIO" "PASS" "$expected_ratio" "$calculated_ratio" "$label"
        echo "✓ 비율 검증 PASS: $label = $calculated_normalized (part=$part, whole=$whole)"
        return 0
    else
        log_verify "RATIO" "FAIL" "$expected_ratio" "$calculated_ratio" "$label"
        echo "✗ 비율 검증 FAIL: $label | 예상=$expected_normalized, 실제=$calculated_normalized (오차=$diff)" >&2
        return 1
    fi
}

# 검증 요약 출력
verify_summary() {
    if [[ ! -f "$DERIVE_VERIFY_LOG" ]]; then
        echo "검증 기록 없음"
        return 0
    fi

    echo "======================================="
    echo "파생값 검증 요약 ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "======================================="
    cat "$DERIVE_VERIFY_LOG"
    echo ""

    # 통계
    local total=$(grep -c "^" "$DERIVE_VERIFY_LOG" 2>/dev/null || echo "0")
    local passed=$(grep -c " PASS " "$DERIVE_VERIFY_LOG" 2>/dev/null || echo "0")
    local failed=$(grep -c " FAIL " "$DERIVE_VERIFY_LOG" 2>/dev/null || echo "0")

    echo "통계: 총 $total건, 통과 $passed건, 실패 $failed건"

    if [[ "$failed" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# 모듈로서 export (source 될 때)
export -f verify_dday verify_sum verify_ratio verify_summary
