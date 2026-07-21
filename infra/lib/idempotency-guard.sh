#!/usr/bin/env bash
# idempotency-guard.sh
# SQLite 기반 명령 중복 감지 및 상태 관리
#
# 사용:
#   source idempotency-guard.sh
#   check_command_status "task_id" "prompt_hash" "allowed_tools"
#   record_command_start "task_id" "prompt_hash" "allowed_tools"
#   record_command_end "task_id" "prompt_hash" "status" "result_path"

set -euo pipefail

# DB 경로
IDEMPOTENCY_DB="${BOT_HOME:-${HOME}/jarvis/runtime}/data/command-state.db"

# DB 초기화 함수
_init_idempotency_db() {
    local db="$1"
    local db_dir
    db_dir=$(dirname "$db")

    mkdir -p "$db_dir"

    # 테이블이 없으면 생성
    sqlite3 "$db" <<EOF 2>/dev/null || true
CREATE TABLE IF NOT EXISTS task_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    command_hash TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'pending',
    started_at TEXT,
    completed_at TEXT,
    result_path TEXT,
    result_summary TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_task_id ON task_state(task_id);
CREATE INDEX IF NOT EXISTS idx_command_hash ON task_state(command_hash);
CREATE INDEX IF NOT EXISTS idx_status ON task_state(status);
EOF
}

# 명령 해시 생성 함수
_compute_command_hash() {
    local task_id="$1"
    local prompt="$2"
    local allowed_tools="${3:-Read}"

    # task_id + prompt + allowed_tools의 SHA256 해시
    # macOS: shasum -a 256, Linux: sha256sum
    printf '%s\n' "${task_id}::${prompt}::${allowed_tools}" | \
        { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -d' ' -f1
}

# 명령 상태 확인 함수
check_command_status() {
    local task_id="$1"
    local prompt="$2"
    local allowed_tools="${3:-Read}"

    local command_hash
    command_hash=$(_compute_command_hash "$task_id" "$prompt" "$allowed_tools")

    _init_idempotency_db "$IDEMPOTENCY_DB"

    # 기존 기록 조회 (parameterized query로 SQL injection 방지)
    local result
    result=$(sqlite3 "$IDEMPOTENCY_DB" "SELECT status, result_path, result_summary FROM task_state WHERE command_hash = ? ORDER BY updated_at DESC LIMIT 1;" "$command_hash" 2>/dev/null || echo "")

    if [[ -z "$result" ]]; then
        echo "NOT_FOUND"
        return 0
    fi

    # 상태 파싱 (status|result_path|result_summary)
    local status
    status=$(echo "$result" | cut -d'|' -f1)
    local result_path
    result_path=$(echo "$result" | cut -d'|' -f2)
    local result_summary
    result_summary=$(echo "$result" | cut -d'|' -f3)

    if [[ "$status" == "in_progress" ]]; then
        # 24시간 이상 오래된 in_progress는 stale로 간주하고 무시
        local last_update
        last_update=$(sqlite3 "$IDEMPOTENCY_DB" "SELECT strftime('%s', updated_at) FROM task_state WHERE command_hash = ?" "$command_hash" 2>/dev/null | tail -1 || echo "0")
        local now
        now=$(date +%s)
        local age=$((now - last_update))
        if [[ $age -gt 86400 ]]; then
            # 24시간 이상 된 in_progress는 무시
            echo "NOT_FOUND"
            return 0
        fi
        echo "DUPLICATE_IN_PROGRESS|$command_hash"
    elif [[ "$status" == "completed" ]]; then
        echo "DUPLICATE_COMPLETED|$command_hash|$result_path|$result_summary"
    elif [[ "$status" == "failed" ]]; then
        echo "DUPLICATE_FAILED|$command_hash|$result_path|$result_summary"
    else
        echo "DUPLICATE_UNKNOWN|$command_hash"
    fi
}

# 명령 시작 기록 함수
record_command_start() {
    local task_id="$1"
    local prompt="$2"
    local allowed_tools="${3:-Read}"

    local command_hash
    command_hash=$(_compute_command_hash "$task_id" "$prompt" "$allowed_tools")

    _init_idempotency_db "$IDEMPOTENCY_DB"

    # 기존 기록이 있는지 확인 (parameterized query)
    local exists
    exists=$(sqlite3 "$IDEMPOTENCY_DB" "SELECT COUNT(*) FROM task_state WHERE command_hash = ?;" "$command_hash" 2>/dev/null || echo "0")

    if [[ "$exists" -gt 0 ]]; then
        # 기존 기록 업데이트 (parameterized query)
        sqlite3 "$IDEMPOTENCY_DB" "UPDATE task_state SET status = 'in_progress', started_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE command_hash = ?;" "$command_hash" 2>/dev/null || true
    else
        # 새 기록 생성 (parameterized query)
        sqlite3 "$IDEMPOTENCY_DB" "INSERT INTO task_state (task_id, command_hash, status, started_at) VALUES (?, ?, 'in_progress', CURRENT_TIMESTAMP);" "$task_id" "$command_hash" 2>/dev/null || true
    fi

    echo "$command_hash"
}

# 명령 종료 기록 함수
record_command_end() {
    local task_id="$1"
    local command_hash="$2"
    local status="$3"  # completed, failed
    local result_path="${4:-}"
    local result_summary="${5:-}"

    _init_idempotency_db "$IDEMPOTENCY_DB"

    sqlite3 "$IDEMPOTENCY_DB" "UPDATE task_state SET status = ?, completed_at = CURRENT_TIMESTAMP, result_path = ?, result_summary = ?, updated_at = CURRENT_TIMESTAMP WHERE command_hash = ?;" "$status" "$result_path" "$result_summary" "$command_hash" 2>/dev/null || true
}

# 오래된 기록 정리 함수 (기본값: 7일)
cleanup_old_records() {
    local retention_days="${1:-7}"

    _init_idempotency_db "$IDEMPOTENCY_DB"

    sqlite3 "$IDEMPOTENCY_DB" <<EOF 2>/dev/null || true
DELETE FROM task_state
WHERE created_at < datetime('now', '-$retention_days days');
EOF
}

# 상태 조회 함수 (디버깅용)
get_command_state() {
    local command_hash="$1"

    _init_idempotency_db "$IDEMPOTENCY_DB"

    sqlite3 "$IDEMPOTENCY_DB" "SELECT task_id, status, started_at, completed_at, result_path, result_summary, updated_at FROM task_state WHERE command_hash = ? ORDER BY updated_at DESC LIMIT 1;" "$command_hash" 2>/dev/null || echo ""
}

# 초기화 수행
_init_idempotency_db "$IDEMPOTENCY_DB"
