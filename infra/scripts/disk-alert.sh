#!/usr/bin/env bash
# disk-alert.sh — 디스크 사용률 + 여유 공간 이중 체크
# APFS 볼륨에서 capacity%만으로는 실제 여유 공간 파악 불가 → avail GB 병행 체크
# Claude -p 불필요. 순수 bash.

set -euo pipefail

USAGE=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
AVAIL_BLOCKS=$(df / | awk 'NR==2 {print $4}')
AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $AVAIL_BLOCKS * 512 / 1024 / 1024 / 1024}")
AVAIL_INT=$(awk "BEGIN {printf \"%d\", $AVAIL_BLOCKS * 512 / 1024 / 1024 / 1024}")

# 알람 조건: capacity 85%+ OR 여유 10GB 미만
ALERT=0
ALERT_LEVEL="🟡 경고"
if (( USAGE >= 85 )); then
    ALERT=1
    ALERT_LEVEL="🔴 긴급"
elif (( AVAIL_INT <= 10 )); then
    ALERT=1
fi
[[ "$AVAIL_INT" -le 5 ]] && ALERT_LEVEL="🔴 긴급"

if (( ALERT == 1 )); then
    DISK_INFO=$(df -h / | awk 'NR==2 {print $3"|"$2"|"$4}')
    DISK_USED=$(echo "$DISK_INFO" | cut -d'|' -f1)
    DISK_TOTAL=$(echo "$DISK_INFO" | cut -d'|' -f2)
    DISK_FREE=$(echo "$DISK_INFO" | cut -d'|' -f3)

    echo "${ALERT_LEVEL} 디스크 경고: ${USAGE}% 사용 중 / 여유 ${AVAIL_GB}GB"
    echo "사용: $DISK_USED / 전체: $DISK_TOTAL / 여유: $DISK_FREE"

    # 시각화 카드 Discord 전송
    BOT_HOME_LOCAL="${BOT_HOME:-${HOME}/jarvis/runtime}"
    VISUAL_SCRIPT="$BOT_HOME_LOCAL/scripts/discord-visual.mjs"
    if command -v node >/dev/null 2>&1 && [[ -f "$VISUAL_SCRIPT" ]]; then
        DISK_JSON="{\"pct\":${USAGE},\"used\":\"${DISK_USED}\",\"total\":\"${DISK_TOTAL}\",\"free\":\"${DISK_FREE}\",\"timestamp\":\"$(date '+%Y-%m-%d %H:%M')\"}"
        node "$VISUAL_SCRIPT" --type disk --data "$DISK_JSON" --channel jarvis-system \
            >> "$BOT_HOME_LOCAL/logs/system-doctor.log" 2>&1 || true
    fi

    # [ON-DEMAND HOOK] disk.threshold_exceeded 이벤트 발행 → log-cleanup 태스크 트리거
    "$BOT_HOME_LOCAL/scripts/emit-event.sh" "disk.threshold_exceeded" \
        "{\"usage\":${USAGE}}" \
        >> "$BOT_HOME_LOCAL/logs/event-watcher.log" 2>&1 || true
fi
# 90% 미만이면 무출력 → bot-cron.sh가 allowEmptyResult=true 처리
exit 0