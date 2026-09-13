#!/usr/bin/env bash
# cluster-guard-cl-faf6f4c1f94bd512.test.sh — 가드 자기 검증 테스트
#
# 사용: bash ~/projects/jarvis/infra/lib/cluster-guard-cl-faf6f4c1f94bd512.test.sh
# 종료: 0=전부 통과, 1=일부 실패

set -o pipefail

GUARD_SCRIPT="${HOME}/projects/jarvis/infra/lib/cluster-guard-cl-faf6f4c1f94bd512.sh"
source "$GUARD_SCRIPT" || { echo "ERROR: 가드 로드 실패" >&2; exit 1; }

PASS=0; FAIL=0; TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

_assert() {
    local desc="$1" expected_rc="$2"
    shift 2
    local actual_rc=0
    "$@" >/dev/null 2>&1 || actual_rc=$?
    if [[ "$actual_rc" -eq "$expected_rc" ]]; then
        echo "  PASS: $desc"
        (( PASS++ )) || true
    else
        echo "  FAIL: $desc (기대 rc=${expected_rc}, 실제 rc=${actual_rc})"
        (( FAIL++ )) || true
    fi
}

echo "=== cl-faf6f4c1f94bd512 가드 테스트 ==="
echo ""

# ── 1. bg_task_verify ────────────────────────────────────────────────────────
echo "[1] bg_task_verify"

# 1-1: 산출물 존재 + .exit 파일 없음 → OK (rc=0)
ARTIFACT="${TMPDIR_TEST}/artifact1.txt"
touch "$ARTIFACT"
_assert "산출물 존재, .exit 없음 → rc=0" 0 \
    bg_task_verify "test-task-1" "0" "$ARTIFACT"

# 1-2: 산출물 없음 → rc=1
_assert "산출물 누락 → rc=1" 1 \
    bg_task_verify "test-task-2" "0" "${TMPDIR_TEST}/nonexistent.txt"

# 1-3: 산출물 존재 + exit code 일치 → rc=0
ARTIFACT3="${TMPDIR_TEST}/artifact3.txt"
touch "$ARTIFACT3"
echo "0" > "${_CL_FAF6_STATE_DIR}/test-task-3.exit"
_assert "산출물+exit 일치 → rc=0" 0 \
    bg_task_verify "test-task-3" "0" "$ARTIFACT3"

# 1-4: 산출물 존재 + exit code 불일치 → rc=2
ARTIFACT4="${TMPDIR_TEST}/artifact4.txt"
touch "$ARTIFACT4"
echo "1" > "${_CL_FAF6_STATE_DIR}/test-task-4.exit"
_assert "산출물 있지만 exit 불일치 → rc=2" 2 \
    bg_task_verify "test-task-4" "0" "$ARTIFACT4"

# 1-5: bg_task_record_exit 기록 후 대조
bg_task_record_exit "test-task-5" "0" 2>/dev/null
ARTIFACT5="${TMPDIR_TEST}/artifact5.txt"
touch "$ARTIFACT5"
_assert "record_exit 후 verify → rc=0" 0 \
    bg_task_verify "test-task-5" "0" "$ARTIFACT5"

# ── 2. exec_declare_check ────────────────────────────────────────────────────
echo ""
echo "[2] exec_declare_check"

# 2-1: 파일 없음 → rc=1
_assert "파일 없음 → rc=1" 1 \
    exec_declare_check "check-1" "$(date '+%s')" "${TMPDIR_TEST}/nope.txt"

# 2-2: 선언 시각 == now, 파일 mtime == now → 차이 0초 → OK
FILE2="${TMPDIR_TEST}/check2.txt"
NOW=$(date '+%s')
touch "$FILE2"
_assert "선언==now, mtime==now → rc=0" 0 \
    exec_declare_check "check-2" "$NOW" "$FILE2" 5

# 2-3: 선언 시각 vs 파일 mtime 차이가 skew 초과 → rc=2
FILE3="${TMPDIR_TEST}/check3.txt"
touch "$FILE3"
STALE_EPOCH=$(( $(date '+%s') - 120 ))  # 2분 전 선언
_assert "선언 2분 전, skew=30 → rc=2" 2 \
    exec_declare_check "check-3" "$STALE_EPOCH" "$FILE3" 30

# ── 3. interruption_recovery_check ───────────────────────────────────────────
echo ""
echo "[3] interruption_recovery_check"

# 3-1: 존재하지 않는 PID + 산출물 없음 → rc=1 (재실행 필요)
_assert "Dead PID + 산출물 없음 → rc=1" 1 \
    interruption_recovery_check "irec-1" "99999999" "${TMPDIR_TEST}/missing.txt"

# 3-2: 존재하지 않는 PID + 산출물 있음 → rc=2 (완료로 간주)
IREC2_ART="${TMPDIR_TEST}/irec2.txt"
touch "$IREC2_ART"
_assert "Dead PID + 산출물 있음 → rc=2" 2 \
    interruption_recovery_check "irec-2" "99999999" "$IREC2_ART"

# 3-3: 현재 셸의 PID는 살아있음 → rc=0
IREC3_ART="${TMPDIR_TEST}/irec3.txt"
touch "$IREC3_ART"
_assert "살아있는 PID → rc=0" 0 \
    interruption_recovery_check "irec-3" "$$" "$IREC3_ART"

# ── 4. layout_revalidate_hook ────────────────────────────────────────────────
echo ""
echo "[4] layout_revalidate_hook"

SESS="test-sess-$(date '+%s')"
LFILE="${TMPDIR_TEST}/layout.html"
touch "$LFILE"

# threshold=3, 처음 두 번은 rc=0
_assert "수정1/3 → rc=0" 0 layout_revalidate_hook "$SESS" "$LFILE" 3
_assert "수정2/3 → rc=0" 0 layout_revalidate_hook "$SESS" "$LFILE" 3
# 세 번째에 threshold 도달 → rc=1
_assert "수정3/3 → rc=1 (재검증 필요)" 1 layout_revalidate_hook "$SESS" "$LFILE" 3

# mark_done 후 다음 호출 → rc=2
layout_revalidate_mark_done "$SESS" "$LFILE" 2>/dev/null
_assert "mark_done 후 → rc=2 (이미 완료)" 2 layout_revalidate_hook "$SESS" "$LFILE" 3

# ── 결과 ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== 결과: PASS=${PASS}, FAIL=${FAIL} ==="

# cleanup test exit files
rm -f "${_CL_FAF6_STATE_DIR}/test-task-"*.exit 2>/dev/null || true
rm -f "${_CL_FAF6_STATE_DIR}/irec-1.recovery" 2>/dev/null || true

[[ $FAIL -eq 0 ]]
