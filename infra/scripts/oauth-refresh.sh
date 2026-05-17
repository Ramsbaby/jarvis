#!/usr/bin/env bash
# oauth-refresh.sh — Claude Code OAuth 토큰 자동 갱신

# cron 환경에서 node/claude 경로 확보
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}/lib/compat.sh" 2>/dev/null || true
#
# 역할: credentials.json의 refreshToken으로 새 accessToken을 발급받아
#       credentials.json을 갱신하고, 만료 임박 시 봇을 재시작.
#
# 호출: cron 2시간마다 (0 */2 * * *)
# 종료 코드: 0=정상(갱신 or 여유있음), 1=갱신실패

set -euo pipefail

# 중복 실행 방지
_OAUTH_PID="/tmp/jarvis-oauth-refresh.pid"
if [[ -f "$_OAUTH_PID" ]]; then
  _OLD=$(cat "$_OAUTH_PID" 2>/dev/null || echo "")
  if [[ -n "$_OLD" ]] && kill -0 "$_OLD" 2>/dev/null; then
    echo "[oauth-refresh] already running (PID $_OLD) — skip" >&2
    exit 0
  fi
fi
echo $$ > "$_OAUTH_PID"
trap 'rm -f "$_OAUTH_PID"' EXIT

# G5/B (2026-05-08): 쿨다운 가드 — 60초 이내 재호출 차단
# 다채널(crontab + Claude CLI 자체 + retry-wrapper G5) 동시 갱신 시도 → Anthropic rate_limit 만성 발생 차단
# --force 플래그도 쿨다운에 막힘 (방금 갱신한 토큰을 즉시 다시 갱신할 의미 없음)
_OAUTH_LAST_SUCCESS="/tmp/jarvis-oauth-refresh.last-success"
_OAUTH_COOLDOWN_SECS=60
if [[ -f "$_OAUTH_LAST_SUCCESS" ]]; then
  _last=$(cat "$_OAUTH_LAST_SUCCESS" 2>/dev/null || echo "0")
  _now=$(date +%s)
  _delta=$((_now - _last))
  if (( _delta < _OAUTH_COOLDOWN_SECS )); then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oauth-refresh] 쿨다운 스킵 — 직전 성공 후 ${_delta}초 < ${_OAUTH_COOLDOWN_SECS}초 (다채널 중복 호출 방어)" >&2
    exit 0
  fi
fi

# 2026-05-14: 실패 backoff 가드 — 연속 실패 시 지수 backoff
# 사고 사례: 2026-05-13 rate_limit_error로 모든 갱신 실패 → 쿨다운 가드는 성공 케이스만 기록 → 무한 재시도 → rate_limit 영구화
# 실패 기록과 별도 backoff 트래커로 실패 케이스에도 호출 빈도 제어
_OAUTH_LAST_FAIL="/tmp/jarvis-oauth-refresh.last-fail"
_OAUTH_FAIL_COUNT="/tmp/jarvis-oauth-refresh.fail-count"
if [[ -f "$_OAUTH_LAST_FAIL" ]]; then
  _last_fail=$(cat "$_OAUTH_LAST_FAIL" 2>/dev/null || echo "0")
  _fail_count=$(cat "$_OAUTH_FAIL_COUNT" 2>/dev/null || echo "0")
  _now=$(date +%s)
  _delta=$((_now - _last_fail))
  if (( _fail_count > 6 )); then _fail_count_clamped=6; else _fail_count_clamped=$_fail_count; fi
  _backoff=$(( (1 << _fail_count_clamped) * 60 ))
  if (( _backoff > 3600 )); then _backoff=3600; fi
  if (( _delta < _backoff )); then
    # 2026-05-15: --force도 rate_limit backoff 우회 불가 — 치명적 버그 수정
    # 사고 사례: --force 우회 허용 → pre-cron/retry-wrapper가 AUTH_ERROR 감지 후 --force 재호출
    #            → rate_limit 무한루프 (2026-05-14 23:00~23:30 연쇄 실패 실증)
    # --force의 역할: RENEW_THRESHOLD_SECS 임계값 우회만. rate_limit backoff는 절대 우회 불가.
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oauth-refresh] backoff 스킵 — ${_fail_count}회 연속 실패 후 ${_delta}초 < ${_backoff}초 (rate_limit 보호, --force 포함)" >&2
    exit 0
  fi
fi

CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG="${BOT_HOME}/logs/oauth-refresh.log"
RENEW_THRESHOLD_SECS=10800  # 만료 3시간 전부터 갱신 (2시간 간격 cron 기준)

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oauth-refresh] $*" >> "${LOG}"; }

# 2026-05-17: 하드 서킷브레이커 — refresh 엔드포인트가 외부(Anthropic)에서 장기 차단(HTTP 429)될 때
# 지수 backoff(상한 1h)는 4h 주기 cron을 한 번도 못 막음 → 10일간 199회 무의미 호출 + 차단창 리셋 → 영구 차단.
# 사고: 2026-05-07 이후 refresh_token grant 100% rate_limit_error. 고립 단일 호출도 거부됨(계정/엔드포인트 레벨).
# 동작: 연속 N회 실패 시 curl 호출 자체를 24h 완전 봉쇄(--force 포함) + 에스컬레이션 알림 1회만.
#       차단창이 비워질 시간을 확보(두드림 중단) + 로그/알림 폭격 차단. 24h 후 1회 자동 재시도(self-heal).
_OAUTH_STATE_DIR="${BOT_HOME}/state"
_OAUTH_CIRCUIT_UNTIL="${_OAUTH_STATE_DIR}/oauth-circuit-until"
_OAUTH_CIRCUIT_THRESHOLD=8       # 연속 실패 임계값 (현재 backoff clamp와 동일선)
_OAUTH_CIRCUIT_COOLDOWN=86400    # 24h 완전 봉쇄
mkdir -p "${_OAUTH_STATE_DIR}" 2>/dev/null || true

if [[ -f "${_OAUTH_CIRCUIT_UNTIL}" ]]; then
  _circuit_until=$(cat "${_OAUTH_CIRCUIT_UNTIL}" 2>/dev/null || echo "0")
  _now=$(date +%s)
  if (( _now < _circuit_until )); then
    _remain_h=$(( (_circuit_until - _now) / 3600 ))
    log "🛑 서킷 OPEN — refresh 엔드포인트 차단 상태. curl 호출 봉쇄 (재시도까지 약 ${_remain_h}h, 수동 /login 필요)"
    exit 0
  fi
  # 봉쇄 시간 경과 → self-heal 1회 시도 (실패 시 아래 실패분기에서 재무장)
  log "서킷 HALF-OPEN — 봉쇄 ${_OAUTH_CIRCUIT_COOLDOWN}s 경과, 1회 자동 재시도 진입"
fi

# credentials.json 존재 확인
if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
  log "ERROR: ${CREDENTIALS_FILE} 없음 — 로그인 필요"
  exit 1
fi

# 현재 토큰 정보 파싱
REFRESH_TOKEN=$(node -e "
  const d = JSON.parse(require('fs').readFileSync('${CREDENTIALS_FILE}', 'utf-8'));
  process.stdout.write(d.claudeAiOauth?.refreshToken || '');
" 2>/dev/null)

EXPIRES_AT=$(node -e "
  const d = JSON.parse(require('fs').readFileSync('${CREDENTIALS_FILE}', 'utf-8'));
  process.stdout.write(String(d.claudeAiOauth?.expiresAt || 0));
" 2>/dev/null)

if [[ -z "${REFRESH_TOKEN}" ]]; then
  log "ERROR: refreshToken 없음 — OAuth 재인증 필요"
  exit 1
fi

# 만료까지 남은 시간 계산
NOW_MS=$(node -e "process.stdout.write(String(Date.now()))")
EXPIRES_AT_MS="${EXPIRES_AT}"
REMAINING_SECS=$(( (EXPIRES_AT_MS - NOW_MS) / 1000 ))

log "토큰 만료까지 ${REMAINING_SECS}초 남음 (임계값: ${RENEW_THRESHOLD_SECS}초)"

# G5 (2026-05-08): --force 플래그 시 임계값 우회 강제 갱신
# retry-wrapper가 AUTH_ERROR 감지 후 즉시 호출하는 진입점
FORCE_REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE_REFRESH=1 ;;
  esac
done

if (( REMAINING_SECS > RENEW_THRESHOLD_SECS )) && (( FORCE_REFRESH == 0 )); then
  log "갱신 불필요 — 여유 있음"
  exit 0
fi

if (( FORCE_REFRESH == 1 )); then
  log "FORCE_REFRESH=1 — AUTH_ERROR 트리거로 임계값 무시 강제 갱신"
fi

log "갱신 시작 (만료 ${REMAINING_SECS}초 전)"

# OAuth refresh_token grant 요청
RESPONSE=$(curl -s -X POST "${TOKEN_URL}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "anthropic-version: 2023-06-01" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "refresh_token=${REFRESH_TOKEN}" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --max-time 15 2>/dev/null)

# 응답 파싱
ACCESS_TOKEN=$(echo "${RESPONSE}" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));
  process.stdout.write(d.access_token || '');
" 2>/dev/null)

NEW_REFRESH_TOKEN=$(echo "${RESPONSE}" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));
  process.stdout.write(d.refresh_token || '');
" 2>/dev/null)

EXPIRES_IN=$(echo "${RESPONSE}" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));
  process.stdout.write(String(d.expires_in || 0));
" 2>/dev/null)

if [[ -z "${ACCESS_TOKEN}" ]]; then
  log "ERROR: 갱신 실패 — 응답: ${RESPONSE:0:200}"
  # 2026-05-14: 실패 backoff 카운터 기록 — rate_limit 영구화 방지
  date +%s > "$_OAUTH_LAST_FAIL"
  _prev_count=$(cat "$_OAUTH_FAIL_COUNT" 2>/dev/null || echo "0")
  _new_count=$((_prev_count + 1))
  echo "${_new_count}" > "$_OAUTH_FAIL_COUNT"

  # 2026-05-17: 하드 서킷브레이커 무장 — 연속 실패가 임계값 도달 시 24h 완전 봉쇄.
  # 알림은 서킷이 새로 OPEN 될 때 단 1회만 (기존: 매 실패마다 발송 → 199회 폭격의 원인).
  if (( _new_count >= _OAUTH_CIRCUIT_THRESHOLD )); then
    _now=$(date +%s)
    _existing_until=0
    [[ -f "${_OAUTH_CIRCUIT_UNTIL}" ]] && _existing_until=$(cat "${_OAUTH_CIRCUIT_UNTIL}" 2>/dev/null || echo "0")
    if (( _now >= _existing_until )); then
      # 새 트립(또는 직전 봉쇄창 만료 후 재실패) → 재무장 + 에스컬레이션 1회
      echo $(( _now + _OAUTH_CIRCUIT_COOLDOWN )) > "${_OAUTH_CIRCUIT_UNTIL}"
      log "🛑 서킷 OPEN 무장 — 연속 ${_new_count}회 실패, 향후 ${_OAUTH_CIRCUIT_COOLDOWN}s 자동 갱신 봉쇄"
      bash "${BOT_HOME}/scripts/alert.sh" \
        critical \
        "🛑 OAuth 자동갱신 차단 — 수동 /login 필요" \
        "refresh 엔드포인트가 ${_new_count}회 연속 거부(외부 차단 추정). 자동 재시도를 24h 봉쇄합니다. 그동안 하루 1회 'claude /login' 필요. 24h 후 1회 자동 재시도(self-heal)." \
        2>/dev/null || true
    else
      log "서킷 이미 OPEN — 알림 중복 억제 (재시도까지 $(( (_existing_until - _now) / 3600 ))h)"
    fi
  fi
  exit 1
fi

# credentials.json 원자적 업데이트
NEW_EXPIRES_AT=$(node -e "process.stdout.write(String(Date.now() + ${EXPIRES_IN} * 1000))")
FINAL_REFRESH="${NEW_REFRESH_TOKEN:-${REFRESH_TOKEN}}"  # 새 refresh_token이 없으면 기존 유지

node --input-type=module << JSEOF
import { readFileSync, writeFileSync } from 'fs';
const path = '${CREDENTIALS_FILE}';
const d = JSON.parse(readFileSync(path, 'utf-8'));
d.claudeAiOauth.accessToken = '${ACCESS_TOKEN}';
d.claudeAiOauth.refreshToken = '${FINAL_REFRESH}';
d.claudeAiOauth.expiresAt = ${NEW_EXPIRES_AT};
const tmp = path + '.tmp.' + process.pid;
writeFileSync(tmp, JSON.stringify(d, null, 2));
import { renameSync } from 'fs';
renameSync(tmp, path);
JSEOF

log "✅ 갱신 완료 — 새 만료: $(node -e "process.stdout.write(new Date(${NEW_EXPIRES_AT}).toISOString())")"

# 쿨다운 가드용 성공 시각 기록 (다음 호출이 60초 이내면 스킵)
date +%s > "$_OAUTH_LAST_SUCCESS"

# 2026-05-14: 성공 시 실패 카운터 리셋
# 2026-05-17: 서킷브레이커도 함께 해제 (정상 복귀 → self-heal 완료)
# 직전이 실패/서킷 상태였는지 판정 (회복 알림 1회 발송용 — 평시 성공은 무알림으로 폭격 방지)
_was_recovering=0
if [[ -f "$_OAUTH_FAIL_COUNT" || -f "$_OAUTH_CIRCUIT_UNTIL" ]]; then _was_recovering=1; fi
rm -f "$_OAUTH_LAST_FAIL" "$_OAUTH_FAIL_COUNT" "$_OAUTH_CIRCUIT_UNTIL"

# 2026-05-17: 실패/서킷차단에서 복귀한 경우에만 정상 복귀 알림 1회
if (( _was_recovering == 1 )); then
  log "🟢 정상 복귀 — 직전 실패/서킷 상태에서 갱신 성공, 알림 발송"
  bash "${BOT_HOME}/scripts/alert.sh" \
    info \
    "🟢 OAuth 자동갱신 정상 복귀" \
    "refresh 엔드포인트 차단이 해제되어 자동 갱신이 재개됐습니다. 서킷브레이커 해제 완료. 수동 /login 불필요." \
    2>/dev/null || true
fi

# 봇 재시작 — 활성 세션 중이면 대화 완료 후 재시작 (graceful defer)
ACTIVE_SESSION_FILE="${BOT_HOME}/state/active-session"
PENDING_RESTART_FILE="${BOT_HOME}/state/pending-oauth-restart"

if $IS_MACOS && launchctl list ai.jarvis.discord-bot &>/dev/null; then
  if [[ -f "$ACTIVE_SESSION_FILE" ]]; then
    # 활성 세션 진행 중 → 즉시 kill 금지. 마커 남기고 봇이 스스로 재시작하도록 위임
    log "활성 세션 감지 — 재시작 보류 (pending-oauth-restart 마커 기록)"
    touch "$PENDING_RESTART_FILE"
  else
    # 유휴 상태 → graceful restart (15초 딜레이, 현재 응답 전송 보장)
    log "봇 재시작 (새 토큰 반영 — graceful)"
    bash "${BOT_HOME}/scripts/bot-self-restart.sh" "OAuth 토큰 갱신" >> "${LOG}" 2>&1 &
  fi
elif ! $IS_MACOS; then
  log "봇 재시작 (새 토큰 반영 — pm2)"
  pm2 restart discord-bot 2>/dev/null || true
fi

exit 0