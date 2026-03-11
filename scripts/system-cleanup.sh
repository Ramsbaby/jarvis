#!/usr/bin/env bash
# system-cleanup.sh — OS 재부팅 대신 경량 리소스 청소
# 매일 새벽 04:00 cron 실행 (pmset 예약 재시작 대체)
#
# 수행 항목:
#   1. 메모리 캐시 purge (sudo purge)
#   2. Discord bot 재시작 (메모리 누수 방지)
#   3. RAG watcher 재시작
#   4. 오래된 임시 파일 정리
#   5. 정리 결과 로그 기록

set -euo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true

LOG_FILE="${BOT_HOME}/logs/system-cleanup.log"

_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

get_mem_free_pct() {
    memory_pressure 2>/dev/null \
        | awk '/System-wide memory free percentage:/{gsub(/%/,"",$NF); print $NF+0}' || echo "0"
}

restart_launchagent() {
    local label="$1"
    if launchctl list | grep -q "$label"; then
        launchctl stop "$label" 2>/dev/null || true
        sleep 2
        launchctl start "$label" 2>/dev/null || true
        _log "재시작: $label"
    else
        _log "SKIP: $label (등록 안 됨)"
    fi
}

main() {
    _log "=== system-cleanup 시작 ==="

    # 1. 재시작 전 메모리 상태
    local mem_before
    mem_before=$(get_mem_free_pct)
    _log "메모리 여유 (전): ${mem_before}%"

    # 2. Discord bot 재시작 (메모리 누수 방지)
    restart_launchagent "ai.jarvis.discord-bot"
    sleep 3

    # 3. RAG watcher 재시작
    restart_launchagent "ai.jarvis.rag-watcher"

    # 4. 메모리 캐시 purge
    if sudo -n purge 2>/dev/null; then
        _log "sudo purge 완료"
    else
        _log "SKIP: sudo purge (권한 없음 — sudoers에 추가 필요)"
    fi

    # 5. 오래된 임시 파일 정리 (7일 이상)
    local cleaned=0
    if [[ -d /tmp ]]; then
        find /tmp -maxdepth 1 -name "jarvis-*" -mtime +1 -delete 2>/dev/null && cleaned=1 || true
        find /tmp -maxdepth 1 -name "claude-*" -mtime +1 -delete 2>/dev/null && cleaned=1 || true
    fi
    if [[ $cleaned -eq 1 ]]; then _log "임시 파일 정리 완료"; else _log "임시 파일: 정리 대상 없음"; fi

    # 6. state/ 디렉토리 정리
    _log "state/ 디렉토리 정리"

    # state/events/ — event-watcher 미구현, 7일 초과 파일 제거
    if [[ -d "${BOT_HOME}/state/events" ]]; then
        find "${BOT_HOME}/state/events" -type f -mtime +7 -delete
        _log "state/events/ 오래된 파일 정리 완료"
    fi

    # state/triggers/ — update-broadcast.sh 외 미사용, 30일 초과 파일 제거
    if [[ -d "${BOT_HOME}/state/triggers" ]]; then
        find "${BOT_HOME}/state/triggers" -type f -mtime +30 -delete
    fi

    # state/board-minutes/ — 90일 초과 제거 (vault-sync.sh가 Vault에 이미 복사함)
    if [[ -d "${BOT_HOME}/state/board-minutes" ]]; then
        find "${BOT_HOME}/state/board-minutes" -type f -mtime +90 -delete
    fi

    # state/decisions/ — 90일 초과 제거 (vault-sync.sh가 Vault에 이미 복사함)
    if [[ -d "${BOT_HOME}/state/decisions" ]]; then
        find "${BOT_HOME}/state/decisions" -type f -mtime +90 -delete
    fi

    # 7. 오래된 debug 로그 정리 (3일 이상 된 파일)
    local debug_dir="${BOT_HOME}/logs/../.claude/debug"
    if [[ -d "$HOME/.claude/debug" ]]; then
        local before_count after_count
        before_count=$(find "$HOME/.claude/debug" -name "*.json" -mtime +3 2>/dev/null | wc -l | tr -d ' ')
        find "$HOME/.claude/debug" -name "*.json" -mtime +3 -delete 2>/dev/null || true
        after_count=$(find "$HOME/.claude/debug" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        _log "Claude debug 정리: ${before_count}개 삭제 → ${after_count}개 남음"
    fi

    # 7. 정리 후 메모리 상태
    sleep 2
    local mem_after
    mem_after=$(get_mem_free_pct)
    _log "메모리 여유 (후): ${mem_after}% (변화: $((mem_after - mem_before))%p)"

    _log "=== system-cleanup 완료 ==="
}

main "$@"
