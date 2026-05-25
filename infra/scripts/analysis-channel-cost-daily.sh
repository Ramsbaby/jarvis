#!/usr/bin/env bash
# analysis-channel-cost-daily.sh — 분석 채널 4종 일간 응답 비용/건수 모니터링
# 매일 09:00 KST
#
# DRYRUN 의무 (자비스 자동화 표준):
#   ANALYSIS_COST_DRYRUN=1 default → 측정만, Discord 송출 X
#   ANALYSIS_COST_DRYRUN=0 → production (discord-route info 채널 송출)
#
# Why: 분석 채널 매트릭스 정식 등재 (2026-05-25) 후 비용 폭증 감지 + 건수 추세 모니터링.
# DRY: response-ledger.jsonl 사용. cost-summary-daily.mjs(routing-metrics 전용)와 분리.
# Frequency: daily → 비용 변동 작으면 weekly로 다운그레이드.

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/analysis-channel-cost-daily.log"
LEDGER="$JARVIS_HOME/runtime/state/analysis-channel-cost-ledger.jsonl"
RESPONSE_LEDGER="$JARVIS_HOME/runtime/state/response-ledger.jsonl"

# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LEDGER")"
_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S KST')] $*" | tee -a "$LOG_FILE"; }

DRYRUN="${ANALYSIS_COST_DRYRUN:-1}"

# 분석 채널 4종 ID (정식 등재 매트릭스 SSoT)
CH_CAREER="1471694919339868190"
CH_DEV="1469905074661757049"
CH_CEO="1475786634510467186"
CH_MARKET="1469190686145384513"

# 24시간 rolling window (UTC 기준, ledger ts와 정합).
# 라벨링: "어제 KST" 표기 회피 — rolling window는 cron 실행 시점 기준 -24h이므로 어제 KST와 정확 일치 안 함.
WINDOW_LABEL="최근 24h (UTC $(date -u -v-24H '+%Y-%m-%dT%H:%M') ~ $(date -u '+%Y-%m-%dT%H:%M'))"

_log "분석 시작 — 대상: $WINDOW_LABEL"

# === 1. response-ledger.jsonl에서 어제 분석 채널 entries 추출 ===
if [ ! -f "$RESPONSE_LEDGER" ]; then
    _log "[ERROR] response-ledger.jsonl 부재 — 측정 중단"
    exit 1
fi

# ledger ts는 UTC ISO (Z 종료) — 마지막 24시간 윈도우로 비교 (단순화)
RANGE_START=$(date -u -v-24H +%FT%TZ)
RANGE_END=$(date -u +%FT%TZ)

# jq는 줄 하나 parse 실패하면 전체 종료 — 줄 단위 stream으로 호출하여 invalid 줄만 skip
STATS=$(while IFS= read -r line; do
  echo "$line" | jq -r --arg s "$RANGE_START" --arg e "$RANGE_END" --arg c1 "$CH_CAREER" --arg c2 "$CH_DEV" --arg c3 "$CH_CEO" --arg c4 "$CH_MARKET" '
    select(.ts >= $s and .ts < $e and .channelId != null)
    | select(.channelId == $c1 or .channelId == $c2 or .channelId == $c3 or .channelId == $c4)
    | "\(.channelId) \(.input_tokens // 0) \(.cache_read_input_tokens // 0) \(.cache_creation_input_tokens // 0) \(.output_tokens // 0)"
  ' 2>/dev/null || true
done < "$RESPONSE_LEDGER" | awk -v c1="$CH_CAREER" -v c2="$CH_DEV" -v c3="$CH_CEO" -v c4="$CH_MARKET" '
{
  ch=$1; inp[ch]+=$2; cr[ch]+=$3; cc[ch]+=$4; outp[ch]+=$5; n[ch]++
  total_n++; total_in+=$2; total_cr+=$3; total_cc+=$4; total_out+=$5
}
END {
  name[c1]="career"; name[c2]="dev"; name[c3]="ceo"; name[c4]="market"
  print "n_total="total_n+0
  in_c = total_in*0.003/1000
  cr_c = total_cr*0.0003/1000
  cc_c = total_cc*0.00375/1000
  out_c = total_out*0.015/1000
  printf "cost_total=%.4f\n", in_c+cr_c+cc_c+out_c
  for (ch in n) {
    nm = name[ch]
    in_c = inp[ch]*0.003/1000
    cr_c = cr[ch]*0.0003/1000
    cc_c = cc[ch]*0.00375/1000
    out_c = outp[ch]*0.015/1000
    total = in_c+cr_c+cc_c+out_c
    avg = (n[ch] > 0) ? total/n[ch] : 0
    printf "%s_n=%d\n%s_cost=%.4f\n%s_avg=%.4f\n", nm, n[ch], nm, total, nm, avg
  }
}
')

# === 2. 파싱 + 집계 (grep 실패 시 0 fallback — pipefail 보호) ===
_get() { echo "$STATS" | grep "^$1=" 2>/dev/null | cut -d= -f2 || echo "0"; }
N_TOTAL=$(_get n_total) ; N_TOTAL="${N_TOTAL:-0}"
COST_TOTAL=$(_get cost_total) ; COST_TOTAL="${COST_TOTAL:-0}"
CAREER_N=$(_get career_n) ; CAREER_N="${CAREER_N:-0}"
CAREER_COST=$(_get career_cost) ; CAREER_COST="${CAREER_COST:-0}"
DEV_N=$(_get dev_n) ; DEV_N="${DEV_N:-0}"
DEV_COST=$(_get dev_cost) ; DEV_COST="${DEV_COST:-0}"
CEO_N=$(_get ceo_n) ; CEO_N="${CEO_N:-0}"
CEO_COST=$(_get ceo_cost) ; CEO_COST="${CEO_COST:-0}"
MARKET_N=$(_get market_n) ; MARKET_N="${MARKET_N:-0}"
MARKET_COST=$(_get market_cost) ; MARKET_COST="${MARKET_COST:-0}"

_log "결과 — 총 ${N_TOTAL}건 / 총 \$${COST_TOTAL}"
_log "career: ${CAREER_N}건/\$${CAREER_COST} | dev: ${DEV_N}건/\$${DEV_COST} | ceo: ${CEO_N}건/\$${CEO_COST} | market: ${MARKET_N}건/\$${MARKET_COST}"

# === 3. ledger 적재 (DRYRUN 무관 — 측정 데이터는 항상 기록) ===
TS_UTC=$(date -u +%FT%TZ)
echo "{\"ts\":\"$TS_UTC\",\"window\":\"24h\",\"range_start\":\"$RANGE_START\",\"range_end\":\"$RANGE_END\",\"n_total\":${N_TOTAL:-0},\"cost_total\":${COST_TOTAL:-0},\"channels\":{\"career\":{\"n\":${CAREER_N:-0},\"cost\":${CAREER_COST:-0}},\"dev\":{\"n\":${DEV_N:-0},\"cost\":${DEV_COST:-0}},\"ceo\":{\"n\":${CEO_N:-0},\"cost\":${CEO_COST:-0}},\"market\":{\"n\":${MARKET_N:-0},\"cost\":${MARKET_COST:-0}}},\"dryrun\":\"$DRYRUN\"}" >> "$LEDGER"

# === 4. 비용 폭증 임계 검사 (월 $500 등재 후 트리거 기준) ===
# 일간 $17 = 월 $500 추정. 일간 $30 이상은 critical.
ALERT_LEVEL=""
if awk "BEGIN {exit !(${COST_TOTAL:-0} > 30)}"; then
    ALERT_LEVEL="critical"
elif awk "BEGIN {exit !(${COST_TOTAL:-0} > 17)}"; then
    ALERT_LEVEL="warn"
fi

# === 5. Discord 송출 (DRYRUN=0 + discord-route 가용 시) ===
TITLE="📊 분석 채널 비용 — 최근 24h"
BODY="총 ${N_TOTAL}건 / 총 \$${COST_TOTAL} | career: ${CAREER_N}/\$${CAREER_COST} · dev: ${DEV_N}/\$${DEV_COST} · ceo: ${CEO_N}/\$${CEO_COST} · market: ${MARKET_N}/\$${MARKET_COST}"
if [ -n "$ALERT_LEVEL" ]; then
    BODY="$BODY | ⚠️ ALERT=$ALERT_LEVEL (월 \$500 등재 후 트리거)"
fi

if [ "$DRYRUN" = "0" ] && command -v discord_route >/dev/null 2>&1; then
    if [ "$ALERT_LEVEL" = "critical" ]; then
        discord_route critical "$TITLE" "$BODY"
    else
        discord_route info "$TITLE" "$BODY"
    fi
    _log "Discord 송출 완료 (severity=${ALERT_LEVEL:-info})"
else
    _log "DRYRUN=$DRYRUN — Discord 송출 skip / TITLE: $TITLE / BODY: $BODY"
fi

exit 0
