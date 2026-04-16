#!/usr/bin/env bash
set -euo pipefail

# health-check.sh - Quick health status for all bot components
# Usage: health-check.sh [--json]

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/.jarvis}}/lib/compat.sh" 2>/dev/null || true
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
bot_status=$($IS_MACOS && launchctl list 2>/dev/null | grep "ai.jarvis.discord-bot" || echo "")
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
wd_status=$($IS_MACOS && launchctl list 2>/dev/null | grep "ai.jarvis.watchdog" || echo "")
if [[ -z "$wd_status" ]]; then
    check "watchdog" "fail" "not loaded in launchd"
else
    check "watchdog" "ok" "loaded (StartInterval=180s)"
fi

# 3. Cron tasks (launchd-based — crontab 금지: com.vix.cron 데몬 비활성 시 hang)
cron_count=$(ls ~/Library/LaunchAgents/ 2>/dev/null | grep -cE "com\.jarvis\.|ai\.jarvis\." || echo "0")
check "cron-tasks" "ok" "${cron_count} launchd agents"

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
# inactivity timeout은 사용자 비응답(정상 동작) — critical 카운트 제외
bot_errors_today=$(grep "$(date +%F)" "$BOT_HOME/logs/discord-bot.jsonl" 2>/dev/null \
    | grep '"level":"error"' \
    | grep -v "inactivity timeout\|no_response_expected" \
    | { wc -l || true; } | tr -d ' ')
bot_errors_today=${bot_errors_today:-0}
if [[ "$bot_errors_today" -gt 50 ]]; then
    check "bot-errors" "fail" "today: ${bot_errors_today} real errors (critical)"
elif [[ "$bot_errors_today" -gt 10 ]]; then
    check "bot-errors" "warn" "today: ${bot_errors_today} errors"
else
    check "bot-errors" "ok" "today: ${bot_errors_today} errors"
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
total_logs=$(du -sh "$BOT_HOME/logs" 2>/dev/null | awk '{print $1}' || echo "0")
check "log-size" "ok" "${total_logs:-0}"

# ── Enhanced health.json (version 2) ─────────────────────────────────────────
# Only write when NOT in per-line JSON mode (i.e. normal or --write-health flag)
_write_health_json() {
    local _start_ms
    _start_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo "0")

    # --- system: disk ---
    local _disk_used_pct _disk_free_gb _inode_used_pct
    _disk_used_pct=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}' 2>/dev/null || echo "0")
    _disk_free_gb=$(df -k / | awk 'NR==2 {printf "%.1f", $4/1024/1024}' 2>/dev/null || echo "0")
    _inode_used_pct=$(df -i / | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}' 2>/dev/null || echo "0")

    # --- system: memory (memory_pressure 기반 — macOS에서 free pages만 보면 실제 가용량을 과소평가) ---
    local _mem_free_pct _mem_severity _rss_mb
    _mem_free_pct=$(memory_pressure 2>/dev/null \
        | awk '/System-wide memory free percentage:/{gsub(/%/,"",$NF); print $NF+0}' || echo "0")
    if [[ "$_mem_free_pct" -lt 10 ]]; then
        _mem_severity="HIGH"
    elif [[ "$_mem_free_pct" -lt 20 ]]; then
        _mem_severity="MEDIUM"
    else
        _mem_severity="LOW"
    fi
    _rss_mb=0
    local _bot_pid_h
    _bot_pid_h=$($IS_MACOS && launchctl list 2>/dev/null | awk '/ai\.jarvis\.discord-bot/{print $1}' | grep -v '^-' || echo "")
    if [[ -n "$_bot_pid_h" ]] && [[ "$_bot_pid_h" =~ ^[0-9]+$ ]]; then
        local _rss_kb
        _rss_kb=$(ps -p "$_bot_pid_h" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
        _rss_mb=$(( ${_rss_kb:-0} / 1024 ))
    fi

    # --- services: discord_bot ---
    local _bot_loaded _bot_status_h _bot_pid_val _bot_pid_int
    _bot_loaded="false"
    _bot_status_h="down"
    _bot_pid_val=0
    local _bot_launchd
    _bot_launchd=$($IS_MACOS && launchctl list 2>/dev/null | grep "ai\.jarvis\.discord-bot" || echo "")
    if [[ -n "$_bot_launchd" ]]; then
        _bot_loaded="true"
        _bot_pid_int=$(echo "$_bot_launchd" | awk '{print $1}')
        if [[ "$_bot_pid_int" =~ ^[0-9]+$ ]] && [[ "$_bot_pid_int" -gt 0 ]]; then
            _bot_pid_val="$_bot_pid_int"
            if [[ "${_rss_mb:-0}" -gt 512 ]]; then
                _bot_status_h="degraded"
            else
                _bot_status_h="healthy"
            fi
        else
            _bot_status_h="down"
        fi
    fi

    # backward-compat discord_bot string field
    local _discord_bot_compat
    if [[ "$_bot_status_h" == "healthy" ]]; then
        _discord_bot_compat="healthy"
    elif [[ "$_bot_status_h" == "degraded" ]]; then
        _discord_bot_compat="degraded"
    else
        _discord_bot_compat="down"
    fi

    # --- services: watchdog ---
    local _wd_loaded
    _wd_loaded="false"
    if $IS_MACOS && launchctl list 2>/dev/null | grep -q "ai\.jarvis\.watchdog"; then
        _wd_loaded="true"
    fi

    # --- services: rag_watcher ---
    local _rag_loaded
    _rag_loaded="false"
    if $IS_MACOS && launchctl list 2>/dev/null | grep -q "ai\.jarvis\.rag-watch\|rag.watch\|rag-watch" 2>/dev/null; then
        _rag_loaded="true"
    fi
    # fallback: check if rag-watch process is running
    if [[ "$_rag_loaded" == "false" ]]; then
        if ps -eo command 2>/dev/null | grep -q "[r]ag-watch"; then
            _rag_loaded="true"
        fi
    fi

    # --- crons: last 5 lines of cron.log ---
    local _cron_log="$BOT_HOME/logs/cron.log"
    local _cron_json="[]"
    if [[ -f "$_cron_log" ]]; then
        local _cron_entries=""
        local _first=1
        while IFS= read -r _line; do
            # format: [2026-03-10 16:00:01] [task-id] STATUS
            local _ts _task _state
            # format: [2026-03-10 16:00:01] [task-id] STATUS ...
            _ts=$(echo "$_line" | sed -nE 's/^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\].*/\1/p' || echo "")
            _task=$(echo "$_line" | sed -nE 's/^\[[^]]*\] \[([^]]+)\].*/\1/p' || echo "")
            _state=$(echo "$_line" | awk '{print $NF}' || echo "")
            if [[ -n "$_ts" ]] && [[ -n "$_task" ]]; then
                local _entry
                _entry=$(printf '{"ts":"%s","task":"%s","state":"%s"}' \
                    "$_ts" "$_task" "$_state")
                if [[ "$_first" -eq 1 ]]; then
                    _cron_entries="$_entry"
                    _first=0
                else
                    _cron_entries="${_cron_entries},${_entry}"
                fi
            fi
        done < <(tail -5 "$_cron_log" 2>/dev/null)
        if [[ -n "$_cron_entries" ]]; then
            _cron_json="[${_cron_entries}]"
        fi
    fi

    # --- checks: array from this script's check() calls (summarized) ---
    local _today_h
    _today_h=$(date +%F)
    local _success_h _failures_h _crash_h _stale_h
    _success_h=$(grep "$_today_h" "$BOT_HOME/logs/task-runner.jsonl" 2>/dev/null | { grep -c '"success"' || true; } || echo "0")
    _failures_h=$(grep "$_today_h" "$BOT_HOME/logs/task-runner.jsonl" 2>/dev/null | { grep -c '"error"\|"timeout"' || true; } || echo "0")
    _crash_h=0
    if [[ -f "$BOT_HOME/watchdog/crash-count" ]]; then
        _crash_h=$(cat "$BOT_HOME/watchdog/crash-count" 2>/dev/null || echo "0")
    fi
    _stale_h=$(ps -eo pid,etime,command 2>/dev/null | { grep "[c]laude -p " || true; } | wc -l | tr -d ' ' || echo "0")

    local _checks_json
    _checks_json=$(printf '[{"name":"cron_today","success":%s,"fail":%s},{"name":"crash_count","value":%s},{"name":"stale_claude","count":%s}]' \
        "${_success_h:-0}" "${_failures_h:-0}" "${_crash_h:-0}" "${_stale_h:-0}")

    # --- timing ---
    local _end_ms _duration_ms _now_iso
    _end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo "0")
    _duration_ms=$(( _end_ms - _start_ms )) 2>/dev/null || _duration_ms=0
    _now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # --- stale_claude_killed (read from watchdog state if available) ---
    local _stale_killed=0
    if [[ -f "$BOT_HOME/state/health.json" ]]; then
        _stale_killed=$(python3 -c "import json,sys; d=json.load(open('$BOT_HOME/state/health.json')); print(d.get('stale_claude_killed',0))" 2>/dev/null || echo "0")
    fi

    # P3: FSM 상태 요약 (task-store.mjs list 기반 집계)
    local _fsm_total=0 _fsm_done=0 _fsm_failed=0 _fsm_running=0 _fsm_queued=0 _fsm_skipped=0 _fsm_cb_open=0
    local _fsm_list
    _fsm_list=$(node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" list 2>/dev/null || echo "[]")
    if [[ "$_fsm_list" != "[]" && -n "$_fsm_list" ]]; then
        _fsm_total=$(echo "$_fsm_list" | python3 -c "import json,sys; t=json.load(sys.stdin); print(len(t))" 2>/dev/null || echo "0")
        _fsm_done=$(echo "$_fsm_list" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sum(1 for x in t if x.get('status')=='done'))" 2>/dev/null || echo "0")
        _fsm_failed=$(echo "$_fsm_list" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sum(1 for x in t if x.get('status')=='failed'))" 2>/dev/null || echo "0")
        _fsm_running=$(echo "$_fsm_list" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sum(1 for x in t if x.get('status')=='running'))" 2>/dev/null || echo "0")
        _fsm_queued=$(echo "$_fsm_list" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sum(1 for x in t if x.get('status')=='queued'))" 2>/dev/null || echo "0")
        _fsm_skipped=$(echo "$_fsm_list" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sum(1 for x in t if x.get('status')=='skipped'))" 2>/dev/null || echo "0")
        # CB open: skipped 중 reason=cb_open인 태스크 (meta.reason 필드 확인)
        _fsm_cb_open=$(echo "$_fsm_list" | python3 -c "
import json,sys
t=json.load(sys.stdin)
print(sum(1 for x in t if x.get('status')=='skipped' and x.get('meta',{}).get('reason')=='cb_open'))
" 2>/dev/null || echo "0")
    fi

    # --- atomic write ---
    local _tmp="$BOT_HOME/state/health.json.tmp"
    cat > "$_tmp" <<JSONEOF
{
  "version": "2",
  "last_check": "${_now_iso}",
  "check_duration_ms": ${_duration_ms},
  "discord_bot": "${_discord_bot_compat}",
  "memory_mb": ${_rss_mb},
  "stale_claude_killed": ${_stale_killed},
  "crash_count": ${_crash_h},
  "fsm": {
    "total": ${_fsm_total},
    "done": ${_fsm_done},
    "failed": ${_fsm_failed},
    "running": ${_fsm_running},
    "queued": ${_fsm_queued},
    "skipped": ${_fsm_skipped},
    "cb_open": ${_fsm_cb_open},
    "updated": "${_now_iso}"
  },
  "system": {
    "disk_root": { "used_pct": ${_disk_used_pct}, "free_gb": ${_disk_free_gb}, "inode_used_pct": ${_inode_used_pct} },
    "memory": { "free_pct": ${_mem_free_pct}, "severity": "${_mem_severity}", "rss_mb": ${_rss_mb} }
  },
  "services": {
    "discord_bot": { "status": "${_bot_status_h}", "pid": ${_bot_pid_val}, "loaded": ${_bot_loaded} },
    "watchdog": { "loaded": ${_wd_loaded} },
    "rag_watcher": { "loaded": ${_rag_loaded} }
  },
  "crons": ${_cron_json},
  "checks": ${_checks_json}
}
JSONEOF
    mv "$_tmp" "$BOT_HOME/state/health.json"
}

# Write enhanced health.json unless in --json streaming mode
if [[ "$JSON_MODE" != "--json" ]]; then
    _write_health_json
fi
