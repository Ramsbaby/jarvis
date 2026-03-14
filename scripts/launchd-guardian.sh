#!/usr/bin/env bash
set -euo pipefail

# launchd-guardian.sh - Cron-based LaunchAgent watchdog (SPOF safety net)
# Runs every 3 minutes via cron. Detects unloaded launchd services and re-registers them.
# Ensures critical LaunchAgents remain registered after system sleep or restart.

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-$HOME/.jarvis}}/lib/compat.sh" 2>/dev/null || true

# launchd-guardian is macOS-only; exit gracefully on other platforms
if ! $IS_MACOS; then
    echo "[compat] launchd-guardian skipped on non-macOS"
    exit 0
fi
LOG_FILE="$BOT_HOME/logs/launchd-guardian.log"
ROUTE_RESULT="$BOT_HOME/bin/route-result.sh"
UID_NUM=$(id -u)

# KeepAlive services: must always have a running PID
KEEPALIVE_SERVICES=(
    "ai.jarvis.discord-bot"
    "ai.jarvis.watchdog"
)

# StartInterval services: run periodically, PID=- between runs is normal
INTERVAL_SERVICES=()

PLIST_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [guardian] $*" >> "$LOG_FILE"; }

# Hourly heartbeat only (minute 00-02 to match */3 cron)
minute=$(date +%M)
is_heartbeat=false
if [[ "$minute" == "00" || "$minute" == "01" || "$minute" == "02" ]]; then
    is_heartbeat=true
fi

recovered=0

check_loaded() {
    local service="$1"
    local plist_file="${PLIST_DIR}/${service}.plist"
    if [[ ! -f "$plist_file" ]]; then return 0; fi
    local status_line
    status_line=$(launchctl list 2>/dev/null | grep "$service" || true)
    if [[ -z "$status_line" ]]; then
        log "RECOVERY: $service not loaded, re-registering"
        if launchctl bootstrap "gui/${UID_NUM}" "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via bootstrap"
        elif launchctl load "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via load (fallback)"
        else
            log "ERROR: Failed to register $service"
            return 0
        fi
        recovered=$(( recovered + 1 ))
    fi
}

# KeepAlive: must always have a running PID — kickstart if PID=-
for service in "${KEEPALIVE_SERVICES[@]}"; do
    plist_file="${PLIST_DIR}/${service}.plist"
    if [[ ! -f "$plist_file" ]]; then continue; fi
    status_line=$(launchctl list 2>/dev/null | grep "$service" || true)
    if [[ -z "$status_line" ]]; then
        log "RECOVERY: $service not loaded, re-registering"
        if launchctl bootstrap "gui/${UID_NUM}" "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via bootstrap"
        elif launchctl load "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via load (fallback)"
        else
            log "ERROR: Failed to register $service"
            continue
        fi
        recovered=$(( recovered + 1 ))
    else
        pid=$(echo "$status_line" | awk '{print $1}')
        if [[ "$pid" == "-" ]]; then
            log "RECOVERY: $service not running (PID=-), kickstarting"
            launchctl kickstart -k "gui/${UID_NUM}/${service}" 2>/dev/null || true
            recovered=$(( recovered + 1 ))
        fi
    fi
done

# StartInterval: check loaded + detect stalled execution
# If the service's log hasn't been updated in 3x its interval, kickstart it.
WATCHDOG_LOG="$BOT_HOME/logs/watchdog.log"
WATCHDOG_INTERVAL=180  # seconds (must match plist StartInterval)
STALL_MULTIPLIER=10   # 180*10=1800s(30분) — 실제 관측 최대 주기 ~1080s(18분) 기준 넉넉한 버퍼

for service in "${INTERVAL_SERVICES[@]+"${INTERVAL_SERVICES[@]}"}"; do
    check_loaded "$service"

    # Stall detection: if log file hasn't been written in INTERVAL * STALL_MULTIPLIER, kickstart
    if [[ "$service" == "ai.jarvis.watchdog" && -f "$WATCHDOG_LOG" ]]; then
        log_mtime=$(stat -f %m "$WATCHDOG_LOG" 2>/dev/null || stat -c '%Y' "$WATCHDOG_LOG" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        log_age=$(( now_epoch - log_mtime ))
        stall_threshold=$(( WATCHDOG_INTERVAL * STALL_MULTIPLIER ))
        if [[ "$log_age" -gt "$stall_threshold" ]]; then
            log "RECOVERY: $service stalled (log age=${log_age}s > ${stall_threshold}s), kickstarting"
            launchctl kickstart -k "gui/${UID_NUM}/${service}" 2>/dev/null || true
            recovered=$(( recovered + 1 ))
        fi
    fi
done

# Send alert on recovery
if (( recovered > 0 )); then
    if [[ -x "$ROUTE_RESULT" ]]; then
        "$ROUTE_RESULT" discord "guardian" "[Bot Guardian] Recovered ${recovered} service(s)" 2>/dev/null || true
    fi
fi

# Heartbeat log (hourly only)
if [[ "$is_heartbeat" == "true" ]]; then
    total=$(( ${#KEEPALIVE_SERVICES[@]} + ${#INTERVAL_SERVICES[@]} ))
    log "Heartbeat: checked ${total} services, recovered=$recovered"
fi
