#!/usr/bin/env bash
# false-positive-guard.sh — 감시 규칙 거짓양성 자동 검사 (cl-ea9810ebd3a98d01)
#
# 사용: ./false-positive-guard.sh <규칙명> <탐지조건> [--threshold <값>] [--window <초>]
#
# 검사 항목:
#   1. 동일 조건 기존 경보 중복 탐지
#   2. 임계값이 정상 운영 범위 내에 있는지 확인
#   3. 경보 채널 중복 발송 위험 탐지
#   4. 경보 억제(cooldown) 설정 누락 탐지

set -eo pipefail

JARVIS_HOME="${HOME}/projects/jarvis"
MONITORING_JSON="${JARVIS_HOME}/infra/config/monitoring.json"
CRONTAB_SNAPSHOT="/tmp/fp-guard-cron-snapshot.txt"

RULE_NAME="${1:-}"
DETECT_COND="${2:-}"
THRESHOLD=""
WINDOW_SEC=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift ;;
        --window)    WINDOW_SEC="$2"; shift ;;
        *) ;;
    esac
    shift
done

fail_count=0
warn_count=0

check() {
    local level="$1" label="$2" msg="$3"
    case "$level" in
        FAIL) echo "  ❌ FAIL  [$label] $msg"; fail_count=$((fail_count + 1)) ;;
        WARN) echo "  ⚠️  WARN  [$label] $msg"; warn_count=$((warn_count + 1)) ;;
        OK)   echo "  ✅ OK    [$label] $msg" ;;
    esac
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 거짓양성(FP) 가드 검사: ${RULE_NAME:-<미지정>}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================
# 검사 1: 기존 경보 중복 탐지
# ============================================================
echo "▸ 검사 1: 기존 감시 인프라 중복 탐지"

if [[ -n "$DETECT_COND" ]]; then
    # crontab에서 동일 키워드 탐지
    cron_dup=$(crontab -l 2>/dev/null | grep -v '^#' | grep -i "$DETECT_COND" || true)
    if [[ -n "$cron_dup" ]]; then
        check "WARN" "crontab.dup" "동일 조건 기존 cron 항목 발견: $(echo "$cron_dup" | head -1 | cut -c1-80)"
    else
        check "OK" "crontab.dup" "crontab 중복 없음"
    fi

    # launchd에서 동일 키워드 탐지
    la_dup=$(ls "${HOME}/Library/LaunchAgents/"*.plist 2>/dev/null | \
        xargs -I{} basename {} .plist 2>/dev/null | \
        grep -i "$DETECT_COND" || true)
    if [[ -n "$la_dup" ]]; then
        check "WARN" "launchd.dup" "동일 조건 기존 LaunchAgent 발견: $la_dup"
    else
        check "OK" "launchd.dup" "LaunchAgent 중복 없음"
    fi

    # scripts 디렉토리에서 동일 키워드 탐지
    script_dup=$(ls "${JARVIS_HOME}/scripts/"*"${DETECT_COND}"* \
                    "${JARVIS_HOME}/infra/scripts/"*"${DETECT_COND}"* \
                    2>/dev/null | head -3 || true)
    if [[ -n "$script_dup" ]]; then
        check "WARN" "scripts.dup" "유사 스크립트 발견: $(echo "$script_dup" | xargs -I{} basename {} | tr '\n' ', ')"
    else
        check "OK" "scripts.dup" "유사 스크립트 중복 없음"
    fi
else
    check "WARN" "dup.check" "탐지조건(DETECT_COND) 미지정 — 중복 검사 생략"
fi
echo ""

# ============================================================
# 검사 2: 임계값 범위 검증
# ============================================================
echo "▸ 검사 2: 임계값 설정"
if [[ -n "$THRESHOLD" ]]; then
    # 임계값이 숫자인지 확인
    if [[ "$THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        check "OK" "threshold.format" "임계값 형식 유효: $THRESHOLD"
        # 경고: 임계값이 너무 낮으면 FP 위험
        if (( $(echo "$THRESHOLD < 5" | bc -l 2>/dev/null || echo 0) )); then
            check "WARN" "threshold.low" "임계값($THRESHOLD)이 낮음 — 정상 운영 시 오경보 위험"
        fi
    else
        check "WARN" "threshold.format" "임계값이 숫자 아님: $THRESHOLD (단위 포함 여부 확인)"
    fi
else
    check "WARN" "threshold.missing" "임계값 미지정 — 정상 범위 대비 검증 불가"
fi
echo ""

# ============================================================
# 검사 3: 경보 채널 중복 발송 위험
# ============================================================
echo "▸ 검사 3: 경보 채널 중복 발송 위험"
if [[ -f "$MONITORING_JSON" ]]; then
    channel_count=$(python3 -c "
import json
with open('$MONITORING_JSON') as f:
    d = json.load(f)
count = 0
wh = d.get('webhooks', {})
if isinstance(wh, dict):
    count += sum(1 for v in wh.values() if v)
if d.get('ntfy', {}).get('topic', ''):
    count += 1
print(count)
" 2>/dev/null || echo "0")

    if [[ "$channel_count" -gt 2 ]]; then
        check "WARN" "channels.count" "활성 채널 ${channel_count}개 — 다중 채널 중복 발송 여부 확인 필요"
    else
        check "OK" "channels.count" "활성 채널 ${channel_count}개"
    fi
else
    check "WARN" "monitoring.json" "monitoring.json 미존재 — 채널 구성 확인 불가"
fi
echo ""

# ============================================================
# 검사 4: 경보 억제(cooldown) 설정
# ============================================================
echo "▸ 검사 4: 경보 억제(cooldown)"
if [[ -n "$WINDOW_SEC" ]]; then
    if [[ "$WINDOW_SEC" -ge 300 ]]; then
        check "OK" "cooldown.window" "억제 구간 ${WINDOW_SEC}초 (≥5분) — 적절"
    else
        check "WARN" "cooldown.window" "억제 구간 ${WINDOW_SEC}초 (<5분) — 짧으면 폭탄 경보 위험"
    fi
else
    check "WARN" "cooldown.missing" "억제 구간 미지정 — 동일 경보 폭탄 발송 가능"
fi
echo ""

# ============================================================
# 최종 요약
# ============================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $fail_count -gt 0 ]]; then
    echo " ❌ FP가드 FAIL: ${fail_count}개 — 새 규칙 추가 중단 권고"
    exit 2
elif [[ $warn_count -gt 0 ]]; then
    echo " ⚠️  FP가드 WARN: ${warn_count}개 — 각 항목 검토 후 진행"
    exit 1
else
    echo " ✅ FP가드 통과: 거짓양성 위험 없음"
    exit 0
fi
