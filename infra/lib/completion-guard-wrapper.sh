#!/usr/bin/env bash
# completion-guard-wrapper.sh — 완료 검증 가드를 ask-claude.sh 워크플로우에 통합
#
# 목적:
#   ask-claude.sh의 exit code가 0이어도, 실제 검증(PDF, 응답 본문, 중복)을 거친 후에만
#   최종 success 판정. 검증 실패 시 exit 1로 반환.
#
# 사용 시나리오:
#   1. ask-claude.sh가 반환: exit 0 (실행 완료)
#   2. 하지만 PDF 페이지 수 미검증, 업로드 응답 본문 미확인, 중복 파일 감지 안 함
#   3. completion-guard-wrapper.sh가 이를 모두 검증 후 진짜 성공 여부 판정
#
# 통합 방법:
#   # 기존: ask-claude.sh TASK "..." || exit $?
#   # 개선: ask-claude.sh TASK "..." && completion-guard-wrapper.sh check-completion --task $TASK --pdf $PDF_PATH
#
# 성공 기준:
#   - 모든 검증(PDF, 응답, 중복)을 통과해야만 exit 0
#   - 검증 실패 시 exit 1로 강제 실패
#   - 로그에 검증 결과 상세 기록

set -euo pipefail

JARVIS_HOME="${HOME}/.jarvis"
GUARD_SCRIPT="${JARVIS_HOME}/infra/guards/completion-validation-guard.sh"
WRAPPER_LOG="${JARVIS_HOME}/runtime/logs/completion-guard-wrapper.jsonl"

# ── 로그 디렉토리 초기화 ────────────────────────────────────────────────────
_ensure_log_dir() {
    mkdir -p "$(dirname "$WRAPPER_LOG")" 2>/dev/null || true
}
_ensure_log_dir

# ── JSON 로깅 ────────────────────────────────────────────────────────────────
_log_wrapper() {
    local task_id="$1"
    local check_type="$2"
    local result="$3"  # pass|fail
    local details="${4:-}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local log_entry="{\"ts\":\"$timestamp\",\"task\":\"$task_id\",\"check\":\"$check_type\",\"result\":\"$result\""
    if [[ -n "$details" ]]; then
        log_entry="$log_entry,\"details\":\"$details\""
    fi
    log_entry="$log_entry}"

    echo "$log_entry" >> "$WRAPPER_LOG" 2>/dev/null || true
}

# ── 검증 실행 (guard script를 통해) ────────────────────────────────────────
_run_guard_check() {
    local check_type="$1"
    local pdf_file="${2:-}"
    local response="${3:-}"
    local file_to_check="${4:-}"

    local result=0
    local output=""

    case "$check_type" in
        pdf)
            if [[ -n "$pdf_file" ]]; then
                output=$("$GUARD_SCRIPT" validate-pdf "$pdf_file" 2>&1 || true)
                [[ $? -eq 0 ]] && result=0 || result=1
            fi
            ;;
        response)
            if [[ -n "$response" ]]; then
                output=$("$GUARD_SCRIPT" validate-upload --response "$response" 2>&1 || true)
                [[ $? -eq 0 ]] && result=0 || result=1
            fi
            ;;
        duplicate)
            if [[ -n "$file_to_check" ]]; then
                output=$("$GUARD_SCRIPT" check-duplicate --file "$file_to_check" 2>&1 || true)
                [[ $? -eq 0 ]] && result=0 || result=1
            fi
            ;;
    esac

    echo "$output"
    return $result
}

# ── 메인: 완료 검증 체크 ────────────────────────────────────────────────────
check_completion() {
    local task_id="${1:-unknown}"
    local pdf_file="${2:-}"
    local upload_response="${3:-}"
    local file_to_check="${4:-}"

    local all_pass=1
    local failed_checks=()

    echo "=== Completion Validation Guard ===" >&2
    echo "Task: $task_id" >&2
    echo "PDF: $pdf_file" >&2
    echo "Response provided: $([ -n "$upload_response" ] && echo 'yes' || echo 'no')" >&2
    echo "File to check: $file_to_check" >&2

    # [1] PDF 검증
    if [[ -n "$pdf_file" ]]; then
        echo "Checking PDF..." >&2
        if _run_guard_check "pdf" "$pdf_file" 2>/dev/null >/dev/null; then
            echo "  ✓ PDF validation PASSED" >&2
            _log_wrapper "$task_id" "pdf" "pass"
        else
            echo "  ✗ PDF validation FAILED" >&2
            _log_wrapper "$task_id" "pdf" "fail"
            failed_checks+=("pdf")
            all_pass=0
        fi
    fi

    # [2] 응답 본문 검증
    if [[ -n "$upload_response" ]]; then
        echo "Checking upload response..." >&2
        if _run_guard_check "response" "" "$upload_response" 2>/dev/null >/dev/null; then
            echo "  ✓ Response validation PASSED" >&2
            _log_wrapper "$task_id" "response" "pass"
        else
            echo "  ✗ Response validation FAILED" >&2
            _log_wrapper "$task_id" "response" "fail"
            failed_checks+=("response")
            all_pass=0
        fi
    fi

    # [3] 중복 파일 검사
    if [[ -n "$file_to_check" ]]; then
        echo "Checking for duplicates..." >&2
        if _run_guard_check "duplicate" "" "" "$file_to_check" 2>/dev/null >/dev/null; then
            echo "  ✓ Duplicate check PASSED" >&2
            _log_wrapper "$task_id" "duplicate" "pass"
        else
            echo "  ✗ Duplicate check FAILED" >&2
            _log_wrapper "$task_id" "duplicate" "fail"
            failed_checks+=("duplicate")
            all_pass=0
        fi
    fi

    # 최종 판정
    if [[ $all_pass -eq 1 ]]; then
        echo "=== All validations PASSED ===" >&2
        return 0
    else
        echo "=== Validation FAILED: ${failed_checks[*]} ===" >&2
        return 1
    fi
}

# ── 메인 CLI ────────────────────────────────────────────────────────────────
main() {
    local command="${1:-}"

    case "$command" in
        check-completion)
            local task_id=""
            local pdf_file=""
            local response=""
            local file_to_check=""

            while [[ $# -gt 1 ]]; do
                case "$2" in
                    --task)
                        task_id="$3"
                        shift 2
                        ;;
                    --pdf)
                        pdf_file="$3"
                        shift 2
                        ;;
                    --response)
                        response="$3"
                        shift 2
                        ;;
                    --file)
                        file_to_check="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            check_completion "$task_id" "$pdf_file" "$response" "$file_to_check"
            ;;

        *)
            echo "Usage: $0 check-completion --task <task_id> [--pdf <file>] [--response <text>] [--file <file>]" >&2
            exit 1
            ;;
    esac
}

main "$@"
