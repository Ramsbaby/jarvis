#!/usr/bin/env bash
# discord-route.sh — Discord 채널 라우팅 wrapper (severity → channel)
#
# 사용:
#   source ~/jarvis/infra/lib/discord-route.sh
#   discord_route critical "title" "key=val,key2=val2"
#   discord_route info "..."
#   discord_route retro "..."
#
# severity → channel:
#   critical → jarvis-system  (즉시 대응 필요)
#   info     → jarvis-system  (단순 알림 — 채널 신설 후 jarvis-info로 이전)
#   retro    → jarvis-system  (자가 회고 — 채널 신설 후 jarvis-retro로 이전)
#
# 채널 신설 마이그 시 이 함수 본문만 수정 — 모든 cron이 자동 분산.

DISCORD_VISUAL="$HOME/.jarvis/scripts/discord-visual.mjs"

# severity → channel 매핑 (단일 함수, 양쪽 wrapper에서 재사용)
_discord_route_channel() {
    local severity="$1"
    case "$severity" in
        critical) echo "jarvis-system" ;;  # 향후: jarvis-critical
        info)     echo "jarvis-system" ;;  # 향후: jarvis-info
        retro)    echo "jarvis-system" ;;  # 향후: jarvis-retro
        *)        echo "jarvis-system" ;;
    esac
}

# raw payload 모드 — 기존 jq로 만든 PAYLOAD 그대로 + severity 라우팅만
# 사용: discord_route_payload info "$PAYLOAD"
discord_route_payload() {
    local severity="$1" payload="$2"
    [ -f "$DISCORD_VISUAL" ] || { echo "[discord-route] visual unavailable"; return 1; }
    local channel
    channel=$(_discord_route_channel "$severity")
    node "$DISCORD_VISUAL" --type stats --data "$payload" --channel "$channel" 2>&1 || true
}

discord_route() {
    local severity="$1" title="$2" data_kv="$3"
    [ -f "$DISCORD_VISUAL" ] || { echo "[discord-route] visual unavailable"; return 1; }

    local channel
    channel=$(_discord_route_channel "$severity")

    # data_kv "k=v,k2=v2" → JSON
    local data_json="{"
    local first=1
    IFS=',' read -ra PAIRS <<< "$data_kv"
    for p in "${PAIRS[@]}"; do
        local k="${p%%=*}"
        local v="${p#*=}"
        [ "$first" = "0" ] && data_json+=","
        data_json+="\"${k}\":\"${v}\""
        first=0
    done
    data_json+="}"

    local payload
    payload=$(jq -nc \
        --arg t "[$severity] $title" \
        --argjson d "$data_json" \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        '{title:$t, data:$d, timestamp:$ts}')

    node "$DISCORD_VISUAL" --type stats --data "$payload" --channel "$channel" 2>&1 || true
}
