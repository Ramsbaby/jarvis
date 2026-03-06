#!/usr/bin/env bash
set -euo pipefail

# health-check.sh - Quick health status for all bot components
# Usage: health-check.sh [--json]

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
JSON_MODE="${1:-}"

check() {
    local name="$1" status="$2" detail="$3"
    if [[ "$JSON_MODE" == "--json" ]]; then
        printf '{"component":"%s","status":"%s","detail":"%s"}\n' "$name" "$status" "$detail"
    else
        local icon="✅"
        if [[ "$status" == "warn" ]]; then icon="⚠️"; fi
        if [[ "$status" == "fail" ]]; then icon="❌"; fi
        printf "%s %-20s %s\n" "$icon" "$name" "$detail"
    fi
}

# 1. Discord Bot (launchd)
bot_status=$(launchctl list 2>/dev/null | grep "ai.jarvis.discord-bot" || echo "")
if [[ -z "$bot_status" ]]; then
    check "discord-bot" "fail" "not loaded in launchd"
else
    bot_pid=$(echo "$bot_status" | awk '{print $1}')
    if [[ "$bot_pid" != "-" ]] && [[ "$bot_pid" -gt 0 ]] 2>/dev/null; then
        mem_kb=$(ps -p "$bot_pid" -o rss= 2>/dev/null | tr -d ' ')
        mem_mb=$(( ${mem_kb:-0} / 1024 ))
        if [[ $mem_mb -gt 512 ]]; then
            check "discord-bot" "warn" "PID:${bot_pid} RSS:${mem_mb}MB (high)"
        else
            check "discord-bot" "ok" "PID:${bot_pid} RSS:${mem_mb}MB"
        fi
    else
        exit_code=$(echo "$bot_status" | awk '{print $2}')
        check "discord-bot" "fail" "not running (exit:${exit_code})"
    fi
fi

# 2. Watchdog (launchd)
wd_status=$(launchctl list 2>/dev/null | grep "ai.jarvis.watchdog" || echo "")
if [[ -z "$wd_status" ]]; then
    check "watchdog" "fail" "not loaded in launchd"
else
    check "watchdog" "ok" "loaded (StartInterval=180s)"
fi

# 3. Cron tasks
cron_count=$(crontab -l 2>/dev/null | grep -c "jarvis-cron\|bot-cron\|launchd-guardian\|event-trigger\|calendar-alert" || echo "0")
check "cron-tasks" "ok" "${cron_count} entries"

# 4. Stale claude -p processes
stale=$(ps -eo pid,etime,command 2>/dev/null | { grep "[c]laude -p " || true; } | wc -l | tr -d ' ')
if [[ "$stale" -gt 2 ]]; then
    check "claude-procs" "warn" "${stale} running (max 2 expected)"
else
    check "claude-procs" "ok" "${stale} running"
fi

# 5. Disk space
disk_pct=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
if [[ "$disk_pct" -gt 90 ]]; then
    check "disk" "fail" "${disk_pct}% used"
elif [[ "$disk_pct" -gt 80 ]]; then
    check "disk" "warn" "${disk_pct}% used"
else
    check "disk" "ok" "${disk_pct}% used"
fi

# 6. Recent cron results
today=$(date +%F)
success=$(grep "$today" "$BOT_HOME/logs/task-runner.jsonl" 2>/dev/null | { grep -c '"success"' || true; })
failures=$(grep "$today" "$BOT_HOME/logs/task-runner.jsonl" 2>/dev/null | { grep -c '"error"\|"timeout"' || true; })
check "cron-results" "ok" "today: ${success} success, ${failures} failures"

# 7. Discord bot error log (infra 팀장용 가시성)
bot_errors_today=$(grep "$(date +%F)" "$BOT_HOME/logs/discord-bot.jsonl" 2>/dev/null | { grep -c '"level":"error"' || true; })
if [[ "$bot_errors_today" -gt 10 ]]; then
    check "bot-errors" "fail" "today: ${bot_errors_today} errors (critical)"
elif [[ "$bot_errors_today" -gt 0 ]]; then
    check "bot-errors" "warn" "today: ${bot_errors_today} errors"
else
    check "bot-errors" "ok" "today: 0 errors"
fi

# 8. Crash counter
crash_count=0
if [[ -f "$BOT_HOME/watchdog/crash-count" ]]; then crash_count=$(cat "$BOT_HOME/watchdog/crash-count"); fi
if [[ "$crash_count" -gt 3 ]]; then
    check "crash-count" "warn" "${crash_count} crashes"
else
    check "crash-count" "ok" "${crash_count} crashes"
fi

# 8. Log sizes
total_logs=$(du -sh "$BOT_HOME/logs" 2>/dev/null | awk '{print $1}')
check "log-size" "ok" "${total_logs:-0}"
