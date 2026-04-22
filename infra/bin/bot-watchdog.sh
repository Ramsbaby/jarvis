#!/usr/bin/env bash
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}/lib/compat.sh" 2>/dev/null || true
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
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
BOT_LOG="$BOT_HOME/logs/discord-bot.jsonl"
WATCHDOG_LOG="$BOT_HOME/logs/bot-watchdog.log"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.jarvis.discord-bot}"
STATE_DIR="$BOT_HOME/watchdog"
COOLDOWN_FILE="$STATE_DIR/bot-watchdog-last-alert"

SILENCE_THRESHOLD_SEC=900   # 15 minutes
ALERT_COOLDOWN_SEC=900      # 15 minutes between alerts
HEAL_CYCLE_TIMEOUT_SEC=1800 # 30 minutes — heal-cycle이 이 시간 초과 시 Discord 알람
HEAL_START_FILE="$STATE_DIR/bot-heal-start-epoch"
HEAL_TIMEOUT_ALERTED_FILE="$STATE_DIR/bot-heal-timeout-alerted"
DISCORD_VISUAL="${HOME}/jarvis/runtime/scripts/discord-visual.mjs"

# --- Level 3/4 에스컬레이션 설정 (openclaw v4.4 선별 이식, 2026-04-22) ---
# Jarvis 고유 방침(iii): Mac Mini 재부팅 안 함. Level 4는 수동 개입 요청 알람만.
MAX_TOTAL_RETRIES=6                     # 이 값 도달 시 Level 3 Clean Restart 트리거
CRASH_DECAY_HOURS=6                     # 크래시 카운터 자동 리셋 시간
LEVEL4_ESCALATE_AFTER_SEC=1800          # Level 3 실패 후 Level 4 알람까지 (30분)
RECOVERY_MIN_DURATION_SEC=30            # 이 시간 미만 복구는 알림 생략 (깜빡임 무시)
BACKOFF_DELAYS=(10 30 90 180 300 600)   # 지수 백오프 (초) — 인덱스=crash_count-1

BOT_CRASH_COUNTER_FILE="$STATE_DIR/bot-crash-counter"
BOT_CRASH_TIMESTAMP_FILE="$STATE_DIR/bot-crash-timestamp"
BOT_RESTART_COOLDOWN_FILE="$STATE_DIR/bot-restart-cooldown"
BOT_RECOVERY_START_FILE="$STATE_DIR/bot-recovery-start"
BOT_CRITICAL_FAILURE_FILE="$STATE_DIR/bot-critical-failure-since"
BOT_LEVEL4_ALERTED_FILE="$STATE_DIR/bot-level4-alerted"

mkdir -p "$STATE_DIR" "$(dirname "$WATCHDOG_LOG")"

# --- Shared libraries ---
source "${BOT_HOME}/lib/ntfy-notify.sh"

# --- Utility ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHDOG_LOG"; }

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

# --- Heal-cycle reset 함수 (Main 진입 전 정의 필수: Bash 호이스팅 없음) ---
# 봇이 살아있을 때 heal-cycle 추적 파일을 리셋해, 다음 사건의 30분 알람이 발송되도록 보장.
# 라인 105 (silence < threshold) 정상 복구 경로에서 반드시 호출되어야 함 — 누락 시 알람 영구 침묵 버그.
_check_heal_reset() {
    local recent_ts
    recent_ts=$(tail -5 "$BOT_LOG" 2>/dev/null | grep -oE '"ts":"[-0-9T:.Z]+"' | tail -1 | sed 's/"ts":"//;s/"//' || true)
    if [[ -n "$recent_ts" ]]; then
        local recent_clean="${recent_ts%%.*}Z"
        local recent_epoch
        recent_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$recent_clean" "+%s" 2>/dev/null \
          || TZ=UTC date -d "$recent_clean" "+%s" 2>/dev/null || echo 0)
        local age=$(( $(date +%s) - recent_epoch ))
        if (( age < 120 )); then
            if [[ -f "$HEAL_START_FILE" || -f "$HEAL_TIMEOUT_ALERTED_FILE" ]]; then
                rm -f "$HEAL_START_FILE" "$HEAL_TIMEOUT_ALERTED_FILE"
                log "HEAL: 봇 복구 확인 — heal-cycle 추적 파일 리셋 (다음 사건 알람 부활)"
            fi
        fi
    fi
}

# --- Level 3/4 에스컬레이션 함수 (openclaw v4.4 선별 이식, 2026-04-22) ---

_get_crash_count() {
    [[ -f "$BOT_CRASH_COUNTER_FILE" ]] && cat "$BOT_CRASH_COUNTER_FILE" || echo "0"
}

_check_crash_decay() {
    [[ ! -f "$BOT_CRASH_TIMESTAMP_FILE" ]] && return 0
    local last elapsed decay_seconds
    last=$(cat "$BOT_CRASH_TIMESTAMP_FILE" 2>/dev/null || echo "0")
    elapsed=$(( $(date +%s) - last ))
    decay_seconds=$(( CRASH_DECAY_HOURS * 3600 ))
    if (( elapsed >= decay_seconds )); then
        echo "0" > "$BOT_CRASH_COUNTER_FILE"
        rm -f "$BOT_CRASH_TIMESTAMP_FILE" "$BOT_CRITICAL_FAILURE_FILE" "$BOT_LEVEL4_ALERTED_FILE"
        log "CRASH_DECAY: 카운터 자동 리셋 (${CRASH_DECAY_HOURS}시간 경과)"
    fi
}

_increment_crash_count() {
    local c
    c=$(_get_crash_count)
    echo $((c + 1)) > "$BOT_CRASH_COUNTER_FILE"
    date +%s > "$BOT_CRASH_TIMESTAMP_FILE"
}

_decrement_crash_count() {
    local c
    c=$(_get_crash_count)
    if (( c > 0 )); then
        echo $((c - 1)) > "$BOT_CRASH_COUNTER_FILE"
        log "CRASH_DECAY: 정상 체크 — 카운터 $c → $((c - 1))"
    fi
}

_get_backoff_delay() {
    local c idx
    c=$(_get_crash_count)
    idx=$(( c - 1 ))
    (( idx < 0 )) && idx=0
    (( idx >= ${#BACKOFF_DELAYS[@]} )) && idx=$(( ${#BACKOFF_DELAYS[@]} - 1 ))
    echo "${BACKOFF_DELAYS[$idx]}"
}

_is_in_restart_cooldown() {
    [[ ! -f "$BOT_RESTART_COOLDOWN_FILE" ]] && return 1
    local last elapsed required
    last=$(cat "$BOT_RESTART_COOLDOWN_FILE" 2>/dev/null || echo "0")
    elapsed=$(( $(date +%s) - last ))
    required=$(_get_backoff_delay)
    if (( elapsed < required )); then
        log "BACKOFF: 쿨다운 중 (elapsed=${elapsed}s < required=${required}s)"
        return 0
    fi
    return 1
}

_set_restart_cooldown() {
    date +%s > "$BOT_RESTART_COOLDOWN_FILE"
}

_send_recovery_alert() {
    # 이전에 재시작 사이클이 있었을 때만 복구 완료 알림
    [[ ! -f "$BOT_RECOVERY_START_FILE" ]] && return 0
    local start elapsed minutes seconds
    start=$(cat "$BOT_RECOVERY_START_FILE" 2>/dev/null || echo "0")
    elapsed=$(( $(date +%s) - start ))
    rm -f "$BOT_RECOVERY_START_FILE"

    # 깜빡임(30초 미만)은 알림 안 함 — 노이즈 방지
    (( elapsed < RECOVERY_MIN_DURATION_SEC )) && return 0

    minutes=$(( elapsed / 60 ))
    seconds=$(( elapsed % 60 ))
    log "RECOVERY: 복구 완료 (소요 ${minutes}분 ${seconds}초)"

    send_discord_webhook "✅ Discord 봇 자동 복구 완료 (${minutes}분 ${seconds}초 소요)"
    if [[ -f "$DISCORD_VISUAL" ]]; then
        node "$DISCORD_VISUAL" --type stats \
          --data "{\"title\":\"✅ 봇 자동 복구 완료\",\"data\":{\"소요\":\"${minutes}분 ${seconds}초\",\"복구시각\":\"$(TZ=Asia/Seoul date '+%F %H:%M KST')\"},\"timestamp\":\"$(TZ=Asia/Seoul date '+%F %H:%M KST')\"}" \
          --channel jarvis-system 2>/dev/null || true
    fi
}

# Level 3 — Clean Restart (launchctl bootout → bootstrap 완전 리셋 + bot-heal.sh PTY 진단 세션)
_trigger_level3_clean_restart() {
    local reason="$1"
    local crash_count
    crash_count=$(_get_crash_count)
    log "LEVEL3: Clean Restart 트리거 — reason=$reason, crash=$crash_count"

    # heal-in-progress 중복 방지 (bot-heal.sh 이미 기동 중이면 스킵)
    if [[ -f "${BOT_HOME}/state/heal-in-progress" ]]; then
        log "LEVEL3: heal-in-progress 존재 — Clean Restart 스킵 (이미 진행 중)"
        return 0
    fi

    # bootout → bootstrap 완전 리셋
    if $IS_MACOS; then
        local uid plist
        uid=$(id -u)
        plist="$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist"
        launchctl bootout "gui/${uid}/${DISCORD_SERVICE}" 2>/dev/null || true
        sleep 3
        if [[ -f "$plist" ]]; then
            launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null || true
            log "LEVEL3: launchctl bootout → bootstrap 완료 ($plist)"
        else
            log "LEVEL3: plist 누락 — bootstrap 스킵 ($plist)"
        fi
    else
        pm2 delete jarvis-bot 2>/dev/null || true
        sleep 2
        pm2 start jarvis-bot 2>/dev/null || log "LEVEL3: pm2 재시작 실패"
    fi

    # bot-heal.sh Claude PTY 진단 세션 기동 (setsid 분리 프로세스)
    local bot_heal="${BOT_HOME}/bin/bot-heal.sh"
    if [[ -x "$bot_heal" ]]; then
        log "LEVEL3: bot-heal.sh Claude PTY 진단 기동 (setsid 분리)"
        setsid "$bot_heal" >> "$WATCHDOG_LOG" 2>&1 &
    else
        log "LEVEL3: bot-heal.sh 없음 또는 실행 불가 ($bot_heal) — PTY 진단 스킵"
    fi

    # Discord 중간 알람 (Level 3 진입)
    send_discord_webhook "🚨 [Bot Watchdog Level 3] 연속 실패 ${crash_count}회 — Clean Restart (bootout→bootstrap) + PTY 진단 기동. 이유: $reason"
    send_ntfy "Bot Level 3 Clean Restart" "연속 실패 ${crash_count}회 — 완전 재시작 + PTY 진단" "high"

    if [[ -f "$DISCORD_VISUAL" ]]; then
        node "$DISCORD_VISUAL" --type stats \
          --data "{\"title\":\"🚨 Level 3 — Clean Restart\",\"data\":{\"크래시\":\"${crash_count}회\",\"조치\":\"bootout→bootstrap + PTY 진단\",\"이유\":\"${reason}\"},\"timestamp\":\"$(TZ=Asia/Seoul date '+%F %H:%M KST')\"}" \
          --channel jarvis-system 2>/dev/null || true
    fi

    # Critical failure 타임스탬프 기록 (Level 4 트리거용)
    [[ ! -f "$BOT_CRITICAL_FAILURE_FILE" ]] && date +%s > "$BOT_CRITICAL_FAILURE_FILE"
}

# Level 4 — 수동 개입 요청 Discord 긴급 알람 (Jarvis 고유 방침: 재부팅 안 함)
_check_and_trigger_level4() {
    [[ ! -f "$BOT_CRITICAL_FAILURE_FILE" ]] && return 0
    local since elapsed minutes crash_count since_kst
    since=$(cat "$BOT_CRITICAL_FAILURE_FILE" 2>/dev/null || echo "0")
    elapsed=$(( $(date +%s) - since ))

    if (( elapsed < LEVEL4_ESCALATE_AFTER_SEC )); then
        log "LEVEL4: Level 3 이후 ${elapsed}s 경과 — 한계 ${LEVEL4_ESCALATE_AFTER_SEC}s 미도달"
        return 0
    fi

    # 이미 알람 발송됨 — 중복 방지
    if [[ -f "$BOT_LEVEL4_ALERTED_FILE" ]]; then
        log "LEVEL4: 알람 이미 발송됨 — 중복 방지 (주인님 수동 개입 대기 중)"
        return 0
    fi

    minutes=$(( elapsed / 60 ))
    crash_count=$(_get_crash_count)
    since_kst=$(TZ=Asia/Seoul date -r "$since" '+%F %H:%M KST' 2>/dev/null \
        || TZ=Asia/Seoul date -d "@$since" '+%F %H:%M KST' 2>/dev/null \
        || echo "알 수 없음")

    log "LEVEL4: 🚨🚨🚨 수동 개입 필수 알람 발송 (Level 3 실패 후 ${minutes}분 경과, 크래시 ${crash_count})"

    send_ntfy "🚨 Jarvis 봇 Level 4 — 수동 개입 필수" \
        "Clean Restart 후에도 ${minutes}분째 복구 실패.\nLevel 3 시작: ${since_kst}\n크래시 카운트: ${crash_count}\n\n주인님께서 직접 점검하셔야 합니다. Mac Mini 재부팅은 자동 실행되지 않습니다." "max"

    send_discord_webhook "🚨🚨🚨 **[Bot Watchdog Level 4] 수동 개입 필수** — Clean Restart 후 ${minutes}분째 복구 실패. 크래시 카운트 ${crash_count}. 주인님 직접 점검 필요. Mac Mini 재부팅은 자동 실행되지 않습니다 (Iron Law 안전 정책)."

    if [[ -f "$DISCORD_VISUAL" ]]; then
        node "$DISCORD_VISUAL" --type stats \
          --data "{\"title\":\"🚨🚨🚨 Level 4 — 수동 개입 필수\",\"data\":{\"경과\":\"${minutes}분\",\"Level3 시작\":\"${since_kst}\",\"크래시\":\"${crash_count}회\",\"방침\":\"재부팅 안 함\",\"조치\":\"주인님 직접 점검\"},\"timestamp\":\"$(TZ=Asia/Seoul date '+%F %H:%M KST')\"}" \
          --channel jarvis-system 2>/dev/null || true
    fi

    date +%s > "$BOT_LEVEL4_ALERTED_FILE"
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
    # Bot is active — heal-cycle 추적 파일 리셋 (다음 사건 알람 부활 보장)
    # 2026-04-22 verify: 정상 복구 경로에서 reset 누락 시 HEAL_TIMEOUT_ALERTED_FILE 영구 잔존 → 다음 알람 침묵
    _check_heal_reset
    # Level 3/4 복구 후처리 (openclaw v4.4 이식, 2026-04-22)
    _check_crash_decay          # 6시간 경과 시 카운터 자동 리셋
    _send_recovery_alert        # 이전에 재시작 사이클이 있었다면 복구 완료 알림 (30초+ 복구만)
    _decrement_crash_count      # 정상 체크마다 카운터 1 감쇠 — 단발 실패가 영구 누적 안 됨
    exit 0
fi

# --- Silent death detected ---

# Check if watchdog.sh is already handling recovery (shared healing lock)
HEALING_LOCK="/tmp/bot-healing.lock"
if [[ -d "$HEALING_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -c '%Y' "$HEALING_LOCK" 2>/dev/null || stat -f %m "$HEALING_LOCK" 2>/dev/null || echo "$(date +%s)") ))
    if (( lock_age < 600 )); then
        log "SKIP: watchdog.sh healing in progress (lock age=${lock_age}s)"
        exit 0
    fi
fi

# Check if bot-heal.sh (preflight Claude PTY 세션) 진행 중인지 확인 — 2026-04-22 버그픽스
# bot-heal.sh는 $BOT_HOME/state/heal-in-progress 를 생성하는데,
# 이 락을 확인하지 않으면 watchdog이 kickstart -k로 heal 세션을 강제 종료하는 버그 발생.
# (오늘 6시간 다운 원인: heal 세션이 5분마다 watchdog에게 kill 당하는 무한 루프)
PREFLIGHT_HEAL_LOCK="${BOT_HOME}/state/heal-in-progress"
PREFLIGHT_HEAL_STALE_SEC=1800   # 30분 — Claude PTY 진단 시간 여유 확보 (verify 권고)
if [[ -f "$PREFLIGHT_HEAL_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$PREFLIGHT_HEAL_LOCK" 2>/dev/null || stat -c '%Y' "$PREFLIGHT_HEAL_LOCK" 2>/dev/null || echo 0) ))
    if (( lock_age < PREFLIGHT_HEAL_STALE_SEC )); then
        log "SKIP: bot-heal.sh Claude 진단 세션 진행 중 (age=${lock_age}s, 한계 ${PREFLIGHT_HEAL_STALE_SEC}s) — kickstart 보류"
        exit 0
    else
        log "WARN: heal-in-progress 락이 ${lock_age}s 경과 — stale 락 제거 후 계속"
        rm -f "$PREFLIGHT_HEAL_LOCK"
    fi
fi

# --- Heal-cycle 30분 초과 감지 (2026-04-22 재발방지) ---
# 재시작 시도 중이라면 heal 시작 시각을 기록하고, 30분 초과 시 Discord 알람
# heal-start 파일이 없으면 지금을 시작 시각으로 기록
if [[ ! -f "$HEAL_START_FILE" ]]; then
    date +%s > "$HEAL_START_FILE"
    log "HEAL: 재시작 사이클 시작 시각 기록 ($(TZ=Asia/Seoul date '+%F %H:%M KST'))"
else
    heal_start_epoch=$(cat "$HEAL_START_FILE" 2>/dev/null || echo "0")
    heal_elapsed=$(( $(date +%s) - heal_start_epoch ))
    log "HEAL: 재시작 사이클 경과 ${heal_elapsed}s (한계 ${HEAL_CYCLE_TIMEOUT_SEC}s)"

    if (( heal_elapsed >= HEAL_CYCLE_TIMEOUT_SEC )); then
        # 30분 초과 — 아직 알람 미발송 상태일 때만 전송
        if [[ ! -f "$HEAL_TIMEOUT_ALERTED_FILE" ]]; then
            log "ALERT: Heal-cycle ${heal_elapsed}s 초과 (>${HEAL_CYCLE_TIMEOUT_SEC}s). Discord 알람 전송."
            _heal_elapsed_min=$(( heal_elapsed / 60 ))
            _heal_start_kst=$(TZ=Asia/Seoul date -r "$heal_start_epoch" '+%F %H:%M KST' 2>/dev/null \
                || TZ=Asia/Seoul date -d "@${heal_start_epoch}" '+%F %H:%M KST' 2>/dev/null \
                || echo "알 수 없음")

            send_ntfy "Jarvis 봇 장시간 복구 실패" \
                "봇이 ${_heal_elapsed_min}분째 재시작 사이클을 반복 중입니다.\n시작: ${_heal_start_kst}\n\n수동 확인이 필요합니다." "urgent"

            if [[ -f "$DISCORD_VISUAL" ]]; then
                node "$DISCORD_VISUAL" --type stats \
                  --data "{\"title\":\"🚨 봇 Heal-cycle ${_heal_elapsed_min}분 초과\",\"data\":{\"경과\":\"${_heal_elapsed_min}분\",\"시작\":\"${_heal_start_kst}\",\"조치\":\"수동 개입 필요\"},\"timestamp\":\"$(TZ=Asia/Seoul date '+%F %H:%M KST')\"}" \
                  --channel jarvis-system 2>/dev/null \
                  && log "Discord #jarvis-system 알람 전송 완료" \
                  || log "Discord 알람 전송 실패 (무시)"
            fi

            date +%s > "$HEAL_TIMEOUT_ALERTED_FILE"
        else
            log "HEAL: 30분 초과이나 Discord 알람은 이미 발송됨 (중복 방지)"
        fi
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
    # 프로세스가 없는 상태 — Level 3/4 에스컬레이션 체크 (2026-04-22 openclaw v4.4 이식)
    _check_crash_decay

    crash_count=$(_get_crash_count)

    # Level 3 Clean Restart 트리거 조건 (크래시 N회 이상)
    if (( crash_count >= MAX_TOTAL_RETRIES )); then
        log "ESCALATION: 크래시 카운트 ${crash_count}/${MAX_TOTAL_RETRIES} 도달 — Level 3/4 검토"
        _check_and_trigger_level4  # Level 3 이후 30분 경과 시 Level 4 알람 발동

        if _is_in_restart_cooldown; then
            log "LEVEL3: Backoff 쿨다운 중 — 다음 주기 재시도"
            exit 0
        fi

        _trigger_level3_clean_restart "프로세스 없음 (crash=${crash_count})"
        _set_restart_cooldown
        [[ ! -f "$BOT_RECOVERY_START_FILE" ]] && date +%s > "$BOT_RECOVERY_START_FILE"
        exit 0
    fi

    # Level 3 미도달 — 일반 재시작 (Backoff 적용)
    if _is_in_restart_cooldown; then
        log "Bot process not running, Backoff 쿨다운 중 — 재시작 보류"
        exit 0
    fi

    _increment_crash_count
    crash_count=$(_get_crash_count)
    backoff=$(_get_backoff_delay)
    log "Bot process not running. crash=${crash_count}/${MAX_TOTAL_RETRIES}, backoff=${backoff}s. Attempting direct restart."

    # 첫 사건이면 복구 시작 시각 기록 (복구 성공 시 소요 시간 알림용)
    [[ ! -f "$BOT_RECOVERY_START_FILE" ]] && date +%s > "$BOT_RECOVERY_START_FILE"

    if $IS_MACOS; then
        uid=$(id -u)
        launchctl kickstart "gui/${uid}/${DISCORD_SERVICE}" 2>/dev/null || {
            log "kickstart failed, trying bootstrap"
            launchctl bootstrap "gui/${uid}" "$HOME/Library/LaunchAgents/${DISCORD_SERVICE}.plist" 2>/dev/null || true
        }
    else
        pm2 restart jarvis-bot 2>/dev/null || { log "pm2 restart failed"; }
    fi
    log "Restart issued for stopped $DISCORD_SERVICE (crash=${crash_count})"
    _set_restart_cooldown

    if ! is_in_alert_cooldown; then
        send_discord_webhook "[Bot Watchdog] Bot was not running (silent ${silence_sec}s, crash ${crash_count}/${MAX_TOTAL_RETRIES}, backoff ${backoff}s). Restart issued."
        send_ntfy "Bot Down - Restarted" "Bot not running (silence ${silence_sec}s, crash ${crash_count})" "high"
        date +%s > "$COOLDOWN_FILE"
    fi
    exit 0
fi

# 봇 복구 성공 확인 — 함수는 라인 ~67에 이미 정의됨 (호이스팅 없는 Bash 특성상 Main 진입 전 정의 필수)
_check_heal_reset

# Level 3/4 에스컬레이션 체크 (2026-04-22 openclaw v4.4 이식) — Silent death 경로도 동일 정책 적용
_check_crash_decay

crash_count=$(_get_crash_count)

# Level 3 Clean Restart 트리거 조건 (크래시 N회 이상)
if (( crash_count >= MAX_TOTAL_RETRIES )); then
    log "ESCALATION: 크래시 카운트 ${crash_count}/${MAX_TOTAL_RETRIES} 도달 (Silent death) — Level 3/4 검토"
    _check_and_trigger_level4  # Level 3 이후 30분 경과 시 Level 4 알람 발동

    if _is_in_restart_cooldown; then
        log "LEVEL3: Backoff 쿨다운 중 — 다음 주기 재시도"
        exit 0
    fi

    _trigger_level3_clean_restart "Silent death (PID ${bot_pid}, silence ${silence_sec}s, crash=${crash_count})"
    _set_restart_cooldown
    [[ ! -f "$BOT_RECOVERY_START_FILE" ]] && date +%s > "$BOT_RECOVERY_START_FILE"
    exit 0
fi

# Level 3 미도달 — 일반 kill+restart (Backoff 적용)
if _is_in_restart_cooldown; then
    log "Silent death detected (PID ${bot_pid}, silence ${silence_sec}s), Backoff 쿨다운 중 — 재시작 보류"
    exit 0
fi

_increment_crash_count
crash_count=$(_get_crash_count)
backoff=$(_get_backoff_delay)
log "Silent death: crash=${crash_count}/${MAX_TOTAL_RETRIES}, backoff=${backoff}s. Performing kill+restart."

# 첫 사건이면 복구 시작 시각 기록 (복구 성공 시 소요 시간 알림용)
[[ ! -f "$BOT_RECOVERY_START_FILE" ]] && date +%s > "$BOT_RECOVERY_START_FILE"

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

log "Restart issued for $DISCORD_SERVICE (crash=${crash_count})"
_set_restart_cooldown

# Send alerts (with cooldown)
if ! is_in_alert_cooldown; then
    alert_msg="[Bot Watchdog] Silent death detected. Bot was alive (PID $bot_pid) but no log output for ${silence_sec}s (crash ${crash_count}/${MAX_TOTAL_RETRIES}, backoff ${backoff}s). Restarted."

    send_ntfy "Bot Silent Death" "$alert_msg" "high"
    send_discord_webhook "$alert_msg"

    date +%s > "$COOLDOWN_FILE"
    log "Alerts sent (ntfy + Discord webhook)"
else
    log "Alert suppressed (cooldown active)"
fi