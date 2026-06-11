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
#   critical → jarvis-system  (즉시 대응 필요 — 시스템 채널은 critical 전용)
#   info     → jarvis-info    (단순 알림 — 2026-06-11 채널 신설로 완전 분리)
#   retro    → jarvis-retro   (자가 회고 — 안 봐도 되는 기록)
#
# 채널 신설 마이그 시 이 함수 본문만 수정 — 모든 cron이 자동 분산.

DISCORD_VISUAL="$HOME/.jarvis/scripts/discord-visual.mjs"

# severity → channel 매핑 (단일 함수, 양쪽 wrapper에서 재사용)
_discord_route_channel() {
    local severity="$1"
    case "$severity" in
        critical) echo "jarvis-system" ;;
        info)     echo "jarvis-info" ;;
        retro)    echo "jarvis-retro" ;;
        *)        echo "jarvis-system" ;;
    esac
}

# 중복 송출 차단 (2026-06-11): 동일 severity+제목이 쿨다운(기본 1h) 내 재송출되면 스킵.
# cron 호출자 다수(system-doctor·cron-master 등)가 자체 중복 차단이 없어 라우터 공통으로 막는다.
# 비활성화/조정: DISCORD_ROUTE_COOLDOWN_SECS=0 (또는 원하는 초)
_DISCORD_ROUTE_DEDUP_DIR="${HOME}/jarvis/runtime/state/discord-route-dedup"
_discord_route_dedup_ok() {
    local key="$1"
    local cooldown="${DISCORD_ROUTE_COOLDOWN_SECS:-3600}"
    [ "$cooldown" -le 0 ] 2>/dev/null && return 0
    mkdir -p "$_DISCORD_ROUTE_DEDUP_DIR" 2>/dev/null || return 0
    local h f now last
    h=$(printf '%s' "$key" | /sbin/md5 -q)
    f="$_DISCORD_ROUTE_DEDUP_DIR/$h"
    now=$(date +%s)
    if [ -f "$f" ]; then
        last=$(cat "$f" 2>/dev/null || echo 0)
        case "$last" in (''|*[!0-9]*) last=0 ;; esac
        if [ $((now - last)) -lt "$cooldown" ]; then
            return 1
        fi
    fi
    echo "$now" > "$f"
    find "$_DISCORD_ROUTE_DEDUP_DIR" -type f -mmin +2880 -delete 2>/dev/null || true
    return 0
}

# raw payload 모드 — 기존 jq로 만든 PAYLOAD 그대로 + severity 라우팅만
# 사용: discord_route_payload info "$PAYLOAD"
discord_route_payload() {
    local severity="$1" payload="$2"
    [ -f "$DISCORD_VISUAL" ] || { echo "[discord-route] visual unavailable"; return 1; }
    local channel ptitle
    channel=$(_discord_route_channel "$severity")
    ptitle=$(printf '%s' "$payload" | jq -r '.title // empty' 2>/dev/null || true)
    if ! _discord_route_dedup_ok "${severity}:${ptitle:-$payload}"; then
        echo "[discord-route] 중복 차단 (쿨다운 내 동일 알림): ${ptitle:-payload}"
        return 0
    fi
    node "$DISCORD_VISUAL" --type stats --data "$payload" --channel "$channel" 2>&1 || true
}

discord_route() {
    local severity="$1" title="$2" data_kv="$3"
    [ -f "$DISCORD_VISUAL" ] || { echo "[discord-route] visual unavailable"; return 1; }

    local channel
    channel=$(_discord_route_channel "$severity")

    if ! _discord_route_dedup_ok "${severity}:${title}"; then
        echo "[discord-route] 중복 차단 (쿨다운 내 동일 알림): $title"
        return 0
    fi

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
