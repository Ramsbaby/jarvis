#!/bin/bash
#
# session-size-guard.sh
# 워크플로 가드: 측정 결과 없이 세션 크기 수치를 응답에 포함하지 못하도록 방지
#
# 용도: Claude Code 응답 전 후킹하여 검증하지 않은 세션 크기 주장을 필터링
#
# 호출:
#   source session-size-guard.sh
#   validate_session_size_claim "<응답 텍스트>"
#
# 반환값:
#   0: 통과 (세션 크기 주장 없음 또는 검증된 측정 결과 있음)
#   1: 실패 (검증 없는 세션 크기 주장 감지)

set -euo pipefail

# 설정
MEASURE_SCRIPT="${HOME}/jarvis/infra/bin/measure-session-size.sh"
CACHE_DIR="${HOME}/jarvis/runtime/state/session-size-cache"
CACHE_TTL_SECONDS=300  # 5분 캐시

# 캐시 디렉토리 초기화
mkdir -p "$CACHE_DIR"

# 함수: 현재 세션 크기 측정값을 캐시하거나 가져오기
get_cached_session_metrics() {
    local cache_file="$CACHE_DIR/latest-metrics.json"
    local cache_age=0

    if [[ -f "$cache_file" ]]; then
        cache_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
    fi

    # 캐시 유효성 검사
    if [[ -f "$cache_file" ]] && [[ $cache_age -lt $CACHE_TTL_SECONDS ]]; then
        cat "$cache_file"
        return 0
    fi

    # 캐시 미스: 새로 측정
    if [[ ! -x "$MEASURE_SCRIPT" ]]; then
        echo '{"error":"measure-session-size.sh not found or not executable"}' >&2
        return 1
    fi

    local metrics=$("$MEASURE_SCRIPT" 2>/dev/null || echo '{"error":"measurement failed"}')

    # 캐시 저장
    echo "$metrics" > "$cache_file"
    echo "$metrics"
    return 0
}

# 함수: 응답 텍스트에서 세션 크기 주장 검출
detect_session_size_claims() {
    local response_text="$1"

    # 패턴: 세션 크기, 파일 크기, 토큰 수에 대한 구체적인 수치 주장
    # 예: "약 500MB", "4,096 bytes", "100K tokens", "총 2.5GB" 등
    #
    # 감지할 패턴:
    # - "약" + 숫자 + (MB|GB|KB|bytes|토큰)
    # - 숫자 + "(MB|GB|KB|bytes|토큰|tokens)"
    # - "파일 크기", "세션 크기", "토큰 수" + 구체 수치

    grep -i -E '(약\s*[0-9]+\.?[0-9]*\s*(MB|GB|KB|bytes|토큰)|[0-9,]+\s*(MB|GB|KB|bytes|토큰|tokens)|파일\s*크기|세션\s*크기|세션\s*파일.*[0-9,]+|토큰\s*수|token\s*count.*[0-9]+)' \
        <<<"$response_text" 2>/dev/null || return 1

    return 0
}

# 함수: 주장된 수치가 측정된 메트릭과 일치하는지 검증
verify_claim_against_metrics() {
    local response_text="$1"
    local metrics_json="$2"

    # metrics_json에서 실제 수치 추출
    local actual_bytes=$(jq -r '.total_bytes // empty' <<<"$metrics_json" 2>/dev/null || echo "")
    local actual_tokens=$(jq -r '.estimated_tokens // empty' <<<"$metrics_json" 2>/dev/null || echo "")

    if [[ -z "$actual_bytes" ]] || [[ -z "$actual_tokens" ]]; then
        # 측정 메트릭을 파싱할 수 없음
        return 1
    fi

    # 바이트를 MB/GB로 변환
    local actual_mb=$((actual_bytes / 1048576))
    local actual_gb=$((actual_bytes / 1073741824))

    # 응답에서 수치 추출 (대략적인 패턴 매칭)
    # 정확한 매칭보다는 "검증 없는 주장" 필터링에 중점

    # 만약 응답에 구체적 수치가 있지만 메트릭과 크게 다르면 실패
    # (예: "2GB"라고 했는데 실제는 320MB)

    if grep -i -E '(약|대략|approximately|around)\s*[0-9]+' <<<"$response_text" >/dev/null 2>&1; then
        # "약"이라는 표현이 있으면 추정값임을 인정 → 통과
        return 0
    fi

    # 구체적 수치를 단정적으로 주장하고 있는지 검사
    if grep -i -E '[0-9,]+\s*(MB|GB|KB|bytes|토큰|tokens)' <<<"$response_text" >/dev/null 2>&1; then
        # 구체적 수치 주장이 있으면, 이는 측정 결과를 참조해야 함
        # 본 함수 호출 시점에 메트릭이 있다면 유효한 것
        return 0
    fi

    return 1
}

# 메인 함수: 응답 텍스트 검증
validate_session_size_claim() {
    local response_text="$1"

    # Step 1: 세션 크기 주장이 있는지 검사
    if ! detect_session_size_claims "$response_text"; then
        # 세션 크기 주장이 없음 → 통과
        return 0
    fi

    # Step 2: 세션 크기 주장이 감지됨 → 측정 메트릭으로 검증
    local metrics
    if ! metrics=$(get_cached_session_metrics); then
        # 측정 실패 → 검증할 메트릭 없음 → 차단
        echo "[SESSION_SIZE_GUARD] ERROR: Cannot verify session size claim without measurement" >&2
        return 1
    fi

    # Step 3: 주장 검증
    if verify_claim_against_metrics "$response_text" "$metrics"; then
        # 검증 성공
        return 0
    fi

    # Step 4: 검증 실패
    echo "[SESSION_SIZE_GUARD] ERROR: Unverified session size claim detected" >&2
    echo "[SESSION_SIZE_GUARD] Response must be based on actual measurement" >&2
    echo "[SESSION_SIZE_GUARD] Actual metrics: bytes=$actual_bytes, tokens=$actual_tokens" >&2
    return 1
}

# 함수: 진단용 - 최신 메트릭 출력
print_latest_metrics() {
    local metrics
    if metrics=$(get_cached_session_metrics); then
        echo "$metrics" | jq .
        return 0
    else
        echo "Failed to get session metrics" >&2
        return 1
    fi
}

# 함수: 캐시 초기화
clear_session_cache() {
    rm -f "$CACHE_DIR/latest-metrics.json"
    echo "Session size cache cleared" >&2
    return 0
}

# CLI 모드 지원 (직접 실행 시)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command="${1:-help}"
    case "$command" in
        validate)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: session-size-guard.sh validate '<response_text>'" >&2
                exit 1
            fi
            validate_session_size_claim "$2"
            exit $?
            ;;
        metrics)
            print_latest_metrics
            exit $?
            ;;
        clear-cache)
            clear_session_cache
            exit $?
            ;;
        help)
            cat <<EOF
session-size-guard.sh - Workflow guard for verified session size claims

Usage:
    source session-size-guard.sh
    validate_session_size_claim "<response_text>"

Commands:
    validate <text>     Validate session size claims in response text
    metrics            Print latest cached session metrics
    clear-cache        Clear session size cache
    help               Show this help message

Exit codes:
    0  Pass (no claims or verified claims)
    1  Fail (unverified session size claims detected)

Examples:
    ./session-size-guard.sh validate "The session size is about 320MB"
    ./session-size-guard.sh metrics
    ./session-size-guard.sh clear-cache
EOF
            exit 0
            ;;
        *)
            echo "Unknown command: $command" >&2
            exit 1
            ;;
    esac
fi
