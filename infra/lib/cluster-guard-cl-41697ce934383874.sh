#!/bin/bash
# cluster-guard-cl-41697ce934383874.sh
#
# 오답승격 클러스터 cl-41697ce934383874 가드
# 불완전 응답 / 거짓 완료 보고 자동 차단
#
# 문제:
#   - 사용자 질문에 불완전 응답 (1글자만 출력 후 중단)
#   - 실제 불가능한 웹 폼 조작을 완료했다고 거짓 보고
#   - 검증 도구 통과만으로 완료 선언
#   - 실제 콘텐츠 재구성 미확인
#   - 완료 선언 후 미흡한 결과물 제시
#   - 텍스트 설명 추가 후 전체 완료 선언 (하위 기능 일관성 검증 누락)
#
# 솔루션:
#   1. 불가능한 작업 유형 사전 등록 후 완료 주장 시 자동 차단
#   2. 완료 선언 전 실제 산출물 자동 검증
#   3. 응답 완전성 검증 (중단 여부, 길이)
#   4. 연관 기능 일관성 검증
#
# 사용:
#   source ~/.jarvis/infra/lib/cluster-guard-cl-41697ce934383874.sh
#   guard_init
#
#   # 완료 선언 전 차단 검증
#   guard_verify_completion "task-001" "response_text" "output_file" "html_file"
#
#   # 불가능한 작업 감지
#   guard_detect_impossible_task "response_text"

set -o pipefail

GUARD_CLUSTER_ID="cl-41697ce934383874"
GUARD_VERSION="1.0"
GUARD_STATE_DIR="${HOME}/.jarvis/state/cluster-guard-${GUARD_CLUSTER_ID}"
IMPOSSIBLE_TASKS_REGISTRY="${HOME}/.jarvis/infra/lib/impossible-tasks-registry.json"

# 의존성
source "${HOME}/.jarvis/infra/lib/response-completion-validator.sh" || {
    echo "ERROR: response-completion-validator.sh not found" >&2
    exit 1
}
source "${HOME}/.jarvis/infra/lib/artifact-validation-gate.sh" || {
    echo "ERROR: artifact-validation-gate.sh not found" >&2
    exit 1
}

# 함수: 초기화
guard_init() {
    mkdir -p "$GUARD_STATE_DIR"

    if [ ! -f "$IMPOSSIBLE_TASKS_REGISTRY" ]; then
        echo "WARN: impossible-tasks-registry.json not found at $IMPOSSIBLE_TASKS_REGISTRY" >&2
        return 1
    fi

    echo "Guard initialized: $GUARD_CLUSTER_ID"
    return 0
}

# 함수: 불가능한 작업 감지
guard_detect_impossible_task() {
    local response_text="$1"

    [ -z "$response_text" ] && return 0

    local registry="$IMPOSSIBLE_TASKS_REGISTRY"
    [ ! -f "$registry" ] && {
        echo "WARN: Registry not found: $registry" >&2
        return 0
    }

    # JSON에서 불가능한 작업 패턴 추출
    local patterns=$(jq -r '.impossibleTaskTypes[].pattern' "$registry" 2>/dev/null)

    local matched_pattern=""
    while IFS= read -r pattern; do
        if echo "$response_text" | grep -qiE "$pattern"; then
            matched_pattern="$pattern"
            break
        fi
    done <<< "$patterns"

    if [ -n "$matched_pattern" ]; then
        local reason=$(jq -r ".impossibleTaskTypes[] | select(.pattern == \"$matched_pattern\") | .reason" "$registry" 2>/dev/null)
        echo "BLOCKED: 불가능한 작업 감지 — $reason" >&2
        return 1
    fi

    return 0
}

# 함수: 완료 선언 감지 및 검증
guard_detect_completion_claim() {
    local response_text="$1"

    # 완료 선언 패턴 확인
    if echo "$response_text" | grep -qiE '완료했|완료되었|작업.*완료|완료.*선언'; then
        return 0  # 완료 선언 감지
    fi

    return 1  # 완료 선언 없음
}

# 함수: 통합 검증 — 완료 선언 전 호출
guard_verify_completion() {
    local task_id="$1"
    local response_text="$2"
    local output_file="$3"       # 선택사항: 생성되어야 할 파일
    local html_file="$4"          # 선택사항: HTML 파일 (기능 일관성 검증용)

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }
    [ -z "$response_text" ] && { echo "ERROR: response_text required" >&2; return 1; }

    local log_file="$GUARD_STATE_DIR/${task_id}.log"
    local passed_checks=0
    local failed_checks=0
    local warnings=0

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task: $task_id" > "$log_file"
    echo "Response length: ${#response_text}" >> "$log_file"

    # 검사 1: 불가능한 작업 감지
    echo ">>> Check 1: 불가능한 작업 감지" >> "$log_file"
    if guard_detect_impossible_task "$response_text" >> "$log_file" 2>&1; then
        passed_checks=$((passed_checks + 1))
    else
        failed_checks=$((failed_checks + 1))
        echo "FAIL: 불가능한 작업이 포함됨" >&2
        return 1
    fi

    # 검사 2: 응답 완전성 검증
    echo ">>> Check 2: 응답 완전성 검증" >> "$log_file"
    if validate_response_completion "$response_text" "$output_file" >> "$log_file" 2>&1; then
        passed_checks=$((passed_checks + 1))
    else
        case $? in
            1)
                failed_checks=$((failed_checks + 1))
                echo "WARN: 응답이 중단되었을 가능성 있음" >&2
                ;;
            2)
                warnings=$((warnings + 1))
                echo "WARN: 산출물 파일 미확인" >&2
                ;;
        esac
    fi

    # 검사 3: 완료 선언 감지
    echo ">>> Check 3: 완료 선언 감지" >> "$log_file"
    if guard_detect_completion_claim "$response_text" >> "$log_file" 2>&1; then
        echo "완료 선언 감지, 추가 검증 실행..." >> "$log_file"

        # 검사 3.1: 산출물 존재 여부 검증
        if [ -n "$output_file" ]; then
            echo ">>> Check 3.1: 산출물 존재성 검증" >> "$log_file"
            if [ -f "$output_file" ]; then
                local fsize=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
                if [ "$fsize" -gt 0 ]; then
                    echo "OK: 파일 존재 ($output_file, $fsize bytes)" >> "$log_file"
                    passed_checks=$((passed_checks + 1))
                else
                    echo "FAIL: 파일 비어있음 ($output_file)" >> "$log_file"
                    failed_checks=$((failed_checks + 1))
                    echo "거짓 완료 보고 감지: 파일이 비어있음" >&2
                    return 1
                fi
            else
                echo "FAIL: 파일 미존재 ($output_file)" >> "$log_file"
                failed_checks=$((failed_checks + 1))
                echo "거짓 완료 보고 감지: 파일 미생성" >&2
                return 1
            fi
        fi

        # 검사 3.2: 연관 기능 일관성 검증 (HTML 파일)
        if [ -n "$html_file" ] && [ -f "$html_file" ]; then
            echo ">>> Check 3.2: HTML 기능 일관성 검증" >> "$log_file"

            # 설명 섹션이 추가되었는지 확인
            local description_exists=0
            if grep -q 'description\|설명\|explanation' "$html_file"; then
                description_exists=1
            fi

            if [ "$description_exists" -eq 1 ]; then
                # 인터랙티브 기능 확인
                if grep -q 'onclick\|addEventListener\|<script' "$html_file"; then
                    echo "OK: 설명과 인터랙티브 기능 일관성 확인" >> "$log_file"
                    passed_checks=$((passed_checks + 1))
                else
                    echo "WARN: 설명은 추가했으나 인터랙티브 기능 미확인" >> "$log_file"
                    warnings=$((warnings + 1))
                fi
            fi
        fi
    else
        echo "완료 선언 없음 (보수적 응답)" >> "$log_file"
    fi

    # 최종 결과
    echo "" >> "$log_file"
    echo "=== 최종 결과 ===" >> "$log_file"
    echo "Passed: $passed_checks" >> "$log_file"
    echo "Failed: $failed_checks" >> "$log_file"
    echo "Warnings: $warnings" >> "$log_file"

    if [ "$failed_checks" -gt 0 ]; then
        echo "결과: FAILED" >> "$log_file"
        echo "거짓 완료 보고 또는 불완전한 작업 감지" >&2
        cat "$log_file" >&2
        return 1
    fi

    echo "결과: PASSED" >> "$log_file"
    return 0
}

# 함수: 상태 조회
guard_get_status() {
    local task_id="$1"

    if [ -z "$task_id" ]; then
        # 모든 태스크 상태 출력
        echo "Guard State Directory: $GUARD_STATE_DIR"
        ls -la "$GUARD_STATE_DIR" 2>/dev/null || echo "No state files found"
    else
        # 특정 태스크 상태 출력
        local log_file="$GUARD_STATE_DIR/${task_id}.log"
        if [ -f "$log_file" ]; then
            cat "$log_file"
        else
            echo "No state found for task: $task_id"
        fi
    fi
}

# 함수: 레지스트리 상태 확인
guard_check_registry() {
    if [ ! -f "$IMPOSSIBLE_TASKS_REGISTRY" ]; then
        echo "ERROR: Registry not found: $IMPOSSIBLE_TASKS_REGISTRY" >&2
        return 1
    fi

    echo "Registry: $IMPOSSIBLE_TASKS_REGISTRY"
    jq '.impossibleTaskTypes | length' "$IMPOSSIBLE_TASKS_REGISTRY" 2>/dev/null && \
        echo "Impossible task types registered"

    return 0
}

# CLI 인터페이스
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    guard_init

    case "${1:-help}" in
        verify)
            # 사용: ./cluster-guard-cl-41697ce934383874.sh verify "task_id" "response_text" "output_file"
            shift
            guard_verify_completion "$@"
            ;;
        detect-impossible)
            # 사용: ./cluster-guard-cl-41697ce934383874.sh detect-impossible "response_text"
            shift
            guard_detect_impossible_task "$1"
            ;;
        status)
            # 사용: ./cluster-guard-cl-41697ce934383874.sh status [task_id]
            shift
            guard_get_status "$1"
            ;;
        check-registry)
            guard_check_registry
            ;;
        init)
            guard_init
            ;;
        help)
            cat <<'EOF'
usage: cluster-guard-cl-41697ce934383874.sh <command> [options]

Commands:
  verify <task_id> <response_text> <output_file> [html_file]
    검증 실행 — 완료 선언 전 호출

  detect-impossible <response_text>
    불가능한 작업 감지

  status [task_id]
    가드 상태 확인

  check-registry
    레지스트리 상태 확인

  init
    가드 초기화

  help
    이 메시지 출력

Examples:
  # 완료 선언 전 검증
  ./cluster-guard-cl-41697ce934383874.sh verify "task-001" "작업을 완료했습니다." "/tmp/output.txt"

  # 불가능한 작업 감지
  ./cluster-guard-cl-41697ce934383874.sh detect-impossible "웹 폼을 조작했습니다."

Exit codes:
  0 - 검증 통과
  1 - 검증 실패 (불완전한 작업, 불가능한 작업, 거짓 완료)
  2 - 오류 (설정 미싱)
EOF
            ;;
        *)
            echo "ERROR: Unknown command: $1" >&2
            exit 1
            ;;
    esac
fi

# 내보내기
export -f guard_init
export -f guard_detect_impossible_task
export -f guard_detect_completion_claim
export -f guard_verify_completion
export -f guard_get_status
export -f guard_check_registry
