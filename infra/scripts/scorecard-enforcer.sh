#!/usr/bin/env bash
# scorecard-enforcer.sh — 크론 실패 → DevOps 자동 조치 집행기
#
# 역할 (DevOps, HR 아님):
#   1. cron-failure-tracker.sh 실행 → FAIL/STALE 크론 감지
#   2. 실패 크론 → dev-queue 티켓 자동 생성 (중복 없음)
#   3. 티켓 생성 결과 요약 → board 저장 + 필요 시 Discord
#
# 구 벌점 시스템 (HR 개념) 완전 제거:
#   - PROBATION/DISCIPLINARY/소집 없음
#   - 에이전트는 HR 대상이 아닌 DevOps 대상
#   - 실패 → 티켓 → 자동 수정 시도 or 에스컬레이션
#
# Usage:
#   scorecard-enforcer.sh           # 실제 실행
#   scorecard-enforcer.sh --dry-run # 현황만 출력

set -uo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG="${BOT_HOME}/logs/scorecard-enforcer.log"
mkdir -p "$(dirname "$LOG")"

# board-report 라이브러리 로드
source "${BOT_HOME}/lib/board-report.sh" 2>/dev/null || true

DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TS] scorecard-enforcer 시작 (dry_run=${DRY_RUN})" | tee -a "$LOG"

# ── 1. cron-failure-tracker.sh 실행 ───────────────────────────────────────────
TRACKER_ARGS=""
[[ "$DRY_RUN" == "true" ]] && TRACKER_ARGS="--dry-run"

TRACKER_OUT=$(BOT_HOME="$BOT_HOME" bash "${BOT_HOME}/scripts/cron-failure-tracker.sh" $TRACKER_ARGS 2>/dev/null) || {
    echo "[$TS] ERROR: cron-failure-tracker.sh 실행 실패" | tee -a "$LOG"
    exit 1
}

echo "$TRACKER_OUT"
echo "[$TS] cron-failure-tracker 완료" | tee -a "$LOG"

# ── 2. 신규 티켓 수 추출 ─────────────────────────────────────────────────────
NEW_TICKETS=$(echo "$TRACKER_OUT" | grep -c "🆕" 2>/dev/null) || NEW_TICKETS=0
TOTAL_FAIL=$(echo "$TRACKER_OUT" | grep "감지된 실패:" | grep -oE '[0-9]+' | head -1 2>/dev/null) || TOTAL_FAIL=0
ALL_OK=0
echo "$TRACKER_OUT" | grep -q "크론 전체 정상" 2>/dev/null && ALL_OK=1 || true

# ── 3. Board 저장 + Discord 라우팅 ────────────────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
    TODAY=$(date '+%Y-%m-%d')

    if [[ "$ALL_OK" -gt 0 ]]; then
        # 전체 정상 — INFO 레벨 (board만, Discord 없음)
        board_report \
            --level INFO \
            --team infra \
            --title "크론 상태 정상 — ${TODAY}" \
            --body "${TRACKER_OUT}" \
            --tag "크론점검"
        echo "[$TS] 전체 정상 — INFO 레벨 board 저장" | tee -a "$LOG"

    elif [[ "$NEW_TICKETS" -gt 0 ]]; then
        # 신규 실패 티켓 생성됨 — ACTION 레벨 (board + Discord)
        REPORT_BODY="## 크론 실패 감지 — ${TODAY}

${TRACKER_OUT}

---
**자동 처리:** dev-queue에 디버깅 티켓 ${NEW_TICKETS}건 생성됨
**대표님 액션:** dev-queue 확인 후 우선순위 조정 가능"

        board_report \
            --level ACTION \
            --team infra \
            --title "크론 실패 감지 — 티켓 ${NEW_TICKETS}건 생성 (${TODAY})" \
            --body "$REPORT_BODY" \
            --tag "크론실패"
        echo "[$TS] 신규 티켓 ${NEW_TICKETS}건 — ACTION 레벨 board+Discord" | tee -a "$LOG"

    else
        # 기존 티켓 있음 (진행 중) — WARNING 레벨 (board + jarvis-system)
        REPORT_BODY="## 크론 실패 현황 — ${TODAY}

${TRACKER_OUT}

기존 티켓 처리 중 (신규 중복 생성 없음)"

        board_report \
            --level WARNING \
            --team infra \
            --title "크론 실패 처리 중 — ${TODAY}" \
            --body "$REPORT_BODY" \
            --tag "크론실패"
        echo "[$TS] 기존 티켓 처리 중 — WARNING 레벨" | tee -a "$LOG"
    fi
fi

echo "[$TS] scorecard-enforcer 완료" | tee -a "$LOG"