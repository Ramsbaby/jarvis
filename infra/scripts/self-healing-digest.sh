#!/usr/bin/env bash
set -euo pipefail
# self-healing-digest.sh — 주간 self-healing 감사 리포트
#
# OpenClaw incident-digest.sh 패턴 기반.
# 최근 7일 크래시/복구 로그를 파싱해 자율 복구율(autonomy rate)을 산출.
# 결과를 #jarvis-system Discord + 파일로 출력.

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
WATCHDOG_LOG="$BOT_HOME/logs/watchdog.log"
BOT_WATCHDOG_LOG="$BOT_HOME/logs/bot-watchdog.log"
HEAL_LOG="$BOT_HOME/logs/bot-heal.log"
GUARDIAN_LOG="$BOT_HOME/logs/launchd-guardian.log"
PREFLIGHT_LOG="$BOT_HOME/logs/preflight.log"
RESULTS_DIR="$BOT_HOME/results/self-healing-digest"
DISCORD_NOTIFY="${BOT_HOME}/lib/discord-notify-bash.sh"

mkdir -p "$RESULTS_DIR"

# 7일 전 날짜 (macOS/Linux 호환)
if date -v-7d +%Y-%m-%d >/dev/null 2>&1; then
    SINCE=$(date -v-7d +%Y-%m-%d)
else
    SINCE=$(date -d '7 days ago' +%Y-%m-%d)
fi
TODAY=$(date +%Y-%m-%d)

# --- 로그 카운팅 ---

count_pattern() {
    local file="$1" pattern="$2"
    [[ -f "$file" ]] || { echo 0; return; }
    grep -c "$pattern" "$file" 2>/dev/null | head -1 || echo 0
}

count_since() {
    local file="$1" pattern="$2"
    [[ -f "$file" ]] || { echo 0; return; }
    { grep "$pattern" "$file" 2>/dev/null || true; } | awk -v since="$SINCE" '$0 >= since' | wc -l | tr -d ' '
}

# 인시던트 (크래시/다운 감지)
incidents_watchdog=$(count_since "$WATCHDOG_LOG" "CRASHED\|CRASH.LOOP\|FATAL\|DEGRADED")
incidents_guardian=$(count_since "$GUARDIAN_LOG" "RECOVERY:")
incidents_preflight=$(count_since "$PREFLIGHT_LOG" "FAIL:")
incidents_bot_wd=$(count_since "$BOT_WATCHDOG_LOG" "ALERT:")
total_incidents=$(( incidents_watchdog + incidents_guardian + incidents_preflight + incidents_bot_wd ))

# 자동 복구 (성공)
auto_heals=$(count_since "$HEAL_LOG" "복구 완료")
auto_restarts_guardian=$(count_since "$GUARDIAN_LOG" "kickstarting")
auto_restarts_watchdog=$(count_since "$WATCHDOG_LOG" "Restart issued\|kickstart")
auto_preflight_heals=$(count_since "$PREFLIGHT_LOG" "복구 세션 시작")
total_auto=$(( auto_heals + auto_restarts_guardian + auto_restarts_watchdog ))

# L3 에스컬레이션 (AI 복구 시도)
l3_attempts=$(count_since "$HEAL_LOG" "Claude에게 복구 요청")
l3_success=$(count_since "$HEAL_LOG" "Claude 완료")
l3_fail=$(count_since "$HEAL_LOG" "Claude 복구 실패")

# CRASH LOOP
crash_loops=$(count_since "$WATCHDOG_LOG" "CRASH.LOOP")

# Degraded Mode
degraded_entries=$(count_since "$WATCHDOG_LOG" "DEGRADED.*진입")
degraded_recoveries=$(count_since "$WATCHDOG_LOG" "DEGRADED.*복구")

# 자율 복구율 계산
if (( total_incidents > 0 )); then
    autonomy_rate=$(( total_auto * 100 / total_incidents ))
    # cap at 100
    (( autonomy_rate > 100 )) && autonomy_rate=100
else
    autonomy_rate=100
fi

# 등급 판정
if (( autonomy_rate >= 80 )); then
    grade="A"
    grade_emoji="✅"
    grade_msg="자율 복구 시스템 정상 작동"
elif (( autonomy_rate >= 60 )); then
    grade="B"
    grade_emoji="⚠️"
    grade_msg="일부 수동 개입 발생 — 개선 필요"
elif (( autonomy_rate >= 40 )); then
    grade="C"
    grade_emoji="🟠"
    grade_msg="자율 복구율 저조 — 구조적 점검 필요"
else
    grade="F"
    grade_emoji="🚨"
    grade_msg="self-healing 사실상 미작동 — 즉시 수정 필요"
fi

# --- 리포트 생성 ---

REPORT="## Self-Healing 주간 감사 리포트
**기간**: ${SINCE} ~ ${TODAY}

| 지표 | 값 |
|------|-----|
| 총 인시던트 | ${total_incidents}건 |
| 자동 복구 | ${total_auto}건 |
| L3 AI 복구 시도 | ${l3_attempts}건 (성공 ${l3_success} / 실패 ${l3_fail}) |
| Crash Loop | ${crash_loops}회 |
| Degraded Mode | 진입 ${degraded_entries} / 복구 ${degraded_recoveries} |
| **자율 복구율** | **${autonomy_rate}%** |

### 등급: ${grade_emoji} ${grade} — ${grade_msg}

### 레벨별 상세
- **L0 Preflight**: 실패 ${incidents_preflight}건, heal 트리거 ${auto_preflight_heals}건
- **L1 Guardian**: 감지 ${incidents_guardian}건, kickstart ${auto_restarts_guardian}건
- **L2 Watchdog**: 감지 ${incidents_watchdog}건 (bot-watchdog: ${incidents_bot_wd}건)
- **L3 AI Heal**: ${l3_attempts}건 시도 → 성공률 $(( l3_attempts > 0 ? l3_success * 100 / l3_attempts : 0 ))%
- **L4 알림**: crash loop ${crash_loops}회 → jarvis-ceo 에스컬레이션"

# 파일 저장
RESULT_FILE="${RESULTS_DIR}/${TODAY}.md"
echo "$REPORT" > "$RESULT_FILE"

# stdout 출력 (크론 결과 캡처용)
echo "$REPORT"
