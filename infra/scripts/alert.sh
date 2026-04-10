#!/usr/bin/env bash
# Alert System v2.0
# Discord Webhook + ntfy 이중 알림

set -euo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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

# 쿨다운 체크 (동일 메시지 중복 방지)
is_in_cooldown() {
    local message_hash="$1"

    if [[ ! -f "$LAST_ALERT_FILE" ]]; then
        return 1
    fi

    local last_hash last_time
    last_hash=$(head -1 "$LAST_ALERT_FILE" 2>/dev/null || echo "")
    last_time=$(tail -1 "$LAST_ALERT_FILE" 2>/dev/null || echo "0")
    # 빈 값이나 숫자가 아닌 경우 0으로 처리
    if [[ ! "$last_time" =~ ^[0-9]+$ ]]; then last_time=0; fi
    local now
    now=$(date +%s)
    local elapsed=$((now - last_time))

    # 동일 메시지 + 쿨다운 시간 내
    if [[ "$last_hash" == "$message_hash" ]] && [[ $elapsed -lt $COOLDOWN_SECONDS ]]; then
        return 0
    fi
    return 1
}

set_last_alert() {
    local message_hash="$1"
    echo "$message_hash" > "$LAST_ALERT_FILE"
    date +%s >> "$LAST_ALERT_FILE"
}

# Discord Embed 색상
get_color() {
    local level="$1"
    case "$level" in
        critical) echo "15158332" ;;  # 빨강
        warning)  echo "16776960" ;;  # 노랑
        info)     echo "3447003" ;;   # 파랑
        success)  echo "3066993" ;;   # 초록
        *)        echo "9807270" ;;   # 회색
    esac
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

    # 쿨다운 체크
    local message_hash
    message_hash=$(echo "$level$title$message" | /sbin/md5 -q)
    if is_in_cooldown "$message_hash"; then
        echo "Alert skipped (cooldown): $title"
        return 0
    fi

    local color emoji timestamp hostname
    color=$(get_color "$level")
    emoji=$(get_emoji "$level")
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    hostname=$(hostname -s)

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
    local http_code
    http_code=$(curl -s -o /tmp/webhook_response.txt -w "%{http_code}" -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$embed_json" 2>&1)

    if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
        set_last_alert "$message_hash"
        echo "Alert sent (Discord): $title"
    else
        local body
        body=$(cat /tmp/webhook_response.txt 2>/dev/null || echo "")
        echo "Alert failed (Discord HTTP $http_code): $body" >&2
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
