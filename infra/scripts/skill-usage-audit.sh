#!/usr/bin/env bash
# skill-usage-audit.sh — 주간 skill 사용량 + 추출량 분석 + Discord 알림
#
# 매주 월 09:15 KST 자동 실행 (ai.jarvis.skill-usage-audit LaunchAgent)
# 분석:
#   - 지난 7일 matcher 호출 횟수 + 매칭률
#   - 지난 7일 extractor 발화 횟수 (DRYRUN vs spawn 분포)
#   - 가장 많이 매칭된 top 5 skill
#   - 한 번도 매칭 안 된 skill (dead skill 후보)

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
SKILLS_DIR="$JARVIS_HOME/runtime/wiki/skills"
MATCHER_LEDGER="$JARVIS_HOME/runtime/state/skill-matcher-ledger.jsonl"
EXTRACTOR_LEDGER="$JARVIS_HOME/runtime/state/skill-extractor-ledger.jsonl"
LOG_FILE="$JARVIS_HOME/runtime/logs/skill-usage-audit.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$(dirname "$LOG_FILE")"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "skill-usage-audit"

CUTOFF=$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)

# 지난 7일 matcher 호출
MATCHER_TOTAL=0
MATCHER_HIT=0
if [ -f "$MATCHER_LEDGER" ]; then
    MATCHER_TOTAL=$(awk -v cutoff="$CUTOFF" -F'"ts":"' 'NF>1 && $2 > cutoff' "$MATCHER_LEDGER" | wc -l | tr -d ' ')
    MATCHER_HIT=$(awk -v cutoff="$CUTOFF" -F'"ts":"' 'NF>1 && $2 > cutoff' "$MATCHER_LEDGER" | grep '"matched_count":[1-9]' | wc -l | tr -d ' \n')
fi

# 지난 7일 extractor
EXTRACTOR_SPAWN=0
EXTRACTOR_DRYRUN=0
if [ -f "$EXTRACTOR_LEDGER" ]; then
    # B3 fix: grep -c || echo 0 패턴이 "0\n0" 출력 → tr로 숫자만 추출
    EXTRACTOR_SPAWN=$(awk -v cutoff="$CUTOFF" -F'"ts":"' 'NF>1 && $2 > cutoff' "$EXTRACTOR_LEDGER" | grep '"action":"spawn"' | wc -l | tr -d ' \n')
    EXTRACTOR_DRYRUN=$(awk -v cutoff="$CUTOFF" -F'"ts":"' 'NF>1 && $2 > cutoff' "$EXTRACTOR_LEDGER" | grep '"action":"dryrun-skip"' | wc -l | tr -d ' \n')
fi

# Top 5 매칭 skill
TOP_SKILLS=""
if [ -f "$MATCHER_LEDGER" ] && [ "$MATCHER_HIT" -gt 0 ]; then
    TOP_SKILLS=$(awk -v cutoff="$CUTOFF" -F'"ts":"' 'NF>1 && $2 > cutoff' "$MATCHER_LEDGER" \
        | grep -oE '"id":"skill-[^"]*"' \
        | sort | uniq -c | sort -rn | head -5 \
        | awk '{print $2": "$1"회"}' | tr '\n' '|' | sed 's/|$//')
fi

# Dead skills (한 번도 매칭 안 된 것)
DEAD_SKILLS=""
ALL_SKILL_IDS=$(grep -h "^id:" "$SKILLS_DIR"/*.md 2>/dev/null | grep -v "SKILL-TEMPLATE" | awk '{print $2}' | sort -u)
USED_IDS=$(grep -hoE '"id":"skill-[^"]*"' "$MATCHER_LEDGER" 2>/dev/null | sort -u | sed 's/"id":"//;s/"//')
for sid in $ALL_SKILL_IDS; do
    if ! echo "$USED_IDS" | grep -q "^$sid$"; then
        DEAD_SKILLS+="$sid|"
    fi
done
DEAD_SKILLS="${DEAD_SKILLS%|}"

TOTAL_SKILLS=$(ls "$SKILLS_DIR"/*.md 2>/dev/null | grep -v SKILL-TEMPLATE | wc -l | tr -d ' ')

_log "audit: matcher_total=$MATCHER_TOTAL, hit=$MATCHER_HIT, extractor_spawn=$EXTRACTOR_SPAWN, dryrun=$EXTRACTOR_DRYRUN, total_skills=$TOTAL_SKILLS"

# Discord 알림 — discord-route 마이그 (B5 fix · 2026-05-08)
# severity=info (주간 리포트), 채널 자동 라우팅 (현재 jarvis-system, 향후 jarvis-info)
# shellcheck source=/dev/null
source "$JARVIS_HOME/infra/lib/discord-route.sh" 2>/dev/null
if command -v discord_route_payload >/dev/null 2>&1; then
    TS=$(date +"%Y-%m-%d %H:%M KST")
    HIT_RATE="0%"
    [ "$MATCHER_TOTAL" -gt 0 ] && HIT_RATE=$(awk -v h="$MATCHER_HIT" -v t="$MATCHER_TOTAL" 'BEGIN{printf "%.0f%%", (h/t)*100}')
    PAYLOAD=$(jq -nc \
        --arg ts "$TS" \
        --arg total "$MATCHER_TOTAL" \
        --arg hit "$MATCHER_HIT ($HIT_RATE)" \
        --arg ext "$EXTRACTOR_SPAWN spawn / $EXTRACTOR_DRYRUN dryrun" \
        --arg top "${TOP_SKILLS:-(없음)}" \
        --arg dead "${DEAD_SKILLS:-(없음)}" \
        --arg sk "$TOTAL_SKILLS" \
        '{title: "🧠 Skill 주간 리포트", data: {"보유 skill": $sk, "matcher 7일 호출": $total, "매칭률": $hit, "extractor 7일": $ext, "Top 매칭": $top, "Dead skills": $dead}, timestamp: $ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
