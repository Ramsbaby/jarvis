#!/usr/bin/env bash
# Duplicate Request Guard Cache Cleanup — 중복 감지 캐시 자동 정리
# 크론 태스크 또는 수동으로 주기적 호출
#
# 사용법:
#   bash cleanup-duplicate-cache.sh
#
# 동작:
#   - TTL 만료 항목 제거
#   - 통계 리포트 출력
#   - 캐시 파일 크기 최적화
#
# [2026-07-13] cl-e30aee511af89e13 가드 통합:
#   - 재실행 전 상태 확인 (status-guard.sh)
#   - exit code 기반 판정 (verdict-wrapper.sh)
#   - 불필요한 재실행 방지

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
GUARD_SCRIPT="${BOT_HOME}/lib/duplicate-request-guard.mjs"
JARVIS_HOME="${JARVIS_HOME:-${HOME}/jarvis}"

# 새 가드 함수 로드 (cl-e30aee511af89e13 방어)
source "${JARVIS_HOME}/infra/lib/exit-code-first-wrapper.sh" 2>/dev/null || {
    echo "[ERROR] exit-code-first-wrapper.sh not found" >&2
    exit 2
}
source "${JARVIS_HOME}/infra/lib/status-guard.sh" 2>/dev/null || {
    echo "[ERROR] status-guard.sh not found" >&2
    exit 2
}

# 작업 식별자 (일일 중복 방지)
TASK_ID="cleanup-duplicate-cache"
STATE_DIR="${HOME}/jarvis/runtime/state"

# --- Step 1: 재실행 전 상태 확인 (TTL: 24시간) ---
if should_skip_task "$TASK_ID" "$STATE_DIR" 86400; then
    echo "[$(date '+%F %H:%M:%S')] Task already completed within 24h, skipping" >&2
    exit 0
fi

# 진행 중으로 표시
record_task_status "$TASK_ID" "in_progress" "$STATE_DIR" '{"start":"'$(date -u +%FT%TZ)'"}'

# --- Step 2: 선행 조건 확인 ---
if ! command -v node >/dev/null 2>&1; then
    echo "[ERROR] node not found in PATH" >&2
    if command -v mark_failure >/dev/null 2>&1; then
        mark_failure "$TASK_ID" >/dev/null 2>&1 || true
    fi
    exit 1
fi

if [[ ! -f "$GUARD_SCRIPT" ]]; then
    echo "[ERROR] Guard script not found: $GUARD_SCRIPT" >&2
    record_task_status "$TASK_ID" "failure" "$STATE_DIR" '{"error":"guard_script_not_found"}'
    exit 1
fi

echo "[$(date '+%F %H:%M:%S')] Starting duplicate cache cleanup..."

# --- Step 3: 캐시 정리 (exit code 중심 판정) ---
# exit code만으로 판정 (stderr 내용은 로그에만 기록)
run_command_with_guard "$TASK_ID" node "$GUARD_SCRIPT" cleanup

if [[ $? -ne 0 ]]; then
    echo "[ERROR] Cache cleanup failed" >&2
    record_task_status "$TASK_ID" "failure" "$STATE_DIR" '{"error":"cleanup_failed"}'
    exit 1
fi

# --- Step 4: 통계 출력 ---
echo ""
echo "[$(date '+%F %H:%M:%S')] Duplicate Request Guard Statistics:"
node "$GUARD_SCRIPT" stats 2>&1 | sed 's/^/  /'
stats_exit_code=$?

if [[ $stats_exit_code -ne 0 ]]; then
    echo "[WARN] Statistics generation returned exit code $stats_exit_code (proceeding anyway)" >&2
fi

# --- Step 5: 성공 표시 ---
echo ""
echo "[$(date '+%F %H:%M:%S')] Cleanup completed successfully"

record_task_status "$TASK_ID" "success" "$STATE_DIR" '{"status":"completed"}'

exit 0
