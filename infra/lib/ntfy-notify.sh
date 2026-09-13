#!/usr/bin/env bash
# ntfy-notify.sh — ntfy.sh push notification shared function
# Usage: source "$BOT_HOME/lib/ntfy-notify.sh"

[[ -n "${_NTFY_NOTIFY_LOADED:-}" ]] && return 0
_NTFY_NOTIFY_LOADED=1

# send_ntfy — send push notification via ntfy.sh
# $1: title
# $2: message body
# $3: (optional) priority (default/low/min/high/max) default: high
send_ntfy() {
    local title="$1" msg="$2" priority="${3:-high}"
    # JARVIS_NO_EXTERNAL=1 (2026-09-04, 1d): 테스트·dry-run 은 파일에만 기록
    if [[ "${JARVIS_NO_EXTERNAL:-0}" == "1" ]]; then
        mkdir -p "${BOT_HOME:-$HOME/.openclaw-data/runtime}/logs" 2>/dev/null || true
        printf '%s [NO_EXTERNAL] src=ntfy-notify.sh:send_ntfy title=%s len=%s\n' "$(date -u +%FT%TZ)" "${title:0:60}" "${#msg}" \
            >> "${BOT_HOME:-$HOME/.openclaw-data/runtime}/logs/no-external.log" 2>/dev/null || true
        return 0
    fi
    local topic
    topic=$(jq -r '.ntfy.topic // empty' "${BOT_HOME:-$HOME/.openclaw-data/runtime}/config/monitoring.json" 2>/dev/null || echo "")
    [[ -z "$topic" ]] && return 1
    curl -s --max-time 10 \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: warning" \
        -d "$msg" "https://ntfy.sh/${topic}" >/dev/null 2>&1 || true
}