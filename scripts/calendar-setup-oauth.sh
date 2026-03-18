#!/usr/bin/env bash
# calendar-setup-oauth.sh — 1회성 Google Calendar OAuth 설정
# 브라우저에서 인증 후 refresh token을 파일에 저장
set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
TOKEN_FILE="$BOT_HOME/config/google-calendar-token.json"
CRED_FILE="$HOME/Library/Application Support/gogcli/credentials.json"

if [[ ! -f "$CRED_FILE" ]]; then
    echo "ERROR: $CRED_FILE 없음"
    exit 1
fi

CLIENT_ID=$(python3 -c "import json; print(json.load(open('$CRED_FILE'))['client_id'])")
CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$CRED_FILE'))['client_secret'])")

SCOPE="https://www.googleapis.com/auth/calendar.readonly"
REDIRECT="urn:ietf:wg:oauth:2.0:oob"

AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT}&response_type=code&scope=${SCOPE}&access_type=offline&prompt=consent"

echo ""
echo "=== Google Calendar OAuth 설정 ==="
echo ""
echo "1. 아래 URL을 브라우저에서 열어주세요:"
echo ""
echo "$AUTH_URL"
echo ""
echo "2. Google 로그인 후 '허용' 클릭"
echo "3. 표시되는 인증 코드를 아래에 붙여넣기:"
echo ""
read -r -p "인증 코드: " AUTH_CODE

if [[ -z "$AUTH_CODE" ]]; then
    echo "ERROR: 코드가 비어있습니다."
    exit 1
fi

# Exchange auth code for tokens
RESPONSE=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
    -d "code=$AUTH_CODE" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "redirect_uri=$REDIRECT" \
    -d "grant_type=authorization_code")

REFRESH_TOKEN=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('refresh_token',''))")

if [[ -z "$REFRESH_TOKEN" ]]; then
    echo "ERROR: refresh token 발급 실패"
    echo "$RESPONSE"
    exit 1
fi

# Save tokens
cat > "$TOKEN_FILE" << TOKEOF
{
  "client_id": "$CLIENT_ID",
  "client_secret": "$CLIENT_SECRET",
  "refresh_token": "$REFRESH_TOKEN",
  "account": "${GOOGLE_ACCOUNT}"
}
TOKEOF
chmod 600 "$TOKEN_FILE"

echo ""
echo "✅ 토큰 저장 완료: $TOKEN_FILE"
echo "   calendar-alert.sh가 자동으로 이 파일을 사용합니다."
