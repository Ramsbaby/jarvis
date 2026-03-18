#!/usr/bin/env bash
# kakao-token-refresh.sh — 카카오 access_token 자동 갱신
# LaunchAgent로 매 5시간마다 실행 (access_token 유효기간 6시간)

set -euo pipefail

SECRETS="$HOME/.jarvis/config/secrets/kakao.json"
LOG="$HOME/.jarvis/logs/kakao-token-refresh.log"

mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [[ ! -f "$SECRETS" ]]; then
  log "ERROR: kakao.json 없음"
  exit 1
fi

REST_API_KEY=$(jq -r '.rest_api_key' "$SECRETS")
CLIENT_SECRET=$(jq -r '.client_secret' "$SECRETS")
REFRESH_TOKEN=$(jq -r '.refresh_token' "$SECRETS")

RESP=$(curl -s -X POST https://kauth.kakao.com/oauth/token \
  -d "grant_type=refresh_token" \
  -d "client_id=$REST_API_KEY" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "refresh_token=$REFRESH_TOKEN")

NEW_AT=$(echo "$RESP" | jq -r '.access_token // empty')
NEW_RT=$(echo "$RESP" | jq -r '.refresh_token // empty')

if [[ -z "$NEW_AT" ]]; then
  log "ERROR: 갱신 실패 — $RESP"
  exit 1
fi

TMP=$(mktemp)
jq --arg at "$NEW_AT" '.access_token = $at' "$SECRETS" > "$TMP"

if [[ -n "$NEW_RT" ]]; then
  jq --arg rt "$NEW_RT" '.refresh_token = $rt' "$TMP" > "$SECRETS"
  log "access_token + refresh_token 갱신 완료"
else
  mv "$TMP" "$SECRETS"
  log "access_token 갱신 완료 (refresh_token 유지)"
fi
