#!/bin/bash
# 🚲 카카오 캘린더 자전거 기록 전용 스크립트
# 주황색(ORANGE), 하루종일, 제목 "🚲🚲 자전거"

set -euo pipefail

TOKEN_FILE="$HOME/.openclaw/secrets/kakao-token.json"

# 토큰 갱신 (만료 임박 시 자동)
bash "$(dirname "$0")/../../openclaw/scripts/kakao-token-refresh.sh" > /dev/null 2>&1 || true

if [ -f "$TOKEN_FILE" ]; then
    KAKAO_ACCESS_TOKEN=$(python3 -c "import json; print(json.load(open('$TOKEN_FILE'))['access_token'])" 2>/dev/null)
fi

if [ -z "${KAKAO_ACCESS_TOKEN:-}" ]; then
    echo "❌ KAKAO_ACCESS_TOKEN 없음. $TOKEN_FILE 확인 필요."
    exit 1
fi

# 날짜 파라미터 (YYYY-MM-DD)
DATE="${1:-}"
if [ -z "$DATE" ]; then
    echo "❌ 사용법: $0 YYYY-MM-DD"
    exit 1
fi

# KST 기준 하루종일 → UTC T00:00:00Z (카카오 all_day 규칙)
START_AT="${DATE}T00:00:00Z"
# end_at = 다음 날 T00:00:00Z
NEXT_DAY=$(date -j -v+1d -f "%Y-%m-%d" "$DATE" +%Y-%m-%d 2>/dev/null \
    || date -d "$DATE + 1 day" +%Y-%m-%d)
END_AT="${NEXT_DAY}T00:00:00Z"

EVENT_JSON=$(cat << EOF
{
  "title": "🚲🚲 자전거",
  "color": "ORANGE",
  "time": {
    "start_at": "$START_AT",
    "end_at": "$END_AT",
    "time_zone": "Asia/Seoul",
    "all_day": true,
    "lunar": false
  }
}
EOF
)

RESPONSE=$(curl -s -X POST "https://kapi.kakao.com/v2/api/calendar/create/event" \
  -H "Authorization: Bearer $KAKAO_ACCESS_TOKEN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "calendar_id=primary" \
  --data-urlencode "event=$EVENT_JSON")

if echo "$RESPONSE" | jq -e '.event_id' > /dev/null 2>&1; then
    EVENT_ID=$(echo "$RESPONSE" | jq -r '.event_id')
    echo "✅ 자전거 기록 완료"
    echo "날짜: $DATE"
    echo "색상: ORANGE"
    echo "ID: $EVENT_ID"
else
    echo "❌ 등록 실패"
    echo "$RESPONSE" | jq '.'
    exit 1
fi
