#!/usr/bin/env bash
# oauth-refresh.sh — Claude Code OAuth 토큰 자동 갱신
#
# ┌─ 2026-05-31 영구 비활성화 (NO-OP 가드) ─────────────────────────────────────┐
# │ 근거(관찰자 실측 타임라인): 메인 토큰 갱신 주체가 둘(① Claude CLI 자체갱신     │
# │   ② 이 스크립트)이라, 한쪽이 회전시킨 refresh_token을 다른 쪽이 옛것으로 덮어  │
# │   invalid_grant + 패밀리 무효화 → 401 반복. 2026-05-30 23:33 메인 생존(+7.5h) │
# │   → 내가 손 뗀 23:34 이 스크립트류가 credentials를 옛 토큰으로 덮음 → 00:00    │
# │   http=401 remain=-3.1h(만료시각이 과거로 회귀) → 23:44/00:44 ledger          │
# │   invalid_grant. = 이 스크립트가 401 반복의 직접 주범.                          │
# │ 조치: Claude CLI 자체갱신 단일 주체에 위임. 이 스크립트는 호출돼도(pre-cron/   │
# │   retry-wrapper가 --force로 부를 수 있음) 즉시 무해 종료. 봇용은 별도          │
# │   oauth-refresh-bot.sh(정적 격리)가 담당하므로 영향 없음.                       │
# │ 복원 금지. 갱신이 다시 필요하면 단일 주체 원칙부터 재설계할 것.                 │
# └─────────────────────────────────────────────────────────────────────────────┘
if [[ "${OAUTH_REFRESH_FORCE_RUN:-0}" != "1" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oauth-refresh] NO-OP — 2026-05-31 영구 비활성화(2주체 race 주범). CLI 자체갱신에 위임. 호출자: PPID $PPID" \
    >> "${BOT_HOME:-${HOME}/jarvis/runtime}/logs/oauth-refresh.log" 2>/dev/null || true
  exit 0
fi

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
TOKEN_URL="https://api.anthropic.com/v1/oauth/token"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG="${BOT_HOME}/logs/oauth-refresh.log"
RENEW_THRESHOLD_SECS=4200   # 만료 70분 전에만 회전 (1h cron 최소 마진 = 3600+600). 2026-05-30: 백그라운드 회전을 '만료 직전 안전망'으로 한정해 race 창 최소화. 정상 운영에선 SDK 자체갱신이 먼저 회전 → 이 cron은 거의 안 뜸. SDK가 실패(유휴 야간 등)할 때만 마지막에 1회 회전. 일찍 회전(넓은 window)은 인터랙티브/웹 세션과의 race 창만 키워 해로움.

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oauth-refresh] $*" >> "${LOG}"; }

# 2026-05-17: 하드 서킷브레이커 — refresh 엔드포인트가 외부(Anthropic)에서 장기 차단(HTTP 429)될 때
# 지수 backoff(상한 1h)는 4h 주기 cron을 한 번도 못 막음 → 10일간 199회 무의미 호출 + 차단창 리셋 → 영구 차단.
# 사고: 2026-05-07 이후 refresh_token grant 100% rate_limit_error. 고립 단일 호출도 거부됨(계정/엔드포인트 레벨).
# 동작: 연속 N회 실패 시 curl 호출 자체를 24h 완전 봉쇄(--force 포함) + 에스컬레이션 알림 1회만.
#       차단창이 비워질 시간을 확보(두드림 중단) + 로그/알림 폭격 차단. 24h 후 1회 자동 재시도(self-heal).
_OAUTH_STATE_DIR="${BOT_HOME}/state"
_OAUTH_CIRCUIT_UNTIL="${_OAUTH_STATE_DIR}/oauth-circuit-until"
_OAUTH_CIRCUIT_THRESHOLD=4       # 2026-05-23: 8→4 (자기치유 빠르게, 4시간 추세 안에 critical 알림)
_OAUTH_CIRCUIT_COOLDOWN=1800     # 2026-05-23: 7200→1800 (30분, CLI 자기 회복 사이클 매칭)
mkdir -p "${_OAUTH_STATE_DIR}" 2>/dev/null || true

if [[ -f "${_OAUTH_CIRCUIT_UNTIL}" ]]; then
  _circuit_until=$(cat "${_OAUTH_CIRCUIT_UNTIL}" 2>/dev/null || echo "0")
  _now=$(date +%s)
  # 🔄 외부 갱신 자동 감지 — Claude Code CLI 등이 credentials.json을 갱신한 경우 서킷 자동 해제
  _creds_mtime=$(python3 -c "import os; print(int(os.path.getmtime('${CREDENTIALS_FILE}')))" 2>/dev/null || echo 0)
  _circuit_armed_at=$(( _circuit_until - _OAUTH_CIRCUIT_COOLDOWN ))
  if (( _creds_mtime > _circuit_armed_at )); then
    log "🔄 외부 갱신 감지 — credentials.json이 서킷 설정 이후 갱신됨. 서킷/fail-count 자동 해제"
    rm -f "${_OAUTH_FAIL_COUNT}" "${_OAUTH_LAST_FAIL}" "${_OAUTH_CIRCUIT_UNTIL}"
    unset _circuit_until
  elif (( _now < _circuit_until )); then
    _remain_h=$(( (_circuit_until - _now) / 3600 ))
    # ⚡ 긴급 오버라이드: 토큰 15분 이내 만료 시 서킷 무시 1회 시도
    _exp_ms=$(python3 -c "
import json
d=json.load(open('${CREDENTIALS_FILE}'))
print(d.get('claudeAiOauth',{}).get('expiresAt',0))
" 2>/dev/null || echo 0)
    _exp_s=$((_exp_ms / 1000))
    if (( _exp_s > 0 && _now > _exp_s - 900 )); then
      log "⚡ 긴급 오버라이드 — 토큰 $((_exp_s > _now ? _exp_s - _now : 0))초 후 만료, 서킷 무시 갱신 시도"
    else
      log "🛑 서킷 OPEN — refresh 엔드포인트 차단 상태. curl 호출 봉쇄 (재시도까지 약 ${_remain_h}h, 수동 /login 필요)"
      exit 0
    fi
  else
    log "서킷 HALF-OPEN — 봉쇄 ${_OAUTH_CIRCUIT_COOLDOWN}s 경과, 1회 자동 재시도 진입"
  fi
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
# 2026-05-30 force 영구 무력화 (5시간 사고 근본조치): --force가 활성 인터랙티브/SDK 세션의
#   캐시 accessToken을 stale로 만들어 reuse race로 죽이는 게 오늘 사고의 직접 방아쇠(22:31 덫 실측).
#   근거 2가지로 force는 무용+유해: (1) claude CLI가 401 시 credentials 재읽기로 자체 복구함.
#   (2) reuse로 죽은 refresh_token은 force로도 복구 불가(invalid_grant). 즉 멀쩡한 토큰만 회전시켜
#   죽일 뿐 복구엔 무용. → --force 인자는 덫에 기록만 하고 갱신 강제는 절대 안 함(FORCE_REFRESH 0 고정).
_FORCE_REQUESTED=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) _FORCE_REQUESTED=1 ;;
  esac
done
FORCE_REFRESH=0   # 영구 0 고정 — race 방아쇠 제거 (임계값/만료 기반 갱신만 허용)

# 덫(caller trap): force 요청 호출자 부모 체인을 ledger에 기록(무력화해도 누가 시도하는지 추적).
if (( _FORCE_REQUESTED == 1 )); then
  _CALLER_LEDGER="${BOT_HOME:-${HOME}/jarvis/runtime}/ledger/oauth-force-caller-trap.jsonl"
  mkdir -p "$(dirname "$_CALLER_LEDGER")" 2>/dev/null || true
  _pp=$PPID; _chain=""; _depth=0
  while [[ -n "$_pp" && "$_pp" != "0" && "$_pp" != "1" && $_depth -lt 6 ]]; do
    _pc=$(ps -o comm= -p "$_pp" 2>/dev/null | tr -d '\n')
    _pa=$(ps -o args= -p "$_pp" 2>/dev/null | cut -c1-120 | tr '\n' ' ' | tr '"' "'")
    _chain="${_chain}[${_pp}:${_pc}] "
    _pp=$(ps -o ppid= -p "$_pp" 2>/dev/null | tr -d ' ')
    _depth=$((_depth+1))
  done
  _imm_args=$(ps -o args= -p "$PPID" 2>/dev/null | cut -c1-160 | tr '\n' ' ' | tr '"' "'")
  printf '{"ts":"%s","pid":%s,"ppid":%s,"args":"%s","chain":"%s","self_args":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$PPID" "${_imm_args}" "${_chain}" "$*" >> "$_CALLER_LEDGER"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oauth-refresh] 🪤 force 호출 감지 — 호출자 체인: ${_chain}" >> "${LOG}"
fi

# 2026-05-30: skip-if-active 가드 — 모든 호출(--force 포함)에 적용. SDK와의 refresh_token reuse race 차단.
# [실측 근거] 갱신 주체가 credentials.json 1개의 회전형(1회용) refresh_token을 공유: oauth-refresh.sh +
#   봇이 메시지마다 spawn하는 claude SDK 서브프로세스(--output-format stream-json) + 인터랙티브/워크플로
#   에이전트. jarvis PID락 ↔ SDK 자체 lockfile은 호환 안 됨 → 백그라운드가 활성 SDK 턴의 캐시 토큰을
#   stale로 만들면, 그 턴의 다음 SDK 갱신이 reuse detection → 토큰 패밀리 전체 revoke
#   (05-30 13:01 watchdog 회전 → 13:52 사망 / 15:30 워크플로 에이전트 → 15:37 사망, 둘 다 실측).
# [패턴 정밀화] 토큰을 회전시키는 건 'claude SDK 턴'(봇 서브프로세스·에이전트)뿐. serena MCP·chrome-host·
#   remote/srv·claude rc 같은 상주 데몬은 토큰을 회전 안 시키는데 bare "claude"엔 다 걸려 영구 보류를
#   유발(2026-05-30 1차 패턴 [c]laude의 결함, 감사관 적발). → stream-json 턴만 매칭해 정확히 회전자만 탐지.
# [해법] 활성 SDK 턴이 있으면 회전을 보류하고 SDK 자체갱신(자체 락으로 자기들끼리 조율)에 위임.
#   봇/에이전트 턴이 없을 때(야간 유휴 등)만 백그라운드가 만료 직전 안전망으로 회전.
#   단, 만료 임박(<900s)이면 보류 무시 — 토큰 만료 위험 > reuse 위험.
_active_claude=$( { pgrep -f "claude.*--output-format stream-json" 2>/dev/null || true; } | wc -l | tr -d ' ')
if (( _active_claude > 0 )) && (( REMAINING_SECS > 900 )); then
  log "⏸️ skip-if-active — 활성 claude SDK 턴 ${_active_claude}개 + 만료 ${REMAINING_SECS}s 여유 → 백그라운드 회전 보류 (SDK 자체갱신 위임, reuse race 차단)"
  exit 0
fi

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
  # 2026-05-23: invalid_grant 전용 분기 — refresh_token race condition 자가 복구
  # 사고 사례: 05-21 13:00Z 단발 invalid_grant → backoff/circuit 41h 다운 → 주인님 수동 /login
  # 원인: Anthropic refresh 엔드포인트는 매 호출마다 refresh_token 회전. CLI가 평시 갱신 후
  #       cron이 stale refresh_token으로 호출 → invalid_grant. backoff로는 못 푼다 (새 토큰 필요).
  # 해법: credentials.json 재로드 → refresh_token 바뀌었으면 1회 재시도. 두 번째도 실패면
  #       fail-count 증가 없이 즉시 Discord critical 알림 (수동 /login 유도).
  _err_field=$(echo "${RESPONSE}" | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));process.stdout.write(d.error||d.error?.type||'')}catch(e){process.stdout.write('')}" 2>/dev/null || echo "")
  if [[ "${_err_field}" == "invalid_grant" ]]; then
    log "⚠️ invalid_grant 감지 — refresh_token 회전 race 추정, credentials.json 재로드 후 1회 재시도"
    sleep 2
    RELOAD_REFRESH=$(node -e "
      const d = JSON.parse(require('fs').readFileSync('${CREDENTIALS_FILE}', 'utf-8'));
      process.stdout.write(d.claudeAiOauth?.refreshToken || '');
    " 2>/dev/null)
    if [[ -n "${RELOAD_REFRESH}" && "${RELOAD_REFRESH}" != "${REFRESH_TOKEN}" ]]; then
      log "📥 refresh_token이 외부에서 회전됨 — 새 토큰으로 재시도"
      REFRESH_TOKEN="${RELOAD_REFRESH}"
      RESPONSE=$(curl -s -X POST "${TOKEN_URL}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "anthropic-version: 2023-06-01" \
        --data-urlencode "grant_type=refresh_token" \
        --data-urlencode "refresh_token=${REFRESH_TOKEN}" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --max-time 15 2>/dev/null)
      ACCESS_TOKEN=$(echo "${RESPONSE}" | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));process.stdout.write(d.access_token||'')}catch(e){process.stdout.write('')}" 2>/dev/null)
      NEW_REFRESH_TOKEN=$(echo "${RESPONSE}" | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));process.stdout.write(d.refresh_token||'')}catch(e){process.stdout.write('')}" 2>/dev/null)
      EXPIRES_IN=$(echo "${RESPONSE}" | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));process.stdout.write(String(d.expires_in||0))}catch(e){process.stdout.write('0')}" 2>/dev/null)
      if [[ -n "${ACCESS_TOKEN}" ]]; then
        log "✅ 재시도 성공 — race condition 자동 복구"
      fi
    else
      log "📌 credentials.json refresh_token 변화 없음 — 진짜 invalid grant (수동 /login 필요)"
    fi
  fi

  # 재시도 후에도 ACCESS_TOKEN 비어있으면 최종 실패 처리
  if [[ -z "${ACCESS_TOKEN}" ]]; then
  log "ERROR: 갱신 실패 — 응답: ${RESPONSE:0:200}"
  # 2026-05-20: ledger append (감사·통계용 append-only)
  _LEDGER="${BOT_HOME:-${HOME}/jarvis/runtime}/ledger/oauth-refresh-ledger.jsonl"
  mkdir -p "$(dirname "$_LEDGER")"
  _err_type=$(echo "${RESPONSE}" | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));process.stdout.write(d.error?.type||d.error||'unknown')}catch(e){process.stdout.write('parse_error')}" 2>/dev/null || echo "unknown")
  printf '{"ts":"%s","result":"fail","trigger":"%s","err_type":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FORCE_REFRESH:-cron}" "${_err_type}" >> "$_LEDGER"

  # 2026-05-23: invalid_grant 즉시 에스컬레이션 — backoff/circuit 우회
  # 재시도 후에도 invalid_grant라면 refresh_token이 진짜 죽은 것. 재시도는 무의미하니
  # fail-count 증가시키지 않고 (다른 정상 호출 방해 X) 사용자에게 즉시 /login 요청.
  if [[ "${_err_type}" == "invalid_grant" ]]; then
    log "🚨 invalid_grant 최종 — refresh_token 사망. fail-count/circuit 우회, 즉시 critical 알림"
    _INVALID_MARKER="${_OAUTH_STATE_DIR}/invalid_grant-last-alert"
    _now=$(date +%s)
    _last_alert=$(cat "${_INVALID_MARKER}" 2>/dev/null || echo "0")
    if (( _now - _last_alert > 3600 )); then
      echo "${_now}" > "${_INVALID_MARKER}"
      bash "${BOT_HOME}/scripts/alert.sh" \
        critical \
        "🚨 OAuth refresh_token 무효 — 즉시 /login 필요" \
        "refresh_token이 회전 후 stale 상태로 추정되어 자동 재시도도 실패했습니다. 'claude /login' 1회 수동 실행이 필요합니다. (backoff 우회 — 다른 갱신 흐름 방해 없음)" \
        2>/dev/null || true
    else
      log "invalid_grant 알림 1h 중복 억제 — 직전 알림 $(( (_now - _last_alert) / 60 ))분 전"
    fi
    exit 1
  fi

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
    if [[ -f "${_OAUTH_CIRCUIT_UNTIL}" ]]; then _existing_until=$(cat "${_OAUTH_CIRCUIT_UNTIL}" 2>/dev/null || echo "0"); fi
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
  fi  # close: 재시도 후에도 ACCESS_TOKEN 비어있으면 최종 실패
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

# 2026-05-20: ledger append (성공)
_LEDGER="${BOT_HOME:-${HOME}/jarvis/runtime}/ledger/oauth-refresh-ledger.jsonl"
mkdir -p "$(dirname "$_LEDGER")"
printf '{"ts":"%s","result":"success","trigger":"%s","new_expires_at":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FORCE_REFRESH:-cron}" "${NEW_EXPIRES_AT}" >> "$_LEDGER"

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