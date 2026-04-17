#!/usr/bin/env bash
# trajectory-logger.sh — 크론 실행 궤적(Trajectory) 수집 라이브러리
# source로 로드하여 사용. jarvis-cron.sh에서 태스크 시작/종료 시 호출.
#
# 기록: JSONL append-only → ~/jarvis/runtime/logs/trajectory.jsonl
# 보존: 30일 (rotation은 별도 크론)
#
# "경쟁 우위는 프롬프트가 아닌, 하네스가 수집하는 궤적에 있다." — Phil Schmid

# 중복 source 방지
[[ -n "${_TRAJECTORY_LOGGER_LOADED:-}" ]] && return 0
_TRAJECTORY_LOGGER_LOADED=1

_TRAJECTORY_FILE="${BOT_HOME:-${HOME}/jarvis/runtime}/logs/trajectory.jsonl"
_TRAJECTORY_START_EPOCH=""

# trajectory_log — 궤적 이벤트 기록
#
# Usage:
#   trajectory_log start <task_id> [model]
#   trajectory_log end   <task_id> <exit_code> [duration_ms]
#
# start 호출 시 내부적으로 epoch를 저장하여 end에서 duration 자동 계산 가능.
# duration_ms를 명시하면 그 값을 우선 사용.
trajectory_log() {
    local event="${1:?trajectory_log: event required (start|end)}"
    local task_id="${2:?trajectory_log: task_id required}"

    # 로그 디렉토리 보장
    mkdir -p "$(dirname "$_TRAJECTORY_FILE")"

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S+09:00')

    case "$event" in
        start)
            local model="${3:-unknown}"
            _TRAJECTORY_START_EPOCH=$(date +%s)
            printf '{"task_id":"%s","ts":"%s","event":"start","model":"%s"}\n' \
                "$task_id" "$ts" "$model" >> "$_TRAJECTORY_FILE" 2>/dev/null || true
            ;;
        end)
            local exit_code="${3:-0}"
            local duration_ms="${4:-}"
            local _traj_status="success"
            [[ "$exit_code" -ne 0 ]] && _traj_status="failure"

            # duration 자동 계산: 명시값 없으면 start epoch 기반
            if [[ -z "$duration_ms" && -n "$_TRAJECTORY_START_EPOCH" ]]; then
                local end_epoch
                end_epoch=$(date +%s)
                duration_ms=$(( (end_epoch - _TRAJECTORY_START_EPOCH) * 1000 ))
            fi
            duration_ms="${duration_ms:-0}"

            printf '{"task_id":"%s","ts":"%s","event":"end","status":"%s","duration_ms":%s,"exit_code":%s}\n' \
                "$task_id" "$ts" "$_traj_status" "$duration_ms" "$exit_code" >> "$_TRAJECTORY_FILE" 2>/dev/null || true
            ;;
        *)
            # 알 수 없는 이벤트는 조용히 무시 (기존 동작 깨뜨리지 않음)
            return 0
            ;;
    esac
}