#!/usr/bin/env bash

# disk-alert.sh - 디스크 사용률 모니터링 및 경보
# 디스크 사용률이 임계값(기본 90%) 이상일 때 경고 발송
# Usage: disk-alert.sh [threshold_percent]

set -euo pipefail

# 기본 임계값 (90%)
THRESHOLD="${1:-90}"

# df 명령어로 모든 마운트 포인트 확인 (header 제외)
# 형식: /dev/xxx  123456  45678  77890  37% /mnt

output=""
found_high_usage=false

# 각 파티션마다 체크
while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # 필드 분해: 1=filesystem, 2=blocks, 3=used, 4=avail, 5=percent, 6=mount
    # 예: /dev/disk1s5  234567890  123456789  111111101  52% /
    usage_percent=$(echo "$line" | awk '{print $(NF-1)}' | tr -d '%')
    mount_point=$(echo "$line" | awk '{print $NF}')
    filesystem=$(echo "$line" | awk '{print $1}')

    # 숫자 검증 (percent가 정수인지 확인)
    if ! [[ "$usage_percent" =~ ^[0-9]+$ ]]; then
        continue
    fi

    # 임계값 이상인 파티션만 기록
    if (( usage_percent >= THRESHOLD )); then
        found_high_usage=true
        output="${output}⚠️  ${filesystem} (${mount_point}): ${usage_percent}%
"
    fi
done < <(df -h | tail -n +2)

# 경고 있으면 출력, 없으면 조용히 성공
if [[ "$found_high_usage" == "true" ]]; then
    echo "🔴 DISK ALERT (threshold: ${THRESHOLD}%)
${output}"
    exit 0
else
    # allowEmptyResult=true 설정에 따라 무출력이 정상으로 처리됨
    exit 0
fi
