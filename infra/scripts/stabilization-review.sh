#!/usr/bin/env bash
# stabilization-review.sh — 1주 안정화 sprint 후 자비스 자가 진화 시스템 평가
# 발화: 2026-05-15 09:00 KST (1회만)
# 목적: 5/8 폭주 도입한 18개 cron + skill 시스템의 ROI를 1주 데이터 기반으로 평가
# 산출물: 마크다운 보고서 + Discord 카드 + 다음 단계 권고

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/stabilization-review.log"
REPORT="$JARVIS_HOME/runtime/wiki/meta/stabilization-review-2026-05-15.md"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$REPORT")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

_log "=== 1주 안정화 sprint 평가 시작 ==="

# ── 1. Skill 시뮬 ledger 분석 ──────────────────────────────────────
SKILL_DRYRUN=0
SKILL_SPAWN=0
SKILL_LEDGER="$JARVIS_HOME/runtime/state/skill-extractor-ledger.jsonl"
if [ -f "$SKILL_LEDGER" ]; then
    SKILL_DRYRUN=$(grep '"action":"dryrun-skip"' "$SKILL_LEDGER" 2>/dev/null | wc -l | tr -d ' \n')
    SKILL_SPAWN=$(grep '"action":"spawn"' "$SKILL_LEDGER" 2>/dev/null | wc -l | tr -d ' \n')
fi

# ── 2. 17개 cron 발화 빈도 (지난 7일) ─────────────────────────────
CRON_LIST="weekly-self-retrospective skill-dead-archive audit-dashboard llm-cost-cap-monitor mistake-to-skill-pipeline repeat-pattern-detector personal-snapshot self-monitor-snapshot external-detect action-dispatch resilience-guard jarvis-meta-audit jarvis-retention docs-freshness-audit model-version-audit skill-dryrun-auto-activate skill-usage-audit"
DEAD_CRONS=""
ACTIVE_CRONS=""
for c in $CRON_LIST; do
    LOG="$JARVIS_HOME/runtime/logs/${c}.log"
    if [ -f "$LOG" ]; then
        LINES_7D=$(awk -v c="$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '-7 days' +%Y-%m-%d)" '$0 ~ c || $0 > c' "$LOG" 2>/dev/null | wc -l | tr -d ' \n')
        if [ "$LINES_7D" -lt 2 ]; then
            DEAD_CRONS+="$c "
        else
            ACTIVE_CRONS+="$c "
        fi
    else
        DEAD_CRONS+="$c "
    fi
done

# ── 3. 효과 측정 (alerted / FAIL / mismatch) ──────────────────────
SUPERVISOR_ALERTS_7D=$(awk -v c="$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)" \
    -F'"ts":"' 'NF>1 && $2 > c' "$JARVIS_HOME/runtime/state/supervisor-tick-ledger.jsonl" 2>/dev/null \
    | grep '"alerted":true' | wc -l | tr -d ' \n')
DOCS_REGENS_7D=$(grep "재생성: 성공" "$JARVIS_HOME/runtime/logs/docs-freshness-audit.log" 2>/dev/null | wc -l | tr -d ' \n')
META_FAIL_7D=$(grep "fails=" "$JARVIS_HOME/runtime/logs/jarvis-meta-audit.log" 2>/dev/null | tail -1 || echo "no data")

# ── 4. 알림 노이즈 평가 (Discord 송출 추정) ──────────────────────
DISCORD_SENT_7D=$(grep -h "Discord visual sent" "$JARVIS_HOME/runtime/logs"/*.log 2>/dev/null | wc -l | tr -d ' \n')

# ── 5. AUTH_ERROR 추세 ─────────────────────────────────────────────
AUTH_ERROR_7D=$(find "$JARVIS_HOME/runtime/logs" -name ".repeated-fail-*-AUTH_ERROR-*" -mtime -7 2>/dev/null | wc -l | tr -d ' \n')

# ── 6. 자체 권고 (룰 기반) ────────────────────────────────────────
RECOMMENDATIONS=()
if [ "$SKILL_DRYRUN" -ge 5 ] && [ "$SKILL_SPAWN" -eq 0 ]; then
    RECOMMENDATIONS+=("✅ Skill production 활성화 OK — touch ~/jarvis/runtime/state/skill-extract-production-active")
fi
DEAD_COUNT=$(echo "$DEAD_CRONS" | wc -w | tr -d ' ')
if [ "$DEAD_COUNT" -ge 3 ]; then
    RECOMMENDATIONS+=("🟡 Dead cron $DEAD_COUNT개 — 정리 검토: $DEAD_CRONS")
fi
if [ "$DISCORD_SENT_7D" -gt 100 ]; then
    RECOMMENDATIONS+=("🔴 Discord 알림 7일 ${DISCORD_SENT_7D}건 — 채널 분리 필수")
fi
if [ "$AUTH_ERROR_7D" -gt 10 ]; then
    RECOMMENDATIONS+=("🔴 AUTH_ERROR ${AUTH_ERROR_7D}건 지속 — OAuth 정책 재점검")
fi
if [ "${#RECOMMENDATIONS[@]}" -eq 0 ]; then
    RECOMMENDATIONS+=("🟢 1주 시뮬 안정 — 다음 단계 자유 결정")
fi

# ── 7. 마크다운 보고서 ────────────────────────────────────────────
{
    echo "# 자비스 1주 안정화 sprint 평가 — 2026-05-15"
    echo ""
    echo "> 5/8 도입한 18개 cron + skill 시스템 + 메타 가드의 ROI 평가"
    echo "> 자동 실행 (ai.jarvis.stabilization-review, 1회만 발화 후 자동 비활성)"
    echo ""
    echo "## 📊 7일 데이터"
    echo "- Skill DRYRUN 시뮬: ${SKILL_DRYRUN}건 / spawn(production): ${SKILL_SPAWN}건"
    echo "- Supervisor 알림: ${SUPERVISOR_ALERTS_7D}건"
    echo "- 사전 자동 재생성: ${DOCS_REGENS_7D}건"
    echo "- AUTH_ERROR 발생: ${AUTH_ERROR_7D}건"
    echo "- Discord 알림 송출: ${DISCORD_SENT_7D}건"
    echo "- Meta-audit 마지막: ${META_FAIL_7D}"
    echo ""
    echo "## 🟢 활성 cron"
    echo "$ACTIVE_CRONS" | tr ' ' '\n' | sed 's/^/- /' | head -20
    echo ""
    echo "## 🔴 Dead cron 후보 (7일 발화 < 2회)"
    echo "$DEAD_CRONS" | tr ' ' '\n' | sed 's/^/- /' | head -20
    echo ""
    echo "## 🎯 자비스 자체 권고"
    for r in "${RECOMMENDATIONS[@]}"; do echo "- $r"; done
    echo ""
    echo "## 📌 다음 sprint 결정"
    echo "- (주인님 검토 후 한 줄 결정)"
    echo ""
    echo "---"
    echo "_자동 실행: ai.jarvis.stabilization-review LaunchAgent (1회 발화 후 자동 unload)_"
} > "$REPORT"

_log "report: $REPORT"

# ── 8. Discord 카드 ───────────────────────────────────────────────
if command -v discord_route_payload >/dev/null 2>&1; then
    REC_JOINED=$(printf '%s | ' "${RECOMMENDATIONS[@]}" | head -c 300 | sed 's/ | $//')
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg sk "${SKILL_DRYRUN} dryrun / ${SKILL_SPAWN} prod" \
        --arg sup "$SUPERVISOR_ALERTS_7D" \
        --arg disc "$DISCORD_SENT_7D" \
        --arg auth "$AUTH_ERROR_7D" \
        --arg dead "$DEAD_COUNT" \
        --arg rec "$REC_JOINED" \
        '{title:"🎩 1주 안정화 평가 (자동)", data:{"Skill 시뮬":$sk,"Supervisor 알림":$sup,"Discord 송출":$disc,"AUTH_ERROR":$auth,"Dead cron":$dead,"권고":$rec}, timestamp:$ts}')
    discord_route_payload retro "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

# ── 9. 1회성 자동 비활성화 ────────────────────────────────────────
PLIST="$HOME/Library/LaunchAgents/ai.jarvis.stabilization-review.plist"
if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>>"$LOG_FILE" || true
    mv "$PLIST" "${PLIST}.executed-$(date +%Y-%m-%d)" 2>>"$LOG_FILE" || true
    _log "1회성 LaunchAgent 자동 비활성 + archive"
fi

exit 0
