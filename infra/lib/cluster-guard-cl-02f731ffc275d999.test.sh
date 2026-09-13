#!/usr/bin/env bash
# 스모크 테스트 — cluster-guard-cl-02f731ffc275d999
# 실행: bash ~/projects/jarvis/infra/lib/cluster-guard-cl-02f731ffc275d999.test.sh
set -u
FAIL=0
pass() { printf '  ✅ %s\n' "$*"; }
fail() { printf '  ❌ %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "== 1. 표준 명명 shim 로드 =="
if source ~/projects/jarvis/infra/lib/cluster-guard-cl-02f731ffc275d999.sh 2>/dev/null; then
    pass "shim source OK"
else
    fail "shim source 실패"
fi

echo "== 2. 공개 API 존재 =="
for fn in check_file_freshness annotate_context_with_timestamps data_freshness_summary guard_cl_02f731_status; do
    if declare -F "$fn" >/dev/null; then pass "$fn 정의됨"; else fail "$fn 미정의"; fi
done

echo "== 3. fresh 파일 판정 =="
TMP="$(mktemp)"; touch "$TMP"
if check_file_freshness "$TMP" 30 "smoke" >/dev/null 2>&1; then
    pass "새 파일 = fresh"
else
    fail "새 파일이 stale로 판정됨"
fi
rm -f "$TMP"

echo "== 4. stale 판정 =="
TMP="$(mktemp)"; touch -t 202001010000 "$TMP"
check_file_freshness "$TMP" 30 "smoke-stale" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 1 ]]; then pass "오래된 파일 = stale (exit 1)"; else fail "stale 판정 실패 (rc=$rc)"; fi
rm -f "$TMP"

echo "== 5. 파일 부재 = exit 2 =="
check_file_freshness "/nonexistent/$$/x" 30 "smoke-missing" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then pass "부재 = exit 2"; else fail "부재 판정 실패 (rc=$rc)"; fi

echo "== 6. annotate_context 출력에 헤더 포함 =="
out="$(annotate_context_with_timestamps 2>/dev/null)"
if echo "$out" | grep -q "참조 데이터 신선도"; then
    pass "헤더 포함"
else
    fail "헤더 누락"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf '전체 통과 ✅\n'; exit 0
else
    printf '실패 %d건 ❌\n' "$FAIL"; exit 1
fi
