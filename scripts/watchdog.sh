#!/usr/bin/env bash
set -euo pipefail

# watchdog.sh - Discord bot process monitor & self-healer
# Runs every 180s via launchd. Monitors discord-bot, cleans stale claude -p.

# --- Configuration ---
BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="$BOT_HOME/watchdog"
LOG_FILE="$BOT_HOME/logs/watchdog.log"
HEALING_LOCK="/tmp/bot-healing.lock"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.jarvis.discord-bot}"
DISCORD_PLIST="$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist"
ROUTE_RESULT="$BOT_HOME/bin/route-result.sh"

MEMORY_WARN_MB=512
MEMORY_CRITICAL_MB=1024
CLAUDE_STALE_MINUTES=10
BACKOFF_DELAYS=(10 30 90 180 300)
MAX_RETRIES=5
CRASH_DECAY_HOURS=6
FATAL_ALERT_COOLDOWN_SEC=3600  # FATAL 알림 최소 1시간 간격

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# --- Utility functions ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

send_alert() {
    local message="$1"
    log "ALERT: $message"
    if [[ -x "$ROUTE_RESULT" ]]; then
        "$ROUTE_RESULT" discord "watchdog" "$message" 2>/dev/null || true
    fi
}

acquire_lock() {
    if mkdir "$HEALING_LOCK" 2>/dev/null; then
        trap 'rmdir "$HEALING_LOCK" 2>/dev/null' EXIT
        return 0
    fi
    # Stale lock detection (600s = 10 min)
    local lock_age
    if [[ -d "$HEALING_LOCK" ]]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$HEALING_LOCK") ))
        if (( lock_age > 600 )); then
            log "WARN: Removing stale lock (age=${lock_age}s)"
            rmdir "$HEALING_LOCK" 2>/dev/null || true
            mkdir "$HEALING_LOCK" 2>/dev/null || return 1
            trap 'rmdir "$HEALING_LOCK" 2>/dev/null' EXIT
            return 0
        fi
    fi
    log "Another healing in progress, exiting"
    return 1
}

get_crash_count() {
    local file="$STATE_DIR/crash-count"
    if [[ -f "$file" ]]; then cat "$file"; else echo 0; fi
}

increment_crash() {
    local count
    count=$(get_crash_count)
    echo $(( count + 1 )) > "$STATE_DIR/crash-count"
    date +%s > "$STATE_DIR/last-crash"
}

decrement_crash() {
    local count
    count=$(get_crash_count)
    if (( count > 0 )); then
        echo $(( count - 1 )) > "$STATE_DIR/crash-count"
    fi
}

check_crash_decay() {
    local last_crash_file="$STATE_DIR/last-crash"
    if [[ ! -f "$last_crash_file" ]]; then return; fi
    local last_crash elapsed
    last_crash=$(cat "$last_crash_file")
    elapsed=$(( $(date +%s) - last_crash ))
    if (( elapsed > CRASH_DECAY_HOURS * 3600 )); then
        log "Crash decay: ${CRASH_DECAY_HOURS}h since last crash, resetting counter"
        echo 0 > "$STATE_DIR/crash-count"
        rm -f "$last_crash_file"
    fi
}

get_backoff() {
    local count="$1"
    local max_idx=$(( ${#BACKOFF_DELAYS[@]} - 1 ))
    local idx=$(( count < max_idx ? count : max_idx ))
    echo "${BACKOFF_DELAYS[$idx]}"
}

is_in_cooldown() {
    local cooldown_file="$STATE_DIR/last-restart"
    if [[ ! -f "$cooldown_file" ]]; then return 1; fi
    local last_restart elapsed backoff_secs
    last_restart=$(cat "$cooldown_file")
    elapsed=$(( $(date +%s) - last_restart ))
    backoff_secs=$(get_backoff "$(get_crash_count)")
    if (( elapsed < backoff_secs )); then
        log "In cooldown: ${elapsed}s / ${backoff_secs}s"
        return 0
    fi
    return 1
}

graceful_kill() {
    local pid="$1"
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
            sleep 1
            waited=$(( waited + 1 ))
        done
        if kill -0 "$pid" 2>/dev/null; then
            log "WARN: SIGKILL pid=$pid after ${waited}s"
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
}

# --- Stale claude -p cleanup ---
cleanup_stale_claude() {
    local stale_killed=0
    local now
    now=$(date +%s)
    while IFS= read -r line; do
        local pid elapsed_min
        pid=$(echo "$line" | awk '{print $1}')
        elapsed_min=$(echo "$line" | awk '{print $2}')
        if (( elapsed_min >= CLAUDE_STALE_MINUTES )); then
            log "Killing stale claude -p pid=$pid (age=${elapsed_min}m)"
            graceful_kill "$pid"
            stale_killed=$(( stale_killed + 1 ))
        fi
    done < <(pgrep -f "claude -p " 2>/dev/null | while read -r p; do
        # macOS ps -o etime= gives elapsed as [[dd-]hh:]mm:ss — parse with awk
        local raw_etime elapsed_min
        raw_etime=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')
        if [[ -n "$raw_etime" ]]; then
            elapsed_min=$(echo "$raw_etime" | awk -F'[-:]' '{
                n = NF
                if (n == 4) print ($1*1440 + $2*60 + $3 + $4/60)
                else if (n == 3) print ($1*60 + $2 + $3/60)
                else if (n == 2) print ($1 + $2/60)
                else print 0
            }' | awk '{printf "%d", $1}')
            echo "$p $elapsed_min"
        fi
    done)
    echo "$stale_killed"
}

# --- Discord bot status check ---
check_discord_bot() {
    local uid
    uid=$(id -u)
    local status_line
    status_line=$(launchctl list 2>/dev/null | grep "$DISCORD_SERVICE" || true)

    if [[ -z "$status_line" ]]; then
        echo "NOT_LOADED"
        return
    fi

    local pid exit_code
    pid=$(echo "$status_line" | awk '{print $1}')
    exit_code=$(echo "$status_line" | awk '{print $2}')

    if [[ "$pid" == "-" ]]; then
        if [[ "$exit_code" != "0" && "$exit_code" != "-" ]]; then
            echo "CRASHED:$exit_code"
        else
            echo "STOPPED"
        fi
    else
        echo "RUNNING:$pid"
    fi
}

# --- Memory check for process tree ---
check_memory() {
    local pid="$1"
    local total_rss=0
    # Sum RSS of process and children
    while IFS= read -r child_pid; do
        local rss
        rss=$(ps -o rss= -p "$child_pid" 2>/dev/null | tr -d ' ')
        if [[ -n "$rss" ]]; then
            total_rss=$(( total_rss + rss ))
        fi
    done < <(pgrep -P "$pid" 2>/dev/null; echo "$pid")
    echo $(( total_rss / 1024 ))  # Convert KB to MB
}

# --- Main ---
acquire_lock || exit 0
check_crash_decay

stale_killed=$(cleanup_stale_claude)
if (( stale_killed > 0 )); then
    log "Cleaned $stale_killed stale claude -p process(es)"
fi

bot_status=$(check_discord_bot)
crash_count=$(get_crash_count)
memory_mb=0
health_status="unknown"

case "$bot_status" in
    RUNNING:*)
        pid="${bot_status#RUNNING:}"
        memory_mb=$(check_memory "$pid")
        health_status="healthy"
        decrement_crash

        if (( memory_mb >= MEMORY_CRITICAL_MB )); then
            send_alert "[Bot Watchdog] CRITICAL: Discord bot memory=${memory_mb}MB (>=${MEMORY_CRITICAL_MB}MB). Restarting."
            graceful_kill "$pid"
            launchctl kickstart -k "gui/$(id -u)/$DISCORD_SERVICE" 2>/dev/null || true
            health_status="restarted:memory"
        elif (( memory_mb >= MEMORY_WARN_MB )); then
            log "WARN: Discord bot memory=${memory_mb}MB (>=${MEMORY_WARN_MB}MB)"
            health_status="warning:memory"
        fi
        ;;

    NOT_LOADED|CRASHED:*|STOPPED)
        health_status="down:$bot_status"
        increment_crash
        crash_count=$(get_crash_count)

        if (( crash_count >= MAX_RETRIES )); then
            local fatal_last="$STATE_DIR/fatal-alert-last"
            local now_ts
            now_ts=$(date +%s)
            local last_ts=0
            [[ -f "$fatal_last" ]] && last_ts=$(cat "$fatal_last")
            if (( now_ts - last_ts >= FATAL_ALERT_COOLDOWN_SEC )); then
                send_alert "[Bot Watchdog] FATAL: Discord bot crashed ${crash_count} times, max retries reached. Manual intervention required."
                echo "$now_ts" > "$fatal_last"
            else
                log "FATAL alert suppressed (cooldown: $(( FATAL_ALERT_COOLDOWN_SEC - (now_ts - last_ts) ))s remaining)"
            fi
            health_status="fatal:max_retries"
        elif is_in_cooldown; then
            health_status="cooldown"
        else
            backoff=$(get_backoff "$crash_count")
            log "Attempting restart #${crash_count} (backoff=${backoff}s)"
            date +%s > "$STATE_DIR/last-restart"

            if [[ "$bot_status" == "NOT_LOADED" && -f "$DISCORD_PLIST" ]]; then
                launchctl bootstrap "gui/$(id -u)" "$DISCORD_PLIST" 2>/dev/null \
                    || launchctl load "$DISCORD_PLIST" 2>/dev/null || true
            else
                launchctl kickstart -k "gui/$(id -u)/$DISCORD_SERVICE" 2>/dev/null || true
            fi

            if (( crash_count >= 3 )); then
                send_alert "[Bot Watchdog] Discord bot restart #${crash_count}. Status was: $bot_status"
            fi
            health_status="restarting:attempt_$crash_count"
        fi
        ;;
esac

# Write health status
cat > "$BOT_HOME/state/health.json" <<HEALTHEOF
{
  "last_check": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "discord_bot": "$health_status",
  "memory_mb": $memory_mb,
  "stale_claude_killed": $stale_killed,
  "crash_count": $crash_count
}
HEALTHEOF

log "Check complete: bot=$health_status mem=${memory_mb}MB stale_killed=$stale_killed crashes=$crash_count"
