#!/bin/bash
# cluster-guard-cl-3e0048f79eb206f9.sh — 명령 중복 처리 및 상태 혼란 방지
#
# 문제: 동일 명령 중복 제출 시 상태 혼란, 부분 완료 상태에서 병렬 진행, 중복에 대해 각각 독립적 작업 보고
#
# 해결책: 명령 해시 기반 멱등성 체크 + 실행 상태 저장소
#
# 사용:
#   source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh
#   check_command_duplicate "명령 텍스트"  # 중복 여부 확인
#   record_command_start "명령 해시" "명령 텍스트"  # 실행 시작 기록
#   record_command_result "명령 해시" "결과 JSON"  # 실행 결과 기록
#

set -euo pipefail

# 상수
readonly CLUSTER_ID="cl-3e0048f79eb206f9"
readonly DB_PATH="${HOME}/jarvis/runtime/state/command-state-${CLUSTER_ID}.db"
readonly STATE_DIR="${HOME}/jarvis/runtime/state/cluster-guards"
readonly STATE_FILE="${STATE_DIR}/cl-3e0048f79eb206f9-command-state.json"
readonly LOCK_DIR="${HOME}/jarvis/runtime/state/guard-locks"

# 디렉토리 초기화
_init_guard_dirs() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$LOCK_DIR"
}

# SQLite DB 초기화 (1회만)
_init_sqlite_db() {
    _init_guard_dirs

    # DB 파일 존재 여부 확인
    if [[ ! -f "$DB_PATH" ]]; then
        # SQLite로 테이블 생성
        sqlite3 "$DB_PATH" << 'EOF'
CREATE TABLE IF NOT EXISTS task_state (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  command_hash TEXT UNIQUE NOT NULL,
  command_text TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  result TEXT,
  result_timestamp INTEGER,
  created_at INTEGER NOT NULL,
  started_at INTEGER,
  completed_at INTEGER,
  retries INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_status ON task_state(status);
CREATE INDEX IF NOT EXISTS idx_hash ON task_state(command_hash);
EOF
    fi
}

# 명령 텍스트 기반 SHA256 해시 생성
_get_command_hash() {
    local cmd="$1"
    echo -n "$cmd" | sha256sum | awk '{print $1}'
}

# 해당 명령의 현재 상태 조회
_query_command_state() {
    local cmd_hash="$1"

    sqlite3 "$DB_PATH" << EOF
SELECT status, result, completed_at FROM task_state
WHERE command_hash = '$cmd_hash'
ORDER BY created_at DESC
LIMIT 1;
EOF
}

# 명령 중복 여부 확인 및 상태 반환
# 반환: 0=새 명령, 1=진행중, 2=완료됨(결과 반환 가능), 3=실패
check_command_duplicate() {
    local cmd_text="$1"
    local cmd_hash

    _init_sqlite_db
    cmd_hash=$(_get_command_hash "$cmd_text")

    local status result completed_at

    # DB에서 조회
    local query_result
    query_result=$(sqlite3 "$DB_PATH" "SELECT status, result, completed_at FROM task_state WHERE command_hash = '$cmd_hash' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || true)

    if [[ -z "$query_result" ]]; then
        # 새로운 명령
        echo "0:$cmd_hash:new"
        return 0
    fi

    # 상태 파싱
    IFS='|' read -r status result completed_at <<< "$query_result"

    case "$status" in
        "pending")
            echo "1:$cmd_hash:진행중"
            return 1
            ;;
        "running")
            echo "1:$cmd_hash:진행중"
            return 1
            ;;
        "completed")
            echo "2:$cmd_hash:완료된 명령 (해시=$cmd_hash, 결과=$result)"
            return 2
            ;;
        "failed")
            echo "3:$cmd_hash:이전 실행 실패"
            return 3
            ;;
        *)
            echo "0:$cmd_hash:unknown_status($status)"
            return 0
            ;;
    esac
}

# 명령 실행 시작 기록
record_command_start() {
    local cmd_hash="$1"
    local cmd_text="$2"
    local timestamp

    timestamp=$(date +%s)
    _init_sqlite_db

    # INSERT OR REPLACE로 중복 처리
    sqlite3 "$DB_PATH" << EOF
INSERT OR REPLACE INTO task_state (command_hash, command_text, status, created_at, started_at, retries)
VALUES ('$cmd_hash', '$cmd_text', 'running', $timestamp, $timestamp,
  (SELECT COALESCE(retries + 1, 1) FROM task_state WHERE command_hash = '$cmd_hash' ORDER BY created_at DESC LIMIT 1));
EOF

    return 0
}

# 명령 실행 결과 기록
record_command_result() {
    local cmd_hash="$1"
    local result="$2"  # JSON 형식 또는 결과 텍스트
    local success="${3:-true}"  # true=completed, false=failed
    local timestamp

    timestamp=$(date +%s)
    _init_sqlite_db

    local status
    [[ "$success" == "true" ]] && status="completed" || status="failed"

    # JSON escape (간단한 버전)
    result=$(printf '%s\n' "$result" | sed 's/"/\\"/g')

    sqlite3 "$DB_PATH" << EOF
UPDATE task_state
SET status = '$status',
    result = '$result',
    completed_at = $timestamp,
    result_timestamp = $timestamp
WHERE command_hash = '$cmd_hash'
ORDER BY created_at DESC
LIMIT 1;
EOF

    return 0
}

# 상태 조회 (읽기 전용)
get_command_status() {
    local cmd_hash="$1"

    _init_sqlite_db

    sqlite3 "$DB_PATH" << EOF
SELECT command_text, status, result, started_at, completed_at
FROM task_state
WHERE command_hash = '$cmd_hash'
ORDER BY created_at DESC
LIMIT 1;
EOF
}

# 모든 진행 중인 명령 조회
list_pending_commands() {
    _init_sqlite_db

    sqlite3 "$DB_PATH" << EOF
SELECT command_hash, command_text, status, started_at
FROM task_state
WHERE status IN ('pending', 'running')
ORDER BY created_at DESC
LIMIT 20;
EOF
}

# 상태 초기화 (테스트/관리 용도)
clear_command_state() {
    local cmd_hash="$1"

    if [[ -z "$cmd_hash" ]]; then
        echo "ERROR: command_hash required" >&2
        return 1
    fi

    _init_sqlite_db

    sqlite3 "$DB_PATH" << EOF
DELETE FROM task_state WHERE command_hash = '$cmd_hash';
EOF

    return 0
}

# DB 전체 상태 덤프 (디버깅)
dump_state_db() {
    _init_sqlite_db

    echo "=== Command State Database (last 10 entries) ==="
    sqlite3 "$DB_PATH" << EOF
SELECT
  command_hash,
  substr(command_text, 1, 50) as cmd_short,
  status,
  datetime(created_at, 'unixepoch') as created,
  datetime(completed_at, 'unixepoch') as completed
FROM task_state
ORDER BY created_at DESC
LIMIT 10;
EOF
}

# 메인: 초기화 확인
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _init_sqlite_db
    echo "OK: cluster-guard-cl-3e0048f79eb206f9 initialized"
fi
