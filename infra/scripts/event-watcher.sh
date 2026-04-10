#!/usr/bin/env bash
set -euo pipefail

# event-watcher.sh — 이벤트 트리거 파일 감지 → 태스크 즉시 실행
# 30초마다 ~/.jarvis/state/events/*.trigger 파일 스캔
# LaunchAgent (ai.jarvis.event-watcher.plist) 또는 백그라운드 데몬으로 실행
#
# 이벤트 발생 방법:
#   emit-event.sh <event_name>
#   예) emit-event.sh github.push → state/events/github.push.trigger 생성 → 이 데몬이 감지 후 github-monitor 실행

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
EVENTS_DIR="${BOT_HOME}/state/events"
LOG="${BOT_HOME}/logs/event-watcher.log"
TASKS_FILE=""

# tasks 파일 선택 (effective-tasks.json 우선)
if [[ -f "${BOT_HOME}/config/effective-tasks.json" ]]; then
    TASKS_FILE="${BOT_HOME}/config/effective-tasks.json"
else
    TASKS_FILE="${BOT_HOME}/config/tasks.json"
fi

SCAN_INTERVAL=30   # 스캔 주기 (초)

# --- 새벽 무음 시간대: KST 00:00~06:00 이벤트는 06:00까지 지연 ---
# trigger 파일을 삭제하지 않고 대기. 06:00 이후 정상 처리.
QUIET_START=0   # KST 00:00
QUIET_END=6     # KST 06:00

mkdir -p "$EVENTS_DIR" "$(dirname "$LOG")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [event-watcher] $*" >> "$LOG"
}

# --- 새벽 시간대 체크 ---
is_quiet_hours() {
    local hour
    hour=$(date +%-H)
    if (( hour >= QUIET_START && hour < QUIET_END )); then
        return 0  # 새벽 무음 시간대
    fi
    return 1
}

# --- debounce 체크 ---
# 반환: 0=통과(실행 가능), 1=debounce 중(스킵)
check_debounce() {
    local task_id="$1" debounce_s="$2"
    local last_run_file="${EVENTS_DIR}/${task_id}.last_run"

    if [[ ! -f "$last_run_file" ]]; then
        return 0  # last_run 없음 → 통과
    fi

    local last_ts now_ts elapsed
    last_ts=$(cat "$last_run_file" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    elapsed=$(( now_ts - last_ts ))

    if (( elapsed < debounce_s )); then
        local remaining=$(( debounce_s - elapsed ))
        log "DEBOUNCE skip: task=${task_id}, 남은 쿨다운=${remaining}s"
        return 1
    fi
    return 0
}

# --- 태스크 실행 ---
run_task() {
    local task_id="$1"
    local last_run_file="${EVENTS_DIR}/${task_id}.last_run"

    log "FIRING task=${task_id}"
    date +%s > "$last_run_file"

    # bot-cron.sh는 내부적으로 sentinel lock으로 중복 실행 방지함
    /bin/bash "${BOT_HOME}/bin/bot-cron.sh" "$task_id" >> "$LOG" 2>&1 &
    log "DISPATCHED task=${task_id} (pid=$!)"
}

# --- trigger 파일 처리 ---
process_trigger() {
    local trigger_file="$1"
    local filename
    filename=$(basename "$trigger_file")

    # .trigger 확장자 제거 → event_name
    local event_name="${filename%.trigger}"

    # event_name이 비어있거나 .last_run 파일이면 무시
    if [[ -z "$event_name" || "$event_name" == *.last_run ]]; then
        return
    fi

    log "DETECTED event=${event_name} (file=${trigger_file})"

    # tasks 파싱: event_trigger == event_name 인 태스크 목록
    local matching_tasks
    matching_tasks=$(python3 -c "
import json, sys

tasks_file = sys.argv[1]
event_name = sys.argv[2]

try:
    with open(tasks_file) as f:
        data = json.load(f)
    for t in data.get('tasks', []):
        if t.get('disabled', False):
            continue
        if t.get('event_trigger') == event_name:
            debounce = t.get('event_trigger_debounce_s', 0)
            print(f\"{t['id']}:{debounce}\")
except Exception as e:
    sys.stderr.write(f'ERROR parsing tasks: {e}\n')
    sys.exit(1)
" "$TASKS_FILE" "$event_name" 2>>"$LOG" || true)

    if [[ -z "$matching_tasks" ]]; then
        log "WARN: event=${event_name} 에 매칭되는 태스크 없음 — trigger 파일 제거"
        rm -f "$trigger_file" 2>/dev/null || true
        return
    fi

    local any_fired=false
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        local task_id debounce_s
        task_id="${line%%:*}"
        debounce_s="${line##*:}"

        if check_debounce "$task_id" "$debounce_s"; then
            run_task "$task_id"
            any_fired=true
        fi
    done <<< "$matching_tasks"

    # trigger 파일 삭제 (debounce로 전부 스킵됐어도 삭제 — 다음 emit에서 재생성됨)
    rm -f "$trigger_file" 2>/dev/null || true

    if [[ "$any_fired" == "false" ]]; then
        log "INFO: event=${event_name} — 모든 매칭 태스크가 debounce 중"
    fi
}

# --- 메인 루프 ---
log "=== event-watcher 시작 (PID=$$, scan_interval=${SCAN_INTERVAL}s) ==="
log "TASKS_FILE=${TASKS_FILE}"
log "EVENTS_DIR=${EVENTS_DIR}"

while true; do
    # 새벽 무음 시간대 체크
    if is_quiet_hours; then
        # 로그 과다 방지: 30분에 한 번만 기록
        _quiet_mark="${EVENTS_DIR}/.quiet_logged"
        if [[ ! -f "$_quiet_mark" ]] || (( $(date +%s) - $(cat "$_quiet_mark" 2>/dev/null || echo 0) > 1800 )); then
            log "QUIET_HOURS: KST $(date +%H:%M) — 새벽 무음 시간대 (이벤트 지연 대기 중)"
            date +%s > "$_quiet_mark"
        fi
        sleep "$SCAN_INTERVAL"
        continue
    fi

    # .trigger 파일 스캔
    for trigger_file in "${EVENTS_DIR}"/*.trigger; do
        # glob 미매칭(파일 없음) 처리
        [[ -e "$trigger_file" ]] || continue
        process_trigger "$trigger_file"
    done

    sleep "$SCAN_INTERVAL"
done
