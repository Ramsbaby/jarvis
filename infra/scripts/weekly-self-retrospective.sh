#!/usr/bin/env bash
# weekly-self-retrospective.sh — 자비스가 매주 일요일 22:00 KST 자기 자신 회고
#
# 능동성 도입 (2026-05-08 주인님 지적 "넌 너무 수동적이야")
#
# 데이터 소스 (모두 자비스 내부):
#   - dev-queue tasks.db (지난 7일 transitions)
#   - audit logs (model-version / docs-freshness / skill-usage)
#   - skill-matcher / skill-extractor ledger
#   - learned-mistakes.md
#   - supervisor-tick-ledger.jsonl
#
# 출력:
#   - ~/jarvis/runtime/wiki/meta/weekly-retro-YYYY-WW.md
#   - Discord #jarvis-system 카드

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
DB="$JARVIS_HOME/runtime/state/tasks.db"
WIKI_META="$JARVIS_HOME/runtime/wiki/meta"
LOG_FILE="$JARVIS_HOME/runtime/logs/weekly-self-retro.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$WIKI_META" "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# 7일 cutoff (epoch ms)
NOW_MS=$(($(date +%s) * 1000))
CUTOFF_MS=$((NOW_MS - 7 * 86400 * 1000))
WEEK=$(date +"%Y-W%V")
TODAY=$(date +%Y-%m-%d)

# ── 1. dev-queue 처리 통계 ───────────────────────────────────────────
DONE_7D=$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_transitions WHERE to_status='done' AND created_at > $CUTOFF_MS;")
FAILED_7D=$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_transitions WHERE to_status='failed' AND created_at > $CUTOFF_MS;")
REAPER_7D=$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_transitions WHERE triggered_by LIKE 'reaper%' AND created_at > $CUTOFF_MS;")

# ── 2. AUTH_ERROR 사고 (오늘 사각지대 검증) ─────────────────────────
AUTH_ERROR_7D=$(find "$JARVIS_HOME/runtime/logs" -name ".repeated-fail-*-AUTH_ERROR-*" -mtime -7 2>/dev/null | wc -l | tr -d ' ')

# ── 3. supervisor 알림 발화 횟수 (7일) ──────────────────────────────
SUPERVISOR_ALERTS=$(awk -v cutoff="$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)" \
    -F'"ts":"' 'NF>1 && $2 > cutoff' "$JARVIS_HOME/runtime/state/supervisor-tick-ledger.jsonl" 2>/dev/null \
    | grep '"alerted":true' | wc -l | tr -d ' \n')

# ── 4. skill 시스템 활동 ────────────────────────────────────────────
SKILL_TOTAL=$(ls "$JARVIS_HOME/runtime/wiki/skills"/*.md 2>/dev/null | grep -v SKILL-TEMPLATE | wc -l | tr -d ' ')
SKILL_MATCHER_HITS_7D=0
if [ -f "$JARVIS_HOME/runtime/state/skill-matcher-ledger.jsonl" ]; then
    SKILL_MATCHER_HITS_7D=$(awk -v cutoff="$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)" \
        -F'"ts":"' 'NF>1 && $2 > cutoff' "$JARVIS_HOME/runtime/state/skill-matcher-ledger.jsonl" \
        | grep '"matched_count":[1-9]' | wc -l | tr -d ' \n')
fi

# ── 5b. Meta-audit SPOF 가드 (B fix: meta-audit 자체 fail 감지) ──────
# meta-audit이 자기 fail 시 알림 안 가는 문제 → weekly-self-retro가 last-run age 점검
META_AUDIT_LOG="$JARVIS_HOME/runtime/logs/jarvis-meta-audit.log"
META_AUDIT_AGE_DAYS=999
if [ -f "$META_AUDIT_LOG" ]; then
    META_MTIME=$(stat -f %m "$META_AUDIT_LOG" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    META_AUDIT_AGE_DAYS=$(( (NOW_EPOCH - META_MTIME) / 86400 ))
fi
# 8일 이상 silent = SPOF 의심 (meta-audit는 매주 월 09:40)
if [ "$META_AUDIT_AGE_DAYS" -gt 8 ]; then
    NOTES+=("⚠️  meta-audit ${META_AUDIT_AGE_DAYS}일 silent — SPOF 의심, 수동 점검 필요")
    HEALTH="🔴 critical"
fi

# ── 5. 학습된 오답노트 신규 추가 ────────────────────────────────────
NEW_MISTAKES_7D=$(grep -c "^## 2026-" "$JARVIS_HOME/runtime/wiki/meta/learned-mistakes.md" 2>/dev/null || echo 0)

# ── 6. 자비스 자체 평가 (단순 룰) ───────────────────────────────────
HEALTH="🟢 양호"
NOTES=()
if [ "$AUTH_ERROR_7D" -gt 5 ]; then HEALTH="🟡 주의"; NOTES+=("AUTH_ERROR ${AUTH_ERROR_7D}건 다발 — OAuth 갱신 정책 점검 필요"); fi
if [ "$REAPER_7D" -gt 50 ]; then HEALTH="🟡 주의"; NOTES+=("reaper $REAPER_7D건 강등 — 업스트림 결함 패턴 분석 필요"); fi
if [ "$SKILL_MATCHER_HITS_7D" -eq 0 ] && [ "$SKILL_TOTAL" -gt 0 ]; then NOTES+=("skill 매칭 0회 — skill 시스템 도입 효과 측정 필요"); fi
if [ "${#NOTES[@]}" -eq 0 ]; then NOTES+=("이번 주 특이 사항 없음. 모든 시스템 정상 동작."); fi

# ── 7. 마크다운 보고서 작성 ─────────────────────────────────────────
REPORT="$WIKI_META/weekly-retro-${WEEK}.md"
{
    echo "# 자비스 주간 회고 — ${WEEK}"
    echo ""
    echo "> 생성: $(date '+%Y-%m-%d %H:%M KST') | 자동 (ai.jarvis.weekly-self-retro)"
    echo ""
    echo "## 종합 상태: $HEALTH"
    echo ""
    echo "## 📊 7일 활동 요약"
    echo "- dev-queue 완료: ${DONE_7D}건"
    echo "- dev-queue 실패: ${FAILED_7D}건"
    echo "- 자가 정리(reaper): ${REAPER_7D}건"
    echo "- AUTH_ERROR 발생: ${AUTH_ERROR_7D}건"
    echo "- supervisor Discord 알림: ${SUPERVISOR_ALERTS}건"
    echo "- 보유 skill: ${SKILL_TOTAL}개"
    echo "- skill 매칭 (7일): ${SKILL_MATCHER_HITS_7D}회"
    echo ""
    echo "## 🧠 자비스 자체 평가"
    for n in "${NOTES[@]}"; do echo "- $n"; done
    echo ""
    echo "## 📌 다음 주 권고"
    echo "- (자비스가 다음 주 도입 후 자동 채움)"
    echo ""
    echo "---"
    echo "_데이터 출처: tasks.db / supervisor-tick-ledger.jsonl / skill-matcher-ledger.jsonl / learned-mistakes.md_"
} > "$REPORT"

_log "report: $REPORT"
_log "stats: done=$DONE_7D failed=$FAILED_7D reaper=$REAPER_7D auth_err=$AUTH_ERROR_7D skill=$SKILL_TOTAL/$SKILL_MATCHER_HITS_7D"

# ── 8. Discord 알림 카드 ────────────────────────────────────────────
if [ -f "$DISCORD_VISUAL" ]; then
    NOTES_JOINED=$(printf '%s | ' "${NOTES[@]}" | sed 's/ | $//')
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg week "$WEEK" \
        --arg health "$HEALTH" \
        --arg done "$DONE_7D" \
        --arg failed "$FAILED_7D" \
        --arg reaper "$REAPER_7D" \
        --arg auth "$AUTH_ERROR_7D" \
        --arg sk "$SKILL_TOTAL ($SKILL_MATCHER_HITS_7D 매칭)" \
        --arg notes "$NOTES_JOINED" \
        '{title: ("🎩 자비스 주간 회고 " + $week), data: {"상태": $health, "완료": $done, "실패": $failed, "자가정리": $reaper, "AUTH_ERROR": $auth, "skill": $sk, "주요 사항": $notes}, timestamp: $ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
