#!/usr/bin/env bash
# skill-dead-archive.sh — 8주 동안 매칭 0회 skill 자동 archive (frontmatter에 archived: true)
# 매주 월 09:25 KST (skill-usage-audit 09:15 후)

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
SKILLS_DIR="$JARVIS_HOME/runtime/wiki/skills"
LEDGER="$JARVIS_HOME/runtime/state/skill-matcher-ledger.jsonl"
LOG_FILE="$JARVIS_HOME/runtime/logs/skill-dead-archive.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
DEAD_THRESHOLD_DAYS=56  # 8주

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "skill-dead-archive"

CUTOFF=$(date -v-${DEAD_THRESHOLD_DAYS}d +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -d "-${DEAD_THRESHOLD_DAYS} days" +%Y-%m-%dT%H:%M:%S)

ARCHIVED=0
ARCHIVE_LIST=""

for sf in "$SKILLS_DIR"/*.md; do
    [ -f "$sf" ] || continue
    case "$(basename "$sf")" in SKILL-TEMPLATE.md) continue;; esac
    # 이미 archived?
    if grep -q "^archived: true" "$sf"; then continue; fi

    SKILL_ID=$(grep "^id:" "$sf" | head -1 | awk '{print $2}')
    [ -z "$SKILL_ID" ] && continue

    # 8주 내 매칭 카운트
    HITS=0
    if [ -f "$LEDGER" ]; then
        HITS=$(awk -v cutoff="$CUTOFF" -F'"ts":"' 'NF>1 && $2 > cutoff' "$LEDGER" \
            | grep "\"id\":\"$SKILL_ID\"" | wc -l | tr -d ' \n')
    fi

    # skill 생성일 8주 이내면 archive 면제 (도입 후 매칭 기회 부족)
    CREATED=$(grep "^created:" "$sf" | head -1 | awk '{print $2}')
    if [ -n "$CREATED" ]; then
        CREATED_EPOCH=$(date -j -f "%Y-%m-%d" "$CREATED" +%s 2>/dev/null || echo 0)
        CUTOFF_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$CUTOFF" +%s 2>/dev/null || echo 0)
        if [ "$CREATED_EPOCH" -gt "$CUTOFF_EPOCH" ]; then
            continue
        fi
    fi

    if [ "$HITS" -eq 0 ]; then
        # frontmatter에 archived: true 추가
        TODAY=$(date +%Y-%m-%d)
        if grep -q "^updated:" "$sf"; then
            sed -i.bak -E "s/^updated:.*/updated: $TODAY\narchived: true\narchived_reason: \"no-match-${DEAD_THRESHOLD_DAYS}d\"/" "$sf"
            rm -f "${sf}.bak"
        fi
        ARCHIVED=$((ARCHIVED + 1))
        ARCHIVE_LIST+="$SKILL_ID\n"
        _log "archived: $SKILL_ID (no match for ${DEAD_THRESHOLD_DAYS}d)"
    fi
done

_log "summary: archived=$ARCHIVED"

# Discord 알림 (archive 발생 시만)
if [ "$ARCHIVED" -gt 0 ] && [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg cnt "$ARCHIVED" \
        --arg list "$(echo -e "$ARCHIVE_LIST" | head -5 | tr '\n' '|' | sed 's/|$//')" \
        --arg th "$DEAD_THRESHOLD_DAYS" \
        '{title: "🗄️ Dead Skill Archive", data: {"archive 건수": $cnt, "기준": ($th + "일 매칭 0회"), "archived": $list}, timestamp: $ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
