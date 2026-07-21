#!/usr/bin/env bash
# execution-verdict-wrapper.sh
# 반복 실수 클러스터 cl-e30aee511af89e13 방어: 로그 에러를 API 호출 실패로 오판하는 실수 방지
#
# 원칙: exit code를 1순위로 판정하고, stderr는 참고 정보로만 사용
# - exit code == 0      → 성공
# - exit code != 0      → 실패 (stderr 내용은 판정 근거가 아님)
# - stderr 에러 메시지 존재 → 참고용, 판정 기준 X
#
# 사용법:
#   source ${BOT_HOME}/lib/execution-verdict-wrapper.sh
#   determine_verdict $exit_code $command_name [$stderr_sample]
#   echo $? → 0 (성공) 또는 1 (실패)
#
#   또는:
#   is_success $exit_code && echo "OK" || echo "FAIL"
#   get_error_type $exit_code → "timeout", "auth_failure", "tool_error", "unknown"

set -euo pipefail

# 고정된 exit code → 의미 매핑
# 참고: ask-claude.sh에서 정의한 exit code들
declare -r VERDICT_SUCCESS=0
declare -r VERDICT_TIMEOUT=124         # gtimeout에서 발생
declare -r VERDICT_AUTH_FAILURE=2      # claude CLI 인증 실패
declare -r VERDICT_CMD_NOT_FOUND=126   # 명령어 없음
declare -r VERDICT_DUPLICATE_REQUEST=98    # 중복 요청 차단
declare -r VERDICT_BUDGET_EXCEEDED=2   # 토큰 예산 초과
declare -r VERDICT_CIRCUIT_OPEN=99     # Circuit breaker open
declare -r VERDICT_GENERIC_ERROR=1     # 일반 오류

# Log file for verdict audit trail
VERDICT_AUDIT="${BOT_HOME:-${HOME}/jarvis/runtime}/logs/execution-verdict-audit.log"
mkdir -p "$(dirname "$VERDICT_AUDIT")" 2>/dev/null || true

_verdict_log() {
    local message="$1"
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$message" >> "$VERDICT_AUDIT" 2>/dev/null || true
}

# 핵심 함수: exit code 기반 판정
# 목표: "stderr에 ERROR 텍스트가 있다"는 이유로 실패 판정하지 않기
# 대신: exit code 0 = 성공, exit code != 0 = 실패
determine_verdict() {
    local exit_code="${1:?exit_code required}"
    local command_name="${2:-unknown}"
    local stderr_sample="${3:-}"

    # Exit code 0 = 성공 (stderr 무시)
    if [[ $exit_code -eq $VERDICT_SUCCESS ]]; then
        _verdict_log "VERDICT=SUCCESS cmd=$command_name exit_code=$exit_code"
        return 0
    fi

    # Exit code != 0 = 실패 (stderr는 참고용)
    _verdict_log "VERDICT=FAILURE cmd=$command_name exit_code=$exit_code stderr_snippet=$(echo "$stderr_sample" | head -c 200)"
    return 1
}

# 편의 함수: exit code만으로 성공 여부 판정
is_success() {
    local exit_code="${1:?exit_code required}"
    [[ $exit_code -eq $VERDICT_SUCCESS ]]
}

# 편의 함수: exit code만으로 실패 여부 판정
is_failure() {
    local exit_code="${1:?exit_code required}"
    [[ $exit_code -ne $VERDICT_SUCCESS ]]
}

# 현재 실패의 분류 (참고용, 판정 기준 아님)
# 이 함수는 로깅/모니터링 용도로만 사용, 성공/실패 판정은 exit code로만 함
get_error_type() {
    local exit_code="${1:?exit_code required}"

    case "$exit_code" in
        $VERDICT_SUCCESS)
            echo "success"
            ;;
        $VERDICT_TIMEOUT)
            echo "timeout"
            ;;
        $VERDICT_AUTH_FAILURE)
            echo "auth_failure"
            ;;
        $VERDICT_CMD_NOT_FOUND)
            echo "command_not_found"
            ;;
        $VERDICT_DUPLICATE_REQUEST)
            echo "duplicate_request"
            ;;
        $VERDICT_CIRCUIT_OPEN)
            echo "circuit_open"
            ;;
        $VERDICT_GENERIC_ERROR)
            echo "generic_error"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 하위 호환성: 기존 로그 참고 기반 판정을 거부하는 함수
# stderr에 "ERROR" 또는 "FAIL" 텍스트가 있다고 해서 실패 판정하지 않음
should_not_retry_based_on_stderr_pattern() {
    local stderr_sample="${1:?stderr_sample required}"

    # ANTI-PATTERN: stderr에 error 텍스트가 있으면 재시도 → 이것을 거부함
    # 대신, exit code만 사용하도록 강제

    # 경고: 호출자가 stderr 기반 판정을 하려 시도하면, 이 함수는 항상 "no"를 반환
    # 즉, 재시도하지 말라는 뜻
    return 1
}

# 감사 함수: 기존 크론/태스크가 stderr 로그를 판정 기준으로 오판했는지 확인
audit_stderr_judgment_misuse() {
    local task_id="${1:?task_id required}"
    local stderr_file="${2:?stderr_file required}"
    local exit_code="${3:?exit_code required}"

    if [[ ! -f "$stderr_file" ]]; then
        return 0  # 파일 없음 = OK
    fi

    # stderr에 ERROR/error 패턴이 있지만, exit code는 0인 경우 (오판 가능성)
    if grep -q -i 'error\|fail' "$stderr_file" && [[ $exit_code -eq 0 ]]; then
        _verdict_log "AUDIT_WARNING task=$task_id has_stderr_error_pattern=true but exit_code=0 (stderr-based judgment risk)"
        return 1  # 리스크 있음
    fi

    return 0  # 리스크 없음
}

# 디버그: 현재 판정 규칙 출력
print_verdict_rules() {
    cat <<'EOF'
=== Execution Verdict Wrapper Rules (cl-e30aee511af89e13) ===

PRIMARY (exit code 기반):
  exit_code = 0     → SUCCESS (regardless of stderr content)
  exit_code != 0    → FAILURE (stderr is for reference only)

SPECIAL CODES:
  exit_code = 124   → TIMEOUT (stderr check unnecessary)
  exit_code = 2     → AUTH_FAILURE or BUDGET_EXCEEDED (not stderr-based)
  exit_code = 98    → DUPLICATE_REQUEST (blocked, not a failure)
  exit_code = 99    → CIRCUIT_OPEN (graceful degradation, not a failure)

ANTI-PATTERN (절대 금지):
  ❌ grep "ERROR" stderr && exit 1
  ❌ if [[ "$stderr" =~ "failed" ]]; then retry...
  ❌ stderr 내용으로 "성공했지만 로그에 error 텍스트가 있다"고 오판
  ✅ $? 값만 사용하여 판정
  ✅ stderr는 로깅/모니터링 용도로만 사용

EOF
}

export -f determine_verdict
export -f is_success
export -f is_failure
export -f get_error_type
export -f should_not_retry_based_on_stderr_pattern
export -f audit_stderr_judgment_misuse
export -f print_verdict_rules
