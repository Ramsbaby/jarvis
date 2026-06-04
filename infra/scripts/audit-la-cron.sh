#!/usr/bin/env bash
# audit-la-cron.sh — LaunchAgent · tasks.json · crontab 정합성 감사
#
# 2026-05-23 복원: 2026-04-20에 stub(exit 0)으로 대체되어 5주간 no-op 상태였음.
# 자비스 자기 감사 도구의 정지가 36→84건 중복 오진을 만든 메타 결함의 직접 원인.
#
# 역할: 3개 데이터 소스를 비교하여 진짜 중복(이중 실행 위험)만 식별.
#   1) LaunchAgent plist (~/Library/LaunchAgents/com.jarvis.*.plist, ai.jarvis.*.plist)
#   2) tasks.json (~/jarvis/runtime/config/tasks.json) — task spec/manifest SSoT
#   3) crontab -l — 외부 *.sh / *.mjs / *.py 호출
#
# 진짜 중복 판정 기준:
#   - LA가 dispatcher(bot-cron.sh)를 호출 + 동일 task가 crontab에서도 직접 호출 → DUPLICATE_CRITICAL
#   - LA가 직접 *.sh 호출 + crontab도 같은 *.sh 호출 → DUPLICATE_DIRECT
#   - LA만 호출 (bot-cron.sh dispatcher 패턴 1:1) → OK_TASK (정상 토폴로지)
#
# 출력: Discord severity 따라 라우팅 (severity 필드 사용)
set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/audit-la-cron.log"
TASKS_JSON="${HOME}/jarvis/runtime/config/tasks.json"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }
log "=== audit-la-cron 시작 (복원 v2.0) ==="

# 1) LA short names (disabled/bak 제외)
LA_LIST=$(ls ${HOME}/Library/LaunchAgents/com.jarvis.*.plist ${HOME}/Library/LaunchAgents/ai.jarvis.*.plist 2>/dev/null \
  | grep -v "\.disabled\|\.bak\|\.nexus_primary" \
  | xargs -n1 basename \
  | sed 's/\.plist$//')
LA_COUNT=$(echo "${LA_LIST}" | grep -c . || true)

# 2) tasks.json id 목록
TASK_IDS=$(jq -r '.tasks[].id' "${TASKS_JSON}" 2>/dev/null | sort -u || true)
TASK_COUNT=$(echo "${TASK_IDS}" | grep -c . || true)

# 3) crontab 활성 스크립트
# 2026-05-23: grep 0매치 시 sort 입력 비어 exit 0이지만 pipefail로 set -e 트리거 가능 → 외곽 || true 유지
# .js 추가로 next.js server 등 매치 — LA 측 direct_script와 매치 키 동기화
CRON_SCRIPTS=$(crontab -l 2>/dev/null | grep -v "^#" | grep -oE "[a-z0-9_-]+\.(sh|mjs|py|js)\b" 2>/dev/null | sort -u 2>/dev/null || true)
CRON_COUNT=$(echo "${CRON_SCRIPTS}" | grep -c . || true)

log "LA plist: ${LA_COUNT}건, tasks.json: ${TASK_COUNT}건, crontab 스크립트: ${CRON_COUNT}건"

# 4) 진짜 중복 식별 — LA의 ProgramArguments 분석
DUP_CRITICAL=0
DUP_DIRECT=0
OK_TASK=0
EXIT_FAIL=0
GHOST=0

> /tmp/audit-la-cron-detail.txt

for full_name in ${LA_LIST}; do
  plist="${HOME}/Library/LaunchAgents/${full_name}.plist"
  short="${full_name#com.jarvis.}"
  short="${short#ai.jarvis.}"

  # 4a) ProgramArguments 추출 (마지막 string 인자)
  # 2026-05-23 디버그: pipefail + grep 0매치 → set -e silent fail로 board.plist(.js만)에서 스크립트 조기 종료.
  # 모든 grep 파이프에 `|| true` 보호 적용.
  prog=$(grep -A10 "ProgramArguments" "$plist" 2>/dev/null | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/' | head -3 || true)
  is_dispatcher=$(echo "${prog}" | grep -c "bot-cron\.sh" || true)
  # 2026-05-23: .js 추가 + binary basename fallback (cloudflared 등 직접 binary 호출 LA 오분류 차단)
  direct_script=$(echo "${prog}" | grep -oE "[a-z0-9_-]+\.(sh|mjs|py|js)\b" | head -1 || true)
  if [[ -z "${direct_script}" ]]; then
    # ProgramArguments 첫 인자(executable path)의 basename — cloudflared/ollama 등 직접 binary 호출
    direct_script=$(echo "${prog}" | head -1 | xargs basename 2>/dev/null || true)
  fi

  # 4b) 실패 상태 확인
  exit_status=$(launchctl list 2>/dev/null | awk -v label="${full_name}" '$3==label {print $2}')
  if [[ "${exit_status}" != "0" && "${exit_status}" != "-" && -n "${exit_status}" ]]; then
    EXIT_FAIL=$((EXIT_FAIL+1))
    echo "EXIT_FAIL ${full_name} exit=${exit_status}" >> /tmp/audit-la-cron-detail.txt
  fi

  # 4c) 진짜 중복 판정
  if (( is_dispatcher > 0 )); then
    # LA가 dispatcher 호출 — task id가 crontab에도 직접 호출되는지 확인
    if crontab -l 2>/dev/null | grep -qE "bot-cron\.sh ${short}\b"; then
      DUP_CRITICAL=$((DUP_CRITICAL+1))
      echo "DUP_CRITICAL ${full_name} ↔ crontab(bot-cron.sh ${short})" >> /tmp/audit-la-cron-detail.txt
    else
      OK_TASK=$((OK_TASK+1))
    fi
  elif [[ -n "${direct_script}" ]]; then
    # LA가 직접 *.sh/.mjs/.py/.js 또는 binary 호출 — crontab과 매치 검사
    if echo "${CRON_SCRIPTS}" | grep -qxF "${direct_script}"; then
      DUP_DIRECT=$((DUP_DIRECT+1))
      echo "DUP_DIRECT ${full_name} ↔ crontab(${direct_script})" >> /tmp/audit-la-cron-detail.txt
    else
      # 2026-05-23 누락 분기 보강: 직접 호출 + 중복 없음 = 정상 (board·cloudflared 등)
      OK_TASK=$((OK_TASK+1))
    fi
  else
    # ProgramArguments 자체가 비어있는 진짜 GHOST
    GHOST=$((GHOST+1))
    echo "GHOST ${full_name} (ProgramArguments 파싱 불가)" >> /tmp/audit-la-cron-detail.txt
  fi
done

log "정합성 결과: DUP_CRITICAL=${DUP_CRITICAL}, DUP_DIRECT=${DUP_DIRECT}, EXIT_FAIL=${EXIT_FAIL}, GHOST=${GHOST}, OK_TASK=${OK_TASK}"

# 5) 결과 분류 + Discord 라우팅
SEVERITY="info"
TITLE="✅ LA-Cron 정합성 정상"
DETAIL="LA ${LA_COUNT}건, tasks.json ${TASK_COUNT}건. 진짜 중복 0건. OK_TASK=${OK_TASK} (dispatcher 패턴 정상)"

if (( DUP_CRITICAL > 0 || DUP_DIRECT > 0 )); then
  SEVERITY="critical"
  TITLE="🚨 LA-Cron 진짜 중복 발견"
  DETAIL="DUP_CRITICAL=${DUP_CRITICAL} (이중 dispatcher), DUP_DIRECT=${DUP_DIRECT} (직접 충돌). 상세: ~/jarvis/runtime/logs/audit-la-cron.log"
elif (( EXIT_FAIL > 0 )); then
  SEVERITY="info"
  TITLE="⚠️ LA exit≠0 ${EXIT_FAIL}건"
  DETAIL="실패 상태 plist ${EXIT_FAIL}개. 개별 조사 필요."
fi

log "판정: severity=${SEVERITY} ${TITLE}"

# 6) 상세 첫 10건 로그 첨부
log "--- 상세 detail (top 10) ---"
head -10 /tmp/audit-la-cron-detail.txt | tee -a "${LOG}"

# 7) Discord 알림 (정상=silent, 비정상=전송)
if [[ "${SEVERITY}" != "info" || "${EXIT_FAIL}" -gt 0 ]]; then
  if [[ -x "${HOME}/jarvis/runtime/scripts/alert.sh" ]]; then
    bash "${HOME}/jarvis/runtime/scripts/alert.sh" "${SEVERITY}" "${TITLE}" "${DETAIL}" 2>&1 | tee -a "${LOG}"
  fi
fi

log "=== audit-la-cron 종료 ==="
exit 0
