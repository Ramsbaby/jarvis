#!/usr/bin/env bash
set -euo pipefail

# watchdog.sh - Discord bot process monitor & self-healer
# KeepAlive launchd service with internal 180s loop. Monitors discord-bot, cleans stale claude -p.

# --- Configuration ---
BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-$HOME/.jarvis}}/lib/compat.sh" 2>/dev/null || true
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true
STATE_DIR="$BOT_HOME/watchdog"
LOG_FILE="$BOT_HOME/logs/watchdog.log"
HEALING_LOCK="/tmp/bot-healing.lock"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.jarvis.discord-bot}"
DISCORD_PLIST="$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist"
ROUTE_RESULT="$BOT_HOME/bin/route-result.sh"

MEMORY_WARN_MB=900    # LanceDB 인덱스 로드 포함 실측치 고려
MEMORY_CRITICAL_MB=1400  # 재시작 임계값: session-sync 스파이크(+450MB) 여유 확보
CLAUDE_STALE_MINUTES=10
HEARTBEAT_FILE="$BOT_HOME/state/bot-heartbeat"
HEARTBEAT_STALE_SEC=900  # 15분: 하트비트 없으면 좀비
BACKOFF_DELAYS=(10 30 90 180 300)
MAX_RETRIES=5
CRASH_DECAY_HOURS=6
FATAL_ALERT_COOLDOWN_SEC=3600  # FATAL 알림 최소 1시간 간격
CRASH_LOOP_WINDOW_SEC=1800     # 30분 내 재시작이 3회 이상이면 크래시 루프
CRASH_LOOP_THRESHOLD=3

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# --- Utility functions ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

send_alert() {
    local message="$1"
    log "ALERT: $message"
    if [[ -x "$ROUTE_RESULT" ]]; then
        "$ROUTE_RESULT" discord "watchdog" "$message" 2>/dev/null || true
    fi
    # ntfy 직접 전송 — Discord 봇 다운·크래시 루프 중에도 폰 알림 도달
    local _ntfy_topic
    _ntfy_topic=$(jq -r '.ntfy.topic // empty' "$BOT_HOME/config/monitoring.json" 2>/dev/null || true)
    if [[ -n "$_ntfy_topic" ]]; then
        curl -sf --max-time 5 \
            -H "Title: Jarvis 봇 경고" \
            -H "Priority: high" \
            -H "Tags: warning,robot" \
            -d "$message" \
            "https://ntfy.sh/${_ntfy_topic}" >/dev/null 2>&1 || true
    fi
}

# PID 변경 추적 — 크래시 루프(30분 내 3회 이상 재시작) 감지
# 인자: 현재 PID
detect_crash_loop() {
    local current_pid="$1"
    local pid_file="$STATE_DIR/last-pid"
    local restart_log="$STATE_DIR/restart-times"
    local prev_pid=""
    if [[ -f "$pid_file" ]]; then prev_pid=$(cat "$pid_file"); fi
    echo "$current_pid" > "$pid_file"

    if [[ -n "$prev_pid" && "$current_pid" != "$prev_pid" ]]; then
        # PID 바뀜 → 재시작 이벤트 기록
        date +%s >> "$restart_log"
        # 오래된 항목 제거 (30분 초과)
        local threshold=$(( $(date +%s) - CRASH_LOOP_WINDOW_SEC ))
        if [[ -f "$restart_log" ]]; then
            local tmp="$restart_log.tmp"
            awk -v t="$threshold" '$1>t' "$restart_log" > "$tmp" && mv "$tmp" "$restart_log" || true
        fi
        local restart_count
        restart_count=$(wc -l < "$restart_log" 2>/dev/null | tr -d ' ')
        if (( restart_count >= CRASH_LOOP_THRESHOLD )); then
            local last_error
            last_error=$(tail -30 "$BOT_HOME/logs/discord-bot.log" 2>/dev/null \
                | grep -iE "Error:|TypeError|SyntaxError|Cannot find|ENOENT|FATAL" \
                | tail -1 || echo "로그 없음")
            send_alert "[Bot Watchdog] CRASH LOOP: ${restart_count}회 재시작 (30분 내). 마지막 에러: ${last_error}"
            # 크래시 루프 감지 후 restart-times 초기화 (중복 알림 방지)
            true > "$restart_log"
        fi
    fi
}

acquire_lock() {
    if mkdir "$HEALING_LOCK" 2>/dev/null; then
        return 0
    fi
    # Stale lock detection (600s = 10 min)
    local lock_age
    if [[ -d "$HEALING_LOCK" ]]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$HEALING_LOCK" 2>/dev/null || stat -c '%Y' "$HEALING_LOCK" 2>/dev/null || echo "$(date +%s)") ))
        if (( lock_age > 600 )); then
            log "WARN: Removing stale lock (age=${lock_age}s)"
            rmdir "$HEALING_LOCK" 2>/dev/null || true
            mkdir "$HEALING_LOCK" 2>/dev/null || return 1
            return 0
        fi
    fi
    log "Another healing in progress, skipping"
    return 1
}

release_lock() {
    rmdir "$HEALING_LOCK" 2>/dev/null || true
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

# active-session 파일 기반으로 좀비 재시작을 건너뛸지 판단.
# 0(skip) = 세션 활성 중, 1(proceed) = 재시작 진행
_should_skip_zombie_restart() {
    local active_session_file="$BOT_HOME/state/active-session"
    [[ -f "$active_session_file" ]] || return 1
    local active_ts active_age
    active_ts=$(cat "$active_session_file" 2>/dev/null || echo "0")
    if ! [[ "$active_ts" =~ ^[0-9]+$ ]]; then active_ts=0; fi
    active_age=$(( ( $(date +%s) * 1000 - active_ts ) / 1000 ))
    if (( active_age < 900 )); then
        log "Bot has active session (age=${active_age}s), skipping zombie restart"
        return 0
    fi
    return 1
}

# --- Discord bot status check ---
check_discord_bot() {
    if ! $IS_MACOS; then
        # Linux/Docker: pgrep으로 봇 프로세스 직접 감지
        local bot_pid
        bot_pid=$(pgrep -f "discord-bot.js" 2>/dev/null | head -1 || true)
        if [[ -n "$bot_pid" ]]; then
            echo "RUNNING:$bot_pid"
        else
            echo "NOT_LOADED"
        fi
        return
    fi

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

# Linux/Docker pm2 재시작 헬퍼
_bot_restart() {
    if $IS_MACOS; then
        launchctl kickstart -k "gui/$(id -u)/$DISCORD_SERVICE" 2>/dev/null || true
    else
        pm2 restart jarvis-bot 2>/dev/null || true
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

# --- Zombie Claude Code agent cleanup (team agents that outlive their session) ---
cleanup_zombie_agents() {
    local killed=0
    while IFS= read -r line; do
        local pid elapsed_min
        pid=$(echo "$line" | awk '{print $1}')
        elapsed_min=$(echo "$line" | awk '{print $2}')
        # Agents running > 30 minutes are likely zombies
        if (( elapsed_min >= 30 )); then
            log "Killing zombie agent pid=$pid (age=${elapsed_min}m)"
            graceful_kill "$pid"
            killed=$(( killed + 1 ))
        fi
    done < <(pgrep -f "claude.*agent" 2>/dev/null | while read -r p; do
        # Skip the discord-bot.js process itself
        local cmdline
        cmdline=$(ps -o args= -p "$p" 2>/dev/null || true)
        if [[ "$cmdline" == *"discord-bot"* ]]; then continue; fi
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
    if (( killed > 0 )); then
        log "Cleaned $killed zombie agent process(es)"
    fi
}

# Reconcile claude-global.count with actual lock slots (prevent counter drift)
_reconcile_global_count() {
    local lock_dir="/tmp/claude-discord-locks"
    local count_file="$BOT_HOME/state/claude-global.count"
    local actual_slots=0
    if [[ -d "$lock_dir" ]]; then
        actual_slots=$(find "$lock_dir" -maxdepth 1 -name 'slot-*' -type d 2>/dev/null | wc -l | tr -d ' ')
    fi
    local file_count=0
    if [[ -f "$count_file" ]]; then
        file_count=$(cat "$count_file" 2>/dev/null || echo "0")
        if ! [[ "$file_count" =~ ^[0-9]+$ ]]; then file_count=0; fi
    fi
    if [[ "$file_count" -ne "$actual_slots" ]]; then
        echo "$actual_slots" > "$count_file"
        log "Counter reconciled: $file_count → $actual_slots"
    fi
}

# Stale semaphore slot 직접 정리 (STALE_TIMEOUT=180s 기준)
_cleanup_stale_semaphore_slots() {
    local lock_dir="/tmp/claude-discord-locks"
    local stale_sec=180
    local cleaned=0
    if [[ ! -d "$lock_dir" ]]; then return; fi
    while IFS= read -r slot_dir; do
        local pid_file="${slot_dir}/pid"
        local slot_age
        slot_age=$(( $(date +%s) - $(stat -f %m "$slot_dir" 2>/dev/null || stat -c '%Y' "$slot_dir" 2>/dev/null || echo "$(date +%s)") ))
        if (( slot_age > stale_sec )); then
            # PID가 살아있으면 건드리지 않음
            if [[ -f "$pid_file" ]]; then
                local slot_pid
                slot_pid=$(cat "$pid_file" 2>/dev/null || echo "")
                if [[ -n "$slot_pid" ]] && kill -0 "$slot_pid" 2>/dev/null; then
                    continue  # 프로세스 살아있음 — 스킵
                fi
            fi
            rm -rf "$slot_dir" 2>/dev/null || true
            cleaned=$(( cleaned + 1 ))
            log "Stale semaphore slot removed: $slot_dir (age=${slot_age}s)"
        fi
    done < <(find "$lock_dir" -maxdepth 1 -name 'slot-*' -type d 2>/dev/null)
    if (( cleaned > 0 )); then
        _reconcile_global_count
        log "Semaphore cleanup: ${cleaned} stale slot(s) removed — cron unblocked"
    fi
}

# --- Single monitoring pass ---
run_one_check() {
    check_crash_decay

    local stale_killed
    stale_killed=$(cleanup_stale_claude)
    if (( stale_killed > 0 )); then
        log "Cleaned $stale_killed stale claude -p process(es)"
    fi

    cleanup_zombie_agents
    _cleanup_stale_semaphore_slots
    _reconcile_global_count

    local bot_status crash_count memory_mb health_status
    bot_status=$(check_discord_bot)
    crash_count=$(get_crash_count)
    memory_mb=0
    health_status="unknown"

    case "$bot_status" in
        RUNNING:*)
            local pid
            pid="${bot_status#RUNNING:}"
            memory_mb=$(check_memory "$pid")
            health_status="healthy"
            # 크래시 루프 감지 (PID 변경 빈도 추적)
            detect_crash_loop "$pid"

            # Zombie detection: PID alive but no heartbeat for 15+ minutes
            # Safety: also check process uptime to avoid restart loop on fresh boots
            local proc_uptime_sec
            proc_uptime_sec=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' | awk -F'[-:]' '{
                n = NF
                if (n == 4) print ($1*86400 + $2*3600 + $3*60 + $4)
                else if (n == 3) print ($1*3600 + $2*60 + $3)
                else if (n == 2) print ($1*60 + $2)
                else print 0
            }')
            if ! [[ "$proc_uptime_sec" =~ ^[0-9]+$ ]]; then proc_uptime_sec=0; fi

            if (( proc_uptime_sec < HEARTBEAT_STALE_SEC )); then
                # Process recently started — skip zombie check, give it time to connect
                log "Bot PID=$pid uptime=${proc_uptime_sec}s < ${HEARTBEAT_STALE_SEC}s, skipping zombie check"
            elif [[ -f "$HEARTBEAT_FILE" ]]; then
                local hb_ts now_ts hb_age
                hb_ts=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
                if ! [[ "$hb_ts" =~ ^[0-9]+$ ]]; then hb_ts=0; fi
                now_ts=$(($(date +%s) * 1000))
                hb_age=$(( (now_ts - hb_ts) / 1000 ))
                if (( hb_age > HEARTBEAT_STALE_SEC )); then
                    send_alert "[Bot Watchdog] ZOMBIE: Bot PID=$pid alive but heartbeat stale (${hb_age}s, uptime=${proc_uptime_sec}s). Force restarting."
                    if _should_skip_zombie_restart; then
                        health_status="skipped:active_session"
                    else
                        _bot_restart
                        health_status="restarted:zombie"
                        increment_crash
                    fi
                fi
            else
                # No heartbeat file + uptime > threshold → zombie
                send_alert "[Bot Watchdog] ZOMBIE: Bot PID=$pid uptime=${proc_uptime_sec}s but no heartbeat file. Force restarting."
                if _should_skip_zombie_restart; then
                    health_status="skipped:active_session_no_hb"
                else
                    _bot_restart
                    health_status="restarted:zombie_no_hb"
                    increment_crash
                fi
            fi

            # Only decrement crash counter if bot is truly healthy
            if [[ "$health_status" == "healthy" ]]; then
                decrement_crash
                if (( memory_mb >= MEMORY_CRITICAL_MB )); then
                    send_alert "[Bot Watchdog] CRITICAL: Discord bot memory=${memory_mb}MB (>=${MEMORY_CRITICAL_MB}MB). Restarting."
                    _bot_restart
                    health_status="restarted:memory"
                elif (( memory_mb >= MEMORY_WARN_MB )); then
                    log "WARN: Discord bot memory=${memory_mb}MB (>=${MEMORY_WARN_MB}MB)"
                    health_status="warning:memory"
                fi
            fi
            ;;

        NOT_LOADED|CRASHED:*|STOPPED)
            health_status="down:$bot_status"
            increment_crash
            crash_count=$(get_crash_count)

            if (( crash_count >= MAX_RETRIES )); then
                local fatal_last now_ts last_ts
                fatal_last="$STATE_DIR/fatal-alert-last"
                now_ts=$(date +%s)
                last_ts=0
                if [[ -f "$fatal_last" ]]; then last_ts=$(cat "$fatal_last"); fi
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
                local backoff
                backoff=$(get_backoff "$crash_count")
                log "Attempting restart #${crash_count} (backoff=${backoff}s)"
                date +%s > "$STATE_DIR/last-restart"

                if $IS_MACOS; then
                    if [[ "$bot_status" == "NOT_LOADED" && -f "$DISCORD_PLIST" ]]; then
                        launchctl bootstrap "gui/$(id -u)" "$DISCORD_PLIST" 2>/dev/null \
                            || launchctl load "$DISCORD_PLIST" 2>/dev/null || true
                    else
                        launchctl kickstart -k "gui/$(id -u)/$DISCORD_SERVICE" 2>/dev/null || true
                    fi
                else
                    pm2 restart jarvis-bot 2>/dev/null || true
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

    # LanceDB 크기 감시 (1GB 초과 시 경고 — 방치 시 2GB+ 급증 선례)
    lancedb_path="$BOT_HOME/rag/lancedb"
    if [[ -d "$lancedb_path" ]]; then
        lancedb_mb=$(du -sm "$lancedb_path" 2>/dev/null | awk '{print $1}')
        if (( lancedb_mb > 1024 )); then
            log "WARN: LanceDB ${lancedb_mb}MB — compact 필요: rag-compact 실행 권장"
            send_alert "[Watchdog] LanceDB ${lancedb_mb}MB 초과 — compact 필요"
        fi
    fi

    log "Check complete: bot=$health_status mem=${memory_mb}MB stale_killed=$stale_killed crashes=$crash_count"
}

# --- Main loop (KeepAlive service: runs forever, checks every 180s) ---
while true; do
    if acquire_lock; then
        run_one_check || log "WARN: check iteration error"
        release_lock
    fi
    sleep 180
done
