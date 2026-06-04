#!/usr/bin/env bash
# oauth-main-observer.sh — 메인(~/.claude) 토큰 순수 관찰자 (Step 1, 2026-05-30)
#
# 목적: 메인 토큰이 "언제·왜" 죽는지 토큰을 일절 건드리지 않고 관찰만 한다.
#   12시간 삽질의 교훈 = 진단 행위(force/워크플로/테스트)가 토큰을 죽인다(관찰자 효과).
#   → 이 스크립트는 갱신·회전·force를 절대 하지 않는다. 오직 read + 상태기록.
#
# 절대 금지(이 스크립트엔 아래가 없어야 함 — 있으면 설계 위반):
#   - grant_type=refresh_token / oauth/token POST (갱신)
#   - --force / credentials.json write (회전)
#   - 새 claude 프로세스 spawn (race 유발)
#
# 기록: expiresAt(만료시각) / API ping HTTP(생존) / credentials mtime(외부 갱신 감지) /
#   메인 금고 공유 claude 수(동시성). → ledger append-only.
#
# 호출: crontab 30분. Step 1 판정(24h) 후 제거 예정(임시 관찰 인프라).

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
set -uo pipefail

CRED="${HOME}/.claude/.credentials.json"
LEDGER="${HOME}/jarvis/runtime/ledger/oauth-main-observer.jsonl"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true

[[ -f "$CRED" ]] || { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"err\":\"no-credentials\"}" >> "$LEDGER"; exit 0; }

# 1. 만료시각 (read only)
EXP_MS=$(node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync('${CRED}','utf-8')).claudeAiOauth?.expiresAt||0))" 2>/dev/null || echo 0)
NOW_MS=$(node -e "process.stdout.write(String(Date.now()))" 2>/dev/null || echo 0)
REMAIN_S=$(( (EXP_MS - NOW_MS) / 1000 ))

# 2. credentials 파일 mtime (외부 갱신/login 감지)
CRED_MTIME=$(stat -f %m "$CRED" 2>/dev/null || echo 0)

# 3. 메인 금고 공유 claude 수 (CLAUDE_CONFIG_DIR 없는 = 메인 사용)
MAIN_CLAUDE=0
for pid in $(ps -Aceo pid,comm 2>/dev/null | awk '$2=="claude"{print $1}'); do
  # CLAUDE_CONFIG_DIR= 가 환경에 있으면 격리 금고, 없으면 메인 금고.
  # grep -c는 매칭 0이어도 "0"을 stdout에 내므로 '|| echo 0' 불필요(중복출력 버그 유발).
  cfg=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -c "CLAUDE_CONFIG_DIR=")
  [[ "${cfg:-0}" == "0" ]] && MAIN_CLAUDE=$((MAIN_CLAUDE+1))
done

# 4. 토큰 생존 ping (갱신 아님 — 단순 API 호출로 200/401 판정)
ATOK=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('${CRED}','utf-8')).claudeAiOauth?.accessToken||'')" 2>/dev/null || echo "")
HTTP=000
if [[ -n "$ATOK" ]]; then
  HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -m 12 -X POST https://api.anthropic.com/v1/messages \
    -H "authorization: Bearer ${ATOK}" -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
    --data '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' 2>/dev/null || echo 000)
fi

# 5b. 장수(8h+) 메인 claude 세션 탐지 (2026-05-31 근본원인: 17h 좀비 세션이 옛 토큰을 30분마다
#     파일에 역동기화 → 401 반복. 8h(토큰수명) 넘는 인터랙티브 세션은 캐시 토큰이 만료됐을 위험).
ZOMBIE_PID=""; ZOMBIE_AGE=""
for pid in $(ps -Aceo pid,comm 2>/dev/null | awk '$2=="claude"{print $1}'); do
  cfg=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -c "CLAUDE_CONFIG_DIR=")
  [[ "${cfg:-0}" != "0" ]] && continue   # 격리 세션 제외, 메인 사용 세션만
  # etime → 초 변환 (DD-HH:MM:SS / HH:MM:SS / MM:SS)
  et=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  secs=$(echo "$et" | awk -F'[-:]' '{n=NF; s=$n + $(n-1)*60; if(n>=3)s+=$(n-2)*3600; if(n>=4)s+=$(n-3)*86400; print s}')
  if [[ -n "$secs" ]] && (( secs > 28800 )); then   # 8h = 28800s
    ZOMBIE_PID="$pid"; ZOMBIE_AGE="$secs"
  fi
done

# 5. 기록 (append-only, 토큰값 없음)
printf '{"ts":"%s","http":%s,"remain_s":%s,"cred_mtime":%s,"main_claude":%s,"zombie_pid":"%s","zombie_age_s":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${HTTP}" "${REMAIN_S}" "${CRED_MTIME}" "${MAIN_CLAUDE}" "${ZOMBIE_PID}" "${ZOMBIE_AGE}" >> "$LEDGER"

# 401 발견 시 + 장수 세션 동시 = 범인 특정 → 알림
if [[ "$HTTP" == "401" ]]; then
  _msg="메인 토큰 401 — 만료 ${REMAIN_S}s, 메인claude ${MAIN_CLAUDE}개"
  if [[ -n "$ZOMBIE_PID" ]]; then
    _msg="${_msg} | 🧟 범인 의심: PID ${ZOMBIE_PID} ($(( ZOMBIE_AGE/3600 ))h 좀비 세션이 옛 토큰 역동기화 추정). 해결: 해당 세션 종료 후 /login"
  fi
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [observer] ⚠️ ${_msg}" >&2
  # ntfy/discord 알림 (1h 중복억제)
  _cd="/tmp/jarvis-observer-401-alert.cd"
  if [[ ! -f "$_cd" ]] || (( $(date +%s) - $(stat -f %m "$_cd" 2>/dev/null || echo 0) > 3600 )); then
    touch "$_cd"
    bash "${HOME}/jarvis/runtime/scripts/alert.sh" critical "🧟 메인 토큰 401 + 좀비세션" "$_msg" 2>/dev/null || true
  fi
elif [[ -n "$ZOMBIE_PID" ]]; then
  # 아직 안 죽었어도 8h+ 세션 있으면 사전 경고 (예방)
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [observer] 🟡 장수 세션 경고 — PID ${ZOMBIE_PID} $(( ZOMBIE_AGE/3600 ))h 가동 중. 8h+ 인터랙티브 세션은 캐시 토큰 만료 위험. 작업 끝나면 종료 권장." >&2
fi
exit 0
