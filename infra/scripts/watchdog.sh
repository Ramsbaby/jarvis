#!/usr/bin/env bash
set -euo pipefail

# watchdog.sh - Discord bot process monitor & self-healer
# KeepAlive launchd service with internal 180s loop. Monitors discord-bot, cleans stale claude -p.

# --- Configuration ---
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}/lib/compat.sh" 2>/dev/null || true
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true
STATE_DIR="$BOT_HOME/watchdog"
LOG_FILE="$BOT_HOME/logs/watchdog.log"
HEALING_LOCK="/tmp/bot-healing.lock"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.jarvis.discord-bot}"
DISCORD_PLIST="$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist"
ROUTE_RESULT="$BOT_HOME/bin/route-result.sh"

MEMORY_WARN_MB=900    # LanceDB 인덱스 로드 포함 실측치 고려
MEMORY_SOFT_MB=1100   # 조용한 선제 재시작 (Discord 알림 없음)
MEMORY_CRITICAL_MB=1400  # 재시작 임계값: session-sync 스파이크(+450MB) 여유 확보

# v4.45 (2026-04-27 OOM 사고 — Mac Mini 시스템 압박 통합 모니터):
# 봇 자체 메모리는 정상이어도 Mac Mini swap 압박 시 봇 GC 지연 → 일시적 RSS 폭증 → OOM.
# swap > 70% 또는 unused < 1GB 감지 시 좀비 정리 트리거 + Discord 알림.
SYSTEM_SWAP_THRESHOLD_PCT=70       # swap 사용률 % (5GB 중 3.5GB+ = 사고 위험)
SYSTEM_UNUSED_MIN_MB=1024          # PhysMem unused < 1GB = 압박 신호
SYSTEM_ALERT_COOLDOWN_SEC=1800     # 시스템 알림 30분 쿨다운
CLAUDE_STALE_MINUTES=10
HEARTBEAT_FILE="$BOT_HOME/state/bot-heartbeat"
HEARTBEAT_STALE_SEC=900  # 15분: 하트비트 없으면 좀비
BACKOFF_DELAYS=(10 30 90 180 300)
MAX_RETRIES=5
CRASH_DECAY_HOURS=6
FATAL_ALERT_COOLDOWN_SEC=3600  # FATAL 알림 최소 1시간 간격
CRASH_LOOP_WINDOW_SEC=1800     # 30분 내 재시작이 3회 이상이면 크래시 루프
CRASH_LOOP_THRESHOLD=3
HANDLER_ERROR_ALERT_COOLDOWN=1800  # 핸들러 에러율 알림 30분 쿨다운

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# --- Utility functions ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

send_alert() {
    local message="$1"
    local severity="${2:-warning}"  # warning | critical
    log "ALERT: $message"
    if [[ -x "$ROUTE_RESULT" ]]; then
        "$ROUTE_RESULT" discord "watchdog" "$message" "jarvis-system" 2>/dev/null || true
        # CRITICAL은 오너 채널(jarvis-ceo)에도 전송 — jarvis-system만으로는 놓침
        if [[ "$severity" == "critical" ]]; then
            "$ROUTE_RESULT" discord "watchdog" "🚨 $message" "jarvis-ceo" 2>/dev/null || true
        fi
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
        # ▶ FIX: "모니터링 모드" 재시작은 정상이므로 크래시 루프로 판단하지 않음
        local preflight_log="$BOT_HOME/logs/preflight.log"
        if [[ -f "$preflight_log" ]]; then
            # 최근 로그에 "모니터링 모드" 로그가 있는지 확인
            if tail -100 "$preflight_log" 2>/dev/null | grep -q "봇 시작 (모니터링 모드)"; then
                log "정상 재시작 감지: preflight 모니터링 모드 — 크래시 루프 판정 제외"
                # restart-times 초기화하여 다음 주기에 다시 카운트 시작
                true > "$restart_log"
                return
            fi
        fi

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
            # stdout + stderr 양쪽 확인 (SyntaxError 등은 stderr에만 기록됨)
            last_error=$(cat "$BOT_HOME/logs/discord-bot.out.log" "$BOT_HOME/logs/discord-bot.err.log" 2>/dev/null \
                | tail -50 \
                | grep -iE "Error:|TypeError|SyntaxError|Cannot find|ENOENT|FATAL" \
                | tail -1 || echo "로그 없음")
            # 에러 유무 무관 알림 + bot-heal.sh 트리거
            send_alert "[Bot Watchdog] CRASH LOOP: ${restart_count}회 재시작 (30분 내). 에러: ${last_error}" "critical"
            # 자가치유 시도 (heal-in-progress 락이 없을 때만)
            if [[ ! -f "$BOT_HOME/state/heal-in-progress" ]]; then
                log "CRASH LOOP: bot-heal.sh 트리거"
                nohup bash "$BOT_HOME/scripts/bot-heal.sh" "CRASH LOOP ${restart_count}회: ${last_error}" \
                    >> "$BOT_HOME/logs/bot-heal.log" 2>&1 &
            fi
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
        lock_age=$(( $(date +%s) - $(stat -c '%Y' "$HEALING_LOCK" 2>/dev/null || stat -f %m "$HEALING_LOCK" 2>/dev/null || echo "$(date +%s)") ))
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

# --- System memory pressure check (2026-04-27 OOM 사고 — Mac Mini swap 압박 통합) ---
# vm_stat + sysctl 조합으로 실측. swap > 70% 또는 unused < 1GB 시 좀비 정리 트리거 + 알림.
check_system_pressure() {
    # PhysMem unused (top 출력 파싱)
    local unused_mb
    unused_mb=$(top -l 1 -n 0 2>/dev/null | grep "^PhysMem:" | awk -F'[, ]+' '{for(i=1;i<=NF;i++) if($i ~ /unused/) print $(i-1)}' | tr -d 'M')
    [[ -z "$unused_mb" ]] && unused_mb=99999  # 측정 실패 시 안전쪽

    # Swap 사용률 (sysctl 출력 파싱)
    local swap_used swap_total swap_pct
    swap_used=$(sysctl -n vm.swapusage 2>/dev/null | grep -oE 'used = [0-9.]+M' | grep -oE '[0-9.]+' | cut -d. -f1)
    swap_total=$(sysctl -n vm.swapusage 2>/dev/null | grep -oE 'total = [0-9.]+M' | grep -oE '[0-9.]+' | cut -d. -f1)
    [[ -z "$swap_used" || -z "$swap_total" || "$swap_total" == "0" ]] && return 0
    swap_pct=$(( swap_used * 100 / swap_total ))

    local pressure=0
    local reasons=()

    if (( swap_pct >= SYSTEM_SWAP_THRESHOLD_PCT )); then
        pressure=1
        reasons+=("swap ${swap_pct}% (${swap_used}MB/${swap_total}MB)")
    fi

    if (( unused_mb < SYSTEM_UNUSED_MIN_MB )); then
        pressure=1
        reasons+=("unused ${unused_mb}MB (< ${SYSTEM_UNUSED_MIN_MB}MB)")
    fi

    if (( pressure == 1 )); then
        # 쿨다운 체크
        local last_alert_file="$BOT_HOME/state/system-pressure-last-alert"
        local now_ts last_ts
        now_ts=$(date +%s)
        last_ts=0
        [[ -f "$last_alert_file" ]] && last_ts=$(cat "$last_alert_file" 2>/dev/null || echo 0)

        if (( now_ts - last_ts >= SYSTEM_ALERT_COOLDOWN_SEC )); then
            local reason_str
            reason_str=$(IFS=' / '; echo "${reasons[*]}")
            log "SYSTEM PRESSURE DETECTED: $reason_str — triggering claude-zombie-cleanup"

            # 좀비 정리 자동 트리거
            bash "$HOME/jarvis/runtime/scripts/claude-zombie-cleanup.sh" 2>&1 | tail -5 >> "$LOG_FILE"

            # Discord 알림
            send_alert "[Watchdog] 🚨 Mac Mini 시스템 압박 — $reason_str. 좀비 자동 정리 트리거됨."

            echo "$now_ts" > "$last_alert_file"
        else
            log "SYSTEM PRESSURE (cooldown): swap=${swap_pct}% unused=${unused_mb}MB"
        fi
    fi

    # JSON status용 변수 echo
    echo "$swap_pct $unused_mb"
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
        slot_age=$(( $(date +%s) - $(stat -c '%Y' "$slot_dir" 2>/dev/null || stat -f %m "$slot_dir" 2>/dev/null || echo "$(date +%s)") ))
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

# --- Handler error rate check ---
# 최근 5분 JSONL에서 handleMessage error 비율이 50%+ && 3회+ 이면 1 반환
# stdout: "errors total" 형태로 출력
check_handler_error_rate() {
    local jsonl="$BOT_HOME/logs/discord-bot.jsonl"
    [[ -f "$jsonl" ]] || return 0
    local result
    result=$(tail -500 "$jsonl" | python3 <<'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(minutes=5)
errors = total = 0
for line in sys.stdin:
    try:
        d = json.loads(line)
        ts = d.get('ts', '')
        if not ts: continue
        t = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        if t < cutoff: continue
        msg = d.get('msg', '')
        if msg == 'handleMessage error': errors += 1
        elif msg in ('Starting Claude session', 'Session summary pre-injected for resume safety'): total += 1
    except: pass
print(f"{errors} {total}")
PYEOF
)
    local errors total
    errors=$(echo "$result" | awk '{print $1}')
    total=$(echo "$result" | awk '{print $2}')
    if ! [[ "$errors" =~ ^[0-9]+$ ]]; then errors=0; fi
    if ! [[ "$total" =~ ^[0-9]+$ ]]; then total=0; fi
    if (( errors >= 3 )) && (( total > 0 )) && (( errors * 100 / total >= 50 )); then
        echo "$errors $total"
        return 1
    fi
    return 0
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
            # Degraded Mode 자동 복구 — 봇 정상 실행 중이면 해제
            local _deg_script="$BOT_HOME/scripts/bot-degraded-mode.sh"
            if [[ -x "$_deg_script" ]] && ! bash "$_deg_script" status >/dev/null 2>&1; then
                log "봇 정상 확인 — Degraded Mode 자동 복구 시도"
                bash "$_deg_script" recover >> "$LOG_FILE" 2>&1 || true
            fi
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

                # 핸들러 에러율 체크 — 프로세스는 살아있지만 기능적으로 망가진 경우 감지
                local _err_info
                if ! _err_info=$(check_handler_error_rate); then
                    local _err_c _total_c _alert_last _now_ts _last_ts
                    _err_c=$(echo "$_err_info" | awk '{print $1}')
                    _total_c=$(echo "$_err_info" | awk '{print $2}')
                    _alert_last="$STATE_DIR/handler-error-alert-last"
                    _now_ts=$(date +%s)
                    _last_ts=0
                    if [[ -f "$_alert_last" ]]; then _last_ts=$(cat "$_alert_last"); fi

                    # 에러율 100% → 코드 버그 확정, 자동 heal + 재시작
                    if (( _total_c > 0 && _err_c == _total_c )); then
                        send_alert "[Bot Watchdog] FATAL: handleMessage 에러율 100% (${_err_c}/${_total_c}). 코드 버그 — 자동 heal 후 재시작" "critical"
                        echo "$_now_ts" > "$_alert_last"
                        # bot-heal.sh로 자동 수정 시도
                        local _last_err
                        _last_err=$(tail -20 "$BOT_HOME/logs/discord-bot.jsonl" 2>/dev/null \
                            | python3 -c "import json,sys
for l in sys.stdin:
 try:
  d=json.loads(l)
  if d.get('msg')=='handleMessage error': print(d.get('error','unknown')); break
 except: pass" 2>/dev/null || echo "unknown")
                        if [[ ! -f "$BOT_HOME/state/heal-in-progress" ]]; then
                            log "HANDLER 100% ERROR: bot-heal.sh 트리거 — ${_last_err}"
                            nohup bash "$BOT_HOME/scripts/bot-heal.sh" "handleMessage 에러율 100%: ${_last_err}" \
                                >> "$BOT_HOME/logs/bot-heal.log" 2>&1 &
                        fi
                        _bot_restart
                        health_status="restarted:handler_errors_100pct"
                    elif (( _now_ts - _last_ts >= HANDLER_ERROR_ALERT_COOLDOWN )); then
                        send_alert "[Bot Watchdog] DEGRADED: handleMessage errors ${_err_c}/${_total_c} (최근 5분). 코드 버그 의심 — 수동 확인 필요"
                        echo "$_now_ts" > "$_alert_last"
                        health_status="degraded:handler_errors_${_err_c}_${_total_c}"
                    else
                        health_status="degraded:handler_errors_${_err_c}_${_total_c}"
                    fi
                fi

                if (( memory_mb >= MEMORY_CRITICAL_MB )); then
                    send_alert "[Bot Watchdog] CRITICAL: Discord bot memory=${memory_mb}MB (>=${MEMORY_CRITICAL_MB}MB). Restarting."
                    _bot_restart
                    health_status="restarted:memory"
                elif (( memory_mb >= MEMORY_SOFT_MB )); then
                    log "SOFT_RESTART: Discord bot memory=${memory_mb}MB (>=${MEMORY_SOFT_MB}MB). Quiet restart."
                    _bot_restart
                    health_status="restarted:memory_soft"
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

            # 자가 복구 방해 요인 진단: preflight/symlink 건전성 검증
            local _diag_issues=""
            [[ ! -f "$BOT_HOME/scripts/bot-preflight.sh" ]] && _diag_issues="${_diag_issues}\n- bot-preflight.sh 없음"
            [[ ! -f "$BOT_HOME/discord/discord-bot.js" ]] && _diag_issues="${_diag_issues}\n- discord-bot.js 없음"
            [[ ! -f "$BOT_HOME/discord/.env" ]] && _diag_issues="${_diag_issues}\n- discord/.env 없음"
            [[ ! -f "$BOT_HOME/bin/cron-safe-wrapper.sh" ]] && _diag_issues="${_diag_issues}\n- cron-safe-wrapper.sh 없음"
            if [[ -n "$_diag_issues" ]]; then
                log "CRITICAL: 자가 복구 방해 요인 감지:${_diag_issues}"
                send_alert "🚨 **봇 자가 복구 불가** — 필수 파일/symlink 누락:${_diag_issues}\n수동 복구 필요: symlink 재생성 또는 deploy 실행"
            fi

            # [ON-DEMAND HOOK] bot.crashed 이벤트 발행 → bot-crash-classifier 태스크 트리거 (debounce 300s)
            "$BOT_HOME/scripts/emit-event.sh" "bot.crashed" \
                "{\"status\":\"${bot_status}\",\"crash_count\":${crash_count}}" \
                >> "$LOG_FILE" 2>&1 || true

            if (( crash_count >= MAX_RETRIES )); then
                local fatal_last now_ts last_ts
                fatal_last="$STATE_DIR/fatal-alert-last"
                now_ts=$(date +%s)
                last_ts=0
                if [[ -f "$fatal_last" ]]; then last_ts=$(cat "$fatal_last"); fi
                if (( now_ts - last_ts >= FATAL_ALERT_COOLDOWN_SEC )); then
                    # 빠른 크래시(SyntaxError 등)는 RUNNING 상태를 거치지 않아
                    # detect_crash_loop에서 잡히지 않음 → 여기서 bot-heal.sh 트리거
                    if [[ ! -f "$BOT_HOME/state/heal-in-progress" ]]; then
                        local bot_err_last
                        bot_err_last=$(cat "$BOT_HOME/logs/discord-bot.out.log" "$BOT_HOME/logs/discord-bot.err.log" 2>/dev/null \
                            | tail -50 \
                            | grep -iE "Error:|TypeError|SyntaxError|Cannot find|ENOENT|FATAL" \
                            | tail -1 || echo "로그 없음")
                        log "FATAL: MAX_RETRIES 도달 → bot-heal.sh 트리거 (에러: ${bot_err_last})"
                        send_alert "[Bot Watchdog] FATAL: Discord bot crashed ${crash_count} times. 자동복구 시도 중..." "critical"
                        nohup bash "$BOT_HOME/scripts/bot-heal.sh" "MAX_RETRIES ${crash_count}회: ${bot_err_last}" \
                            >> "$BOT_HOME/logs/bot-heal.log" 2>&1 &
                    else
                        send_alert "[Bot Watchdog] FATAL: Discord bot crashed ${crash_count} times. (heal 진행 중)" "critical"
                    fi
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

                # L3 Degraded Mode 진입 체크 (연속 3회 재시작 실패)
                if (( crash_count >= 3 )); then
                    local degraded_script="$BOT_HOME/scripts/bot-degraded-mode.sh"
                    if [[ -x "$degraded_script" ]]; then
                        # 아직 Degraded Mode가 아닐 때만 진입
                        if ! bash "$degraded_script" status >/dev/null 2>&1; then
                            :  # 이미 Degraded Mode — 재진입 생략
                        else
                            log "연속 ${crash_count}회 재시작 실패 — L3 Degraded Mode 진입"
                            bash "$degraded_script" enter >> "$LOG_FILE" 2>&1 || true
                        fi
                    fi
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

    # LanceDB 크기 감시 (10GB 초과 시 경고 — 2026-05-23 임계 5GB→10GB 상향:
    # 1M+ chunks × dim 1024 정상 운용 7~9GB 도달 → 5GB는 false positive 알람 폭격)
    lancedb_path="$BOT_HOME/rag/lancedb"
    _lancedb_alert_cooldown="$BOT_HOME/state/lancedb-alert-last.txt"
    _lancedb_cooldown_sec=86400  # 24시간 — 하루 1회 알림으로 제한
    if [[ -d "$lancedb_path" ]]; then
        lancedb_mb=$(du -sm "$lancedb_path" 2>/dev/null | awk '{print $1}')
        if (( lancedb_mb > 10240 )); then
            _now_epoch=$(date +%s)
            _last_alert=$(cat "$_lancedb_alert_cooldown" 2>/dev/null || echo "0")
            _elapsed=$(( _now_epoch - _last_alert ))
            if (( _elapsed >= _lancedb_cooldown_sec )); then
                log "WARN: LanceDB ${lancedb_mb}MB — compact 필요: rag-compact 실행 권장"
                # 쿨다운 파일을 먼저 기록 (set -e 환경에서 alert 실패해도 재폭격 방지)
                echo "$_now_epoch" > "$_lancedb_alert_cooldown"
                # jarvis-system에 embed+버튼으로 전송, 실패 시 plain text fallback
                "$BOT_HOME/scripts/lancedb-alert.sh" "$lancedb_mb" 2>/dev/null || \
                    send_alert "[Watchdog] LanceDB ${lancedb_mb}MB 초과 — compact 필요" || true
            else
                log "INFO: LanceDB ${lancedb_mb}MB 초과이나 쿨다운 중 ($(( (_lancedb_cooldown_sec - _elapsed) / 60 ))분 남음) — 알람 생략"
            fi
        fi
    fi

    # v4.50: 디스크 사용률 감시 (85% 초과 시 Discord 경고 — 24시간 쿨다운)
    _disk_alert_cooldown="$BOT_HOME/state/disk-usage-alert-last.txt"
    _disk_cooldown_sec=86400  # 24시간 — 하루 1회 알림으로 제한
    disk_pct=$(df -h / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}' || echo 0)
    if (( disk_pct >= 85 )); then
        _now_epoch=$(date +%s)
        _last_alert=$(cat "$_disk_alert_cooldown" 2>/dev/null || echo "0")
        _elapsed=$(( _now_epoch - _last_alert ))
        if (( _elapsed >= _disk_cooldown_sec )); then
            log "WARN: 디스크 ${disk_pct}% 사용 중 — system-cleanup / rag-compact 확인 필요"
            echo "$_now_epoch" > "$_disk_alert_cooldown"
            send_alert "[Watchdog] 🚨 디스크 ${disk_pct}% 사용 — 즉시 정리 필요 (LanceDB / Claude 세션 기록)" "critical" || true
        else
            log "INFO: 디스크 ${disk_pct}% 이나 쿨다운 중 ($(( (_disk_cooldown_sec - _elapsed) / 60 ))분 남음) — 알람 생략"
        fi
    fi

    # v4.45: 시스템 압박 체크 (swap > 70% / unused < 1GB) — 좀비 정리 트리거 + Discord 알림
    check_system_pressure >/dev/null 2>&1 || true

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