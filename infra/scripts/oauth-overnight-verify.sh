#!/usr/bin/env bash
# oauth-overnight-verify.sh — 매일 새벽 OAuth 자동 갱신 사이클 종합 점검
#
# 역할: 직전 6h ledger·로그·토큰 상태를 종합 분석하여 새벽 갱신 사이클이
#       정상이었는지 1회 보고. 이상 시 Discord critical, 정상 시 silent.
#
# 호출: LaunchAgent ai.jarvis.oauth-overnight-verify (매일 03:30 KST)
#
# 출력 정책:
#   - 정상(전부 success + 토큰 valid): 로그만, Discord 침묵 (폭격 방지)
#   - invalid_grant 분기 발동: Discord info (자가복구 작동 증명)
#   - 진짜 fail 또는 토큰 expired: Discord critical
set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/oauth-overnight-verify.log"
LEDGER="${HOME}/jarvis/runtime/ledger/oauth-refresh-ledger.jsonl"
REFRESH_LOG="${HOME}/jarvis/runtime/logs/oauth-refresh.log"
CRED="${HOME}/.claude/.credentials.json"
ALERT="${HOME}/jarvis/runtime/scripts/alert.sh"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" >> "${LOG}"; }

log "=== 새벽 점검 시작 ==="

# 1) 직전 6h ledger 분석
SIX_H_AGO=$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)
RECENT_LEDGER=$(awk -v cutoff="${SIX_H_AGO}" -F'"' '$4 >= cutoff' "${LEDGER}" 2>/dev/null || true)
SUCCESS_COUNT=$(echo "${RECENT_LEDGER}" | grep -c '"result":"success"' || true)
FAIL_COUNT=$(echo "${RECENT_LEDGER}" | grep -c '"result":"fail"' || true)
log "직전 6h ledger: success=${SUCCESS_COUNT} fail=${FAIL_COUNT}"

# 2) invalid_grant 분기 발동 여부 (오늘 로그)
TODAY=$(date '+%Y-%m-%d')
INVALID_GRANT_DETECTED=$(grep -c "invalid_grant 감지" "${REFRESH_LOG}" 2>/dev/null || true)
SELF_HEALED=$(grep -c "재시도 성공 — race condition 자동 복구" "${REFRESH_LOG}" 2>/dev/null || true)
INVALID_FINAL=$(grep -c "invalid_grant 최종" "${REFRESH_LOG}" 2>/dev/null || true)
INVALID_GRANT_DETECTED=${INVALID_GRANT_DETECTED:-0}
SELF_HEALED=${SELF_HEALED:-0}
INVALID_FINAL=${INVALID_FINAL:-0}
log "invalid_grant 감지=${INVALID_GRANT_DETECTED}, 자가복구 성공=${SELF_HEALED}, 최종 실패=${INVALID_FINAL}"

# 3) 현재 토큰 상태
EXP_MS=$(node -e "try{const d=JSON.parse(require('fs').readFileSync('${CRED}','utf-8'));process.stdout.write(String(d.claudeAiOauth?.expiresAt||0))}catch(e){process.stdout.write('0')}" 2>/dev/null || echo 0)
NOW_MS=$(node -e "process.stdout.write(String(Date.now()))")
REMAIN_S=$(( (EXP_MS - NOW_MS) / 1000 ))
REMAIN_H=$(( REMAIN_S / 3600 ))
log "토큰 잔여: ${REMAIN_S}초 (${REMAIN_H}h)"

# 4) 판정
STATUS="OK"
SEVERITY="info"
DETAIL=""

if (( REMAIN_S <= 0 )); then
  STATUS="TOKEN_EXPIRED"
  SEVERITY="critical"
  DETAIL="토큰 이미 만료(${REMAIN_S}s). 자동 갱신 사이클 실패. 즉시 /login 필요."
elif (( INVALID_FINAL > 0 )); then
  STATUS="INVALID_GRANT_FINAL"
  SEVERITY="critical"
  DETAIL="invalid_grant 최종 실패 감지. refresh_token 사망 추정. /login 필요. (직전 6h: success=${SUCCESS_COUNT} fail=${FAIL_COUNT})"
elif (( FAIL_COUNT > SUCCESS_COUNT )); then
  STATUS="FAIL_DOMINANT"
  SEVERITY="critical"
  DETAIL="직전 6h 갱신 실패가 성공보다 많음 (success=${SUCCESS_COUNT} fail=${FAIL_COUNT}). 사이클 단절 가능."
elif (( SELF_HEALED > 0 )); then
  STATUS="SELF_HEALED"
  SEVERITY="info"
  DETAIL="invalid_grant race 감지 + 자가복구 성공 (${SELF_HEALED}회). 토큰 잔여 ${REMAIN_H}h. 새 분기 정상 작동."
fi

log "판정: status=${STATUS} severity=${SEVERITY}"

# 5) 알림 (정상이면 silent)
if [[ "${STATUS}" == "OK" ]]; then
  log "✅ 정상 — Discord 침묵 (success=${SUCCESS_COUNT} fail=${FAIL_COUNT} remain=${REMAIN_H}h)"
  exit 0
fi

# 이상 또는 자가복구 발동: 알림
if [[ -x "${ALERT}" ]]; then
  TITLE="🌙 OAuth 새벽 점검 — ${STATUS}"
  bash "${ALERT}" "${SEVERITY}" "${TITLE}" "${DETAIL}" 2>&1 | tee -a "${LOG}"
  log "알림 발송 완료"
else
  log "❌ alert.sh 미발견 (${ALERT})"
fi

exit 0
