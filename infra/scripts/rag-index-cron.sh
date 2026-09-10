#!/usr/bin/env bash
# 2026-09-02: LanceDB 를 만지는 태스크 간 상호 배제.
# 백업(매일 03:00)과 인덱싱(매시 :30)이 같은 디렉터리에서 겹쳐
# tar 가 "File removed before we read it" 로 51회 실패했다.
# 백업 대상과 인덱싱 대상은 같은 디렉터리다(inode 동일 확인).
JARVIS_HOME="${JARVIS_HOME:-$HOME/.openclaw-data/jarvis}"
RAG_LOCK_DIR="/tmp/jarvis-rag-lancedb.lock.d"
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] \
  && . "$JARVIS_HOME/infra/lib/single-instance.sh" \
  && single_instance "rag-lancedb" 7200
# rag-index-cron.sh — Nexus tasks.json cron entry용 wrapper
#
# 배경 (2026-04-22 오답노트 등재):
#   rag-index.mjs를 주기 실행하는 트리거(cron/LaunchAgent)가
#   시스템 어디에도 없어 큐가 64+줄 적체, learned-mistakes.md 인덱싱 0건이 된 사고.
#   재발 방지용 cron 진입점.
#
# 동작:
#   1. BOT_HOME 고정 (~/.openclaw-data/jarvis/runtime — 큐/state SSoT 위치)
#   2. rag-index-safe.sh 위임 (OMP/ORT 스레드 가드 포함)
#   3. exit code 그대로 전달 (cron-runner가 SUCCESS/FAIL 판정)
#
# 호출처:
#   ~/.jarvis/ # ALLOW-DOTJARVISconfig/tasks.json → id=rag-index-consume, schedule="30 * * * *"
#
# 실패는 cron-runner가 retry 처리. 본 wrapper는 단순 위임.

set -euo pipefail

export BOT_HOME="${BOT_HOME:-/Users/ramsbaby/.openclaw-data/jarvis/runtime}"

SAFE_SH="/Users/ramsbaby/.openclaw-data/jarvis/rag/bin/rag-index-safe.sh"

if [[ ! -x "$SAFE_SH" ]]; then
  echo "[rag-index-cron] FATAL: $SAFE_SH not found or not executable" >&2
  exit 127
fi

exec bash "$SAFE_SH" "$@"
