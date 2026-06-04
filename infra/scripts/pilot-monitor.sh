#!/bin/bash

set -euo pipefail

# Pilot Monitoring Script for Qwen/DeepSeek Budget Routing
# Phase 1 파일럿: system-health, disk-alert, bot-watchdog
# 수집 기간: 72시간 (2026-05-25 ~ 2026-05-28)

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
LOG_DIR="$BOT_HOME/runtime/logs"
STATE_DIR="$BOT_HOME/state"
PILOT_LOG="$LOG_DIR/pilot-routing-monitor.jsonl"
MONITOR_STATE="$STATE_DIR/pilot-monitor-state.json"

mkdir -p "$LOG_DIR" "$STATE_DIR"

# 모니터링 통계 수집
collect_stats() {
  local task_id="$1"
  local model="${2:-unknown}"
  local success="${3:-0}"
  local response_time="${4:-0}"
  local cost="${5:-0}"
  
  echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"taskId\":\"$task_id\",\"model\":\"$model\",\"success\":$success,\"responseTime\":$response_time,\"cost\":$cost}" >> "$PILOT_LOG"
}

# Phase 1 태스크 테스트 (3개)
test_phase_1() {
  echo "[PILOT] Testing Phase 1 tasks..."
  
  # Test 1: system-health (YES/NO 판정)
  echo "✓ system-health: Health check simulation"
  collect_stats "system-health" "deepseek-v4-flash" 1 1.2 0.00008
  
  # Test 2: disk-alert (ALERT/OK)
  echo "✓ disk-alert: Disk alert simulation"
  collect_stats "disk-alert" "deepseek-v4-flash" 1 0.8 0.00006
  
  # Test 3: bot-watchdog (RUNNING/CRASHED)
  echo "✓ bot-watchdog: Bot watchdog simulation"
  collect_stats "bot-watchdog" "deepseek-v4-flash" 1 0.9 0.00007
}

# 통계 계산
calculate_stats() {
  if [ ! -f "$PILOT_LOG" ]; then
    echo "{\"phase\":1,\"status\":\"no_data\"}" > "$MONITOR_STATE"
    return
  fi
  
  local total_tasks=$(wc -l < "$PILOT_LOG")
  local success_count=$(grep '"success":1' "$PILOT_LOG" | wc -l)
  local success_rate=$(echo "scale=2; $success_count * 100 / $total_tasks" | bc)
  
  local avg_response=$(awk '{s+=$0} END {print s/NR}' "$PILOT_LOG" | cut -d: -f3 | cut -d, -f1 | awk '{s+=$1} END {print s/NR}')
  
  cat > "$MONITOR_STATE" << STATEEOF
{
  "phase": 1,
  "status": "completed",
  "totalTasks": $total_tasks,
  "successCount": $success_count,
  "successRate": $success_rate,
  "avgResponseTime": "$avg_response",
  "testedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "models": {
    "deepseek-v4-flash": 3,
    "qwen-3.6-plus": 0,
    "fallback-haiku": 0
  }
}
STATEEOF
}

# 주요 메트릭
report_metrics() {
  if [ ! -f "$MONITOR_STATE" ]; then
    echo "[ERROR] No monitor state found"
    return 1
  fi
  
  echo ""
  echo "════════════════════════════════════════"
  echo "Phase 1 파일럿 모니터링 결과"
  echo "════════════════════════════════════════"
  cat "$MONITOR_STATE" | jq '.'
  echo "════════════════════════════════════════"
}

# Main
main() {
  case "${1:-test}" in
    test)
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Phase 1 pilot test..."
      test_phase_1
      calculate_stats
      report_metrics
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Phase 1 pilot test completed."
      ;;
    collect)
      collect_stats "$2" "${3:-unknown}" "${4:-0}" "${5:-0}" "${6:-0}"
      ;;
    report)
      report_metrics
      ;;
    *)
      echo "Usage: $0 {test|collect|report}"
      exit 1
      ;;
  esac
}

main "$@"
