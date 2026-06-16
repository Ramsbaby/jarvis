#!/usr/bin/env bash
# validate-watchdog-thresholds.sh
# 감시기 임계값 검증 스크립트 — 클러스터 cl-c334ba50fb007425 가드
#
# 목적: watchdog.sh에 정의된 임계값들이 실제 정상 동작 샘플과 비교했을 때
#       오분류율(misclassification_rate)이 허용 기준치(기본 10%)를 초과하면
#       exit 1을 반환해 CI/가드 파이프라인을 차단한다.
#
# 사용법:
#   ./validate-watchdog-thresholds.sh [--threshold-pct N] [--sample-file FILE]
#   --threshold-pct N  : 허용 최대 오분류율 % (기본값: 10)
#   --sample-file FILE : 정상 샘플 데이터 파일 (기본값: 내장 샘플)
#
# 출력 형식:
#   misclassification_rate=<N>%  (반드시 포함)
#   exit 0: 통과 / exit 1: 오분류율 초과 또는 오류

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-${HOME}/.jarvis}"
WATCHDOG_SCRIPT="${JARVIS_HOME}/scripts/watchdog.sh"
MAX_MISCLASSIFICATION_PCT="${1:-}"  # 기본값은 아래에서 설정

# 인수 파싱
THRESHOLD_PCT=10
SAMPLE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold-pct)
            THRESHOLD_PCT="$2"
            shift 2
            ;;
        --sample-file)
            SAMPLE_FILE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# --------------------------------------------------------------------------
# 1. watchdog.sh에서 현재 임계값 추출
# --------------------------------------------------------------------------
extract_threshold() {
    local var_name="$1"
    local default_val="$2"
    if [[ -f "$WATCHDOG_SCRIPT" ]]; then
        local val
        # awk로 첫 번째 필드(숫자)만 추출 — 한글 주석 포함 행도 안전하게 처리
        val=$(grep -E "^${var_name}=" "$WATCHDOG_SCRIPT" 2>/dev/null \
              | head -1 | awk -F'=' '{print $2}' | awk '{print $1}' | tr -d '"' || true)
        echo "${val:-$default_val}"
    else
        echo "$default_val"
    fi
}

MEMORY_WARN_MB=$(extract_threshold "MEMORY_WARN_MB" "900")
MEMORY_SOFT_MB=$(extract_threshold "MEMORY_SOFT_MB" "1100")
MEMORY_CRITICAL_MB=$(extract_threshold "MEMORY_CRITICAL_MB" "1400")
SYSTEM_SWAP_THRESHOLD_PCT=$(extract_threshold "SYSTEM_SWAP_THRESHOLD_PCT" "70")
SYSTEM_UNUSED_MIN_MB=$(extract_threshold "SYSTEM_UNUSED_MIN_MB" "1024")
CRASH_LOOP_THRESHOLD=$(extract_threshold "CRASH_LOOP_THRESHOLD" "3")
HEARTBEAT_STALE_SEC=$(extract_threshold "HEARTBEAT_STALE_SEC" "900")

echo "=== 감시기 임계값 검증 시작 ==="
echo "  MEMORY_WARN_MB        = ${MEMORY_WARN_MB}"
echo "  MEMORY_SOFT_MB        = ${MEMORY_SOFT_MB}"
echo "  MEMORY_CRITICAL_MB    = ${MEMORY_CRITICAL_MB}"
echo "  SYSTEM_SWAP_PCT       = ${SYSTEM_SWAP_THRESHOLD_PCT}%"
echo "  SYSTEM_UNUSED_MIN_MB  = ${SYSTEM_UNUSED_MIN_MB}"
echo "  CRASH_LOOP_THRESHOLD  = ${CRASH_LOOP_THRESHOLD}"
echo "  HEARTBEAT_STALE_SEC   = ${HEARTBEAT_STALE_SEC}"
echo ""

# --------------------------------------------------------------------------
# 2. 정상 동작 샘플 정의
#    형식: <메트릭타입> <측정값> <기대판정(ok|warn|critical)>
#    샘플은 실제 운영 관측 기반 (시스템 안정 상태 기준)
# --------------------------------------------------------------------------
declare -a SAMPLES=()

if [[ -n "$SAMPLE_FILE" ]] && [[ -f "$SAMPLE_FILE" ]]; then
    # 외부 샘플 파일 로드 (줄 형식: metric_type value expected_verdict)
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        SAMPLES+=("$line")
    done < "$SAMPLE_FILE"
else
    # 내장 샘플: 실제 정상 운영 관측치 기반
    # 형식: <타입> <값> <기대판정>
    # memory_rss (MB): 봇 정상 구동 시 300-700MB 범위
    SAMPLES+=(
        "memory_rss 250 ok"
        "memory_rss 400 ok"
        "memory_rss 550 ok"
        "memory_rss 700 ok"
        "memory_rss 850 ok"
        "memory_rss 920 warn"    # WARN 구간
        "memory_rss 1050 warn"
        "memory_rss 1150 soft"   # SOFT 재시작 구간
        "memory_rss 1350 soft"
        "memory_rss 1500 critical"

        # swap_pct: 정상 0-50%, 압박 70%+
        "swap_pct 10 ok"
        "swap_pct 30 ok"
        "swap_pct 50 ok"
        "swap_pct 65 ok"
        "swap_pct 72 warn"       # 임계값 초과
        "swap_pct 85 warn"

        # unused_mb: 정상 2GB+, 압박 < 1GB
        "unused_mb 3000 ok"
        "unused_mb 2000 ok"
        "unused_mb 1500 ok"
        "unused_mb 1100 ok"
        "unused_mb 900 warn"     # 임계값 미만
        "unused_mb 512 warn"

        # heartbeat_age_sec: 15분(900초) 이내 = 정상
        "heartbeat_age 300 ok"
        "heartbeat_age 600 ok"
        "heartbeat_age 850 ok"
        "heartbeat_age 960 stale"   # 임계값 초과
        "heartbeat_age 1800 stale"

        # crash_count_30min: 3 미만 = 정상
        "crash_count 0 ok"
        "crash_count 1 ok"
        "crash_count 2 ok"
        "crash_count 3 crash_loop"  # 임계값 도달
        "crash_count 5 crash_loop"
    )
fi

# --------------------------------------------------------------------------
# 3. 각 샘플에 대해 임계값 규칙 적용 → 판정 계산
# --------------------------------------------------------------------------
classify_sample() {
    local metric_type="$1"
    local value="$2"

    case "$metric_type" in
        memory_rss)
            if [[ "$value" -ge "$MEMORY_CRITICAL_MB" ]]; then
                echo "critical"
            elif [[ "$value" -ge "$MEMORY_SOFT_MB" ]]; then
                echo "soft"
            elif [[ "$value" -ge "$MEMORY_WARN_MB" ]]; then
                echo "warn"
            else
                echo "ok"
            fi
            ;;
        swap_pct)
            if [[ "$value" -ge "$SYSTEM_SWAP_THRESHOLD_PCT" ]]; then
                echo "warn"
            else
                echo "ok"
            fi
            ;;
        unused_mb)
            if [[ "$value" -lt "$SYSTEM_UNUSED_MIN_MB" ]]; then
                echo "warn"
            else
                echo "ok"
            fi
            ;;
        heartbeat_age)
            if [[ "$value" -gt "$HEARTBEAT_STALE_SEC" ]]; then
                echo "stale"
            else
                echo "ok"
            fi
            ;;
        crash_count)
            if [[ "$value" -ge "$CRASH_LOOP_THRESHOLD" ]]; then
                echo "crash_loop"
            else
                echo "ok"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# --------------------------------------------------------------------------
# 4. 오분류율 계산
# --------------------------------------------------------------------------
TOTAL=0
MISCLASSIFIED=0
MISCLASSIFICATION_DETAILS=()

for sample in "${SAMPLES[@]}"; do
    metric_type=$(echo "$sample" | awk '{print $1}')
    value=$(echo "$sample" | awk '{print $2}')
    expected=$(echo "$sample" | awk '{print $3}')

    actual=$(classify_sample "$metric_type" "$value")
    TOTAL=$((TOTAL + 1))

    if [[ "$actual" != "$expected" ]]; then
        MISCLASSIFIED=$((MISCLASSIFIED + 1))
        MISCLASSIFICATION_DETAILS+=("  MISMATCH: ${metric_type}=${value} → expected=${expected}, got=${actual}")
    fi
done

if [[ "$TOTAL" -eq 0 ]]; then
    echo "ERROR: 샘플이 없습니다. 샘플 파일을 확인하거나 내장 샘플을 사용하세요."
    exit 1
fi

# 오분류율 계산 (정수 나눗셈, 반올림)
MISCLASSIFICATION_RATE_PCT=$(( (MISCLASSIFIED * 100 + TOTAL / 2) / TOTAL ))

# --------------------------------------------------------------------------
# 5. 결과 출력
# --------------------------------------------------------------------------
echo "=== 샘플 분류 결과 ==="
echo "  총 샘플 수       : ${TOTAL}"
echo "  오분류 건수      : ${MISCLASSIFIED}"
echo "  허용 임계치      : ${THRESHOLD_PCT}%"
echo ""

if [[ ${#MISCLASSIFICATION_DETAILS[@]} -gt 0 ]]; then
    echo "  [오분류 목록]"
    for detail in "${MISCLASSIFICATION_DETAILS[@]}"; do
        echo "$detail"
    done
    echo ""
fi

# 반드시 이 형식 포함 (Sprint Contract [2] 충족)
echo "misclassification_rate=${MISCLASSIFICATION_RATE_PCT}%"
echo ""

# --------------------------------------------------------------------------
# 6. 통과/실패 판정
# --------------------------------------------------------------------------
if [[ "$MISCLASSIFICATION_RATE_PCT" -gt "$THRESHOLD_PCT" ]]; then
    echo "RESULT: FAIL — 오분류율 ${MISCLASSIFICATION_RATE_PCT}% > 허용치 ${THRESHOLD_PCT}%"
    echo "ACTION: watchdog.sh 임계값 재검토 필요"
    echo "        현재값: MEMORY_WARN=${MEMORY_WARN_MB}MB, MEMORY_CRITICAL=${MEMORY_CRITICAL_MB}MB"
    echo "        SWAP_PCT=${SYSTEM_SWAP_THRESHOLD_PCT}%, UNUSED_MIN=${SYSTEM_UNUSED_MIN_MB}MB"
    # Sprint Contract [3]: exit 1로 CI 차단
    exit 1
else
    echo "RESULT: PASS — 오분류율 ${MISCLASSIFICATION_RATE_PCT}% ≤ 허용치 ${THRESHOLD_PCT}%"
    echo "STATUS: 감시기 임계값이 정상 동작 샘플과 정합성 유지 중"
    exit 0
fi
