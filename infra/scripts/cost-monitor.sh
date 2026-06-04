#!/usr/bin/env bash

# Cost Monitoring & Alerting Script
# routing-metrics.jsonl을 모니터링하고 이상 탐지 시 Discord 알림 발송

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
METRICS_FILE="$BOT_HOME/logs/routing-metrics.jsonl"
MONITORING_CONFIG="$BOT_HOME/infra/config/task-routing-config.json"

# ── 알림 규칙 ────────────────────────────────────────────────────────────────

check_daily_gemini_cost() {
    # Gemini 일일 비용이 $0.20 초과하면 경고
    if [[ ! -f "$METRICS_FILE" ]]; then
        return 0
    fi

    local today=$(date +%Y-%m-%d)
    local total_cost=$(jq -r --arg date "$today" \
        '[.[] | select(.ts | startswith($date)) and .api_provider == "gemini" | .cost_target] | add // 0' \
        "$METRICS_FILE" 2>/dev/null || echo "0")

    if (( $(echo "$total_cost > 0.20" | bc -l 2>/dev/null || echo 0) )); then
        send_discord_alert "Gemini 일일 비용 경고" "비용: \$$total_cost"
    fi
}

check_fallback_rate() {
    # Fallback 비율이 10% 초과하면 심각 경고
    if [[ ! -f "$METRICS_FILE" ]]; then
        return 0
    fi

    local fallback_count=$(jq -r '[.[] | select(.success == "false" or .success == false)] | length' \
        "$METRICS_FILE" 2>/dev/null || echo "0")
    local total_count=$(jq -r 'length' "$METRICS_FILE" 2>/dev/null || echo "0")

    if [[ $total_count -gt 0 ]]; then
        local fallback_rate=$((fallback_count * 100 / total_count))

        if [[ $fallback_rate -gt 10 ]]; then
            send_discord_alert "Gemini Fallback 높음" "비율: ${fallback_rate}%"
            disable_routing "Fallback 비율 높음"
        fi
    fi
}

disable_routing() {
    local reason="$1"

    if ! command -v jq &>/dev/null; then
        return 1
    fi

    jq '.enabled = false' "$MONITORING_CONFIG" > "$MONITORING_CONFIG.tmp" 2>/dev/null && \
        mv "$MONITORING_CONFIG.tmp" "$MONITORING_CONFIG"

    send_discord_alert "라우팅 자동 비활성화" "사유: $reason"
}

send_discord_alert() {
    local title="$1"
    local message="$2"

    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        return 0
    fi

    local timestamp=$(date -u +%FT%TZ)
    local json_payload="{\"content\": \"$title\", \"embeds\": [{\"title\": \"$title\", \"description\": \"$message\", \"timestamp\": \"$timestamp\"}]}"

    curl -s -X POST "$DISCORD_WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "$json_payload" >/dev/null 2>&1 || true
}

main() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 비용 모니터링 실행"

    check_daily_gemini_cost
    check_fallback_rate

    echo "✓ 모니터링 완료"
}

main "$@"
