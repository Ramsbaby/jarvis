#!/usr/bin/env bash
# discord-notify-bash.sh — Discord 웹훅 전송 공용 함수
# Usage: source "$BOT_HOME/lib/discord-notify-bash.sh"

[[ -n "${_DISCORD_NOTIFY_LOADED:-}" ]] && return 0
_DISCORD_NOTIFY_LOADED=1

# send_discord — Discord 웹훅으로 메시지 전송
# $1: 메시지 내용
# $2: (선택) 웹훅 키 (monitoring.json의 webhooks.KEY) 또는 URL. 기본값: $WEBHOOK
send_discord() {
    local msg="$1"
    local webhook="${2:-${WEBHOOK:-}}"

    # $2가 URL이 아닌 키 이름이면 monitoring.json에서 조회
    if [[ -n "$webhook" && "$webhook" != https://* ]]; then
        webhook=$(jq -r ".webhooks[\"$webhook\"] // empty" "${BOT_HOME:-$HOME/jarvis/runtime}/config/monitoring.json" 2>/dev/null)
    fi

    [[ -z "$webhook" ]] && return 1

    local payload
    payload=$(jq -cn --arg content "$msg" '{"content":$content}')
    curl -s --max-time 10 -H "Content-Type: application/json" \
        -d "$payload" "$webhook" >/dev/null 2>&1 || true
}

# discord_notify — (webhook_key, msg) 시그니처 래퍼 (2026-05-14 추가 — token-health-check 호환)
# 24h 알림 침묵 사고 재발 방지: 호출자가 (channel, msg) 순서로 부르는 패턴 지원
discord_notify() {
    local webhook_key="$1"
    local msg="$2"
    send_discord "$msg" "$webhook_key"
}