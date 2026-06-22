#!/usr/bin/env bash
set -uo pipefail

# task-effectiveness-scan.sh — 정의 태스크의 실제 실행 경로 통합 추적 (2026-06-22 신설)
# 목적: "통제 불능" 해소. tasks.json(정의 SSoT)을 crontab/LaunchAgent/task-outcomes/로그(실제)와
#       교차해, 정의만 있고 어디서도 안 도는 "유명무실(orphan)" 태스크를 식별한다.
# 실행 경로가 파편화(bot-cron/crontab/LA/dev-queue)돼 한 곳만 보면 안 보이던 것을 한곳에서 통합.

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
TASKS="$BOT_HOME/config/tasks.json"
OUTCOMES=$(ls -t "$BOT_HOME"/rag/task-outcomes-*.md 2>/dev/null | head -1)
CRONTAB=$(crontab -l 2>/dev/null || true)

[ -f "$TASKS" ] || { echo "FATAL: tasks.json 없음" >&2; exit 1; }

echo "id|상태|실제경로"
# 주의: jq의 `.enabled // true`는 false도 우측 반환(false // true == true) → enabled:false 오분류 버그.
# 명시적 분기로 수정 (2026-06-22).
jq -r '.tasks[] | "\(.id)\t\(if .enabled == false then "false" else "true" end)\t\(.priority // "normal")"' "$TASKS" 2>/dev/null | \
while IFS=$'\t' read -r id en pri; do
  [ -z "$id" ] && continue
  [ "$en" = "false" ] && { echo "$id|disabled|의도 비활성"; continue; }
  [ "$pri" = "event" ] && { echo "$id|event|action-dispatch(이벤트)"; continue; }

  paths=""
  printf '%s\n' "$CRONTAB" | grep -qE "(^|[ /])${id}([ .]|\.sh|\.mjs)" && paths="${paths}cron "
  { [ -f "$HOME/Library/LaunchAgents/com.jarvis.${id}.plist" ] || [ -f "$HOME/Library/LaunchAgents/ai.jarvis.${id}.plist" ]; } && paths="${paths}LA "
  [ -n "$OUTCOMES" ] && grep -qE "\`${id}\`\$" "$OUTCOMES" 2>/dev/null && paths="${paths}botcron "
  ls "$BOT_HOME/logs/${id}"*.log "$HOME/.jarvis/logs/${id}"*.log >/dev/null 2>&1 && paths="${paths}log "
  ls "$HOME/.jarvis/state/circuit-breaker/"*"${id}"* >/dev/null 2>&1 && paths="${paths}cb "
  find "$BOT_HOME/state" -maxdepth 2 -name "*${id}*" 2>/dev/null | grep -q . && paths="${paths}state "

  if [ -z "$paths" ]; then
    echo "$id|🔴ORPHAN|없음(정의만)"
  else
    echo "$id|active|$paths"
  fi
done
