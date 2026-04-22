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

# 봇 복구 성공 확인 — 함수는 라인 ~67에 이미 정의됨 (호이스팅 없는 Bash 특성상 Main 진입 전 정의 필수)
_check_heal_reset

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