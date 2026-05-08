#!/usr/bin/env bash
# personal-snapshot.sh — 매일 22:30 KST: 이력서/포트폴리오/일상 자동 점검
# 3-in-1: 이력서 STAR 변화 / 포트폴리오 risk 점수 / 일상 키워드 (운동/독서/투자) 누적

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/personal-snapshot.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
SNAPSHOT_FILE="$JARVIS_HOME/runtime/state/personal-snapshot-state.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$SNAPSHOT_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── 1. 이력서 STAR 변화 ──────────────────────────────────────────────
USER_PROFILE="$JARVIS_HOME/runtime/context/user-profile.md"
STAR_COUNT=0
[ -f "$USER_PROFILE" ] && STAR_COUNT=$(grep -E "^### S[0-9]+|^### STAR-[0-9]+" "$USER_PROFILE" 2>/dev/null | wc -l | tr -d ' \n')
LAST_STAR=$(jq -r '.lastStarCount // 0' "$SNAPSHOT_FILE" 2>/dev/null || echo 0)
STAR_DELTA=$((STAR_COUNT - LAST_STAR))

# ── 2. 포트폴리오 risk (단순 — 손절선 근접 종목 카운트) ────────────────
PORTFOLIO_RISK="N/A"
PORTFOLIO_FILE="$JARVIS_HOME/runtime/state/portfolio-snapshot.json"
if [ -f "$PORTFOLIO_FILE" ]; then
    # 단순 risk: holdings 중 -10% 이상 하락한 것 카운트
    PORTFOLIO_RISK=$(jq -r '[.holdings[]? | select((.changePct // 0) < -10)] | length' "$PORTFOLIO_FILE" 2>/dev/null || echo "0")
fi

# ── 3. 일상 키워드 누적 (지난 7일 세션 요약) ────────────────────────
SESSIONS_DIR="$JARVIS_HOME/runtime/state/session-summaries"
EXERCISE_HITS=0
READING_HITS=0
INVESTMENT_HITS=0
if [ -d "$SESSIONS_DIR" ]; then
    RECENT=$(find "$SESSIONS_DIR" -name "*.md" -mtime -7 2>/dev/null)
    if [ -n "$RECENT" ]; then
        EXERCISE_HITS=$(echo "$RECENT" | xargs grep -ohE "운동|러닝|사이클링|스쿼시|헬스|cycling" 2>/dev/null | wc -l | tr -d ' ')
        READING_HITS=$(echo "$RECENT" | xargs grep -ohE "독서|책|읽었|읽고" 2>/dev/null | wc -l | tr -d ' ')
        INVESTMENT_HITS=$(echo "$RECENT" | xargs grep -ohE "TQQQ|SOXL|NVDA|투자|매수|매도|손절" 2>/dev/null | wc -l | tr -d ' ')
    fi
fi

_log "STAR=$STAR_COUNT (Δ$STAR_DELTA), 포트리스크=$PORTFOLIO_RISK, 일상: 운동=$EXERCISE_HITS 독서=$READING_HITS 투자=$INVESTMENT_HITS"

# state 업데이트
echo "{\"lastStarCount\": $STAR_COUNT, \"lastRun\": \"$(date -u +%FT%TZ)\"}" > "$SNAPSHOT_FILE"

# Discord 알림 (변화 있을 때만)
NEED_ALERT=false
[ "$STAR_DELTA" -gt 0 ] && NEED_ALERT=true
[ "$PORTFOLIO_RISK" != "N/A" ] && [ "$PORTFOLIO_RISK" -gt 0 ] && NEED_ALERT=true

if [ "$NEED_ALERT" = "true" ] && [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg star "$STAR_COUNT (+$STAR_DELTA)" \
        --arg risk "$PORTFOLIO_RISK 종목 -10%↓" \
        --arg ex "$EXERCISE_HITS" \
        --arg rd "$READING_HITS" \
        --arg iv "$INVESTMENT_HITS" \
        '{title:"📋 개인 일일 스냅샷", data:{"이력서 STAR":$star,"포트폴리오 risk":$risk,"운동(7일)":$ex,"독서(7일)":$rd,"투자 언급(7일)":$iv}, timestamp:$ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
