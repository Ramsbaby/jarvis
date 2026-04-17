#!/usr/bin/env bash
set -euo pipefail
# geeknews-bench-report.sh — 주간 GeekNews 벤치마크 리포트 → #jarvis-ceo
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "${SCRIPT_DIR}/geeknews-bench.mjs" --mode report 2>>"${BOT_HOME}/logs/geeknews-bench.log"