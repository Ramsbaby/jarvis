#!/usr/bin/env bash
set -euo pipefail

# bot-watchdog.sh - Discord bot log-freshness monitor
# Detects silent death: process alive but WebSocket dead (no log output).
# Runs via cron every 5 minutes.
#
# Logic:
#   1. Parse last log timestamp from discord-bot.out.log
#   2. If gap > SILENCE_THRESHOLD_SEC, kickstart the bot
#   3. Send alerts via ntfy + Discord webhook

# --- Configuration ---
BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BOT_LOG="$BOT_HOME/logs/discord-bot.out.log"
WATCHDOG_LOG="$BOT_HOME/logs/bot-watchdog.log"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.discord-bot}"
STATE_DIR="$BOT_HOME/watchdog"
COOLDOWN_FILE="$STATE_DIR/bot-watchdog-last-alert"

SILENCE_THRESHOLD_SEC=900   # 15 minutes
ALERT_COOLDOWN_SEC=900      # 15 minutes between alerts

# Read ntfy config from monitoring.json (fallback to env)
NTFY_TOPIC="${NTFY_TOPIC:-$(python3 -c "import json; d=json.load(open('$BOT_HOME/config/monitoring.json')); print(d.get('ntfy',{}).get('topic',''))" 2>/dev/null || true)}"
NTFY_SERVER="${NTFY_SERVER:-$(python3 -c "import json; d=json.load(open('$BOT_HOME/config/monitoring.json')); print(d.get('ntfy',{}).get('server','https://ntfy.sh'))" 2>/dev/null || echo "https://ntfy.sh")}"

mkdir -p "$STATE_DIR" "$(dirname "$WATCHDOG_LOG")"

# --- Utility ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHDOG_LOG"; }

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}"
    curl -sf -o /dev/null \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: robot" \
        -d "${body:0:1000}" \
        "${NTFY_SERVER}/${NTFY_TOPIC}" 2>/dev/null || true
}

send_discord_webhook() {
    local message="$1"
    local webhook_url=""
    if [[ -f "$MONITORING_CONFIG" ]]; then
        webhook_url=$(python3 -c "import json,sys; d=json.load(open('$MONITORING_CONFIG')); print(d.get('webhook',{}).get('url',''))" 2>/dev/null || true)
    fi
    if [[ -n "$webhook_url" ]]; then
        local payload
        payload=$(jq -n --arg content "$message" '{"content": $content}')
        curl -sf -o /dev/null \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$webhook_url" 2>/dev/null || true
    fi
}

is_in_alert_cooldown() {
    if [[ ! -f "$COOLDOWN_FILE" ]]; then return 1; fi
    local last_alert elapsed
    last_alert=$(cat "$COOLDOWN_FILE")
    elapsed=$(( $(date +%s) - last_alert ))
    if (( elapsed < ALERT_COOLDOWN_SEC )); then
        return 0
    fi
    return 1
}

# --- Main ---

# Check if log file exists
if [[ ! -f "$BOT_LOG" ]]; then
    log "WARN: Bot log not found: $BOT_LOG"
    exit 0
fi

# Parse last timestamp from log
# Format: [2026-03-02T04:01:08.742Z] level: message
last_line=$(tail -20 "$BOT_LOG" | grep -oE '^\[[-0-9T:.Z]+\]' | tail -1 || true)

if [[ -z "$last_line" ]]; then
    log "WARN: No timestamp found in recent log lines"
    exit 0
fi

# Strip brackets: [2026-03-02T04:01:08.742Z] -> 2026-03-02T04:01:08.742Z
last_ts="${last_line//[\[\]]/}"
# Convert to epoch (strip milliseconds for date compatibility)
last_ts_clean="${last_ts%%.*}Z"
last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts_clean" "+%s" 2>/dev/null || echo 0)

if (( last_epoch == 0 )); then
    log "WARN: Could not parse timestamp: $last_ts"
    exit 0
fi

now_epoch=$(date +%s)
silence_sec=$(( now_epoch - last_epoch ))

log "Check: last_log=$last_ts silence=${silence_sec}s threshold=${SILENCE_THRESHOLD_SEC}s"

if (( silence_sec < SILENCE_THRESHOLD_SEC )); then
    # Bot is active
    exit 0
fi

# --- Silent death detected ---
log "ALERT: Bot silent for ${silence_sec}s (>${SILENCE_THRESHOLD_SEC}s). Restarting."

# Check if process is actually running (confirms silent death vs real crash)
bot_pid=$(launchctl list 2>/dev/null | grep "$DISCORD_SERVICE" | awk '{print $1}')
if [[ "$bot_pid" == "-" || -z "$bot_pid" ]]; then
    log "Bot process not running. Existing watchdog.sh should handle this. Skipping."
    exit 0
fi

# Kickstart (kill + restart)
uid=$(id -u)
launchctl kickstart -k "gui/${uid}/${DISCORD_SERVICE}" 2>/dev/null || {
    log "ERROR: kickstart failed, trying kill + bootstrap"
    kill -TERM "$bot_pid" 2>/dev/null || true
    sleep 3
    launchctl bootstrap "gui/${uid}" "$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist" 2>/dev/null || true
}

log "Restart issued for $DISCORD_SERVICE"

# Send alerts (with cooldown)
if ! is_in_alert_cooldown; then
    alert_msg="[Bot Watchdog] Silent death detected. Bot was alive (PID $bot_pid) but no log output for ${silence_sec}s. Restarted."

    send_ntfy "Bot Silent Death" "$alert_msg" "high"
    send_discord_webhook "$alert_msg"

    date +%s > "$COOLDOWN_FILE"
    log "Alerts sent (ntfy + Discord webhook)"
else
    log "Alert suppressed (cooldown active)"
fi
