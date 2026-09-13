#!/usr/bin/env bash
# verify-derived-values.test.sh — cl-19d6b30bf68b02db 테스트 스위트
# 파생값 검증 함수의 9개 테스트 케이스

set -u pipefail

# 테스트 모듈 로드
source "${HOME}/projects/jarvis/infra/lib/verify-derived-values.sh"

# 테스트 결과 추적
TEST_PASS=0
TEST_FAIL=0

test_case() {
    local name="$1"
    echo ""
    echo "========== [TEST] $name =========="
}

echo "======================================"
echo "파생값 검증 테스트 스위트"
echo "======================================"

# TEST 1: D-day 검증 — 정상 케이스 (9월 4일 - 8월 28일 = 7일)
test_case "D-day 검증: 정상 케이스 (7일)"
if verify_dday "2026-09-04" "2026-08-28" "7" "hanwha_start_to_first_day"; then
    ((TEST_PASS++))
    echo "✓ 통과"
else
    ((TEST_FAIL++))
    echo "✗ 실패"
fi

# TEST 2: D-day 검증 — 틀린 예상값 (5일이라고 했지만 실제는 7일)
test_case "D-day 검증: 예상값 오류 (5일 vs 7일)"
if ! verify_dday "2026-09-04" "2026-08-28" "5" "wrong_dday" 2>/dev/null; then
    ((TEST_PASS++))
    echo "✓ 통과 (예상된 실패)"
else
    ((TEST_FAIL++))
    echo "✗ 실패 (예상: 실패, 실제: 성공)"
fi

# TEST 3: 합계 검증 — 정상 케이스 (100 + 200 + 300 = 600)
test_case "합계 검증: 정상 케이스 (100 + 200 + 300 = 600)"
if verify_sum "100 200 300" "600" "trip_costs"; then
    ((TEST_PASS++))
    echo "✓ 통과"
else
    ((TEST_FAIL++))
    echo "✗ 실패"
fi

# TEST 4: 합계 검증 — 오류 케이스 (실제는 600인데 500이라고 함)
test_case "합계 검증: 예상값 오류 (500 vs 600)"
if ! verify_sum "100 200 300" "500" "wrong_sum" 2>/dev/null; then
    ((TEST_PASS++))
    echo "✓ 통과 (예상된 실패)"
else
    ((TEST_FAIL++))
    echo "✗ 실패 (예상: 실패, 실제: 성공)"
fi

# TEST 5: 비율 검증 — 정상 케이스 (150/600 = 0.25)
test_case "비율 검증: 정상 케이스 (150/600 = 0.25)"
if verify_ratio "150" "600" "0.25" "hotel_cost_ratio"; then
    ((TEST_PASS++))
    echo "✓ 통과"
else
    ((TEST_FAIL++))
    echo "✗ 실패"
fi

# TEST 6: 비율 검증 — 오차 범위 내 (계산: 0.2501, 예상: 0.25)
test_case "비율 검증: 오차 범위 내 (오차 < 1%)"
if verify_ratio "150.06" "600" "0.25" "hotel_ratio_within_tolerance"; then
    ((TEST_PASS++))
    echo "✓ 통과"
else
    ((TEST_FAIL++))
    echo "✗ 실패"
fi

# TEST 7: 비율 검증 — 오차 범위 초과 (계산: 0.33, 예상: 0.25)
test_case "비율 검증: 오차 범위 초과 (오차 > 1%)"
if ! verify_ratio "200" "600" "0.25" "wrong_ratio" 2>/dev/null; then
    ((TEST_PASS++))
    echo "✓ 통과 (예상된 실패)"
else
    ((TEST_FAIL++))
    echo "✗ 실패 (예상: 실패, 실제: 성공)"
fi

# TEST 8: 실제 데이터: 다낭 여행 D-day (8/29~9/2, 4박5일)
test_case "실제 데이터: 다낭 여행 D-day (8/29~9/2, 4박5일)"
if verify_dday "2026-09-02" "2026-08-29" "4" "danang_trip_nights"; then
    ((TEST_PASS++))
    echo "✓ 통과"
else
    ((TEST_FAIL++))
    echo "✗ 실패"
fi

# TEST 9: 실제 데이터: 여행비 합계
test_case "실제 데이터: 여행비 합계 (항공 150만 + 숙박 60만 + 식사 30만 = 240만)"
if verify_sum "1500000 600000 300000" "2400000" "danang_total_cost"; then
    ((TEST_PASS++))
    echo "✓ 통과"
else
    ((TEST_FAIL++))
    echo "✗ 실패"
fi

echo ""
echo "======================================"
echo "테스트 결과"
echo "======================================"
echo "통과: $TEST_PASS건"
echo "실패: $TEST_FAIL건"
echo "======================================"

if [[ $TEST_FAIL -gt 0 ]]; then
    echo "⚠ 일부 테스트 실패"
    exit 1
else
    echo "✓ 모든 테스트 통과"
    exit 0
fi
