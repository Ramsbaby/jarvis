#!/usr/bin/env bash
set -euo pipefail
# geeknews-bench-crawl.sh — 일일 GeekNews 크롤 + 분류 + 위키 주입
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "${SCRIPT_DIR}/geeknews-bench.mjs" --mode crawl 2>>"${BOT_HOME}/logs/geeknews-bench.log"