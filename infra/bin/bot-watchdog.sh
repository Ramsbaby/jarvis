#!/usr/bin/env bash
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/.local/share/jarvis}}/lib/compat.sh" 2>/dev/null || true
set -euo pipefail

# Cross-platform: macOS는 launchctl, Linux/WSL2는 PM2 사용

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
BOT_LOG="$BOT_HOME/logs/discord-bot.jsonl"
WATCHDOG_LOG="$BOT_HOME/logs/bot-watchdog.log"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.jarvis.discord-bot}"
STATE_DIR="$BOT_HOME/watchdog"
COOLDOWN_FILE="$STATE_DIR/bot-watchdog-last-alert"

SILENCE_THRESHOLD_SEC=900   # 15 minutes
ALERT_COOLDOWN_SEC=900      # 15 minutes between alerts

# Read ntfy config from monitoring.json (fallback to env)
NTFY_TOPIC="${NTFY_TOPIC:-$(CFG_PATH="$BOT_HOME/config/monitoring.json" python3 -c "import json,os; d=json.load(open(os.environ['CFG_PATH'])); print(d.get('ntfy',{}).get('topic',''))" 2>/dev/null || true)}"
NTFY_SERVER="${NTFY_SERVER:-$(CFG_PATH="$BOT_HOME/config/monitoring.json" python3 -c "import json,os; d=json.load(open(os.environ['CFG_PATH'])); print(d.get('ntfy',{}).get('server','https://ntfy.sh'))" 2>/dev/null || echo "https://ntfy.sh")}"

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
        webhook_url=$(CFG_PATH="$MONITORING_CONFIG" python3 -c "import json,os; d=json.load(open(os.environ['CFG_PATH'])); print(d.get('webhook',{}).get('url',''))" 2>/dev/null || true)
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

# Parse last timestamp from JSONL log
# Format: {"ts":"2026-03-02T04:01:08.742Z",...}
last_ts=$(tail -20 "$BOT_LOG" | grep -oE '"ts":"[-0-9T:.Z]+"' | tail -1 | sed 's/"ts":"//;s/"//' || true)

if [[ -z "$last_ts" ]]; then
    log "WARN: No timestamp found in recent JSONL lines"
    exit 0
fi
# Convert to epoch (strip milliseconds for date compatibility)
last_ts_clean="${last_ts%%.*}Z"
last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts_clean" "+%s" 2>/dev/null \
  || TZ=UTC date -d "$last_ts_clean" "+%s" 2>/dev/null \
  || echo 0)

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

# Check if watchdog.sh is already handling recovery (shared healing lock)
HEALING_LOCK="/tmp/bot-healing.lock"
if [[ -d "$HEALING_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$HEALING_LOCK" 2>/dev/null || stat -c '%Y' "$HEALING_LOCK" 2>/dev/null || echo "$(date +%s)") ))
    if (( lock_age < 600 )); then
        log "SKIP: watchdog.sh healing in progress (lock age=${lock_age}s)"
        exit 0
    fi
fi

log "ALERT: Bot silent for ${silence_sec}s (>${SILENCE_THRESHOLD_SEC}s). Restarting."

# Check if process is actually running (confirms silent death vs real crash)
if $IS_MACOS; then
    bot_pid=$(launchctl list 2>/dev/null | grep "$DISCORD_SERVICE" | awk '{print $1}')
else
    bot_pid=$(pgrep -f "discord-bot.js" 2>/dev/null | head -1 || echo "")
fi

if [[ "$bot_pid" == "-" || -z "$bot_pid" ]]; then
    # 프로세스가 없는 상태 — 직접 재시작
    log "Bot process not running. Attempting direct restart."
    if $IS_MACOS; then
        uid=$(id -u)
        launchctl kickstart "gui/${uid}/${DISCORD_SERVICE}" 2>/dev/null || {
            log "kickstart failed, trying bootstrap"
            launchctl bootstrap "gui/${uid}" "$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist" 2>/dev/null || true
        }
    else
        pm2 restart jarvis-bot 2>/dev/null || { log "pm2 restart failed"; }
    fi
    log "Restart issued for stopped $DISCORD_SERVICE"
    if ! is_in_alert_cooldown; then
        send_discord_webhook "[Bot Watchdog] Bot was not running (silent ${silence_sec}s). Restart issued."
        send_ntfy "Bot Down - Restarted" "Bot not running after ${silence_sec}s silence. Restart issued." "high"
        date +%s > "$COOLDOWN_FILE"
    fi
    exit 0
fi

# Kill + restart
if $IS_MACOS; then
    uid=$(id -u)
    launchctl kickstart -k "gui/${uid}/${DISCORD_SERVICE}" 2>/dev/null || {
        log "ERROR: kickstart failed, trying kill + bootstrap"
        kill -TERM "$bot_pid" 2>/dev/null || true
        sleep 3
        launchctl bootstrap "gui/${uid}" "$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist" 2>/dev/null || true
    }
else
    pm2 restart jarvis-bot 2>/dev/null || {
        log "ERROR: pm2 restart failed, trying kill + restart"
        kill -TERM "$bot_pid" 2>/dev/null || true
        sleep 3
        pm2 start jarvis-bot 2>/dev/null || true
    }
fi

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
