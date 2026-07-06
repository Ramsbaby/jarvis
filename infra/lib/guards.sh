#!/usr/bin/env bash
# guards.sh — 반복 실수 클러스터 cl-a1a431b0e672e736 방어 가드 함수 라이브러리
#
# 클러스터 ID  : cl-a1a431b0e672e736 (최근 7일 재발 17건)
# 반복 패턴   : 경로 미확인 후 단언 / 프로세스 상태 미반영 / 파일 미확인 후 추정
# 목적        : pre-action 검증으로 단언 블록 진입 자체를 막는 런타임 가드
#
# 사용법:
#   source "${BOT_HOME}/lib/guards.sh"
#   assert_path_exists "/some/path" "descriptive label" || exit 1
#   assert_process_state "process-name" "running" "error label" || return 1
#   assert_file_readable "/path/file" "usage context" || exit 1
#
# 모든 함수는 실패 시 exit 1 반환 (호출 스크립트가 set -e 사용 시 자동 중단)
# exit 1을 호출자가 처리하고 싶으면 명시적으로 || handling_code 사용

set -euo pipefail

# ═════════════════════════════════════════════════════════════════════════════════
# [1] assert_path_exists — 경로 존재 여부 검증 (파일/디렉토리 모두)
# ═════════════════════════════════════════════════════════════════════════════════
#
# 클러스터 패턴: RAG 위치를 ~/jarvis/runtime/data/lancedb라고 가정
#              경로 미확인 후 하드코딩 단언
#
# 사용 예시:
#   assert_path_exists "$HOME/jarvis/runtime/data/lancedb" "RAG database directory" || exit 1
#   assert_path_exists "/tmp/work/$TASK_ID" "working directory" || return 1
#
# 반환값:
#   0 = 경로 존재
#   1 = 경로 없음 (set -e 하에서 자동 종료)

assert_path_exists() {
    local path="$1"
    local label="${2:-path}"

    if [[ -z "$path" ]]; then
        printf '[guard] ERROR: assert_path_exists called with empty path (label=%s)\n' "$label" >&2
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        printf '[guard] FAIL: assert_path_exists — %s does not exist (label=%s)\n' "$path" "$label" >&2
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [2] assert_file_readable — 파일 가독성 검증
# ═════════════════════════════════════════════════════════════════════════════════
#
# 클러스터 패턴: 파일/이미지 미확인 후 추정 제시
#              사용자 정정 후 '확인했어요' 역전 표현
#
# 사용 예시:
#   assert_file_readable "$CONTEXT_FILE" "task context" || exit 1
#   assert_file_readable "/tmp/output.json" "test output" || {
#       echo "WARN: test output not yet available" >&2
#       return 0  # non-blocking 처리
#   }
#
# 반환값:
#   0 = 파일 존재 && 읽기 가능
#   1 = 파일 없음 또는 읽기 불가 (set -e 하에서 자동 종료)

assert_file_readable() {
    local file="$1"
    local label="${2:-file}"

    if [[ -z "$file" ]]; then
        printf '[guard] ERROR: assert_file_readable called with empty path (label=%s)\n' "$label" >&2
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        printf '[guard] FAIL: assert_file_readable — file does not exist: %s (label=%s)\n' "$file" "$label" >&2
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        printf '[guard] FAIL: assert_file_readable — file not readable: %s (label=%s, perms=%s)\n' \
            "$file" "$label" "$(stat -f "%A" "$file" 2>/dev/null || echo 'unknown')" >&2
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [3] assert_directory_exists — 디렉토리 존재 및 쓰기 가능 검증
# ═════════════════════════════════════════════════════════════════════════════════
#
# 클러스터 패턴: 경로 미확인 후 단언 (디렉토리 특수화)
#
# 사용 예시:
#   assert_directory_exists "$RESULTS_DIR" "results directory" || exit 1
#   assert_directory_exists "$LOG_DIR" "log directory" -w || exit 1  # 쓰기 가능 필수
#
# 반환값:
#   0 = 디렉토리 존재 (+ 쓰기 가능 옵션 확인)
#   1 = 디렉토리 없음 또는 쓰기 불가 (set -e 하에서 자동 종료)

assert_directory_exists() {
    local dir="$1"
    local label="${2:-directory}"
    local check_writable="${3:-}"

    if [[ -z "$dir" ]]; then
        printf '[guard] ERROR: assert_directory_exists called with empty path (label=%s)\n' "$label" >&2
        return 1
    fi

    if [[ ! -d "$dir" ]]; then
        printf '[guard] FAIL: assert_directory_exists — directory does not exist: %s (label=%s)\n' "$dir" "$label" >&2
        return 1
    fi

    if [[ "$check_writable" == "-w" && ! -w "$dir" ]]; then
        printf '[guard] FAIL: assert_directory_exists — directory not writable: %s (label=%s)\n' "$dir" "$label" >&2
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [4] assert_process_state — 프로세스 상태 검증 (프로세스 미반영 디스크 여유량 초기 단언 방지)
# ═════════════════════════════════════════════════════════════════════════════════
#
# 클러스터 패턴: 프로세스 상태 미반영 디스크 여유량 초기 단언
#              예: "orchestrator 실행 중" 가정 후 상태 미확인
#
# 사용 예시:
#   assert_process_state "orchestrator" "running" "system state check" || exit 1
#   assert_process_state "redis" "not-running" "cleanup verification" || return 0  # non-blocking
#   assert_process_state "claude" "any" "version check" || exit 2  # 존재 여부만 확인
#
# 상태 옵션:
#   "running"     = 프로세스가 실행 중이어야 함 (pgrep 성공)
#   "not-running" = 프로세스가 실행 중이 아니어야 함 (pgrep 실패)
#   "any"         = 프로세스 실행 여부는 무관 (항상 성공, 진단 용도)
#
# 반환값:
#   0 = 프로세스 상태 기대값과 일치
#   1 = 프로세스 상태 기대값과 불일치 (set -e 하에서 자동 종료)

assert_process_state() {
    local process_name="$1"
    local expected_state="${2:-running}"
    local label="${3:-process state}"

    if [[ -z "$process_name" ]]; then
        printf '[guard] ERROR: assert_process_state called with empty process name (label=%s)\n' "$label" >&2
        return 1
    fi

    # pgrep 실행 후 종료 코드 캡처 (set -e 피하기)
    local pgrep_exit=0
    pgrep -f "$process_name" >/dev/null 2>&1 || pgrep_exit=$?

    # pgrep 성공 (0) = 프로세스 실행 중
    # pgrep 실패 (1) = 프로세스 없음
    local is_running=0
    [[ $pgrep_exit -eq 0 ]] && is_running=1

    case "$expected_state" in
        running)
            if [[ $is_running -eq 0 ]]; then
                printf '[guard] FAIL: assert_process_state — process not running: %s (label=%s)\n' \
                    "$process_name" "$label" >&2
                return 1
            fi
            return 0
            ;;
        not-running)
            if [[ $is_running -eq 1 ]]; then
                printf '[guard] FAIL: assert_process_state — process still running: %s (label=%s)\n' \
                    "$process_name" "$label" >&2
                return 1
            fi
            return 0
            ;;
        any)
            # 진단 목적: 실행 여부만 표시, 항상 성공
            if [[ $is_running -eq 1 ]]; then
                printf '[guard] INFO: assert_process_state — process running: %s (label=%s)\n' \
                    "$process_name" "$label" >&2
            else
                printf '[guard] INFO: assert_process_state — process not running: %s (label=%s)\n' \
                    "$process_name" "$label" >&2
            fi
            return 0
            ;;
        *)
            printf '[guard] ERROR: assert_process_state — unknown state: %s (label=%s)\n' \
                "$expected_state" "$label" >&2
            return 1
            ;;
    esac
}

# ═════════════════════════════════════════════════════════════════════════════════
# [5] assert_disk_space — 디스크 여유 공간 검증 (>=N GB)
# ═════════════════════════════════════════════════════════════════════════════════
#
# 클러스터 패턴: 프로세스 상태 미반영 디스크 여유량 초기 단언
#
# 사용 예시:
#   assert_disk_space "$HOME" 5 "user home" || exit 1  # 5GB 이상 필요
#   assert_disk_space "/tmp" 1 "tmp directory" || return 0  # non-blocking
#   assert_disk_space "." 10 "current directory" || { echo "cleanup needed" >&2; return 1; }
#
# 반환값:
#   0 = 디스크 여유 공간이 요구값 이상
#   1 = 디스크 여유 공간이 요구값 미만 (set -e 하에서 자동 종료)

assert_disk_space() {
    local path="${1:-.}"
    local min_gb="${2:-5}"
    local label="${3:-disk space}"

    if [[ -z "$path" ]]; then
        printf '[guard] ERROR: assert_disk_space called with empty path (label=%s)\n' "$label" >&2
        return 1
    fi

    if ! [[ "$path" =~ ^/ ]]; then
        path="$(cd "$path" 2>/dev/null && pwd)" || {
            printf '[guard] ERROR: assert_disk_space — path not absolute: %s (label=%s)\n' "$1" "$label" >&2
            return 1
        }
    fi

    # macOS: df -k 이용, Linux 호환성도 유지
    local available_kb=0
    if command -v df >/dev/null 2>&1; then
        available_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    else
        printf '[guard] ERROR: assert_disk_space — df command not available (label=%s)\n' "$label" >&2
        return 1
    fi

    local available_gb=$(( available_kb / 1024 / 1024 ))
    if (( available_gb < min_gb )); then
        printf '[guard] FAIL: assert_disk_space — insufficient space: %dGB available, need %dGB (path=%s, label=%s)\n' \
            "$available_gb" "$min_gb" "$path" "$label" >&2
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [6] assert_command_exists — 명령 가용성 검증
# ═════════════════════════════════════════════════════════════════════════════════
#
# 클러스터 패턴: 외부 명령 미확인 후 단언 (jq, python3 등)
#
# 사용 예시:
#   assert_command_exists "jq" "JSON processing" || exit 1
#   assert_command_exists "python3" || exit 1
#
# 반환값:
#   0 = 명령 존재 및 실행 가능
#   1 = 명령 없음 또는 실행 불가 (set -e 하에서 자동 종료)

assert_command_exists() {
    local cmd="$1"
    local label="${2:-command}"

    if [[ -z "$cmd" ]]; then
        printf '[guard] ERROR: assert_command_exists called with empty command (label=%s)\n' "$label" >&2
        return 1
    fi

    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '[guard] FAIL: assert_command_exists — command not found in PATH: %s (label=%s, PATH=%s)\n' \
            "$cmd" "$label" "${PATH:-<empty>}" >&2
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [7] assert_variable_set — 환경 변수 설정 검증
# ═════════════════════════════════════════════════════════════════════════════════
#
# 클러스터 패턴: 환경 변수 미확인 후 단언 (BOT_HOME, JARVIS_HOME 등)
#
# 사용 예시:
#   assert_variable_set "BOT_HOME" "bot home directory" || exit 1
#   assert_variable_set "TASK_ID" || exit 1
#
# 반환값:
#   0 = 변수 설정됨 (empty 문자열도 설정으로 간주)
#   1 = 변수 미설정 (set -e 하에서 자동 종료)

assert_variable_set() {
    local var_name="$1"
    local label="${2:-variable}"

    if [[ -z "$var_name" ]]; then
        printf '[guard] ERROR: assert_variable_set called with empty variable name (label=%s)\n' "$label" >&2
        return 1
    fi

    # 변수 설정 여부 확인: eval을 사용한 간접 참조
    # ${!var_name+x} 문법은 변수가 설정되면 문자열 반환, 미설정이면 빈 문자열
    local is_set=0
    if [[ -n "${!var_name+x}" ]] 2>/dev/null; then
        is_set=1
    fi

    if [[ $is_set -eq 0 ]]; then
        printf '[guard] FAIL: assert_variable_set — variable not set: %s (label=%s)\n' \
            "$var_name" "$label" >&2
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# Diagnostic helper: 가드 함수 자체 검증 (테스트 용)
# ═════════════════════════════════════════════════════════════════════════════════

guard_self_test() {
    local test_dir="/tmp/guard-test-$$"
    local test_file="$test_dir/test.txt"

    mkdir -p "$test_dir"
    echo "test" > "$test_file"

    printf '[guard-test] Running self-tests...\n' >&2

    # Test 1: assert_path_exists (success)
    if assert_path_exists "$test_dir" "test-dir"; then
        printf '[guard-test] ✓ assert_path_exists (existing)\n' >&2
    else
        printf '[guard-test] ✗ assert_path_exists (existing) FAILED\n' >&2
    fi

    # Test 2: assert_path_exists (failure)
    if ! assert_path_exists "/nonexistent/path" "nonexistent" 2>/dev/null; then
        printf '[guard-test] ✓ assert_path_exists (nonexistent)\n' >&2
    else
        printf '[guard-test] ✗ assert_path_exists (nonexistent) FAILED\n' >&2
    fi

    # Test 3: assert_file_readable (success)
    if assert_file_readable "$test_file" "test-file"; then
        printf '[guard-test] ✓ assert_file_readable (readable)\n' >&2
    else
        printf '[guard-test] ✗ assert_file_readable (readable) FAILED\n' >&2
    fi

    # Test 4: assert_directory_exists (success)
    if assert_directory_exists "$test_dir" "test-dir"; then
        printf '[guard-test] ✓ assert_directory_exists (exists)\n' >&2
    else
        printf '[guard-test] ✗ assert_directory_exists (exists) FAILED\n' >&2
    fi

    # Test 5: assert_command_exists (success)
    if assert_command_exists "bash" "bash"; then
        printf '[guard-test] ✓ assert_command_exists (bash)\n' >&2
    else
        printf '[guard-test] ✗ assert_command_exists (bash) FAILED\n' >&2
    fi

    # Test 6: assert_command_exists (failure)
    if ! assert_command_exists "nonexistent-command-xyz" "nonexistent" 2>/dev/null; then
        printf '[guard-test] ✓ assert_command_exists (nonexistent)\n' >&2
    else
        printf '[guard-test] ✗ assert_command_exists (nonexistent) FAILED\n' >&2
    fi

    # Cleanup
    rm -rf "$test_dir"

    printf '[guard-test] Self-tests complete.\n' >&2
}

# ═════════════════════════════════════════════════════════════════════════════════
# Export all guard functions
# ═════════════════════════════════════════════════════════════════════════════════

export -f assert_path_exists
export -f assert_file_readable
export -f assert_directory_exists
export -f assert_process_state
export -f assert_disk_space
export -f assert_command_exists
export -f assert_variable_set
export -f guard_self_test
