#!/usr/bin/env bash
# bot-daily-restart.sh — 일일 봇 재시작 래퍼 (감사 로그 포함)
set -euo pipefail

LOG="/Users/ramsbaby/.openclaw-data/runtime/logs/daily-restart.log"
TS="$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"

echo "[$TS] [daily-restart] 일일 재시작 트리거" >> "$LOG"

/bin/launchctl stop ai.jarvis.discord-bot
STATUS=$?

echo "[$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')] [daily-restart] launchctl stop 완료 (exit=${STATUS})" >> "$LOG"
exit $STATUS
