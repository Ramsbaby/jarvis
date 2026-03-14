#!/usr/bin/env bash
source "${JARVIS_HOME:-${BOT_HOME:-$HOME/.jarvis}}/lib/compat.sh" 2>/dev/null || true
set -euo pipefail
SERVICE="ai.jarvis.discord-bot"
uid=$(id -u)
if ${IS_MACOS:-false}; then
  launchctl kickstart -k "gui/${uid}/${SERVICE}" 2>/dev/null
else
  pm2 restart jarvis-bot
fi
echo "Discord 봇 재시작 완료"
