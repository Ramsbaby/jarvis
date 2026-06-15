#!/usr/bin/env bash
# pre-submit-guard.sh — 완료 선언 직전 실행 검증 가드
#
# 클러스터: cl-b267f5e68d51853c (반복 실수: 실행 환경 제약 미고려 후 코드 정확성 단언)
#
# 목적:
#   완료 단언 메시지에 실행 로그·출력 증거가 첨부되지 않으면 제출을 블로킹한다.
#   "로직 트레이싱만으로 완료 단언" / "실행 0회 머릿속 트레이스만 수행" 패턴을 차단.
#
# 사용법:
#   source pre-submit-guard.sh
#   pre_submit_check "<완료 선언 텍스트>" [실행로그파일]
#     → exit 0: 검증 통과 (실행 증거 있음)
#     → exit 1: 블로킹 (실행 증거 없음 또는 단언 패턴 감지)
#
#   독립 실행:
#   ./pre-submit-guard.sh --check "<텍스트>" [로그파일]
#   ./pre-submit-guard.sh --test   (자기 진단)
#
# 기존 동작 파괴 금지:
#   - source 하지 않고 실행 시, --test/--check 없이 호출 시 exit 0으로 안전 종료
#   - ask-claude.sh 등 크론 태스크 러너는 이 파일을 직접 source하지 않으면 영향 없음

set -euo pipefail

# ─── 상수 ────────────────────────────────────────────────────────────────────
readonly GUARD_VERSION="1.0.0"
readonly GUARD_CLUSTER="cl-b267f5e68d51853c"
readonly GUARD_LOG_DIR="${HOME}/jarvis/runtime/logs"
readonly GUARD_LOG_FILE="${GUARD_LOG_DIR}/pre-submit-guard.jsonl"
readonly GUARD_STATE_DIR="${HOME}/jarvis/runtime/state"

# ─── 완료 단언 감지 패턴 ──────────────────────────────────────────────────────
# 실행 검증 없이 완료를 단언하는 전형적인 표현들
_COMPLETION_ASSERTION_PATTERNS=(
    # 한국어 완료 단언
    "완료되었습니다"
    "완료했습니다"
    "정상적으로 작동"
    "올바르게 작동"
    "문제없이 실행"
    "성공적으로 완료"
    "모두 정상"
    "잘 동작"
    "정상 동작"
    "코드가 맞습니다"
    "로직이 올바릅니다"
    "확인되었습니다"
    "검증되었습니다"
    # 영어 완료 단언
    "is complete"
    "is working"
    "should work"
    "will work"
    "is correct"
    "is fixed"
    "has been implemented"
    "successfully completed"
    "works correctly"
    "is now ready"
)

# 실행 증거로 인정하는 패턴
_EVIDENCE_PATTERNS=(
    # 실행 출력 마커
    "\\$"          # 쉘 프롬프트
    "exit code"
    "exit 0"
    "exit 1"
    "stdout"
    "stderr"
    "출력:"
    "결과:"
    "실행 결과"
    "테스트 결과"
    "로그:"
    # 테스트/검증 증거
    "PASS"
    "FAIL"
    "passed"
    "failed"
    "✓"
    "✗"
    "bash -n"
    "shellcheck"
    "pytest"
    "npm test"
    "go test"
    # 실행 로그 패턴
    "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"  # 타임스탬프
    "ERROR:"
    "INFO:"
    "WARN:"
    # 파일/디렉토리 존재 확인
    "-rw"
    "-rwx"
    "total [0-9]"
)

# ─── 유틸 함수 ───────────────────────────────────────────────────────────────
_guard_log() {
    local level="$1"
    local message="$2"
    local extra="${3:-}"

    mkdir -p "$GUARD_LOG_DIR"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local entry
    entry=$(printf '{"ts":"%s","level":"%s","guard":"pre-submit","cluster":"%s","msg":"%s"%s}\n' \
        "$ts" "$level" "$GUARD_CLUSTER" \
        "$(printf '%s' "$message" | sed 's/"/\\"/g')" \
        "${extra:+,"extra":"$(printf '%s' "$extra" | sed 's/"/\\"/g')"}")
    printf '%s\n' "$entry" >> "$GUARD_LOG_FILE" 2>/dev/null || true
}

_has_completion_assertion() {
    local text="$1"
    for pattern in "${_COMPLETION_ASSERTION_PATTERNS[@]}"; do
        if printf '%s' "$text" | grep -qi "$pattern" 2>/dev/null; then
            printf '%s' "$pattern"
            return 0
        fi
    done
    return 1
}

_has_execution_evidence() {
    local text="$1"
    local log_file="${2:-}"

    # 로그 파일이 제공되고 비어있지 않으면 증거로 인정
    if [[ -n "$log_file" && -f "$log_file" && -s "$log_file" ]]; then
        return 0
    fi

    # 텍스트 내 증거 패턴 검색 (macOS/GNU 호환: grep -E)
    for pattern in "${_EVIDENCE_PATTERNS[@]}"; do
        if printf '%s' "$text" | grep -qE "$pattern" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ─── 메인 검사 함수 ───────────────────────────────────────────────────────────
pre_submit_check() {
    local text="${1:-}"
    local log_file="${2:-}"

    if [[ -z "$text" ]]; then
        # 텍스트 없으면 통과 (가드 자체가 실행을 막으면 안 됨)
        _guard_log "skip" "empty text, skipping guard"
        return 0
    fi

    # 1단계: 완료 단언 패턴 감지
    local matched_assertion
    if matched_assertion=$(_has_completion_assertion "$text"); then
        # 완료 단언 감지 → 실행 증거 확인 필요
        if _has_execution_evidence "$text" "$log_file"; then
            # 증거 있음 → 통과
            _guard_log "pass" "completion assertion with evidence" "assertion=$matched_assertion"
            printf '[pre-submit-guard] PASS: 완료 단언 + 실행 증거 확인됨 (%s)\n' "$matched_assertion" >&2
            return 0
        else
            # 증거 없음 → 블로킹
            _guard_log "block" "completion assertion WITHOUT evidence" "assertion=$matched_assertion"
            printf '\n[pre-submit-guard] BLOCKED (cluster=%s)\n' "$GUARD_CLUSTER" >&2
            printf '  감지된 완료 단언: "%s"\n' "$matched_assertion" >&2
            printf '  실행 증거(로그/출력)가 첨부되지 않았습니다.\n' >&2
            printf '  완료를 주장하려면 다음 중 하나를 포함하세요:\n' >&2
            printf '    - 실제 실행 출력 (stdout/stderr)\n' >&2
            printf '    - 테스트 결과 (PASS/FAIL, exit code)\n' >&2
            printf '    - 실행 로그 파일 경로\n' >&2
            printf '    - 타임스탬프가 있는 실행 기록\n' >&2
            printf '  Iron Law 6: 실행 없는 완료 단언 금지\n' >&2
            printf '\n' >&2
            return 1
        fi
    else
        # 완료 단언 없음 → 통과 (일반 진행 중 메시지)
        _guard_log "pass" "no completion assertion detected"
        return 0
    fi
}

# ─── 자기 진단 (--test) ───────────────────────────────────────────────────────
_run_self_test() {
    local pass=0
    local fail=0

    printf '[pre-submit-guard] 자기 진단 시작 (v%s, cluster=%s)\n' "$GUARD_VERSION" "$GUARD_CLUSTER"
    printf '─────────────────────────────────────────────────────────\n'

    # T1: 완료 단언 + 증거 없음 → exit 1이어야 함
    local t1_text="작업이 완료되었습니다. 코드를 수정했습니다."
    if ! pre_submit_check "$t1_text" 2>/dev/null; then
        printf '[T1] PASS: 증거 없는 완료 단언 → exit 1 확인\n'
        (( pass++ )) || true
    else
        printf '[T1] FAIL: 증거 없는 완료 단언이 통과되었음 (exit 0 반환)\n'
        (( fail++ )) || true
    fi

    # T2: 완료 단언 + 실행 출력 있음 → exit 0이어야 함
    local t2_text="작업이 완료되었습니다.
실행 결과:
$ bash script.sh
exit code: 0
stdout: OK"
    if pre_submit_check "$t2_text" 2>/dev/null; then
        printf '[T2] PASS: 증거 있는 완료 단언 → exit 0 확인\n'
        (( pass++ )) || true
    else
        printf '[T2] FAIL: 증거 있는 완료 단언이 블로킹됨\n'
        (( fail++ )) || true
    fi

    # T3: 완료 단언 + 로그 파일 → exit 0이어야 함
    local t3_log
    t3_log=$(mktemp)
    printf '2026-01-01T00:00:00Z INFO task completed\n' > "$t3_log"
    local t3_text="성공적으로 완료했습니다."
    if pre_submit_check "$t3_text" "$t3_log" 2>/dev/null; then
        printf '[T3] PASS: 로그 파일 첨부 완료 단언 → exit 0 확인\n'
        (( pass++ )) || true
    else
        printf '[T3] FAIL: 로그 파일 첨부 완료 단언이 블로킹됨\n'
        (( fail++ )) || true
    fi
    rm -f "$t3_log"

    # T4: 완료 단언 없는 일반 메시지 → exit 0이어야 함
    local t4_text="파일을 수정하고 있습니다. 다음 단계를 진행합니다."
    if pre_submit_check "$t4_text" 2>/dev/null; then
        printf '[T4] PASS: 완료 단언 없는 메시지 → exit 0 확인\n'
        (( pass++ )) || true
    else
        printf '[T4] FAIL: 완료 단언 없는 메시지가 블로킹됨\n'
        (( fail++ )) || true
    fi

    # T5: 빈 텍스트 → exit 0이어야 함 (안전 통과)
    if pre_submit_check "" 2>/dev/null; then
        printf '[T5] PASS: 빈 텍스트 → exit 0 (안전 통과) 확인\n'
        (( pass++ )) || true
    else
        printf '[T5] FAIL: 빈 텍스트가 블로킹됨\n'
        (( fail++ )) || true
    fi

    printf '─────────────────────────────────────────────────────────\n'
    printf '결과: %d/%d 통과\n' "$pass" "$(( pass + fail ))"

    if (( fail > 0 )); then
        printf '[pre-submit-guard] 자기 진단 실패\n'
        return 1
    else
        printf '[pre-submit-guard] 자기 진단 통과\n'
        return 0
    fi
}

# ─── 독립 실행 엔트리포인트 ──────────────────────────────────────────────────
# source로 로드할 때는 아래 블록이 실행되지 않는다.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --test)
            _run_self_test
            exit $?
            ;;
        --check)
            shift
            pre_submit_check "${1:-}" "${2:-}"
            exit $?
            ;;
        --version)
            printf 'pre-submit-guard v%s (cluster=%s)\n' "$GUARD_VERSION" "$GUARD_CLUSTER"
            exit 0
            ;;
        "")
            # 인자 없이 실행 → 안전 통과 (기존 파이프라인 파괴 방지)
            exit 0
            ;;
        *)
            printf 'Usage: %s [--test|--check "<text>" [logfile]|--version]\n' "$(basename "$0")" >&2
            exit 0
            ;;
    esac
fi
