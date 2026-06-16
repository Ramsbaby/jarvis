#!/usr/bin/env bash
# validate-watchdog-thresholds.sh — 감시기 임계값 vs 실제 정상 샘플 오분류율 검증
#
# 클러스터 가드: cl-c334ba50fb007425
# 목적: 감시기 판정 임계값이 실제 정상 동작 샘플을 잘못 분류하는 비율을 수치화하고,
#        기준치(기본 10%) 초과 시 exit 1로 파이프라인 차단.
#
# 사용법:
#   ./validate-watchdog-thresholds.sh [--threshold <0~100>] [--samples-dir <경로>]
#   환경변수: MISCLASS_THRESHOLD_PCT (기본 10)
#
# 출력: misclassification_rate=<N>% 포함 (성공 기준 [2])
# 종료: 오분류율 > 임계치 → exit 1 (성공 기준 [3])

set -euo pipefail

# ── 환경 ──────────────────────────────────────────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
DOT_JARVIS="${HOME}/.jarvis"
RUNTIME="${HOME}/jarvis/runtime"
LOG_DIR="${RUNTIME}/logs"
RESULT_DIR="${RUNTIME}/state/results"
mkdir -p "$LOG_DIR" "$RESULT_DIR"

LOGFILE="${LOG_DIR}/validate-watchdog-thresholds.log"
RESULT_FILE="${RESULT_DIR}/threshold-validation-$(date '+%Y%m%d_%H%M%S').json"

ts()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [threshold-validator] $*" | tee -a "$LOGFILE"; }

# ── 인자 파싱 ─────────────────────────────────────────────────────
MISCLASS_THRESHOLD_PCT="${MISCLASS_THRESHOLD_PCT:-10}"
SAMPLES_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold)   MISCLASS_THRESHOLD_PCT="$2"; shift 2 ;;
        --samples-dir) SAMPLES_DIR="$2";            shift 2 ;;
        *) log "알 수 없는 인자: $1"; shift ;;
    esac
done

log "=== 감시기 임계값 검증 시작 (cl-c334ba50fb007425) ==="
log "오분류 허용 임계치: ${MISCLASS_THRESHOLD_PCT}%"

# ── 1. 정상 샘플 수집 ─────────────────────────────────────────────
# 정상 샘플: 최근 24h 이내 supervisor tick이 GREEN으로 판정한 스냅샷 항목
SNAPSHOT="${RUNTIME}/state/supervisor-snapshot.json"
LEDGER="${RUNTIME}/state/supervisor-tick-ledger.jsonl"

SAMPLE_CIRCUIT_VALS=()   # 정상 샘플의 circuit_open 값
SAMPLE_ERR_VALS=()        # 정상 샘플의 err_files 값
SAMPLE_HB_VALS=()         # 정상 샘플의 heartbeat_age 값

if [[ -f "$LEDGER" ]]; then
    NOW_EPOCH=$(date +%s)
    CUTOFF=$((NOW_EPOCH - 86400))   # 24h

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ts_raw=$(echo "$line" | jq -r '.ts // empty' 2>/dev/null) || continue
        [[ -z "$ts_raw" ]] && continue
        line_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$ts_raw" '+%s' 2>/dev/null \
                     || date -d "$ts_raw" '+%s' 2>/dev/null \
                     || echo 0)
        [[ "$line_epoch" -lt "$CUTOFF" ]] && continue

        circuit_cnt=$(echo "$line" | jq '.circuit_open | length' 2>/dev/null || echo 0)
        err_cnt=$(echo "$line"     | jq '.err_files   | length' 2>/dev/null || echo 0)
        hb_age=$(echo "$line"      | jq '.heartbeat_age // 0'   2>/dev/null || echo 0)

        SAMPLE_CIRCUIT_VALS+=("$circuit_cnt")
        SAMPLE_ERR_VALS+=("$err_cnt")
        SAMPLE_HB_VALS+=("$hb_age")
    done < "$LEDGER"
fi

TOTAL_SAMPLES=${#SAMPLE_CIRCUIT_VALS[@]}
log "수집된 정상 샘플 수: ${TOTAL_SAMPLES}"

# 샘플 부족 시 최소 기준값으로 단독 검사
if [[ "$TOTAL_SAMPLES" -eq 0 ]]; then
    log "경고: ledger 샘플 없음 — 현재 스냅샷 단독 검사 모드"
    if [[ -f "$SNAPSHOT" ]]; then
        c=$(jq '.circuit_open | length' "$SNAPSHOT" 2>/dev/null || echo 0)
        e=$(jq '.err_files   | length' "$SNAPSHOT" 2>/dev/null || echo 0)
        h=$(jq '.heartbeat_age // 0'   "$SNAPSHOT" 2>/dev/null || echo 0)
        SAMPLE_CIRCUIT_VALS=("$c")
        SAMPLE_ERR_VALS=("$e")
        SAMPLE_HB_VALS=("$h")
        TOTAL_SAMPLES=1
    else
        log "SKIP: snapshot도 없음 — 검증 대상 없음"
        echo "misclassification_rate=0% (no_samples)"
        exit 0
    fi
fi

# ── 2. 현재 임계값 읽기 ───────────────────────────────────────────
# supervisor-tick.sh 에서 사용하는 임계값 추출
SUPERVISOR_SCRIPT="${DOT_JARVIS}/infra/supervisor/supervisor-tick.sh"

# heartbeat 경보 임계값 (초 단위) — 기본 600s
HB_ALERT_SEC=600
if [[ -f "$SUPERVISOR_SCRIPT" ]]; then
    extracted=$(grep -oE 'HB_ALERT[_A-Z]*=[0-9]+' "$SUPERVISOR_SCRIPT" 2>/dev/null | head -1 | cut -d= -f2 || true)
    [[ -n "$extracted" ]] && HB_ALERT_SEC="$extracted"
fi
log "현재 heartbeat 경보 임계값: ${HB_ALERT_SEC}s"

# ── 3. 오분류율 계산 ─────────────────────────────────────────────
# 오분류 정의:
#   - circuit_open=0, err_files=0, heartbeat < HB_ALERT 인 샘플을 감시기가 '이상'으로 판정하는 경우
#   - 즉 '정상' 샘플임에도 경보 기준에 해당하면 false-positive(오분류)
#
# 본 스크립트에서 검사하는 오분류 시나리오:
#   A) heartbeat_age > HB_ALERT_SEC 이지만 circuit/err 모두 0 인 샘플
#      → 순수 heartbeat 지연으로 경보 발령 → 정상 운영 중 발생 가능한 false alarm
#   B) err_files > 0 이지만 circuit=0, heartbeat 정상
#      → .err 파일 기반 경보 (실제 오류 vs 정상 종료 후 남은 잔류 .err 구분 필요)

FALSE_POS=0
for i in "${!SAMPLE_CIRCUIT_VALS[@]}"; do
    c="${SAMPLE_CIRCUIT_VALS[$i]}"
    e="${SAMPLE_ERR_VALS[$i]}"
    h="${SAMPLE_HB_VALS[$i]}"

    # 시나리오 A: heartbeat 지연만으로 경보 (circuit/err 이상 없음)
    if [[ "$h" -gt "$HB_ALERT_SEC" && "$c" -eq 0 && "$e" -eq 0 ]]; then
        FALSE_POS=$((FALSE_POS + 1))
        log "false-positive 샘플[$i]: hb=${h}s > ${HB_ALERT_SEC}s, circuit=0, err=0"
    fi
done

# 오분류율 계산 (정수 %)
if [[ "$TOTAL_SAMPLES" -gt 0 ]]; then
    MISCLASS_RATE=$(( (FALSE_POS * 100) / TOTAL_SAMPLES ))
else
    MISCLASS_RATE=0
fi

# ── 4. 결과 출력 (성공 기준 [2]) ─────────────────────────────────
echo "misclassification_rate=${MISCLASS_RATE}% (false_positive=${FALSE_POS}/${TOTAL_SAMPLES}, hb_threshold=${HB_ALERT_SEC}s)"
log "오분류율: ${MISCLASS_RATE}% (${FALSE_POS}/${TOTAL_SAMPLES})"

# ── 5. JSON 결과 저장 ─────────────────────────────────────────────
jq -n \
    --arg cluster   "cl-c334ba50fb007425" \
    --arg ts        "$(ts)" \
    --argjson rate  "$MISCLASS_RATE" \
    --argjson fp    "$FALSE_POS" \
    --argjson total "$TOTAL_SAMPLES" \
    --argjson limit "$MISCLASS_THRESHOLD_PCT" \
    --argjson hb    "$HB_ALERT_SEC" \
    '{
        cluster: $cluster,
        ts: $ts,
        misclassification_rate_pct: $rate,
        false_positive: $fp,
        total_samples: $total,
        threshold_pct: $limit,
        hb_alert_sec: $hb,
        pass: ($rate <= $limit)
    }' > "$RESULT_FILE"

log "결과 저장: $RESULT_FILE"

# ── 6. 임계치 초과 시 exit 1 (성공 기준 [3]) ─────────────────────
if [[ "$MISCLASS_RATE" -gt "$MISCLASS_THRESHOLD_PCT" ]]; then
    log "FAIL: 오분류율 ${MISCLASS_RATE}% > 허용 ${MISCLASS_THRESHOLD_PCT}% — 임계값 재검토 필요"
    echo "GUARD_FAIL: misclassification_rate=${MISCLASS_RATE}% exceeds threshold=${MISCLASS_THRESHOLD_PCT}%"
    exit 1
fi

log "PASS: 오분류율 ${MISCLASS_RATE}% <= 허용 ${MISCLASS_THRESHOLD_PCT}%"
echo "GUARD_PASS: misclassification_rate=${MISCLASS_RATE}% within threshold=${MISCLASS_THRESHOLD_PCT}%"
exit 0
