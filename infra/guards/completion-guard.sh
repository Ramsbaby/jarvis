#!/usr/bin/env bash
# completion-guard.sh — 완료 선언 통합 검증 가드
#
# 역할:
#   - 완료 주장 시 불가능한 작업 자동 차단
#   - 산출물 존재 및 품질 자동 검증
#   - 도구 통과 vs. 실제 산출물 일치성 검증
#   - 강력한 완료 신뢰성 확보
#
# 사용:
#   source ~/projects/jarvis/infra/guards/completion-guard.sh
#   guard_completion_declaration \
#     --action "web-form-manipulation" \
#     --artifacts "file:/path/to/output.txt" \
#     --task-id "task-12345"
#
# 반환값:
#   0 - 완료 승인
#   1 - 완료 거부 (불가능한 작업 또는 산출물 미검증)
#   2 - 검증 오류

set -o pipefail

# 의존성 로드
_GUARD_DIR="${HOME}/projects/jarvis/infra/guards"
source "${_GUARD_DIR}/impossible-actions-registry.sh" 2>/dev/null || {
    echo "ERROR: impossible-actions-registry.sh not found" >&2
    exit 2
}
source "${_GUARD_DIR}/task-completion-validator.sh" 2>/dev/null || {
    echo "ERROR: task-completion-validator.sh not found" >&2
    exit 2
}

# 로깅
_log_completion_check() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')

    local log_dir="${HOME}/.openclaw-data/runtime/logs/completion-guard"
    mkdir -p "$log_dir" 2>/dev/null || true

    printf '[%s] [%s] [cl-41697ce934383874] %s\n' "$timestamp" "$level" "$message" \
        >> "$log_dir/completion-checks.log" 2>/dev/null || true

    # stderr에도 출력
    echo "[completion-guard] [$level] $message" >&2
}

# 함수: 완료 선언 통합 검증
guard_completion_declaration() {
    local action_type="" task_id="" verbose=0
    local -a artifact_specs=()

    # 인자 파싱
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                action_type="$2"
                shift 2
                ;;
            --task-id)
                task_id="$2"
                shift 2
                ;;
            --artifacts)
                # 쉼표로 구분된 artifacts (type:path 형식)
                IFS=',' read -ra artifact_specs <<< "$2"
                shift 2
                ;;
            --verbose)
                verbose=1
                shift
                ;;
            *)
                echo "ERROR: Unknown option — $1" >&2
                return 2
                ;;
        esac
    done

    # 필수 인자 확인
    if [[ -z "$action_type" ]] && [[ ${#artifact_specs[@]} -eq 0 ]]; then
        echo "ERROR: --action or --artifacts required" >&2
        return 2
    fi

    local all_checks_pass=0

    # 스텝 1: 불가능한 작업 확인
    if [[ -n "$action_type" ]]; then
        _log_completion_check "INFO" "완료 선언 검증 시작 (action: $action_type, task: $task_id)"

        if is_impossible_action "$action_type"; then
            local reason fallback
            reason=$(get_impossible_reason "$action_type")
            fallback=$(get_impossible_fallback "$action_type")

            _log_completion_check "BLOCK" "불가능한 작업 감지: $action_type"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "❌ 완료 불승인: 실행 불가능한 작업" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            echo "작업 유형: $action_type" >&2
            echo "이유: $reason" >&2
            echo "제안: $fallback" >&2
            echo "" >&2

            [[ "$verbose" == "1" ]] && list_impossible_actions

            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

            all_checks_pass=1
        else
            _log_completion_check "OK" "작업 '$action_type'는 실행 가능"
        fi
    fi

    # 스텝 2: 산출물 검증
    if [[ ${#artifact_specs[@]} -gt 0 ]]; then
        _log_completion_check "INFO" "산출물 검증 시작 (개수: ${#artifact_specs[@]})"

        local artifact_check_pass=0
        for spec in "${artifact_specs[@]}"; do
            # 형식: type:path 또는 type:path:options
            local artifact_type artifact_path options

            IFS=':' read -r artifact_type artifact_path options <<< "$spec"

            if [[ -z "$artifact_type" || -z "$artifact_path" ]]; then
                _log_completion_check "ERROR" "잘못된 산출물 사양: $spec"
                artifact_check_pass=1
                continue
            fi

            echo "" >&2
            echo "검증 중: $artifact_type → $artifact_path" >&2

            if validate_task_completion "$artifact_type" "$artifact_path" "$options"; then
                _log_completion_check "OK" "산출물 검증 성공: $artifact_type ($artifact_path)"
            else
                _log_completion_check "BLOCK" "산출물 검증 실패: $artifact_type ($artifact_path)"
                artifact_check_pass=1
            fi
        done

        [[ "$artifact_check_pass" -eq 1 ]] && all_checks_pass=1
    fi

    # 최종 결과
    if [[ "$all_checks_pass" -eq 0 ]]; then
        _log_completion_check "OK" "모든 검증 통과 — 완료 승인"
        echo "" >&2
        echo "✓ 완료 승인됨" >&2
        return 0
    else
        _log_completion_check "BLOCK" "검증 실패 — 완료 거부"
        echo "" >&2
        echo "✗ 완료 거부됨" >&2
        return 1
    fi
}

# 함수: 간소화된 완료 검증 (단일 파일만)
guard_file_completion() {
    local file_path="$1"
    local min_size="${2:-1}"
    local task_id="${3:-unknown}"

    [[ -z "$file_path" ]] && { echo "ERROR: file_path required" >&2; return 2; }

    _log_completion_check "INFO" "파일 완료 검증 (task: $task_id, file: $file_path)"

    if ! validate_task_completion "file" "$file_path" "min_size=$min_size"; then
        _log_completion_check "BLOCK" "파일 산출물 검증 실패"
        return 1
    fi

    _log_completion_check "OK" "파일 완료 검증 성공"
    return 0
}

# 함수: 간소화된 응답 검증 (텍스트)
guard_response_completion() {
    local response="$1"
    local min_chars="${2:-1}"
    local task_id="${3:-unknown}"

    [[ -z "$response" ]] && { echo "ERROR: response required" >&2; return 2; }

    _log_completion_check "INFO" "응답 완료 검증 (task: $task_id, length: ${#response} chars)"

    if ! validate_task_completion "text" "$response" "min_chars=$min_chars"; then
        _log_completion_check "BLOCK" "응답 검증 실패"
        return 1
    fi

    _log_completion_check "OK" "응답 완료 검증 성공"
    return 0
}

# 함수: 완료 선언 거부 사유 리포트 (JSON)
generate_completion_denial_report() {
    local action_type="$1"
    local task_id="$2"
    local denial_reason="$3"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    [[ -z "$action_type" ]] && action_type="unknown"
    [[ -z "$task_id" ]] && task_id="unknown"
    [[ -z "$denial_reason" ]] && denial_reason="검증 실패"

    cat <<EOF
{
  "timestamp": "$timestamp",
  "cluster": "cl-41697ce934383874",
  "guard": "completion-guard",
  "task_id": "$task_id",
  "action_type": "$action_type",
  "status": "denied",
  "reason": "$denial_reason",
  "remediation": "작업 재설계 또는 산출물 재생성 후 재검증 필요"
}
EOF
}

# 함수: 로그 조회
get_completion_logs() {
    local lines="${1:-50}"
    local log_file="${HOME}/.openclaw-data/runtime/logs/completion-guard/completion-checks.log"

    [[ ! -f "$log_file" ]] && {
        echo "No completion guard logs found" >&2
        return 1
    }

    tail -n "$lines" "$log_file"
}

# Test mode
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Testing completion-guard.sh..."

    # 테스트 1: 불가능한 작업 차단
    echo ""
    echo "Test 1: 불가능한 작업 차단"
    guard_completion_declaration --action "web-form-manipulation" --task-id "test-1" || true

    # 테스트 2: 가능한 작업 + 파일 검증 (성공)
    echo ""
    echo "Test 2: 가능한 작업 + 파일 검증 (성공)"
    echo "valid content" > /tmp/test_completion.txt
    guard_completion_declaration \
        --action "generate-document" \
        --artifacts "file:/tmp/test_completion.txt:min_size=5" \
        --task-id "test-2"

    # 테스트 3: 파일 검증만 (빈 파일)
    echo ""
    echo "Test 3: 파일 검증 (빈 파일 - 실패)"
    touch /tmp/empty_completion.txt
    guard_completion_declaration \
        --artifacts "file:/tmp/empty_completion.txt:min_size=10" \
        --task-id "test-3" || true

    # 테스트 4: 응답 검증 (충분한 길이)
    echo ""
    echo "Test 4: 응답 검증 (충분한 길이 - 성공)"
    guard_response_completion "이것은 충분히 긴 응답입니다" 10 "test-4"

    # 테스트 5: 응답 검증 (너무 짧음)
    echo ""
    echo "Test 5: 응답 검증 (너무 짧음 - 실패)"
    guard_response_completion "a" 10 "test-5" || true

    # 정리
    rm -f /tmp/test_completion.txt /tmp/empty_completion.txt

    # 로그 출력
    echo ""
    echo "Completion Guard Logs:"
    get_completion_logs 10 || true
fi
