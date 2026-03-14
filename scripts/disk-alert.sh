#!/usr/bin/env bash
# disk-alert.sh — 디스크 사용률 확인, 90% 초과 시 경고 출력
# Claude -p 불필요. 순수 bash.

set -euo pipefail

USAGE=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')

if (( USAGE >= 90 )); then
    echo "⚠️ 디스크 경고: ${USAGE}% 사용 중 (루트 파티션)"
    echo "$(df -h / | awk 'NR==2 {print "사용: "$3" / 전체: "$2" / 여유: "$4}')"
fi
# 90% 미만이면 무출력 → bot-cron.sh가 allowEmptyResult=true 처리
