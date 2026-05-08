#!/usr/bin/env bash
# resilience-guard.sh — 매 5분: 외부 의존성 health → 자동 backoff/회복
# Anthropic API + Discord API + Mac 기본 health
#
# 작동 원리:
#   - 각 외부 ping → 실패 시 카운터++
#   - 카운터 ≥3 (15분 연속 실패) → 마커 파일 생성 (다른 cron이 skip 신호로 사용)
#   - 회복 시 마커 삭제 + 알림

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/resilience-guard.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
STATE_DIR="$JARVIS_HOME/runtime/state/resilience"

mkdir -p "$STATE_DIR"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

check_endpoint() {
    local name="$1" url="$2" alive_codes="$3" auth_codes="${4:-}"
    local counter_file="$STATE_DIR/${name}-fail-count"
    local marker_file="$STATE_DIR/${name}-down"
    local auth_marker="$STATE_DIR/${name}-auth-fail"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")

    # Auth 실패 별도 처리 (B5 fix: silent 차단)
    if [ -n "$auth_codes" ] && echo "$auth_codes" | grep -q "$code"; then
        if [ ! -f "$auth_marker" ]; then
            touch "$auth_marker"
            _log "⚠️  $name 인증 실패 ($code) — 서비스는 alive지만 토큰 점검 필요"
            if [ -f "$DISCORD_VISUAL" ]; then
                PAYLOAD=$(jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M KST')" --arg n "$name" --arg c "$code" \
                    '{title:"🟡 외부 인증 실패", data:{"서비스":$n,"코드":$c,"조치":"토큰 갱신 필요","상태":"서비스는 alive"}, timestamp:$ts}')
                discord_route_payload info "$PAYLOAD" 2>&1 || true
            fi
        fi
        echo 0 > "$counter_file"
        # alive (서비스는 살아있음) marker 제거
        [ -f "$marker_file" ] && rm -f "$marker_file"
        return
    fi

    if echo "$alive_codes" | grep -q "$code"; then
        # 회복 (auth 정상도)
        [ -f "$auth_marker" ] && { rm -f "$auth_marker"; _log "✅ $name 인증 회복"; }
        if [ -f "$marker_file" ]; then
            rm -f "$marker_file" "$counter_file"
            _log "✅ $name 회복 ($code)"
            if [ -f "$DISCORD_VISUAL" ]; then
                PAYLOAD=$(jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M KST')" --arg n "$name" \
                    '{title:"🟢 외부 의존성 회복", data:{"서비스":$n,"조치":"자동 회복 — 다른 cron 정상화"}, timestamp:$ts}')
                discord_route_payload info "$PAYLOAD" 2>&1 || true
            fi
        fi
        echo 0 > "$counter_file"
    else
        # 실패
        local cnt
        cnt=$(cat "$counter_file" 2>/dev/null || echo 0)
        cnt=$((cnt + 1))
        echo "$cnt" > "$counter_file"
        _log "🔴 $name 실패 #$cnt (code=$code)"
        if [ "$cnt" -ge 3 ] && [ ! -f "$marker_file" ]; then
            touch "$marker_file"
            _log "🚨 $name 마커 생성 ($cnt회 연속 실패) — 다른 cron skip 신호"
            if [ -f "$DISCORD_VISUAL" ]; then
                PAYLOAD=$(jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M KST')" --arg n "$name" --arg c "$cnt" \
                    '{title:"🚨 외부 의존성 다운", data:{"서비스":$n,"연속 실패":$c,"조치":"마커 생성, 의존 cron skip","회복 감지":"5분마다 자동"}, timestamp:$ts}')
                discord_route_payload info "$PAYLOAD" 2>&1 || true
            fi
        fi
    fi
}

# B5 fix (verify): 401 분리 — Anthropic API는 무인증 호출이라 401 정상이지만, 인증 실패는 토큰 갱신 신호
check_endpoint "anthropic-api" "https://api.anthropic.com/v1/models" "200" "401|403"
check_endpoint "discord-api"   "https://discord.com/api/v10/gateway"  "200" ""

exit 0
