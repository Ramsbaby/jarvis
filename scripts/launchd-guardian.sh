#!/usr/bin/env bash
set -euo pipefail

# launchd-guardian.sh - Cron-based service watchdog (SPOF safety net)
# macOS: monitors LaunchAgents via launchctl
# Linux: monitors systemd user services via systemctl
#
# Runs every 3 minutes via cron. Re-registers/restarts dropped services.
# Service names are read from DISCORD_SERVICE env var (set in .env or cron).

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_FILE="$BOT_HOME/logs/launchd-guardian.log"
ROUTE_RESULT="$BOT_HOME/bin/route-result.sh"
UID_NUM=$(id -u)

# Read service names from env (set these in discord/.env or your cron)
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.claude-discord-bot}"
WATCHDOG_SERVICE="${WATCHDOG_SERVICE:-ai.claude-discord-watchdog}"

# KeepAlive services: must always have a running PID
KEEPALIVE_SERVICES=("$DISCORD_SERVICE")

# StartInterval services: run periodically, PID=- between runs is normal
INTERVAL_SERVICES=("$WATCHDOG_SERVICE")

PLIST_DIR="$HOME/Library/LaunchAgents"
SYSTEMD_DIR="$HOME/.config/systemd/user"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [guardian] $*" >> "$LOG_FILE"; }

# Hourly heartbeat only (minute 00-02 to match */3 cron)
minute=$(date +%M)
is_heartbeat=false
if [[ "$minute" == "00" || "$minute" == "01" || "$minute" == "02" ]]; then
    is_heartbeat=true
fi

recovered=0

# --- macOS launchd helpers ---

launchd_check_loaded() {
    local service="$1"
    local plist_file="${PLIST_DIR}/${service}.plist"
    [[ ! -f "$plist_file" ]] && return 0
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

launchd_keepalive() {
    local service="$1"
    local plist_file="${PLIST_DIR}/${service}.plist"
    [[ ! -f "$plist_file" ]] && return 0
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
    else
        local pid
        pid=$(echo "$status_line" | awk '{print $1}')
        if [[ "$pid" == "-" ]]; then
            log "RECOVERY: $service not running (PID=-), kickstarting"
            launchctl kickstart -k "gui/${UID_NUM}/${service}" 2>/dev/null || true
            recovered=$(( recovered + 1 ))
        fi
    fi
}

# --- Linux systemd helpers ---

systemd_check_active() {
    local service="$1"
    local unit_file="${SYSTEMD_DIR}/${service}.service"
    [[ ! -f "$unit_file" ]] && return 0
    if ! systemctl --user is-enabled "$service" >/dev/null 2>&1; then
        log "RECOVERY: $service not enabled, enabling"
        systemctl --user enable "$service" 2>/dev/null || true
        recovered=$(( recovered + 1 ))
    fi
    if ! systemctl --user is-active "$service" >/dev/null 2>&1; then
        log "RECOVERY: $service not active, starting"
        systemctl --user start "$service" 2>/dev/null || true
        recovered=$(( recovered + 1 ))
    fi
}

# --- Dispatch by platform ---

if command -v launchctl >/dev/null 2>&1; then
    # macOS
    for service in "${KEEPALIVE_SERVICES[@]}"; do
        launchd_keepalive "$service"
    done
    for service in "${INTERVAL_SERVICES[@]}"; do
        launchd_check_loaded "$service"
    done
elif command -v systemctl >/dev/null 2>&1; then
    # Linux
    for service in "${KEEPALIVE_SERVICES[@]}" "${INTERVAL_SERVICES[@]}"; do
        systemd_check_active "$service"
    done
fi

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
