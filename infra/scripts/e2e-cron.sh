#!/usr/bin/env bash

# [오픈클로 이식 2026-09-10] 오픈클로 jarvis-e2e-cron 로 이관(회차5 M단계). OPENCLAW_JOB=1 로 통과한다.
# 재개: rm ~/.openclaw-data/runtime/state/stopped/e2e-cron
if [[ -f "${HOME}/.openclaw-data/runtime/state/stopped/e2e-cron" ]] && [[ "${OPENCLAW_JOB:-}" != "1" ]]; then
    echo "[e2e-cron] 중지 플래그 있음 — 오픈클로로 이관됨"
    exit 0
fi

# e2e-cron.sh - E2E 자가 진단 크론 래퍼 (L1: 자동 실행, 실패 시만 ntfy 에스컬레이션)
# 종료코드: 실패(❌) 1건 이상이면 1 — 잡이 error 로 끝나 failureAlert(연속 2회)가 울린다. 건너뜀·경고만 있으면 0 이되 출력 한 줄에 개수와 이름을 낸다.
# Usage: e2e-cron.sh
# Schedule: 0 5 * * * (매일 05:00 crontab — rag-health 03:00 이후. 2026-09-04 주석을 실제 crontab 에 맞춤; 예전 주석 03:30 은 오기)
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh" 2>/dev/null || true
export BOT_HOME="${BOT_HOME:-${JARVIS_RUNTIME:-${HOME}/.openclaw-data/runtime}}"
export JARVIS_HOME="${JARVIS_HOME:-${HOME}/projects/jarvis}"
SCRIPTS_DIR="${JARVIS_HOME}/infra/scripts"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

# .env 로딩 — 크론 환경에 OPENAI_API_KEY 등 누락 방지
if [[ -f "${BOT_HOME}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${BOT_HOME}/.env"
  set +a
fi

LOG_FILE="${BOT_HOME}/logs/e2e-cron.log"
RESULT_FILE="${BOT_HOME}/results/e2e-health/$(date +%F).txt"
MONITORING="${BOT_HOME}/config/monitoring.json"

mkdir -p "$(dirname "$RESULT_FILE")" "$(dirname "$LOG_FILE")"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $1" >> "$LOG_FILE"; }

log "START"

# gen-inventory.sh 완료 대기 (cron-catalog.md 최신화 필수)
# — e2e-test.sh가 cron-catalog.md 존재/일관성을 검사하므로 선행 필수
if [[ -f "${SCRIPTS_DIR}/gen-inventory.sh" ]]; then
  bash "${SCRIPTS_DIR}/gen-inventory.sh" >> "${BOT_HOME}/logs/gen-inventory.log" 2>&1 || true
  sleep 2  # file sync 대기
fi

# E2E 테스트 실행.
# [2026-10-10] 예전엔 "Discord bot running" 한 건만 실패하면 launchctl 로 ai.jarvis.discord-bot 을 껐다 켜고 최대 2번 재시도했다.
#   그 점검도 봇도 09-10 에 없어졌다 — 없는 서비스를 껐다 켜는 죽은 분기라 뺐다. 한 번만 돌린다.
#   (예전 09-26 주석) `$(...) || true` 바로 뒤에서 $? 를 읽으면 항상 0 이다 — 파이프 앞쪽(e2e-test.sh)의 종료코드를 직접 받는다.
#   스위트가 중간에 죽으면 실패 줄 없이 "통과"로 기록되던 것을 막으려는 것이다.
OUTPUT=$("${SCRIPTS_DIR}/e2e-test.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; exit "${PIPESTATUS[0]}")
E2E_EXIT_CODE=$?

# 작업 트리 상태를 결과 파일 첫 줄에 기록한다 (`# TREE: clean` | `# TREE: dirty (N) — 파일…`).
# 편집 중인 트리를 검사한 FAIL 은 코드 고장이 아니라 미완성 편집일 수 있다 — 2026-09-05 05:00 에
# 편집 중이던 스크립트 2건이 FAIL 로 잡혀 코더 티켓이 만들어졌고 완성 후 두 스위트 모두 통과했다
# (inc-20260905-8a26d2b6). jarvis-auditor 는 dirty 표식이 있으면 FAIL 을 SUSPECT 로만 보고하고 티켓을 만들지 않는다.
# 저장소 루트 기준으로 본다 — 일부 스크립트는 JARVIS_HOME 을 runtime/ 으로 export 하므로 (jarvis-auditor.sh) 그대로 쓰면 pathspec 이 빗나가 fail-open 된다
# [2026-09-26] 위 주의가 경고한 바로 그 일이 이 줄에서 났다 — 앞에서 읽은 runtime/.env 가 JARVIS_HOME 을
#   ~/.jarvis(런타임, git 아님)로 덮어써 git 이 실패했고, 실패가 빈 목록 = "clean" 으로 읽혔다.
#   infra 에 미커밋 파일이 4~7개 있던 09-19~26 내내 결과 첫 줄은 "clean" 이었다(보호 장치가 꺼져 있었다).
#   저장소는 이 스크립트 자신의 위치로 찾고(env 와 무관), git 이 실패하면 clean 이라고 쓰지 않는다.
SELF_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)
DIRTY_FILES=""
if [[ -n "$REPO_ROOT" ]] && DIRTY_FILES=$(git -C "$REPO_ROOT" status --porcelain -- infra 2>/dev/null); then
  DIRTY_FILES=$(printf '%s\n' "$DIRTY_FILES" | awk 'NF{print $2}')
else
  REPO_ROOT=""
fi
DIRTY_COUNT=$(printf '%s' "$DIRTY_FILES" | grep -c . || true)
if [[ -z "$REPO_ROOT" ]]; then
  TREE_LINE="# TREE: dirty (?) — 저장소 상태 확인 실패(${SELF_DIR}) — 모르면 편집 중으로 본다"
  log "TREE: 확인 실패 — dirty 로 기록(FAIL 은 SUSPECT)"
elif [[ "$DIRTY_COUNT" -gt 0 ]]; then
  TREE_LINE="# TREE: dirty (${DIRTY_COUNT}) — $(printf '%s' "$DIRTY_FILES" | head -5 | tr '\n' ' ')"
  log "TREE: dirty (${DIRTY_COUNT} files in infra/) — FAIL 은 SUSPECT 로 취급됨"
else
  TREE_LINE="# TREE: clean"
fi

# 스위트가 끝까지 못 갔으면(요약 줄 없음) 또는 실패 줄 없이 비정상 종료했으면 그 자체를 실패 1건으로 센다.
#   e2e-test.sh 는 실패가 있을 때만 1 로 끝난다 — 실패 줄이 있는 1 은 정상 경로다.
if ! grep -q "Results:" <<<"$OUTPUT"; then
  OUTPUT="${OUTPUT}
❌ FAIL: e2e suite aborted before summary (rc=${E2E_EXIT_CODE})"
elif [[ "$E2E_EXIT_CODE" -ne 0 ]] && ! grep -q "❌ FAIL" <<<"$OUTPUT"; then
  OUTPUT="${OUTPUT}
❌ FAIL: e2e suite exited rc=${E2E_EXIT_CODE} without a FAIL line"
fi

# 결과 파일 저장
{ echo "$TREE_LINE"; echo "$OUTPUT"; } > "$RESULT_FILE"

# 통계 추출
PASS_COUNT=$(echo "$OUTPUT" | grep -c "✅ PASS" || true)
FAIL_COUNT=$(echo "$OUTPUT" | grep -c "❌ FAIL" || true)
WARN_COUNT=$(echo "$OUTPUT" | grep -c "⚠️  WARN" || true)
SKIP_COUNT=$(echo "$OUTPUT" | grep -c "⏭️  SKIP" || true)
# [2026-10-10] 분모는 '실제로 잰 것'(통과+실패+경고)이다. 예전엔 건너뜀까지 분모에 넣어 "65/91 passed, exit 0, OK" 로 기록됐다 —
#   26개는 실패가 아니라 아무것도 재지 않은 건너뜀(디스코드 봇 전용 검사·은퇴 태스크)이었는데, 12일 내내 "26개 실패"처럼 읽혔고
#   system-doctor 도 "65/91 통과"를 정상으로 표시했다. 건너뜀은 따로 센다 — 재지 않은 칸은 통과가 아니다.
MEASURED=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

SUMMARY="${PASS_COUNT}/${MEASURED} passed"
if [[ $FAIL_COUNT -gt 0 ]]; then SUMMARY="${SUMMARY}, ${FAIL_COUNT} FAILED"; fi
if [[ $WARN_COUNT -gt 0 ]]; then SUMMARY="${SUMMARY}, ${WARN_COUNT} warned"; fi
if [[ $SKIP_COUNT -gt 0 ]]; then SUMMARY="${SUMMARY}, ${SKIP_COUNT} skipped"; fi

# 항목 이름만 뽑아 쉼표로 잇는다(최대 5개) — 잡 출력 한 줄로 감지기가 읽을 수 있게.
names_of() {   # <마커 정규식> → "a, b, c (외 N)"
  local list n
  list=$(printf '%s\n' "$OUTPUT" | grep -E "$1" | sed -E 's/^.*(FAIL|WARN|SKIP): //' | sed -E 's/ — .*$//; s/ \(.*\)$//' | awk 'NF')
  n=$(printf '%s\n' "$list" | grep -c . || true)
  [[ "$n" -gt 0 ]] || return 0
  printf '%s' "$(printf '%s\n' "$list" | head -5 | paste -sd',' - | sed 's/,/, /g')"
  [[ "$n" -gt 5 ]] && printf ' (외 %d)' $((n - 5))
  return 0
}

# 어제(직전 결과 파일들)와 같은 실패가 며칠째인가 — 같은 실패가 매일 똑같이 찍혀도 아무도 안 보던 구조(10-10 주간 감사)를 끊는다.
#   오늘 실패가 모두 들어 있는 직전 결과 파일이 며칠 이어지는지 센다(결과 파일 기준, 없는 날은 건너뛴다).
STREAK_DAYS=1; SAME_AS_PREV=0
if [[ $FAIL_COUNT -gt 0 ]]; then
  TODAY_FAILS=$(printf '%s\n' "$OUTPUT" | grep "❌ FAIL" | sed 's/.*❌ FAIL: //' | sort -u)
  TODAY_N=$(printf '%s\n' "$TODAY_FAILS" | grep -c . || true)
  _first=1
  while IFS= read -r _f; do
    [[ -f "$_f" ]] || continue
    _prev=$(grep "❌ FAIL" "$_f" 2>/dev/null | sed 's/.*❌ FAIL: //' | sort -u)
    _common=$(comm -12 <(printf '%s\n' "$TODAY_FAILS") <(printf '%s\n' "$_prev") | grep -c . || true)
    if [[ $_first -eq 1 ]]; then SAME_AS_PREV=$_common; _first=0; fi
    if [[ "$_common" -eq "$TODAY_N" ]]; then STREAK_DAYS=$((STREAK_DAYS + 1)); else break; fi
  done < <(ls -1 "$(dirname "$RESULT_FILE")"/*.txt 2>/dev/null | grep -v -F "$RESULT_FILE" | sort -r)
fi

# Determine exit code (0 if no failures, 1 if there are failures)
if [[ $FAIL_COUNT -gt 0 ]]; then
    log "RESULT: ${SUMMARY} (exit: 1, suite rc=${E2E_EXIT_CODE})"

    # 실패 항목 추출
    FAILED_ITEMS=$(echo "$OUTPUT" | grep "❌ FAIL" | sed 's/❌ FAIL: //' | tr '\n' ', ' | sed 's/,$//')
    ALERT_MSG="E2E 자가진단 실패 (${FAIL_COUNT}건): ${FAILED_ITEMS}"

    log "ALERT: ${ALERT_MSG}"
    log "STREAK: 어제와 같은 실패 ${SAME_AS_PREV}개 · 같은 실패 연속 ${STREAK_DAYS}일째"
    # 잡 출력(자동 작업 목록·감지기가 읽는 한 줄). 종료코드 1 과 함께 나간다.
    echo "E2E 점검 실패 ${FAIL_COUNT}건 (통과 ${PASS_COUNT}/${MEASURED}) — 어제와 같은 실패 ${SAME_AS_PREV}개 · 같은 실패 연속 ${STREAK_DAYS}일째"
    echo "실패: ${FAILED_ITEMS}"

    # ntfy 에스컬레이션
    NTFY_SERVER=$(jq -r '.ntfy.server' "$MONITORING" 2>/dev/null || echo "https://ntfy.sh")
    NTFY_TOPIC=$(jq -r '.ntfy.topic' "$MONITORING" 2>/dev/null || echo "")
    if [[ "${JARVIS_NO_EXTERNAL:-}" == "1" ]]; then
        log "NO_EXTERNAL — ntfy 에스컬레이션 생략"
    elif [[ -n "$NTFY_TOPIC" && "$NTFY_TOPIC" != "null" ]]; then
        curl -sf -m 5 \
            -H "Title: ⚠️ E2E 실패" \
            -H "Priority: high" \
            -H "Tags: warning" \
            -d "$ALERT_MSG" \
            "${NTFY_SERVER}/${NTFY_TOPIC}" > /dev/null 2>&1 || true
    fi

    # 오래된 결과 정리 (30일 초과)
    find "$(dirname "$RESULT_FILE")" -name "*.txt" -mtime +30 -delete 2>/dev/null || true
    exit 1
else
    log "RESULT: ${SUMMARY} (exit: 0, suite rc=${E2E_EXIT_CODE})"
    log "OK: ${SUMMARY}"
    # 잡 출력 — "command ok with no output" 으로 끝나던 것을 결과 한 줄로. 경고·건너뜀이 있으면 이름까지 낸다.
    echo "E2E 점검 통과 ${PASS_COUNT}/${MEASURED} · 실패 0 · 경고 ${WARN_COUNT} · 건너뜀 ${SKIP_COUNT}"
    [[ $WARN_COUNT -gt 0 ]] && echo "경고: $(names_of '⚠️  WARN')"
    [[ $SKIP_COUNT -gt 0 ]] && echo "건너뜀(재지 않은 점검): $(names_of '⏭️  SKIP')"

    # 오래된 결과 정리 (30일 초과)
    find "$(dirname "$RESULT_FILE")" -name "*.txt" -mtime +30 -delete 2>/dev/null || true
    exit 0
fi