#!/usr/bin/env bash
# repeat-pattern-detector.sh — 7일 세션 요약에서 반복 패턴 → 자동화 후보 알림
# 매주 일 21:30 KST (weekly-self-retro 22:00 30분 전)
#
# 데이터: ~/jarvis/runtime/state/session-summaries/*.md
# 분석: 같은 명령/질문 패턴이 ≥3회 등장 → "자동화하시죠?" 카드

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
SESSIONS_DIR="$JARVIS_HOME/runtime/state/session-summaries"
LOG_FILE="$JARVIS_HOME/runtime/logs/repeat-pattern-detector.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
THRESHOLD=3

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

[ -d "$SESSIONS_DIR" ] || { _log "session-summaries 없음"; exit 0; }

# 7일 이내 mtime 세션 파일
RECENT=$(find "$SESSIONS_DIR" -name "*.md" -mtime -7 2>/dev/null)
[ -z "$RECENT" ] && { _log "7일 내 세션 없음"; exit 0; }

# 명령형 패턴 추출 (~해줘 / ~확인 / ~조회 / ~검토 등)
PATTERNS=$(echo "$RECENT" | xargs cat 2>/dev/null | \
    grep -oE "[가-힣A-Za-z]{2,15}\s*(해줘|확인|조회|검토|점검|상태|보여줘|진단)" | \
    sort | uniq -c | sort -rn | awk -v t="$THRESHOLD" '$1 >= t' | head -10)

if [ -z "$PATTERNS" ]; then
    _log "반복 패턴 없음 (≥${THRESHOLD}회)"
    exit 0
fi

_log "반복 패턴 발견:"
echo "$PATTERNS" | tee -a "$LOG_FILE"

# Top 5 패턴 → Discord 카드
TOP_LIST=$(echo "$PATTERNS" | head -5 | awk '{count=$1; $1=""; gsub(/^ /, ""); printf "%s (%d회) | ", $0, count}' | sed 's/ | $//')

if [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg t "$THRESHOLD" \
        --arg list "$TOP_LIST" \
        '{title: "🔁 반복 패턴 — 자동화 후보", data: {"7일 ≥3회 반복": $list, "권고": "cron 자동화 검토. /loop 또는 /schedule 활용."}, timestamp: $ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
