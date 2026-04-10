#!/usr/bin/env bash
set -euo pipefail

# route-result.sh - Route results to Discord, ntfy, file, or alert
# Usage: route-result.sh <mode> <task-id> <message>

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG="${BOT_HOME}/config/monitoring.json"

# --- Config check ---
[[ -f "$CONFIG" ]] || { echo "ERROR: $CONFIG not found" >&2; exit 1; }

# --- Arguments ---
MODE="${1:?Usage: route-result.sh <discord|ntfy|alert|file|all> TASK_ID MESSAGE [CHANNEL]}"
TASK_ID="${2:?Usage: route-result.sh MODE TASK_ID MESSAGE}"
MESSAGE="${3:?Usage: route-result.sh MODE TASK_ID MESSAGE}"
CHANNEL="${4:-}"  # optional: channel name from tasks.json discordChannel field

# --- Marker extraction (before clean_message) ---
# CHART_DATA:<json>  → QuickChart 이미지 embed
# EMBED_DATA:<json>  → Discord rich embed (color card)
CHART_JSON=""
EMBED_JSON=""
if printf '%s' "$MESSAGE" | grep -q '^CHART_DATA:'; then
    CHART_JSON=$(printf '%s' "$MESSAGE" | grep '^CHART_DATA:' | head -1 | sed 's/^CHART_DATA://')
    MESSAGE=$(printf '%s' "$MESSAGE" | grep -v '^CHART_DATA:' || true)
fi
if printf '%s' "$MESSAGE" | grep -q '^EMBED_DATA:'; then
    EMBED_JSON=$(printf '%s' "$MESSAGE" | grep '^EMBED_DATA:' | head -1 | sed 's/^EMBED_DATA://')
    MESSAGE=$(printf '%s' "$MESSAGE" | grep -v '^EMBED_DATA:' || true)
fi

# --- Message quality filter (central pre-send hook) ---
# Strips internal debug/noise lines before sending to any external channel
clean_message() {
    local msg="$1"
    # Remove noise patterns: internal paths, debug logs, SQL artifacts
    msg=$(echo "$msg" | grep -vE \
        '^\[insight\] Saved to |^sent id=|^SELECT .last_insert|^\[debug\]|^\[trace\]|^Fallback:|^NODE_PATH=|^cd /tmp/' \
        || true)
    # Trim leading/trailing blank lines
    msg=$(echo "$msg" | sed -e '/./,$!d' -e ':a' -e '/^[[:space:]]*$/{ $d; N; ba' -e '}')
    # Strip URLs (Discord 썸네일/임베드 방지)
    # 마크다운 링크 [text](url) → text만 보존, 나머지 URL은 제거
    msg=$(echo "$msg" | sed -E 's|\[([^]]*)\]\(https?://[^ )>]*\)|\1|g; s|https?://[^ )>]+||g')
    # If everything got filtered, keep original (safety)
    # 단, 원본이 순수 노이즈(sent id=, SELECT, debug 패턴)만 있으면 복원 금지
    if [[ -z "$msg" ]]; then
        local orig_clean
        orig_clean=$(echo "$1" | grep -vE \
            '^\[insight\] Saved to |^sent id=|^SELECT .last_insert|^\[debug\]|^\[trace\]|^Fallback:|^NODE_PATH=|^cd /tmp/' \
            | sed '/./!d' || true)
        if [[ -n "$orig_clean" ]]; then
            msg="$1"
        fi
    fi
    echo "$msg"
}

MESSAGE=$(clean_message "$MESSAGE")

# --- Format for Discord (table→list, heading normalization, etc.) ---
FORMAT_SCRIPT="${BOT_HOME}/bin/format-discord.mjs"
if [[ -f "$FORMAT_SCRIPT" ]]; then
    FORMATTED=$(printf '%s' "$MESSAGE" | node "$FORMAT_SCRIPT" 2>/dev/null) || true
    if [[ -n "$FORMATTED" ]]; then MESSAGE="$FORMATTED"; fi
fi

# --- Webhook URL resolver ---
get_webhook_url() {
    local url
    if [[ -n "$CHANNEL" ]]; then
        url=$(jq -r --arg ch "$CHANNEL" '.webhooks[$ch] // .webhook.url' "$CONFIG")
        if [[ -z "$url" || "$url" == "null" ]]; then url=$(jq -r '.webhook.url' "$CONFIG"); fi
    else
        url=$(jq -r '.webhook.url' "$CONFIG")
    fi
    printf '%s' "$url"
}

# --- Rich embed sender (Discord color card) ---
send_embed() {
    local embed_json="$1"
    local webhook_url
    webhook_url=$(get_webhook_url)
    local payload
    payload=$(jq -n --argjson embed "$embed_json" '{"embeds":[$embed]}')
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload") || true
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        echo "WARN: embed webhook returned HTTP $http_code" >&2
    fi
}

# --- Chart embed sender (QuickChart.io → Discord image embed) ---
send_chart_embed() {
    local chart_json="$1"
    local webhook_url
    webhook_url=$(get_webhook_url)

    # Build QuickChart GET URL (node for safe URL encoding)
    local chart_url
    chart_url=$(node -e "process.stdout.write('https://quickchart.io/chart?w=700&h=350&bkg=white&c=' + encodeURIComponent(process.argv[1]))" "$chart_json" 2>/dev/null) || return 0
    if [[ -z "$chart_url" ]]; then return 0; fi

    local payload
    payload=$(jq -n --arg url "$chart_url" '{"embeds":[{"image":{"url":$url},"color":3447003}]}')
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload") || true
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        echo "WARN: chart embed webhook returned HTTP $http_code" >&2
    fi
}

# --- Discord: 2000-char chunking ---
send_discord() {
    local message="$1"
    local webhook_url
    webhook_url=$(get_webhook_url)
    local total=${#message}
    local offset=0

    while [[ $offset -lt $total ]]; do
        local chunk="${message:$offset:1990}"
        local payload
        payload=$(jq -n --arg content "$chunk" '{"content": $content, "flags": 4}')
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d "$payload") || true
        if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
            echo "ERROR: Discord webhook returned HTTP $http_code for task $TASK_ID" >&2
        fi
        offset=$((offset + 1990))
        # Rate limit protection between chunks
        if [[ $offset -lt $total ]]; then sleep 1; fi
    done

    # --- Rich embed (if EMBED_DATA present, send as color card) ---
    if [[ -n "$EMBED_JSON" ]]; then
        sleep 0.3
        send_embed "$EMBED_JSON"
    fi

    # --- Chart embed (append after text/embed if CHART_JSON present) ---
    if [[ -n "$CHART_JSON" ]]; then
        sleep 0.5
        send_chart_embed "$CHART_JSON"
    fi
}

# --- ntfy push ---
send_ntfy() {
    local title="$1"
    local message="$2"
    local server
    local topic
    server=$(jq -r '.ntfy.server' "$CONFIG")
    topic=$(jq -r '.ntfy.topic' "$CONFIG")
    curl -s -m 5 \
        -H "Title: $title" \
        -H "Priority: default" \
        -d "$message" \
        "${server}/${topic}" > /dev/null 2>&1
}

# --- Route by mode ---
case "$MODE" in
    discord)
        send_discord "$MESSAGE"
        ;;
    ntfy)
        send_ntfy "${BOT_NAME:-Bot}: $TASK_ID" "$MESSAGE"
        ;;
    alert)
        "$BOT_HOME/scripts/alert.sh" warning "$TASK_ID" "$MESSAGE"
        ;;
    file)
        # No-op: results already saved by ask-claude.sh
        echo "Result for $TASK_ID saved to results directory."
        ;;
    all)
        send_discord "$MESSAGE"
        send_ntfy "${BOT_NAME:-Bot}: $TASK_ID" "$MESSAGE"
        echo "Result for $TASK_ID saved to results directory."
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        echo "Valid modes: discord, ntfy, alert, file, all" >&2
        exit 2
        ;;
esac
