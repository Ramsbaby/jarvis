#!/bin/bash

# Jarvis System Health Check
# 주기적으로 시스템 상태를 점검하고 건강도 갱신

set -euo pipefail
JARVIS_HOME="${HOME}/.jarvis"
STATE_DIR="${JARVIS_HOME}/state"
LOGS_DIR="${JARVIS_HOME}/logs"
HEALTH_FILE="${STATE_DIR}/health.json"

# 현재 상태 수집
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0")
MEMORY_USAGE=$(vm_stat 2>/dev/null | grep "Pages free" | awk '{print $3}' | sed 's/\.//' | awk '{printf "%.0f", 100 * $1 / (4 * 1024 * 1024 * 1024)}' || echo "0")
CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")

# 크론 에러 카운트 (최근 1시간)
HOUR_AGO=$(date -v-1H +%Y-%m-%d\ %H:%M:%S)
CRON_FAILURES=$(tail -200 "${LOGS_DIR}/cron.log" 2>/dev/null | grep -cE 'ABORTED|FAILED' || echo "0")

# health.json 갱신
mkdir -p "${STATE_DIR}"
cat > "${HEALTH_FILE}" << JSON_EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "disk_percent": ${DISK_USAGE:-0},
  "memory_percent": ${MEMORY_USAGE:-0},
  "cpu_load": ${CPU_LOAD:-0},
  "cron_recent_failures": ${CRON_FAILURES:-0},
  "uptime": "$(uptime | awk -F',' '{print $1}')"
}
JSON_EOF

echo "[system-health] Health check complete: disk=${DISK_USAGE}% cpu_load=${CPU_LOAD} cron_fails=${CRON_FAILURES}"
