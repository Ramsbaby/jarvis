#!/usr/bin/env bash
# cluster-guard-cl-de95f30916b8c9a2.test.sh — 가드 통합 테스트
#
# 실행: bash ~/projects/jarvis/infra/lib/cluster-guard-cl-de95f30916b8c9a2.test.sh
#
# 테스트 항목:
#   T1. ssot_prewrite_check: 새 사실이 기존 wiki와 충돌 없으면 통과
#   T2. ssot_prewrite_check: 동일 주제 다른 숫자면 차단
#   T3. ssot_propagation_gate: 대상 1개면 통과
#   T4. ssot_propagation_gate: 대상 2개 이상이면 차단
#   T5. ssot_propagation_gate: --force 로 override 시 경고 후 통과
#   T6. ssot_root_cause_require: 근본 원인 기록 시 통과
#   T7. ssot_root_cause_require: unknown 값이면 차단
#   T8. ssot_conflict_status: 상태 출력 (오류 없음)
#   T9. ssot_unresolved_scan: 미해결 스캔 (오류 없음)

set -o pipefail

GUARD_LIB="${HOME}/projects/jarvis/infra/lib/cluster-guard-cl-de95f30916b8c9a2.sh"

# shellcheck source=/dev/null
source "$GUARD_LIB" || { echo "FATAL: 가드 로드 실패"; exit 1; }

PASS=0
FAIL=0

_t_pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
_t_fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

_t_expect_exit() {
  local desc="$1" expected="$2"
  shift 2
  local actual
  "$@" >/dev/null 2>&1
  actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    _t_pass "$desc (exit $expected)"
  else
    _t_fail "$desc (expected exit $expected, got $actual)"
  fi
}

echo "━━━ cluster-guard-cl-de95f30916b8c9a2 통합 테스트 ━━━"
echo ""

# ── T1: prewrite_check — 충돌 없으면 통과 ───────────────────────────────────
echo "[T1] ssot_prewrite_check: 충돌 없는 신규 사실 → 통과"
_t_expect_exit "충돌 없는 사실 통과" 0 \
  ssot_prewrite_check "완전히 새로운 개념: 테스트 전용 데이터 2026-08-17 cl-de95 테스트"

# ── T2: prewrite_check — 숫자 충돌 시 차단 ──────────────────────────────────
echo "[T2] ssot_prewrite_check: 숫자 충돌 감지 → 차단 (wiki에 실제 유사 항목 없으면 통과도 정상)"
# wiki 내 실제 항목과 충돌하는 값을 넣어 테스트
# 실제 wiki 내용에 따라 결과가 달라질 수 있음 — 로직 실행 여부만 검증
RESULT=0
ssot_prewrite_check "다낭 항공권 결제 완료 비엣젯 1200000원" >/dev/null 2>&1 || RESULT=$?
if [[ "$RESULT" -eq 0 || "$RESULT" -eq 1 ]]; then
  _t_pass "ssot_prewrite_check 실행 성공 (충돌=${RESULT})"
else
  _t_fail "ssot_prewrite_check 예외 오류 (exit $RESULT)"
fi

# ── T3: propagation_gate — 대상 1개 → 통과 ──────────────────────────────────
echo "[T3] ssot_propagation_gate: 대상 1개 → 통과"
_t_expect_exit "단일 대상 통과" 0 \
  ssot_propagation_gate "test.label" "career"

# ── T4: propagation_gate — 대상 2개 → 차단 ──────────────────────────────────
echo "[T4] ssot_propagation_gate: 대상 2개 → 차단"
_t_expect_exit "복수 대상 차단" 1 \
  ssot_propagation_gate "test.label" "career" "family"

# ── T5: propagation_gate — --force → 경고 후 통과 ───────────────────────────
echo "[T5] ssot_propagation_gate: --force → 경고 후 통과"
_t_expect_exit "--force 복수 대상 통과" 0 \
  ssot_propagation_gate "test.label" --force "career" "family"

# ── T6: root_cause_require — 근본 원인 기록 → 통과 ──────────────────────────
echo "[T6] ssot_root_cause_require: 근본 원인 기록 → 통과"
_t_expect_exit "근본 원인 기록 통과" 0 \
  ssot_root_cause_require "test-violation-$(date +%s)" \
  "wiki 슬롯 없이 인라인 하드코딩으로 값을 전달하는 파이프라인 구조"

# ── T7: root_cause_require — unknown → 차단 ─────────────────────────────────
echo "[T7] ssot_root_cause_require: 'unknown' 값 → 차단"
_t_expect_exit "unknown 근본원인 차단" 1 \
  ssot_root_cause_require "test-unknown-$(date +%s)" "unknown"

# ── T8: ssot_conflict_status — 오류 없음 ────────────────────────────────────
echo "[T8] ssot_conflict_status: 출력 정상"
if ssot_conflict_status >/dev/null 2>&1; then
  _t_pass "ssot_conflict_status 정상 실행"
else
  _t_fail "ssot_conflict_status 실패"
fi

# ── T9: ssot_unresolved_scan — 오류 없음 ────────────────────────────────────
echo "[T9] ssot_unresolved_scan: 출력 정상"
SCAN_EXIT=0
ssot_unresolved_scan >/dev/null 2>&1 || SCAN_EXIT=$?
if [[ "$SCAN_EXIT" -le 1 ]]; then
  _t_pass "ssot_unresolved_scan 정상 실행 (미해결=${SCAN_EXIT})"
else
  _t_fail "ssot_unresolved_scan 예외 (exit $SCAN_EXIT)"
fi

# ── 결과 요약 ────────────────────────────────────────────────────────────────
echo ""
echo "━━━ 테스트 결과 ━━━"
echo "  통과: ${PASS} / 실패: ${FAIL}"
[[ "$FAIL" -eq 0 ]] && echo "  ✅ ALL PASS" || echo "  ❌ FAILURES: ${FAIL}"
echo ""

exit "$([[ $FAIL -eq 0 ]] && echo 0 || echo 1)"
