#!/usr/bin/env bash
# kakao-calendar-add.sh — 카카오 캘린더 이벤트 등록
# 사용법: bash kakao-calendar-add.sh "2026-05-10" "제목" ["설명"]
# 날짜 형식: YYYY-MM-DD

set -euo pipefail

SECRETS="$HOME/.jarvis/config/secrets/kakao.json"

if [[ ! -f "$SECRETS" ]]; then
  echo "❌ kakao.json 없음: $SECRETS" >&2
  exit 1
fi

ACCESS_TOKEN=$(jq -r '.access_token' "$SECRETS")
REST_API_KEY=$(jq -r '.rest_api_key' "$SECRETS")
CLIENT_SECRET=$(jq -r '.client_secret' "$SECRETS")
REFRESH_TOKEN=$(jq -r '.refresh_token' "$SECRETS")

DATE="${1:-}"
TITLE="${2:-}"
DESCRIPTION="${3:-}"

if [[ -z "$DATE" || -z "$TITLE" ]]; then
  echo "사용법: $0 YYYY-MM-DD 제목 [설명]" >&2
  exit 1
fi

# access_token 갱신 함수
refresh_access_token() {
  RESP=$(curl -s -X POST https://kauth.kakao.com/oauth/token \
    -d "grant_type=refresh_token" \
    -d "client_id=$REST_API_KEY" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "refresh_token=$REFRESH_TOKEN")

  NEW_AT=$(echo "$RESP" | jq -r '.access_token // empty')
  NEW_RT=$(echo "$RESP" | jq -r '.refresh_token // empty')

  if [[ -z "$NEW_AT" ]]; then
    echo "❌ 토큰 갱신 실패: $RESP" >&2
    exit 1
  fi

  # secrets 업데이트
  TMP=$(mktemp)
  jq --arg at "$NEW_AT" '.access_token = $at' "$SECRETS" > "$TMP"
  if [[ -n "$NEW_RT" ]]; then
    jq --arg rt "$NEW_RT" '.refresh_token = $rt' "$TMP" > "$SECRETS"
  else
    mv "$TMP" "$SECRETS"
  fi

  ACCESS_TOKEN="$NEW_AT"
  echo "🔄 access_token 갱신 완료"
}

# 이벤트 등록
register_event() {
  local at="$1"
  # 카카오 캘린더 all_day=true: start_at/end_at 반드시 yyyy-mm-ddT00:00:00Z 형식
  # end_at은 start_at보다 커야 함 → 다음날 자정으로 설정
  START="${DATE}T00:00:00Z"
  NEXT_DATE=$(date -v+1d -j -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null || date -d "$DATE + 1 day" "+%Y-%m-%d")
  END="${NEXT_DATE}T00:00:00Z"

  BODY=$(jq -n \
    --arg title "$TITLE" \
    --arg desc "$DESCRIPTION" \
    --arg start "$START" \
    --arg end "$END" \
    '{
      title: $title,
      time: {
        start_at: $start,
        end_at: $end,
        time_zone: "Asia/Seoul",
        all_day: true,
        lunar: false
      },
      description: $desc,
      reminders: [1440]
    }')

  curl -s -X POST "https://kapi.kakao.com/v2/api/calendar/create/event" \
    -H "Authorization: Bearer $at" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "event=$BODY"
}

RESULT=$(register_event "$ACCESS_TOKEN")
ERR_CODE=$(echo "$RESULT" | jq -r '.code // empty')

# 401 또는 -401 → 토큰 만료, 갱신 후 재시도
if [[ "$ERR_CODE" == "-401" || "$ERR_CODE" == "401" ]]; then
  echo "⚠️ 토큰 만료 감지 — 갱신 중..."
  refresh_access_token
  RESULT=$(register_event "$ACCESS_TOKEN")
  ERR_CODE=$(echo "$RESULT" | jq -r '.code // empty')
fi

EVENT_ID=$(echo "$RESULT" | jq -r '.event_id // empty')

if [[ -n "$EVENT_ID" ]]; then
  echo "✅ 카카오 캘린더 등록 완료"
  echo "   - 제목: $TITLE"
  echo "   - 날짜: $DATE"
  echo "   - event_id: $EVENT_ID"
else
  echo "❌ 등록 실패: $RESULT" >&2
  exit 1
fi
