#!/usr/bin/env bash
# browser-persistent-launch — 봇이 CDP로 접속할 "항상 떠 있는" 크롬을 띄운다.
#   목적: 봇이 폼을 채운 뒤 브라우저가 닫히지 않아, 주인님이 Mac Mini 화면에서 최종 제출 가능.
#   봇(@playwright/mcp)은 이 크롬에 --cdp-endpoint 로 접속만 하고, 대답이 끝나도 크롬은 그대로 열려 있음.
#   기동 주체는 LaunchAgent(ai.jarvis.browser) — aqua GUI 세션에서 실행되어 화면에 보인다.
set -euo pipefail

PORT="${JARVIS_BROWSER_CDP_PORT:-9222}"
PROFILE="${JARVIS_BROWSER_PROFILE:-$HOME/jarvis/runtime/state/browser-profile}"
CACHE="$HOME/Library/Caches/ms-playwright"

# 최신 chromium-* 빌드의 실행파일을 동적으로 찾음 (버전 하드코딩 회피 — 업데이트 시 자동 추종)
#   실행파일은 chromium-*/chrome-mac-arm64/<app>.app/Contents/MacOS/ 아래(깊이 4)에 있음.
BIN="$(find "$CACHE" -type f -path '*chromium-*/chrome-mac-arm64/*/Contents/MacOS/*' 2>/dev/null | sort | tail -1)"
if [ -z "${BIN:-}" ] || [ ! -x "$BIN" ]; then
  echo "❌ Playwright 크로미움 실행파일을 찾지 못했습니다 ($CACHE/chromium-*). 'npx playwright install chromium' 필요." >&2
  exit 1
fi

mkdir -p "$PROFILE"
echo "🌐 봇 전용 크롬 기동: port=$PORT (localhost only) profile=$PROFILE"
echo "   bin=$BIN"

# --remote-debugging-port 는 기본 127.0.0.1 바인딩(외부 접속 불가). 봇 전용 프로필로 오너 실크롬과 분리.
exec "$BIN" \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-networking \
  --disable-features=Translate \
  about:blank
