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
    # 2026-05-14: || true 제거 — caller가 success/fail 인지하도록 반환값 명시
    # 어제 사고: send_discord 항상 0 반환 → token-health-check fail 분기 dead code → 24h 침묵
    # 재발 방지: HTTP 응답 헤더로 2xx 확인 후 명시적 return
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Content-Type: application/json" \
        -d "$payload" "$webhook" 2>/dev/null)
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    else
        return 1
    fi
}

# discord_notify — (webhook_key, msg) 시그니처 래퍼 (2026-05-14 추가 — token-health-check 호환)
# 24h 알림 침묵 사고 재발 방지: 호출자가 (channel, msg) 순서로 부르는 패턴 지원
discord_notify() {
    local webhook_key="$1"
    local msg="$2"
    send_discord "$msg" "$webhook_key"
}