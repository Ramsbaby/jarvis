#!/usr/bin/env bash
# youtube-bench.sh — YouTube 영상 → LLM Wiki 적재 래퍼
#
# Usage:
#   youtube-bench.sh <youtube-url> [--dry-run] [--notify] [--domain <d>]
#
# 환경변수:
#   YOUTUBE_URL        URL을 env로 전달 가능 (tasks.json 트리거용)
#   YOUTUBE_BENCH_CHANNEL  Discord 알림 채널 ID (기본: jarvis-dev)
#
# 예시:
#   youtube-bench.sh "https://youtu.be/xxx"
#   YOUTUBE_URL="https://youtu.be/xxx" youtube-bench.sh --notify

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${BOT_HOME}/logs/youtube-bench.log"
NODE_BIN="${NODE_BIN:-$(command -v node)}"

# URL 우선순위: 첫 번째 위치 인자 → 환경변수 YOUTUBE_URL
URL="${1:-${YOUTUBE_URL:-}}"

if [[ -z "$URL" ]]; then
  echo "[youtube-bench] ❌ YouTube URL이 필요합니다." >&2
  echo "Usage: youtube-bench.sh <url> [--dry-run] [--notify]" >&2
  exit 1
fi

# 나머지 인자를 그대로 node 스크립트에 전달
EXTRA_ARGS=("${@:2}")

echo "[youtube-bench] 🎬 처리 시작: ${URL}" >&2

exec "$NODE_BIN" "${SCRIPT_DIR}/youtube-bench.mjs" "$URL" "${EXTRA_ARGS[@]}"
