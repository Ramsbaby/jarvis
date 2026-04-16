#!/usr/bin/env bash
# cron-failure-tracker.sh — 크론 실패 감지 → dev-queue 자동 티켓 생성
#
# 역할 (DevOps, HR 아님):
#   1. cron-auditor.sh 실행 → FAIL/DEAD 태스크 목록 추출
#   2. 각 실패 태스크 → task-store에 debug 티켓 자동 등록 (중복 없음)
#   3. 결과 요약 출력 (council → board 저장용)
#
# Usage:
#   cron-failure-tracker.sh           # 실제 실행
#   cron-failure-tracker.sh --dry-run # 티켓 생성 없이 현황만 출력

set -uo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LOG="${BOT_HOME}/logs/cron-failure-tracker.log"
TASK_STORE="${BOT_HOME}/lib/task-store.mjs"
mkdir -p "$(dirname "$LOG")"

DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TS] cron-failure-tracker 시작 (dry_run=${DRY_RUN})" | tee -a "$LOG"

# ── 1. cron-auditor.sh 실행 ────────────────────────────────────────────────────
AUDIT_OUT=$(BOT_HOME="$BOT_HOME" bash "${BOT_HOME}/scripts/cron-auditor.sh" 2>/dev/null) || {
    echo "[$TS] ERROR: cron-auditor.sh 실행 실패" | tee -a "$LOG"
    exit 1
}

# ── 2. FAIL/STALE 태스크 추출 (DEAD 제외 — 비활성/미사용 태스크 정상)
# FAIL = 마지막 실행 결과 FAILED/ERROR
# STALE = 마지막 실행이 예상 주기 5배 초과 (실행 누락)
FAILURES=$(echo "$AUDIT_OUT" | grep -E '\s(FAIL|STALE)\s' | awk '{print $1, $2}' || true)

if [[ -z "$FAILURES" ]]; then
    echo "[$TS] 크론 실패 없음 — 티켓 생성 불필요" | tee -a "$LOG"
    echo ""
    echo "✅ 크론 전체 정상 — 실패 티켓 없음 ($(date '+%Y-%m-%d %H:%M'))"
    exit 0
fi

echo "[$TS] 실패 태스크 감지:" | tee -a "$LOG"
echo "$FAILURES" | while read -r line; do
    echo "  $line" | tee -a "$LOG"
done

# ── 3. 실패 태스크 → dev-queue 티켓 자동 등록 ─────────────────────────────────
TICKET_CREATED=0
TICKET_EXISTS=0
TICKET_DETAILS=""

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    TASK_NAME=$(echo "$line" | awk '{print $1}' | tr -d '[:space:]')
    STATUS=$(echo "$line" | awk '{print $2}' | tr -d '[:space:]')

    [[ -z "$TASK_NAME" ]] && continue

    TICKET_ID="debug-cron-${TASK_NAME}"
    # ID 길이 제한 (50자)
    TICKET_ID="${TICKET_ID:0:50}"

    DESCRIPTION="크론 실패 자동감지: ${TASK_NAME} (상태: ${STATUS}) — 로그 확인 후 원인 파악 및 스크립트 수정 필요. 참고: ${BOT_HOME}/logs/cron.log"

    if [[ "$DRY_RUN" == "false" ]]; then
        RESULT=$(node "$TASK_STORE" ensure "$TICKET_ID" "$DESCRIPTION" "infra" "$DESCRIPTION" 2>/dev/null | grep -v ExperimentalWarning || echo '{"ok":false}')
        IS_NEW=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('isNew','false'))" 2>/dev/null || echo "false")
        if [[ "$IS_NEW" == "True" || "$IS_NEW" == "true" ]]; then
            ((TICKET_CREATED++)) || true
            TICKET_DETAILS="${TICKET_DETAILS}\n  🆕 [${STATUS}] ${TASK_NAME} → 티켓: ${TICKET_ID}"
            echo "[$TS] 신규 티켓 생성: $TICKET_ID" | tee -a "$LOG"
        else
            ((TICKET_EXISTS++)) || true
            TICKET_DETAILS="${TICKET_DETAILS}\n  ♻️  [${STATUS}] ${TASK_NAME} → 기존 티켓 유지"
            echo "[$TS] 기존 티켓 유지: $TICKET_ID" | tee -a "$LOG"
        fi
    else
        TICKET_DETAILS="${TICKET_DETAILS}\n  [DRY] [${STATUS}] ${TASK_NAME} → 티켓 예정: ${TICKET_ID}"
    fi
done <<< "$FAILURES"

# ── 4. 결과 요약 출력 ─────────────────────────────────────────────────────────
TOTAL_FAIL=$(echo "$FAILURES" | grep -c . || echo "0")

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔍 [DRY-RUN] 크론 실패 현황 — $(date '+%Y-%m-%d %H:%M')"
else
    echo "🔧 크론 실패 티켓 처리 완료 — $(date '+%Y-%m-%d %H:%M')"
fi
echo "- 감지된 실패: ${TOTAL_FAIL}건"
if [[ "$DRY_RUN" == "false" ]]; then
    echo "- 신규 티켓: ${TICKET_CREATED}건 / 기존 유지: ${TICKET_EXISTS}건"
fi
echo -e "- 상세:${TICKET_DETAILS}"
echo ""
echo "dev-queue에서 확인: node ${TASK_STORE} list | grep debug-cron"

echo "[$TS] cron-failure-tracker 완료" | tee -a "$LOG"
