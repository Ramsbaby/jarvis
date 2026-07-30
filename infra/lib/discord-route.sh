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

# 2026-07-25 정정: 이전 값은 홈 밑 점(.)으로 시작하는 옛 폴더의 scripts/ 를 가리켰는데
#   그 디렉터리가 존재하지 않았다. 그 결과 아래 파일 존재 게이트에서 막혀
#   discord_route() 와 discord_route_payload() 알림이 발송 전에 반환됐다.
#   바로 아래 두 변수와 동일한 표기로 통일한다.
DISCORD_VISUAL="${HOME}/jarvis/infra/scripts/discord-visual.mjs"
_CHANNEL_MAP_GUARD="${HOME}/jarvis/infra/guards/validate-channel-map.sh"
_EGRESS_AUDIT_LOG="${HOME}/jarvis/runtime/logs/egress-audit.log"

# 감사 로그 기록 — 채널/bytes/caller를 append (실패해도 발송 차단 안 함)
_egress_audit() {
    local channel="$1" bytes="$2" caller="${3:-unknown}"
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    mkdir -p "$(dirname "$_EGRESS_AUDIT_LOG")" 2>/dev/null || true
    printf '%s channel=%s bytes=%s caller=%s\n' "$ts" "$channel" "$bytes" "$caller" \
        >> "$_EGRESS_AUDIT_LOG" 2>/dev/null || true
}

# ── 채널 맵 가드 (cl-975bafeb5bb2be2b) ──────────────────────────────────────
# 전송 전 channel-map.json ↔ monitoring.json 설정 일치 여부를 검증한다.
# 불일치 시 전송을 차단하고 stderr에 경고를 출력한다.
# 가드 스크립트 자체가 없거나 실행 불가인 경우에는 통과시킨다(degraded 허용).
_channel_map_guard_check() {
    if [[ ! -x "$_CHANNEL_MAP_GUARD" ]]; then
        return 0  # 가드 파일 없으면 통과 (degraded mode)
    fi
    if ! "$_CHANNEL_MAP_GUARD" --quiet 2>/dev/null; then
        echo "[discord-route] [GUARD BLOCK] channel-map 검증 실패 — 채널/웹훅 오설정 감지. 전송 차단." >&2
        echo "[discord-route] 가드 상세: $("$_CHANNEL_MAP_GUARD" 2>&1 || true)" >&2
        return 1
    fi
    return 0
}

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
    [ -f "$DISCORD_VISUAL" ] || { echo "[discord-route] visual unavailable: $DISCORD_VISUAL" >&2; return 1; }
    # 채널 맵 가드 검증 (cl-975bafeb5bb2be2b)
    _channel_map_guard_check || return 1
    local channel ptitle
    channel=$(_discord_route_channel "$severity")
    ptitle=$(printf '%s' "$payload" | jq -r '.title // empty' 2>/dev/null || true)
    if ! _discord_route_dedup_ok "${severity}:${ptitle:-$payload}"; then
        echo "[discord-route] 중복 차단 (쿨다운 내 동일 알림): ${ptitle:-payload}"
        return 0
    fi
    _egress_audit "$channel" "${#payload}" "${BASH_SOURCE[1]:-unknown}:${BASH_LINENO[0]:-0}"
    local _node="${NODE_BIN}"
    if [[ -z "$_node" ]]; then
        _node=$(command -v node 2>/dev/null) || _node="/opt/homebrew/bin/node"
    fi
    if [[ ! -x "$_node" ]]; then
        echo "[discord-route] node not found at: $_node" >&2
        return 1
    fi
    "$_node" "$DISCORD_VISUAL" --type stats --data "$payload" --channel "$channel" 2>&1 || true
}

# raw 채널 직접 발송 — 채널명으로 webhook 조회 후 text content 전송, 감사 로그 기록
# monitoring.json 직접 접근을 크론 스크립트에서 분리해 egress를 이 함수로 중앙화한다.
# 사용: discord_route_raw <channel_name> <content>
discord_route_raw() {
    local channel_name="$1" content="$2"
    local monitoring="${HOME}/.jarvis/config/monitoring.json"
    [ -f "$monitoring" ] || monitoring="${HOME}/jarvis/runtime/config/monitoring.json"

    _channel_map_guard_check || return 1

    local webhook_url
    webhook_url=$(jq -r --arg ch "$channel_name" '.webhooks[$ch] // empty' "$monitoring" 2>/dev/null || true)
    if [[ -z "${webhook_url:-}" ]]; then
        echo "[discord-route] [raw] webhook not found for channel: $channel_name" >&2
        return 1
    fi

    local caller="${BASH_SOURCE[1]:-unknown}:${BASH_LINENO[0]:-0}"
    _egress_audit "$channel_name" "${#content}" "$caller"

    local payload
    payload=$(jq -n --arg m "$content" '{content: $m, allowed_mentions: {parse: []}}')
    curl -sS -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

discord_route() {
    local severity="$1" title="$2" data_kv="$3"
    [ -f "$DISCORD_VISUAL" ] || { echo "[discord-route] visual unavailable: $DISCORD_VISUAL" >&2; return 1; }
    # 채널 맵 가드 검증 (cl-975bafeb5bb2be2b)
    _channel_map_guard_check || return 1

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

    # [2026-07-22] 발송 원장: 순정 discord_route()가 egress 미기록이던 결함(Eureka 2026-07-15) 수리.
    #   일일 발송량 측정 근거 확보 — 기존 egress-audit.log 재사용(DRY, 신규 원장 미생성).
    local caller="${BASH_SOURCE[1]:-unknown}:${BASH_LINENO[0]:-0}"
    _egress_audit "$channel" "${#payload}" "$caller"

    local _node="${NODE_BIN}"
    if [[ -z "$_node" ]]; then
        _node=$(command -v node 2>/dev/null) || _node="/opt/homebrew/bin/node"
    fi
    if [[ ! -x "$_node" ]]; then
        echo "[discord-route] node not found at: $_node" >&2
        return 1
    fi
    "$_node" "$DISCORD_VISUAL" --type stats --data "$payload" --channel "$channel" 2>&1 || true
}
