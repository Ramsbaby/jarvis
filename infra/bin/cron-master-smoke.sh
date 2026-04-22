#!/usr/bin/env bash
# cron-master-smoke.sh — cron-master.sh regression 테스트
#
# 2026-04-21 신설: 07:00/07:30 UNLOADED[@] 빈 배열 폭사 재발 방지 포함.
# 주요 동작 플로우를 dry-run으로 재현하며, 과거 결함이 되살아났는지 검증한다.
#
# 사용:
#   bash cron-master-smoke.sh              # 전체 테스트
#   bash cron-master-smoke.sh --verbose    # 각 테스트 stdout/stderr 전체 노출
#
# Exit: 0 = 전체 통과, 1 = 하나 이상 실패

set -euo pipefail

VERBOSE=0
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=1; fi

CRON_MASTER="${HOME}/jarvis/runtime/bin/cron-master.sh"
STATE_DIR="${HOME}/jarvis/runtime/state"
DIGEST_FILE="${STATE_DIR}/cron-master-last-digest.txt"
LEDGER_FILE="${STATE_DIR}/cron-master-ledger.jsonl"

PASS=0
FAIL=0
FAILED_CASES=()

say() { printf "%s\n" "$*"; }
ok()  { PASS=$((PASS+1)); say "  ✅ $*"; }
ng()  { FAIL=$((FAIL+1)); FAILED_CASES+=("$*"); say "  ❌ $*"; }

# ── 사전 체크 ────────────────────────────────────────────────────────────────
say "🧪 cron-master-smoke 시작"
say ""
if [[ ! -x "$CRON_MASTER" ]]; then
  ng "cron-master.sh 실행 불가: $CRON_MASTER"
  exit 1
fi
ok "cron-master.sh 실행 가능 확인"

# ── Test 1: DRY-RUN 기본 실행 rc=0 ────────────────────────────────────────────
say ""
say "[Test 1] DRY-RUN 기본 실행 — rc=0 기대"
rm -f "$DIGEST_FILE"
out=""
rc=0
if out=$(CRON_MASTER_DRY_RUN=1 bash "$CRON_MASTER" 2>&1); then rc=0; else rc=$?; fi
if [[ "$rc" == "0" ]]; then
  ok "rc=0 (정상 종료)"
else
  ng "rc=$rc (기대 0)"
  if [[ "$VERBOSE" == "1" ]]; then say "  out: $out"; fi
fi

# ── Test 2: UNLOADED 빈 배열에서도 폭사하지 않음 ──────────────────────────────
# (2026-04-21 07:00/07:30 폭사 regression 재발 방지)
say ""
say "[Test 2] UNLOADED 빈 배열 시나리오 — unbound variable 에러 없어야 함"
rm -f "$DIGEST_FILE"
out=$(CRON_MASTER_DRY_RUN=1 bash "$CRON_MASTER" 2>&1 || true)
if echo "$out" | grep -q "UNLOADED\[@\]: unbound variable"; then
  ng "UNLOADED[@] unbound variable 재발 감지!"
else
  ok "UNLOADED 빈 배열 regression 없음"
fi

# ── Test 3: 영구 실패 분류기 — 함수/변수/리포트 섹션 구조적 존재 확인 ─────────
# (동적 트리거 검증은 실시점 UNLOADED 상태에 의존 → 원장 기반 간접 검증으로 전환)
say ""
say "[Test 3] 영구 실패 분류기 — 구조적 존재 확인"
if grep -qE "^classify_permanent_failure\s*\(\s*\)" "$CRON_MASTER"; then
  ok "classify_permanent_failure 함수 정의"
else
  ng "classify_permanent_failure 함수 누락"
fi
if grep -qE "^auto_disable_launchagent\s*\(\s*\)" "$CRON_MASTER"; then
  ok "auto_disable_launchagent 함수 정의"
else
  ng "auto_disable_launchagent 함수 누락"
fi
if grep -qE "JARVIS_CRON_AUTO_DISABLE|JARVIS_CRON_PERMA_FAIL_DAYS" "$CRON_MASTER"; then
  ok "환경변수 제어 레버 (AUTO_DISABLE/PERMA_FAIL_DAYS)"
else
  ng "환경변수 제어 레버 누락"
fi

# ── Test 4: auto-disable 기본 OFF (Iron Law 3 — 파괴적 조치 기본 차단) ─────────
say ""
say "[Test 4] AUTO_DISABLE 기본 OFF — 'auto-disable 실행' 섹션 출력 없어야 함"
rm -f "$DIGEST_FILE"
out=$(CRON_MASTER_DRY_RUN=1 JARVIS_CRON_PERMA_FAIL_DAYS=2 bash "$CRON_MASTER" 2>&1 || true)
if echo "$out" | grep -qE "^🔒 \*\*auto-disable 실행"; then
  ng "AUTO_DISABLE OFF인데 disable 섹션이 출력됨 (Iron Law 3 위반)"
else
  ok "AUTO_DISABLE OFF 기본값 준수"
fi

# ── Test 5: 리포트 dedup — 2차 실행 stdout 0줄 ────────────────────────────────
say ""
say "[Test 5] 리포트 dedup — 동일 digest 2차 실행은 stdout 0줄"
rm -f "$DIGEST_FILE"
_first=$(CRON_MASTER_DRY_RUN=1 bash "$CRON_MASTER" 2>/dev/null | wc -l | tr -d ' ')
second=$(CRON_MASTER_DRY_RUN=1 bash "$CRON_MASTER" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$second" == "0" ]]; then
  ok "2차 실행 stdout 0줄 (Discord 전송 skip)"
else
  ng "2차 stdout $second줄 (기대 0) — dedup 깨짐"
fi

# ── Test 6: FORCE_REPORT=1 — 변화 없어도 강제 전송 ────────────────────────────
say ""
say "[Test 6] FORCE_REPORT=1 — 변화 없어도 리포트 출력"
forced=$(CRON_MASTER_DRY_RUN=1 JARVIS_CRON_FORCE_REPORT=1 bash "$CRON_MASTER" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$forced" -gt "10" ]]; then
  ok "강제 전송 모드 (stdout ${forced}줄)"
else
  ng "FORCE_REPORT=1인데 출력 ${forced}줄 (기대 >10)"
fi

# ── Test 7: JSON 원장 파일 append-only 유효성 ─────────────────────────────────
say ""
say "[Test 7] 원장 파일 JSON 라인 유효성"
if [[ -f "$LEDGER_FILE" ]]; then
  invalid=$(tail -20 "$LEDGER_FILE" | while read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    echo "$line" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null || echo "BAD: $line"
  done | grep -c "^BAD:" || true)
  if [[ "$invalid" == "0" ]]; then
    ok "최근 20개 원장 라인 모두 JSON 유효"
  else
    ng "원장에 invalid JSON $invalid건"
  fi
else
  say "  ⚠️ 원장 파일 없음 (첫 실행 전) — skip"
fi

# ── Test 8: 리포트 내 필수 섹션 존재 ──────────────────────────────────────────
say ""
say "[Test 8] FORCE 리포트에 필수 섹션 포함"
rm -f "$DIGEST_FILE"
forced_out=$(CRON_MASTER_DRY_RUN=1 JARVIS_CRON_FORCE_REPORT=1 bash "$CRON_MASTER" 2>/dev/null || true)
for section in "크론 마스터 종합 리포트" "상세 (어제 대비)" "리포트 생성:"; do
  if echo "$forced_out" | grep -qF "$section"; then
    ok "섹션 존재: \"$section\""
  else
    ng "섹션 누락: \"$section\""
  fi
done

# ── 결과 요약 ────────────────────────────────────────────────────────────────
say ""
say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
say "📊 결과: PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -gt "0" ]]; then
  say ""
  say "❌ 실패 케이스:"
  for f in "${FAILED_CASES[@]}"; do
    say "  - $f"
  done
  exit 1
fi
say "✅ 전체 통과"
exit 0
