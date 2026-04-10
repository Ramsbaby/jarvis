#!/usr/bin/env bash
set -euo pipefail

# jarvis-coder.sh — Jarvis 자율 코딩 에이전트 (큐 드레인 모드)
# Usage: jarvis-coder.sh [daily]
# 큐에서 실행 가능한 태스크를 모두 병렬로 처리 후 종료.

JARVIS_HOME="${JARVIS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BOT_HOME="${BOT_HOME:-$JARVIS_HOME}"
export BOT_HOME

# 공용 함수 로드 (run_one_task, update_queue, pick_next_task 등)
source "${BOT_HOME}/lib/coder-functions.sh"

# _log 호환: 기존 호출부에서 _log 사용 시 _coder_log로 전달
_log() { _coder_log "$@"; }

# ============================================================
# 다중 인스턴스 방지: PID 락 파일
# ============================================================
LOCK_FILE="${BOT_HOME}/state/jarvis-coder.lock"
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        _coder_log "이미 실행 중 (PID: ${LOCK_PID}), 중복 실행 방지로 종료"
        echo "dev-queue: 이미 실행 중 (PID ${LOCK_PID})"
        exit 0
    fi
    # 좀비 락 파일 제거
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# ============================================================
# 메인: 큐 드레인 루프 (병렬 처리)
# ============================================================

if [[ ! -f "$DB_FILE" ]]; then
    echo "dev-queue 비어있음: tasks.db 없음"
    exit 0
fi

QUEUED_COUNT=$(${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" count-queued 2>>"$DEV_LOG")
if [[ "$QUEUED_COUNT" -eq 0 ]]; then
    _coder_log "큐 비어있음"
    echo "dev-queue 비어있음: 대기 중인 개발 작업 없음"
    exit 0
fi

MAX_PARALLEL="${MAX_PARALLEL:-1}"  # DB lock 방지: 기본 순차 실행 (병렬 필요 시 MAX_PARALLEL=N 환경변수로 오버라이드)
declare -a _WORKER_PIDS=()

_wait_one() {
    local finished_pid
    wait -n "${_WORKER_PIDS[@]}" 2>/dev/null && finished_pid=$! || finished_pid=$!
    local new_pids=()
    for p in "${_WORKER_PIDS[@]}"; do
        if [[ "$p" != "$finished_pid" ]] && kill -0 "$p" 2>/dev/null; then
            new_pids+=("$p")
        fi
    done
    if [[ ${#new_pids[@]} -gt 0 ]]; then
        _WORKER_PIDS=("${new_pids[@]}")
    else
        _WORKER_PIDS=()
    fi
}

_coder_log "큐 드레인 시작 (MAX_PARALLEL=${MAX_PARALLEL}, QUEUED=${QUEUED_COUNT})"

if [[ "$MAX_PARALLEL" -eq 1 ]]; then
    # ── 순차 모드 (기본): foreground 실행으로 DB lock 경합 원천 차단 ──
    while true; do
        TASK_ID=$(pick_next_task)
        if [[ -z "$TASK_ID" ]]; then
            _coder_log "더 이상 처리할 태스크 없음"
            break
        fi
        _coder_log "태스크 처리 (순차): ${TASK_ID}"
        run_one_task "$TASK_ID"   # foreground — 완료 후 다음 태스크
    done
else
    # ── 병렬 모드 (MAX_PARALLEL>1 명시 시): 기존 &-기반 처리 ──
    while true; do
        while [[ ${#_WORKER_PIDS[@]} -ge $MAX_PARALLEL ]]; do
            _wait_one
        done

        TASK_ID=$(pick_next_task)
        if [[ -z "$TASK_ID" ]]; then
            _coder_log "더 이상 실행 가능한 태스크 없음 — 나머지 완료 대기"
            break
        fi

        _coder_log "태스크 배정: ${TASK_ID} (병렬 슬롯 $((${#_WORKER_PIDS[@]}+1))/${MAX_PARALLEL})"
        run_one_task "$TASK_ID" &
        _WORKER_PIDS+=($!)
    done

    if [[ ${#_WORKER_PIDS[@]} -gt 0 ]]; then
        _coder_log "남은 워커 ${#_WORKER_PIDS[@]}개 완료 대기..."
        wait "${_WORKER_PIDS[@]}" 2>/dev/null || true
    fi
fi

_coder_log "큐 드레인 완료"
echo "## ✍️ Jarvis Coder 완료: 큐 처리 종료"
