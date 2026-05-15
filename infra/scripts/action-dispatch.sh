#!/usr/bin/env bash
# action-dispatch.sh — 매일 03:45 KST (insight-extractor 03:30 후): 결정사항 → 자동 분배
#
# 입력: ~/jarvis/runtime/rag/auto-insights/{TODAY}.md (insight-extractor 산출)
# 출력: insight의 decisions/open_items 중 액션 가능한 것을
#       - dev-queue propose (status=pending — 사용자 promote 대기)
#       - 매 항목당 하나의 카드 알림

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/action-dispatch.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
TASK_STORE="$JARVIS_HOME/infra/lib/task-store.mjs"
LEDGER="$JARVIS_HOME/runtime/state/action-dispatch-ledger.jsonl"

# B4 fix (2026-05-08 verify): DRYRUN 가드 추가
# 매일 dev-queue 무한 누적 위험 차단. 사용자 검토 게이트.
# DRYRUN=1 default: ledger만 (propose 호출 X)
# DRYRUN=0: production
DRYRUN="${ACTION_DISPATCH_DRYRUN:-1}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LEDGER")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

TODAY=$(date +%Y-%m-%d)
INSIGHT_FILE="$JARVIS_HOME/runtime/rag/auto-insights/${TODAY}.md"

[ -f "$INSIGHT_FILE" ] || { _log "오늘 insight 없음 — skip"; exit 0; }

# 미완료 항목(open_items) 추출 → propose
DISPATCHED=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # "- " 로 시작하는 bullet 추출 (단순)
    ITEM=$(echo "$line" | sed -E 's/^- //; s/—.*//' | tr -d '*' | head -c 80)
    [ -z "$ITEM" ] && continue
    SLUG=$(echo "$ITEM" | tr ' ' '-' | sed 's/[^a-zA-Z0-9가-힣-]//g' | head -c 50)
    TASK_ID="action-${TODAY}-${SLUG}"
    PROMPT="자비스 insight 자동 분배: ${ITEM}\n\n주인님 검토 후 promote/reject 결정."

    if [ "$DRYRUN" = "0" ]; then
        # production — 실제 propose
        RESULT=$(node "$TASK_STORE" propose --id "$TASK_ID" --title "$ITEM" --prompt "$PROMPT" --source action-dispatch 2>&1)
        if echo "$RESULT" | grep -q '"action":"proposed"'; then
            DISPATCHED=$((DISPATCHED + 1))
            _log "dispatched: $TASK_ID"
            echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"task_id\":\"$TASK_ID\",\"action\":\"proposed\"}" >> "$LEDGER"
        fi
    else
        # DRYRUN — ledger만
        DISPATCHED=$((DISPATCHED + 1))
        _log "[DRYRUN] would dispatch: $TASK_ID"
        echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"task_id\":\"$TASK_ID\",\"action\":\"dryrun-skip\"}" >> "$LEDGER"
    fi
done < <(awk '/^## 미완료 항목/,/^## /' "$INSIGHT_FILE" 2>/dev/null | grep -E "^- ")

_log "DRYRUN=$DRYRUN — dispatched candidates: $DISPATCHED"

_log "dispatched: $DISPATCHED 건"

if [ "$DISPATCHED" -gt 0 ] && [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg n "$DISPATCHED" \
        '{title:"📤 결정사항 → dev-queue 분배", data:{"분배 건수":$n,"상태":"pending — 검토 후 /promote 또는 /reject", "확인":"node ~/jarvis/infra/lib/task-store.mjs list"}, timestamp:$ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
