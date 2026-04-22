#!/usr/bin/env bash
# rag-index-cron.sh — Nexus tasks.json cron entry용 wrapper
#
# 배경 (2026-04-22 오답노트 등재):
#   rag-index.mjs를 주기 실행하는 트리거(cron/LaunchAgent)가
#   시스템 어디에도 없어 큐가 64+줄 적체, learned-mistakes.md 인덱싱 0건이 된 사고.
#   재발 방지용 cron 진입점.
#
# 동작:
#   1. BOT_HOME 고정 (~/jarvis/runtime — 큐/state SSoT 위치)
#   2. rag-index-safe.sh 위임 (OMP/ORT 스레드 가드 포함)
#   3. exit code 그대로 전달 (cron-runner가 SUCCESS/FAIL 판정)
#
# 호출처:
#   ~/.jarvis/ # ALLOW-DOTJARVISconfig/tasks.json → id=rag-index-consume, schedule="30 * * * *"
#
# 실패는 cron-runner가 retry 처리. 본 wrapper는 단순 위임.

set -euo pipefail

export BOT_HOME="${BOT_HOME:-/Users/ramsbaby/jarvis/runtime}"

SAFE_SH="/Users/ramsbaby/jarvis/rag/bin/rag-index-safe.sh"

if [[ ! -x "$SAFE_SH" ]]; then
  echo "[rag-index-cron] FATAL: $SAFE_SH not found or not executable" >&2
  exit 127
fi

exec bash "$SAFE_SH" "$@"
