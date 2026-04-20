#!/usr/bin/env bash
# job-alert.sh — 채용 공고 크롤링 + 매칭 파이프라인
# Nexus 크론으로 실행: 매일 09:00
set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
NODE="/opt/homebrew/bin/node"
LOG="${BOT_HOME}/logs/job-alert.log"
STAMP=$(date '+%Y-%m-%d %H:%M:%S')

# LaunchAgent 실행 시 .env 자동 로드 (NOTION_TOKEN 등 — Notion 상세 리포트용)
if [[ -f "${HOME}/.jarvis/.env" ]]; then
  set -a; source "${HOME}/.jarvis/.env"; set +a
fi

mkdir -p "$(dirname "$LOG")"
echo "[$STAMP] job-alert 시작" >> "$LOG"

# 1단계: 크롤링 (Discord 전송 없이 JSON만 저장)
if "$NODE" "${BOT_HOME}/scripts/job-crawl.mjs" --json-only >> "$LOG" 2>&1; then
  echo "[$STAMP] job-crawl 완료" >> "$LOG"
else
  echo "[$STAMP] job-crawl 실패 (exit $?)" >> "$LOG"
  exit 1
fi

# 2단계: 매칭 + Discord 전송
if "$NODE" "${BOT_HOME}/scripts/job-match.mjs" --discord >> "$LOG" 2>&1; then
  echo "[$STAMP] job-match 완료" >> "$LOG"
else
  echo "[$STAMP] job-match 실패 (exit $?)" >> "$LOG"
  exit 1
fi

echo "[$STAMP] job-alert 완료" >> "$LOG"