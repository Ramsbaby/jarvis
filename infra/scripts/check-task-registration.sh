#!/usr/bin/env bash
# check-task-registration.sh — 태스크 등록 헬스체크
#
# cl-8080a969ce1423ae: 기존 도구 미탐색 + 자동화 파이프라인 미등록
#
# 목적: tasks.json의 enabled:true 항목과 실제 crontab·LaunchAgent를 대조하여
#       불일치를 감지하고 보고한다. 감시 공백이 없도록 정기 실행하는 가드.
#
# 동작:
#   1. tasks.json에서 enabled:true 태스크 추출 (schedule 필드 有)
#   2. 실제 crontab -l 과 비교
#   3. LaunchAgent plist와 비교 (launchctl list 확인)
#   4. 불일치 탐지 시 상세 리포트 출력
#   5. result file에 JSON 기록

set -euo pipefail

# --- Guards ---
source "${HOME}/projects/jarvis/infra/lib/guards.sh" 2>/dev/null || true
assert_variable_set "HOME" "home directory" || exit 1

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
CONFIG_FILE="${BOT_HOME}/config/tasks.json"
LOG_DIR="$BOT_HOME/logs"
REPORT_FILE="${LOG_DIR}/check-task-registration-$(date '+%Y%m%d').jsonl"

mkdir -p "$LOG_DIR"

# ────────────────────────────────────────────────────────────────────────────

# 태스크 등록 상태 분석
check_task_registration() {
  local has_mismatch=0
  local issues=()
  local summary="OK"

  # ── 1. tasks.json에서 enabled:true 태스크 추출 ──
  if [[ ! -f "$CONFIG_FILE" ]]; then
    issues+=("ERROR: $CONFIG_FILE 파일 없음")
    has_mismatch=1
  fi

  # schedule이 있는 enabled:true 태스크만 수집 (cron 등록 대상)
  local enabled_count=$(jq '[.tasks[] | select(.enabled == true and .schedule != null and .schedule != "")] | length' "$CONFIG_FILE" 2>/dev/null || echo "0")

  # ── 2. LaunchAgent 상태 점검 ──
  local la_status="UNLOADED"
  local la_pid=""

  if launchctl list 2>/dev/null | grep -qx "ai.jarvis.bot-cron"; then
    la_status="LOADED"
    la_pid=$(pgrep -f "bot-cron\.sh" | head -1 || true)
  fi

  # ── 3. schedule이 공백인 enabled:true 태스크 탐지 ──
  local problematic_tasks=$(jq -r '.tasks[] | select(.enabled == true and ((.schedule == null) or (.schedule == ""))) | .id' "$CONFIG_FILE" 2>/dev/null | sed 's/^/  /' || true)
  if [[ -n "$problematic_tasks" ]]; then
    has_mismatch=1
  fi

  # ── 4. crontab 등록 상태 점검 ──
  # 실제 crontab에는 bot-cron.sh → cron-master.sh 흐름이 있고,
  # 그 안에서 tasks.json을 읽어 각 태스크를 실행한다.
  # 따라서 crontab에는 직접 태스크별 항목이 없을 수 있으므로
  # 여기서는 bot-cron 래퍼 프로세스 존재 여부만 점검한다.

  local cron_bot_active=0
  if crontab -l 2>/dev/null | grep -qE 'bot-cron|cron-master'; then
    cron_bot_active=1
  fi

  # LaunchAgent가 활성이지만 crontab에는 bot-cron이 없는 경우 → 잠재적 문제
  if [[ "$la_status" == "LOADED" ]] && [[ "$cron_bot_active" == "0" ]]; then
    issues+=("주의: LaunchAgent 활성이지만 crontab에 bot-cron 항목 없음")
  fi

  # ── 5. 비활성화된 태스크 집계 ──
  local disabled_count=$(jq '[.tasks[] | select(.enabled == false or .enabled == null)] | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
  local total_count=$(jq '.tasks | length' "$CONFIG_FILE" 2>/dev/null || echo "0")

  # ── 6. 결과 정리 ──
  if [[ $has_mismatch -eq 1 ]]; then
    summary="ALERT"
  fi

  # ── Report JSON ──
  local issues_json='[]'
  if [[ ${#issues[@]} -gt 0 ]]; then
    issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
  fi

  local report_json=$(cat <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "cluster": "cl-8080a969ce1423ae",
  "result": "$summary",
  "enabled_tasks": $enabled_count,
  "disabled_tasks": $disabled_count,
  "total_tasks": $total_count,
  "launchagent_status": "$la_status",
  "launchagent_pid": "$([ -n "$la_pid" ] && echo "$la_pid" || echo "null")",
  "crontab_bot_active": $cron_bot_active,
  "issues": $issues_json,
  "problematic_tasks_detail": "$(echo "$problematic_tasks" | tr '\n' ' ' | sed 's/  //')"
}
EOF
  )

  echo "$report_json" | tee -a "$REPORT_FILE"

  # ── Console Report ──
  if [[ "$summary" == "OK" ]]; then
    cat <<EOF
✅ 태스크 등록 헬스체크: 정상
  • 활성 태스크: $enabled_count개
  • 비활성 태스크: $disabled_count개 (의도적)
  • LaunchAgent: $la_status
  • cron-bot: $([ $cron_bot_active -eq 1 ] && echo "✅ 활성" || echo "⚠️ 미활성")
EOF
  else
    cat <<EOF
🔴 태스크 등록 헬스체크: $summary
  • 활성 태스크: $enabled_count개
  • 비활성 태스크: $disabled_count개
  • LaunchAgent: $la_status (PID: $la_pid)
  • cron-bot: $([ $cron_bot_active -eq 1 ] && echo "✅ 활성" || echo "❌ 미활성")

문제 항목:
EOF
    if [[ ${#issues[@]} -gt 0 ]]; then
      for issue in "${issues[@]}"; do
        echo "  - $issue"
      done
    fi
    if [[ -n "$problematic_tasks" ]]; then
      echo "  Schedule 누락:"
      echo "$problematic_tasks" | while read -r task; do
        echo "    - $task"
      done
    fi
  fi

  return $has_mismatch
}

# ────────────────────────────────────────────────────────────────────────────

check_task_registration
exit $?
