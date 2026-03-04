#!/usr/bin/env bash
set -euo pipefail

# bot-watchdog.sh - Discord bot log-freshness monitor
# Detects silent death: process alive but WebSocket dead (no log output).
# Also restarts the bot when launchd/systemd has stopped it (PID=-).
# Runs via cron every 5 minutes.
#
# Logic:
#   1. Parse last log timestamp from discord-bot.out.log
#   2. If bot process is not running at all, kickstart immediately
#   3. If gap > SILENCE_THRESHOLD_SEC (silent death), restart
#   4. Send alerts via ntfy + Discord webhook

# --- Configuration ---
BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BOT_LOG="$BOT_HOME/logs/discord-bot.out.log"
WATCHDOG_LOG="$BOT_HOME/logs/bot-watchdog.log"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.claude-discord-bot}"
STATE_DIR="$BOT_HOME/watchdog"
COOLDOWN_FILE="$STATE_DIR/bot-watchdog-last-alert"

SILENCE_THRESHOLD_SEC=900   # 15 minutes
ALERT_COOLDOWN_SEC=900      # 15 minutes between alerts

NTFY_TOPIC="${NTFY_TOPIC:-$(python3 -c "import json; d=json.load(open('$BOT_HOME/config/monitoring.json')); print(d.get('ntfy',{}).get('topic',''))" 2>/dev/null || true)}"
NTFY_SERVER="${NTFY_SERVER:-$(python3 -c "import json; d=json.load(open('$BOT_HOME/config/monitoring.json')); print(d.get('ntfy',{}).get('server','https://ntfy.sh'))" 2>/dev/null || echo "https://ntfy.sh")}"

mkdir -p "$STATE_DIR" "$(dirname "$WATCHDOG_LOG")"

# --- Utility ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHDOG_LOG"; }

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}"
    [[ -z "$NTFY_TOPIC" ]] && return 0
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
    (( elapsed < ALERT_COOLDOWN_SEC ))
}

# Cross-platform ISO timestamp to epoch
parse_iso_epoch() {
    local ts="$1"
    local ts_clean="${ts%%.*}Z"
    local epoch=0
    # macOS BSD date
    if epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts_clean" "+%s" 2>/dev/null); then
        echo "$epoch"; return
    fi
    # Linux GNU date
    if epoch=$(date -u -d "$ts_clean" "+%s" 2>/dev/null); then
        echo "$epoch"; return
    fi
    echo "0"
}

# Cross-platform restart via launchd (macOS) or systemd (Linux)
restart_bot() {
    local reason="$1"
    log "Restarting bot: $reason"
    local uid
    uid=$(id -u)

    if command -v launchctl >/dev/null 2>&1; then
        if launchctl kickstart -k "gui/${uid}/${DISCORD_SERVICE}" 2>/dev/null; then
            log "Restart issued via launchctl kickstart"; return 0
        fi
        local plist="$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist"
        if [[ -f "$plist" ]]; then
            launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null || true
            log "Restart issued via launchctl bootstrap"
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        if systemctl --user restart "${DISCORD_SERVICE}" 2>/dev/null; then
            log "Restart issued via systemctl"; return 0
        fi
    else
        log "ERROR: No service manager found (launchctl/systemctl)"
    fi
}

send_alert() {
    local msg="$1" priority="${2:-high}"
    if ! is_in_alert_cooldown; then
        send_ntfy "Bot Watchdog" "$msg" "$priority"
        send_discord_webhook "$msg"
        date +%s > "$COOLDOWN_FILE"
        log "Alert sent: $msg"
    else
        log "Alert suppressed (cooldown active)"
    fi
}

# --- Main ---

if [[ ! -f "$BOT_LOG" ]]; then
    log "WARN: Bot log not found: $BOT_LOG"
    exit 0
fi

# --- Check if process is running ---
bot_pid=""
if command -v launchctl >/dev/null 2>&1; then
    bot_pid=$(launchctl list 2>/dev/null | grep "$DISCORD_SERVICE" | awk '{print $1}' || true)
elif command -v systemctl >/dev/null 2>&1; then
    bot_pid=$(systemctl --user show "${DISCORD_SERVICE}" --property=MainPID --value 2>/dev/null || true)
    [[ "$bot_pid" == "0" ]] && bot_pid="-"
fi

# If process is not running, restart immediately (do not defer to watchdog.sh)
if [[ "$bot_pid" == "-" || -z "$bot_pid" ]]; then
    log "ALERT: Bot process not running. Restarting immediately."
    restart_bot "process not running"
    send_alert "[Bot Watchdog] Bot was not running. Restarted ${DISCORD_SERVICE}."
    exit 0
fi

# --- Parse last log timestamp ---
last_line=$(tail -20 "$BOT_LOG" | grep -oE '^\[[-0-9T:.Z]+\]' | tail -1 || true)

if [[ -z "$last_line" ]]; then
    log "WARN: No timestamp found in recent log lines"
    exit 0
fi

last_ts="${last_line//[\[\]]/}"
last_epoch=$(parse_iso_epoch "$last_ts")

if (( last_epoch == 0 )); then
    log "WARN: Could not parse timestamp: $last_ts"
    exit 0
fi

now_epoch=$(date +%s)
silence_sec=$(( now_epoch - last_epoch ))

log "Check: last_log=$last_ts silence=${silence_sec}s threshold=${SILENCE_THRESHOLD_SEC}s"

if (( silence_sec < SILENCE_THRESHOLD_SEC )); then
    exit 0
fi

# --- Silent death detected (process alive but no log output) ---
log "ALERT: Bot silent for ${silence_sec}s (>${SILENCE_THRESHOLD_SEC}s). Restarting."
restart_bot "silent death (no log output for ${silence_sec}s)"
send_alert "[Bot Watchdog] Silent death: no log for ${silence_sec}s (PID $bot_pid). Restarted."
