#!/usr/bin/env bash
# Alert System v2.0
# Discord Webhook + ntfy 이중 알림

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
ALERT_STATE_DIR="$BOT_HOME/state"
LAST_ALERT_FILE="$ALERT_STATE_DIR/last-alert"

# ============================================================================
# 설정 로드
# ============================================================================
if [[ ! -f "$MONITORING_CONFIG" ]]; then
    echo "ERROR: monitoring.json not found" >&2
    exit 1
fi

WEBHOOK_URL=$(jq -r '.webhooks["jarvis-system"] // .webhook.url' "$MONITORING_CONFIG")
COOLDOWN_SECONDS=$(jq -r '.alerts.cooldown_seconds // 300' "$MONITORING_CONFIG")
NTFY_ENABLED=$(jq -r '.ntfy.enabled // false' "$MONITORING_CONFIG")
NTFY_SERVER=$(jq -r '.ntfy.server // "https://ntfy.sh"' "$MONITORING_CONFIG")
NTFY_TOPIC=$(jq -r '.ntfy.topic // ""' "$MONITORING_CONFIG")

mkdir -p "$ALERT_STATE_DIR"

# ============================================================================
# 함수
# ============================================================================

# 채널별 쿨다운(초) 조회: .alerts.cooldown_per_channel.<ch> > .alerts.cooldown_seconds > 300
_cooldown_for_channel() {
    local ch="${1:-default}"
    jq -r --arg ch "$ch" \
       '.alerts.cooldown_per_channel[$ch] // .alerts.cooldown_seconds // 300' \
       "$MONITORING_CONFIG"
}

# 쿨다운 체크 (동일 메시지 중복 방지). 두 번째 인자로 채널별 cooldown 주입 가능.
# 2026-06-11: 단일 last-alert 파일 → 해시별 파일로 교체. 기존 방식은 "마지막 1건"만 기억해
# 서로 다른 알림이 번갈아 오면 동일 알림의 반복을 전혀 막지 못했음 (실패 알림 12연발의 구조 원인).
ALERT_DEDUP_DIR="$ALERT_STATE_DIR/alert-dedup"
mkdir -p "$ALERT_DEDUP_DIR"

is_in_cooldown() {
    local message_hash="$1"
    local cooldown="${2:-$COOLDOWN_SECONDS}"
    local f="$ALERT_DEDUP_DIR/$message_hash"
    [[ -f "$f" ]] || return 1
    local last_time now elapsed
    last_time=$(cat "$f" 2>/dev/null || echo "0")
    if [[ ! "$last_time" =~ ^[0-9]+$ ]]; then last_time=0; fi
    now=$(date +%s)
    elapsed=$((now - last_time))
    if [[ $elapsed -lt $cooldown ]]; then
        return 0
    fi
    return 1
}

set_last_alert() {
    local message_hash="$1"
    date +%s > "$ALERT_DEDUP_DIR/$message_hash"
    # 이틀 지난 해시 파일은 기회적 정리 (상태 디렉토리 비대 방지)
    find "$ALERT_DEDUP_DIR" -type f -mmin +2880 -delete 2>/dev/null || true
}

# 송출 감사 원장 (2026-06-11 신설): 모든 Discord 알림 송출 시도를 JSONL로 기록.
# 측정 원장 없이는 노이즈 개선을 입증할 수 없음 — 30일 추이 분석의 데이터 기반.
_send_audit_log() {
    local level="$1" channel="$2" title="$3" result="$4"
    local ledger_dir="$BOT_HOME/ledger"
    mkdir -p "$ledger_dir" 2>/dev/null || return 0
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg src "alert-send" --arg lvl "$level" --arg ch "$channel" \
        --arg t "$title" --arg r "$result" \
        '{ts:$ts,source:$src,level:$lvl,channel:$ch,title:$t,result:$r}' \
        >> "$ledger_dir/discord-send-audit.jsonl" 2>/dev/null || true
}

# Discord Embed 색상 — 단일 정의(discord-severity.sh) 위임 (2026-06-11 중앙화)
source "$HOME/jarvis/infra/lib/discord-severity.sh"
get_color() {
    severity_color "$1"
}

# Discord Emoji
get_emoji() {
    local level="$1"
    case "$level" in
        critical) echo "🚨" ;;
        warning)  echo "⚠️" ;;
        info)     echo "ℹ️" ;;
        success)  echo "✅" ;;
        *)        echo "📢" ;;
    esac
}

# 메인 알림 전송
send_alert() {
    local level="${1:-warning}"
    local title="$2"
    local message="$3"
    local fields="${4:-}"  # JSON array string
    local channel="${5:-default}"  # 채널별 cooldown 적용용 (없으면 글로벌)

    # 쿨다운 체크 — 채널별 TTL 우선
    local message_hash cooldown
    message_hash=$(echo "$level$title$message" | /sbin/md5 -q)
    cooldown=$(_cooldown_for_channel "$channel")
    if is_in_cooldown "$message_hash" "$cooldown"; then
        echo "Alert skipped (cooldown=${cooldown}s, channel=${channel}): $title"
        _send_audit_log "$level" "$channel" "$title" "skipped:cooldown"
        return 0
    fi

    local color emoji timestamp hostname
    color=$(get_color "$level")
    emoji=$(get_emoji "$level")
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    hostname=$(hostname -s)

    # Discord embed description 한도(4096자) 가드 — 초과분은 자르고 표시 (2026-06-11)
    if [[ ${#message} -gt 4000 ]]; then
        message="${message:0:4000}…(잘림)"
    fi

    # Embed JSON 생성 (jq로 특수문자 안전 처리)
    local embed_json
    if [[ -n "$fields" ]] && [[ "$fields" != "[]" ]]; then
        embed_json=$(jq -n \
            --arg title "$emoji $title" \
            --arg desc "$message" \
            --argjson color "$color" \
            --arg ts "$timestamp" \
            --argjson fields "$fields" \
            --arg footer "Bot Monitor · $hostname" \
            '{"embeds":[{"title":$title,"description":$desc,"color":$color,"timestamp":$ts,"fields":$fields,"footer":{"text":$footer}}]}')
    else
        embed_json=$(jq -n \
            --arg title "$emoji $title" \
            --arg desc "$message" \
            --argjson color "$color" \
            --arg ts "$timestamp" \
            --arg footer "Bot Monitor · $hostname" \
            '{"embeds":[{"title":$title,"description":$desc,"color":$color,"timestamp":$ts,"footer":{"text":$footer}}]}')
    fi

    # Webhook 전송
    local http_code rc=0
    http_code=$(curl -s -o /tmp/webhook_response.txt -w "%{http_code}" -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$embed_json" 2>&1)

    if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
        set_last_alert "$message_hash"
        echo "Alert sent (Discord): $title"
        _send_audit_log "$level" "$channel" "$title" "sent"
    else
        local body
        body=$(cat /tmp/webhook_response.txt 2>/dev/null || echo "")
        echo "Alert failed (Discord HTTP $http_code): $body" >&2
        _send_audit_log "$level" "$channel" "$title" "failed:http_${http_code}"
        rc=1  # 무음 삼킴 금지 — 호출자가 실패를 인지하도록 명시 반환 (2026-06-11)
    fi

    # ntfy 푸시 알림 (Galaxy 폰 직접 전송)
    if [[ "$NTFY_ENABLED" == "true" ]] && [[ -n "$NTFY_TOPIC" ]] && [[ "$NTFY_TOPIC" != "null" ]]; then
        local ntfy_priority="default"
        local ntfy_tags=""
        case "$level" in
            critical) ntfy_priority="urgent"; ntfy_tags="rotating_light" ;;
            warning)  ntfy_priority="high"; ntfy_tags="warning" ;;
            info)     ntfy_priority="low"; ntfy_tags="information_source" ;;
            success)  ntfy_priority="default"; ntfy_tags="white_check_mark" ;;
        esac

        curl -s -m 5 \
            -H "Title: ${emoji} ${title}" \
            -H "Priority: ${ntfy_priority}" \
            -H "Tags: ${ntfy_tags}" \
            -d "${message}" \
            "${NTFY_SERVER}/${NTFY_TOPIC}" > /dev/null 2>&1 \
            && echo "Alert sent (ntfy): $title" \
            || echo "Alert failed (ntfy)" >&2
    fi

    return "$rc"
}

# ============================================================================
# CLI Interface
# ============================================================================

usage() {
    cat <<EOF
Usage: alert.sh <level> <title> <message> [fields_json]

Levels: critical, warning, info, success

Examples:
  alert.sh critical "Gateway Down" "프로세스가 응답하지 않습니다"
  alert.sh warning "High Memory" "메모리 사용량: 85%"
  alert.sh success "Recovery" "Gateway가 정상 복구되었습니다"
EOF
}

# 인자 처리
if [[ $# -lt 3 ]]; then
    usage
    exit 1
fi

LEVEL="$1"
TITLE="$2"
MESSAGE="$3"
FIELDS="${4:-}"

send_alert "$LEVEL" "$TITLE" "$MESSAGE" "$FIELDS"