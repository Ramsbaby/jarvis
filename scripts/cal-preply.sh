#!/usr/bin/env bash
set -euo pipefail

# cal-preply.sh — Google Calendar에서 Preply 수업 일정 조회
# 사용법: cal-preply.sh [FROM:YYYY-MM-DD] [TO:YYYY-MM-DD]
#   인자 생략 시 오늘 기준 조회
# 인증: gog CLI 저장 credentials (calendar scope) 사용

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_HOME="${BOT_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

CALENDAR_ID="ecce39118ebc8f15510d9f8bd6d837f89b17e7f9baf57a6d4587105b235ce7ea@group.calendar.google.com"
TOKEN_CACHE="$BOT_HOME/state/gcal-token.json"
GOG_CREDS="$HOME/Library/Application Support/gogcli/credentials.json"
GOG_EMAIL="${GOOGLE_ACCOUNT:-}"
if [[ -z "$GOG_EMAIL" ]]; then
    if [[ -f "$BOT_HOME/discord/.env" ]]; then
        set -a; source "$BOT_HOME/discord/.env"; set +a
    fi
    GOG_EMAIL="${GOOGLE_ACCOUNT:-}"
fi
if [[ -z "$GOG_EMAIL" ]]; then
    echo '{"error":"GOOGLE_ACCOUNT not set. Add GOOGLE_ACCOUNT=your@gmail.com to discord/.env"}' >&2; exit 1
fi

if [[ ! -f "$GOG_CREDS" ]]; then
    echo "{\"error\":\"gog credentials not found. Run: gog auth add $GOG_EMAIL --services calendar\"}" >&2
    exit 1
fi

DATE_FROM="${1:-$(date +%Y-%m-%d)}"
DATE_TO="${2:-$DATE_FROM}"
TIME_MIN="${DATE_FROM}T00:00:00+09:00"
TIME_MAX="${DATE_TO}T23:59:59+09:00"

# access_token 캐시 확인 (55분)
ACCESS_TOKEN=""
CACHE_TTL=3300

if [[ -f "$TOKEN_CACHE" ]]; then
    CACHED_AT=$(jq -r '.cached_at // 0' "$TOKEN_CACHE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - CACHED_AT ))
    if (( AGE < CACHE_TTL )); then
        ACCESS_TOKEN=$(jq -r '.access_token // ""' "$TOKEN_CACHE" 2>/dev/null || true)
    fi
fi

# 토큰 갱신: gog credentials + gog refresh_token 사용
if [[ -z "$ACCESS_TOKEN" ]]; then
    TMPDIR_TOKEN=$(mktemp -d /tmp/gcal-tok-XXXXXX)
    GOG_TOK_FILE="$TMPDIR_TOKEN/gog-refresh.json"
    trap 'rm -rf "$TMPDIR_TOKEN"' EXIT

    # gog refresh_token export (calendar scope)
    gog auth tokens export "$GOG_EMAIL" --out "$GOG_TOK_FILE" --overwrite 2>/dev/null || {
        echo "{\"error\":\"gog token export failed. Run: gog auth add ${GOG_EMAIL} --services calendar\"}"
        exit 1
    }

    CLIENT_ID=$(jq -r '.client_id' "$GOG_CREDS")
    CLIENT_SECRET=$(jq -r '.client_secret' "$GOG_CREDS")
    REFRESH_TOKEN=$(jq -r '.refresh_token' "$GOG_TOK_FILE")

    TMPFILE=$(mktemp "$TMPDIR_TOKEN/token-XXXXXX.json")

    curl -sf -X POST "https://oauth2.googleapis.com/token" \
        -d "client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&refresh_token=${REFRESH_TOKEN}&grant_type=refresh_token" \
        -o "$TMPFILE" 2>/dev/null || true

    ACCESS_TOKEN=$(jq -r '.access_token // ""' "$TMPFILE" 2>/dev/null || true)

    if [[ -z "$ACCESS_TOKEN" ]]; then
        echo "{\"error\":\"Token refresh failed: $(jq -r '.error_description // .error // "unknown"' "$TMPFILE" 2>/dev/null || echo 'no response')\"}"
        exit 1
    fi

    # 캐시 저장
    mkdir -p "$(dirname "$TOKEN_CACHE")"
    jq -n --arg token "$ACCESS_TOKEN" --argjson ts "$(date +%s)" \
        '{"access_token": $token, "cached_at": $ts}' > "$TOKEN_CACHE"
fi

# URL 인코딩
ENCODED_ID=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$CALENDAR_ID', safe=''))")
ENCODED_MIN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TIME_MIN', safe=''))")
ENCODED_MAX=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TIME_MAX', safe=''))")

# Google Calendar Events API
curl -sf \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://www.googleapis.com/calendar/v3/calendars/${ENCODED_ID}/events?timeMin=${ENCODED_MIN}&timeMax=${ENCODED_MAX}&orderBy=startTime&singleEvents=true&maxResults=20" \
    2>/dev/null || echo '{"error":"Google Calendar API call failed"}'
