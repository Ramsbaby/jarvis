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

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/jarvis/runtime}"
LOG="${BOT_HOME}/logs/cron-failure-tracker.log"
TASK_STORE="${BOT_HOME}/lib/task-store.mjs"
mkdir -p "$(dirname "$LOG")"

# 환경변수 DRY_RUN=true 도 존중한다 — 2026-09-04 12:11 수동 점검 때 env 만 주고 돌려 실제 티켓이 생성돼
# 코더가 daily-summary 4회·tasks.json 덮어쓰기까지 갔다. argv --dry-run 은 여전히 우선한다.
DRY_RUN="${DRY_RUN:-false}"
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done
case "$DRY_RUN" in true|false) ;; *) echo "[ERROR] DRY_RUN 은 true|false 만 허용: '$DRY_RUN'" >&2; exit 2 ;; esac

TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TS] cron-failure-tracker 시작 (dry_run=${DRY_RUN})" | tee -a "$LOG"

# ── 1. cron-auditor.sh 실행 ────────────────────────────────────────────────────
AUDIT_OUT=$(BOT_HOME="$BOT_HOME" bash "${BOT_HOME}/scripts/cron-auditor.sh" 2>/dev/null) || {
    echo "[$TS] ERROR: cron-auditor.sh 실행 실패" | tee -a "$LOG"
    exit 1
}

# ── 2. FAIL/STALE 태스크 추출 (DEAD 제외 — 비활성/미사용 태스크 정상)
# FAIL = 마지막 종결 전이 failed (tasks.db) / 직접 실행 스크립트는 로그 tail 에 error|fail
# STALE = 마지막 실행이 예상 주기 5배 초과 (실행 누락)
# SUSPECT(DB 와 로그가 반대) 는 일부러 안 집는다 — 모순된 근거로는 티켓을 내지 않는다 (2a). 요약 mismatch 로 사람에게 간다.
# 3번째 필드 = auditor 가 붙인 evidence= 토큰 (공백 없음). 티켓 설명·meta.evidence 로 코더에게 전달한다.
FAILURES=$(echo "$AUDIT_OUT" | grep -E '\s(FAIL|STALE)\s' \
    | awk '{e="-"; for(i=3;i<=NF;i++) if($i ~ /^evidence=/) e=substr($i,10); print $1, $2, e}' || true)
MISMATCH=$(echo "$AUDIT_OUT" | grep -oE 'mismatch\): [0-9]+' | grep -oE '[0-9]+$' || echo 0)

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
TICKET_COOLDOWN=0
TICKET_COOLDOWN_H="${TICKET_COOLDOWN_H:-72}"   # 같은 티켓 재큐 금지 시간 (코더 1회 시도 후 사람 확인)
TICKET_DETAILS=""

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    TASK_NAME=$(echo "$line" | awk '{print $1}' | tr -d '[:space:]')
    STATUS=$(echo "$line" | awk '{print $2}' | tr -d '[:space:]')
    EVIDENCE=$(echo "$line" | awk '{print $3}' | tr -d '[:space:]')
    [[ "$EVIDENCE" == "-" ]] && EVIDENCE=""

    [[ -z "$TASK_NAME" ]] && continue

    # cron-auditor 가 스크립트 경로를 못 뽑은 줄(find/pgrep 원라이너 등)은 전부 "unknown" 으로 뭉친다.
    # 대상이 없는 티켓은 코더가 할 일을 지어낸다 — 2026-09-04 03:07 debug-cron-unknown 세션이
    # 엣지케이스 테스트 명목으로 `rm -rf "$BOT_HOME"` 실행(runtime-guard 가 차단, state/runtime-guard.jsonl).
    if [[ "$TASK_NAME" == "unknown" ]]; then
        echo "[$TS] 스킵: 식별 불가 항목(unknown, 상태 ${STATUS}) — 티켓 미생성. crontab 원라이너를 스크립트로 빼거나 auditor 라벨을 고쳐야 한다" | tee -a "$LOG"
        continue
    fi

    TICKET_ID="debug-cron-${TASK_NAME}"
    # ID 길이 제한 (50자)
    TICKET_ID="${TICKET_ID:0:50}"

    DESCRIPTION="크론 실패 자동감지: ${TASK_NAME} (상태: ${STATUS}) — 로그 확인 후 원인 파악 및 스크립트 수정 필요. 참고: ${BOT_HOME}/logs/cron.log"
    if [[ -n "$EVIDENCE" ]]; then
        DESCRIPTION="${DESCRIPTION}
근거(evidence): ${EVIDENCE}
  db:<tasks.db 현재 상태>;last:<마지막 종결 전이>@<시각>/<누가 찍었나>;exit=<종료코드>;err=<lastError>;results:<결과 파일 나이>;log:<cron.log 마지막 결과>
  근거가 실제 고장이 아니면(예: 감사 오탐) 코드를 고치지 말고 결과에 '오탐: <이유>' 를 적고 끝내라."
    fi

    # 같은 실패로 코더가 최근에 이미 한 번 돌았으면 재큐하지 않는다 (task-store ensure 는 done/failed 를
    # 무조건 queued 로 되돌려 매일 밤 같은 티켓을 코더에게 다시 준다 — 2026-09-04 daily-summary 가
    # 이 경로로 4회 실행되며 runtime/config/tasks.json 을 7월 백업으로 덮어썼다).
    # 쿨다운 안에 다시 실패했다는 건 코더 수준에서 못 고치는 문제이므로 사람 판단으로 넘긴다.
    PREV=$(node "$TASK_STORE" get "$TICKET_ID" 2>/dev/null | grep -v ExperimentalWarning || true)
    PREV_STATUS=$(echo "$PREV" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
    PREV_AGE_H=$(echo "$PREV" | python3 -c "import json,sys,time; d=json.load(sys.stdin); print(int((time.time()*1000-int(d.get('updated_at') or 0))/3600000))" 2>/dev/null || echo "")
    if [[ "$PREV_STATUS" == "done" || "$PREV_STATUS" == "failed" ]] \
        && [[ -n "$PREV_AGE_H" && "$PREV_AGE_H" -lt "$TICKET_COOLDOWN_H" ]]; then
        ((TICKET_COOLDOWN++)) || true
        TICKET_DETAILS="${TICKET_DETAILS}\n  ⏸️  [${STATUS}] ${TASK_NAME} → ${PREV_AGE_H}h 전 코더 ${PREV_STATUS} — 재큐 안 함(쿨다운 ${TICKET_COOLDOWN_H}h), 사람 확인 필요"
        echo "[$TS] 쿨다운 스킵: $TICKET_ID (코더 ${PREV_STATUS} ${PREV_AGE_H}h 전) — 같은 실패 반복, 사람 확인 필요" | tee -a "$LOG"
        continue
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
        RESULT=$(node "$TASK_STORE" ensure "$TICKET_ID" "$DESCRIPTION" "infra" "$DESCRIPTION" "" "" "$EVIDENCE" 2>/dev/null | grep -v ExperimentalWarning || echo '{"ok":false}')
        IS_NEW=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('isNew','false'))" 2>/dev/null || echo "false")
        if [[ "$IS_NEW" == "True" || "$IS_NEW" == "true" ]]; then
            ((TICKET_CREATED++)) || true
            TICKET_DETAILS="${TICKET_DETAILS}\n  🆕 [${STATUS}] ${TASK_NAME} → 티켓: ${TICKET_ID}${EVIDENCE:+ · 근거: ${EVIDENCE:0:120}}"
            echo "[$TS] 신규 티켓 생성: $TICKET_ID" | tee -a "$LOG"
        else
            ((TICKET_EXISTS++)) || true
            TICKET_DETAILS="${TICKET_DETAILS}\n  ♻️  [${STATUS}] ${TASK_NAME} → 기존 티켓 유지"
            echo "[$TS] 기존 티켓 유지: $TICKET_ID" | tee -a "$LOG"
        fi
    else
        TICKET_DETAILS="${TICKET_DETAILS}\n  [DRY] [${STATUS}] ${TASK_NAME} → 티켓 예정: ${TICKET_ID}${EVIDENCE:+ · 근거: ${EVIDENCE:0:120}}"
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
echo "- 감지된 실패: ${TOTAL_FAIL}건 / DB-로그 불일치(SUSPECT, 티켓 보류): ${MISMATCH}건"
if [[ "$DRY_RUN" == "false" ]]; then
    echo "- 신규 티켓: ${TICKET_CREATED}건 / 기존 유지: ${TICKET_EXISTS}건 / 쿨다운 보류: ${TICKET_COOLDOWN}건"
else
    echo "- 쿨다운 보류: ${TICKET_COOLDOWN}건 (코더가 ${TICKET_COOLDOWN_H}h 내 이미 시도)"
fi
echo -e "- 상세:${TICKET_DETAILS}"
echo ""
echo "dev-queue에서 확인: node ${TASK_STORE} list | grep debug-cron"

echo "[$TS] cron-failure-tracker 완료" | tee -a "$LOG"