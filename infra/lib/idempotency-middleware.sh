#!/bin/bash
# idempotency-middleware.sh — 명령 중복 감지 및 상태 관리 미들웨어
#
# ask-claude.sh 실행 전에 명령 중복 여부를 확인하고,
# 중복 명령인 경우 경고 또는 이전 결과를 반환하는 미들웨어
#
# 사용:
#   source ~/.jarvis/lib/idempotency-middleware.sh
#   check_and_protect_duplicate TASK_ID PROMPT [CLUSTER_ID]
#

set -euo pipefail

# 의존성
source "${HOME}/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh" 2>/dev/null || {
    echo "ERROR: cluster-guard-cl-3e0048f79eb206f9.sh not found" >&2
    exit 1
}

# 클러스터 ID (기본값)
IDEMPOTENCY_CLUSTER_ID="${IDEMPOTENCY_CLUSTER_ID:-cl-3e0048f79eb206f9}"

# 로그 경로
IDEMPOTENCY_LOG="${HOME}/jarvis/runtime/state/idempotency-middleware.jsonl"

# 명령 식별자 생성: TASK_ID + PROMPT 기반 해시
_generate_command_id() {
    local task_id="$1"
    local prompt="$2"

    # TASK_ID와 첫 100자 PROMPT를 조합하여 해시 생성
    local combined="${task_id}::${prompt:0:200}"
    echo -n "$combined" | sha256sum | awk '{print $1}'
}

# 로그 기록
_log_idempotency() {
    local status="$1"
    local task_id="$2"
    local cmd_hash="$3"
    local message="${4:-}"
    local timestamp

    timestamp=$(date -u +%FT%TZ)
    mkdir -p "$(dirname "$IDEMPOTENCY_LOG")"

    printf '{"ts":"%s","task":"%s","hash":"%s","status":"%s","msg":"%s"}\n' \
        "$timestamp" "$task_id" "$cmd_hash" "$status" "$message" >> "$IDEMPOTENCY_LOG"
}

# 주요 함수: 중복 체크 및 보호
# 반환값:
#   0 = 새 명령, 진행 가능
#   1 = 진행중인 명령 (기다려야 함)
#   2 = 완료된 명령 (결과 재사용 가능)
#   3 = 이전 실패 (재시도 가능하지만 주의)
check_and_protect_duplicate() {
    local task_id="${1:?Task ID required}"
    local prompt="${2:?Prompt required}"
    local cluster_id="${3:-$IDEMPOTENCY_CLUSTER_ID}"

    local cmd_hash
    cmd_hash=$(_generate_command_id "$task_id" "$prompt")

    # DB에서 중복 여부 확인
    local result
    result=$(check_command_duplicate "$prompt" 2>/dev/null || echo "0:$cmd_hash:error")

    local status status_code
    IFS=':' read -r status_code cmd_hash status <<< "$result"

    # 상태별 처리
    case "$status_code" in
        0)
            # 새로운 명령: 시작 기록
            record_command_start "$cmd_hash" "$prompt"
            _log_idempotency "new_command" "$task_id" "$cmd_hash" "시작"
            return 0
            ;;
        1)
            # 진행중인 명령: 경고 + 기다리거나 취소
            _log_idempotency "duplicate_running" "$task_id" "$cmd_hash" "진행중 (경고)"
            cat >&2 << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  DUPLICATE COMMAND DETECTED (Cluster: $cluster_id)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Task ID: $task_id
Command Hash: $cmd_hash
Status: 진행중

Prompt:
$(echo "$prompt" | head -5)...

→ 동일한 명령이 현재 진행 중입니다.
→ 다음 옵션을 선택하세요:
   1. 기다리기: 진행중인 작업이 완료될 때까지 대기
   2. 취소하기: 이 실행을 건너뛰기
   3. 강제 재실행: 새로운 작업으로 시작 (비권장)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
            return 1
            ;;
        2)
            # 완료된 명령: 이전 결과 반환 가능
            _log_idempotency "duplicate_completed" "$task_id" "$cmd_hash" "완료된 명령 (재사용 가능)"
            cat >&2 << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ℹ️  DUPLICATE COMMAND DETECTED (Cluster: $cluster_id)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Task ID: $task_id
Command Hash: $cmd_hash
Status: 완료됨

Prompt:
$(echo "$prompt" | head -5)...

→ 이 명령은 이미 완료되었습니다.
→ 이전 결과를 재사용하거나 새로운 실행을 강제할 수 있습니다.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
            return 2
            ;;
        3)
            # 이전 실패: 주의하면서 재시도
            _log_idempotency "duplicate_failed" "$task_id" "$cmd_hash" "이전 실패 (재시도 가능)"
            cat >&2 << EOF

⚠️  PREVIOUS EXECUTION FAILED (Cluster: $cluster_id)

Task ID: $task_id
Command Hash: $cmd_hash

→ 이전 실행이 실패했습니다. 조건이 변경되었다면 재시도할 수 있습니다.

EOF
            return 3
            ;;
        *)
            # 알 수 없는 상태
            _log_idempotency "unknown_state" "$task_id" "$cmd_hash" "알 수 없는 상태"
            return 0
            ;;
    esac
}

# 명령 실행 완료 후 결과 기록
mark_command_completed() {
    local task_id="$1"
    local prompt="$2"
    local result="${3:-}"

    local cmd_hash
    cmd_hash=$(_generate_command_id "$task_id" "$prompt")

    record_command_result "$cmd_hash" "$result" "true"
    _log_idempotency "marked_completed" "$task_id" "$cmd_hash" "완료 기록"
}

# 명령 실행 실패 후 결과 기록
mark_command_failed() {
    local task_id="$1"
    local prompt="$2"
    local error="${3:-}"

    local cmd_hash
    cmd_hash=$(_generate_command_id "$task_id" "$prompt")

    record_command_result "$cmd_hash" "$error" "false"
    _log_idempotency "marked_failed" "$task_id" "$cmd_hash" "실패 기록"
}

# 상태 조회
get_command_state() {
    local task_id="$1"
    local prompt="$2"

    local cmd_hash
    cmd_hash=$(_generate_command_id "$task_id" "$prompt")

    get_command_status "$cmd_hash"
}

# 초기화 확인
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "OK: idempotency-middleware loaded"
fi
