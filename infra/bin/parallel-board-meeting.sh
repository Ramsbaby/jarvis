#!/usr/bin/env bash
# parallel-board-meeting.sh - Board meeting orchestrator
# Runs board meeting tasks in parallel (AM/PM schedule)
#
# Usage:
#   parallel-board-meeting.sh [am|pm]
#
set -euo pipefail

# ── 환경 설정 ───────────────────────────────────────────────
export HOME="${HOME:-$(eval echo ~$(whoami))}"
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
BOARD_URL="${BOARD_URL:-http://localhost:3100}"
AGENT_KEY="${AGENT_API_KEY:-jarvis-board-internal-2026}"
LOGFILE="${BOT_HOME}/logs/board-meeting.log"
PIDFILE="/tmp/board-meeting-${1:-am}.pid"
WORK_DIR="${BOT_HOME}/work/board-meetings"

# ── 파라미터 ────────────────────────────────────────────────
SESSION="${1:-am}"
if [[ "${SESSION}" != "am" && "${SESSION}" != "pm" ]]; then
    SESSION="am"
fi

# ── 로그 함수 ───────────────────────────────────────────────
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
    printf "[%s] [board-meeting:%s] [%s] %s\n" "$ts" "$SESSION" "$level" "$msg" | tee -a "$LOGFILE"
}

# ── 정리 함수 ───────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    log "INFO" "Cleaning up background processes (session: ${SESSION})"

    # 모든 배경 프로세스 종료
    local pids=$(jobs -p)
    if [[ -n "$pids" ]]; then
        log "INFO" "Terminating ${SESSION} background processes..."
        while IFS= read -r pid; do
            if kill -0 "$pid" 2>/dev/null; then
                log "INFO" "Sending SIGTERM to PID $pid"
                kill -15 "$pid" 2>/dev/null || true
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    log "WARN" "Force killing PID $pid with SIGKILL"
                    kill -9 "$pid" 2>/dev/null || true
                fi
            fi
        done <<< "$pids"
    fi

    # PID 파일 정리
    [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE"

    return $exit_code
}

trap cleanup EXIT INT TERM

# ── 디렉토리 확인 ──────────────────────────────────────────
mkdir -p "$(dirname "$LOGFILE")"
mkdir -p "$WORK_DIR"

# ── 프로세스 PID 기록 ──────────────────────────────────────
echo $$ > "$PIDFILE"

# ── Board API 헬스 체크 ────────────────────────────────────
log "INFO" "Checking board API health..."
health_response=$(curl -s -m 5 -H "x-agent-key: ${AGENT_KEY}" "${BOARD_URL}/api/health" 2>/dev/null || echo "")
if ! echo "$health_response" | grep -q '"ok"'; then
    log "WARN" "Board API not responding — skipping (status: ${health_response:-NO_RESPONSE})"
    exit 0
fi

log "INFO" "Board API OK, starting ${SESSION} session"

# ── 병렬 작업 함수 ──────────────────────────────────────────
run_board_task() {
    local task_name="$1"
    local task_id="$2"
    local output_file="${WORK_DIR}/${SESSION}-${task_id}.out"

    log "INFO" "Starting task: $task_name (${task_id})"
    {
        # 작업 실행 (placeholder)
        echo "Completed: $task_name" > "$output_file"
        log "INFO" "Task completed: $task_id"
    } &
}

# ── 세션별 작업 ────────────────────────────────────────────
if [[ "${SESSION}" == "am" ]]; then
    log "INFO" "Running morning board meeting session"
    # 아침 세션: 뉴스 브리핑 이후 보드 회의 준비
    # - 목표: 일일 우선순위 논의
    # - 참석: CEO, 팀장들

    # 병렬 작업 실행
    run_board_task "Daily Priority Discussion" "priority-discussion" &
    run_board_task "Team Status Sync" "team-sync" &

elif [[ "${SESSION}" == "pm" ]]; then
    log "INFO" "Running evening board meeting session"
    # 저녁 세션: 일일 회의 결과 검토 및 의사결정
    # - 목표: 일일 결과 평가 및 다음날 준비
    # - 참석: CEO, 팀장들

    # 병렬 작업 실행
    run_board_task "Daily Results Review" "results-review" &
    run_board_task "Decision Making" "decisions" &
fi

# ── 보드 상태 조회 ──────────────────────────────────────────
log "INFO" "Retrieving board status..."
board_status=$(curl -s -H "x-agent-key: ${AGENT_KEY}" "${BOARD_URL}/api/board-status" 2>/dev/null || echo "{}")

# 활성 논의 개수 확인
active_count=$(echo "$board_status" | jq '.activeDiscussions // 0' 2>/dev/null || echo "0")
log "INFO" "Active discussions: ${active_count}"

# ── 배경 프로세스 완료 대기 ─────────────────────────────────
log "INFO" "Waiting for parallel tasks to complete..."
wait_count=0
max_wait=300
while [[ $(jobs -r | wc -l) -gt 0 ]] && [[ $wait_count -lt $max_wait ]]; do
    sleep 1
    ((wait_count++))
done

if [[ $(jobs -r | wc -l) -gt 0 ]]; then
    log "WARN" "Timeout: some tasks are still running, terminating..."
    # kill 명령어는 cleanup trap에서 처리됨
    exit 1
fi

# ── 결과 수집 ───────────────────────────────────────────────
log "INFO" "Collecting task results..."
result_count=$(find "$WORK_DIR" -name "${SESSION}-*.out" -type f 2>/dev/null | wc -l)
log "INFO" "Board meeting session (${SESSION}) complete - ${result_count} tasks executed"

exit 0
