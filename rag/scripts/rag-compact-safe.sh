#!/usr/bin/env bash
set -euo pipefail

# RAG 스크립트 위치 자동 감지
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# INFRA_HOME 결정: BOT_HOME > ~/.local/share/jarvis
INFRA_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
# RAG_HOME 결정: JARVIS_RAG_HOME > INFRA_HOME/rag
RAG_HOME="${JARVIS_RAG_HOME:-${INFRA_HOME}/rag}"

LOG="${INFRA_HOME}/logs/rag-compact.log"
mkdir -p "$(dirname "$LOG")"

COOLDOWN_FILE="${INFRA_HOME}/state/rag-compact-last.txt"
COOLDOWN_SEC=21600  # 6시간
REBUILD_SENTINEL="${INFRA_HOME}/state/rag-rebuilding.json"
COMPACT_FLAG="${INFRA_HOME}/state/rag-compact-needed"
LOCK_FILE="${RAG_HOME}/write.lock"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# 리빌드 중이면 compact 건너뜀
if [ -f "$REBUILD_SENTINEL" ]; then
  echo "[$(ts)] [rag-compact] fresh rebuild 진행 중 — compact 건너뜀" >> "$LOG"
  exit 0
fi

# compact-needed 플래그 확인
_bypass_cooldown=0
if [ -f "$COMPACT_FLAG" ]; then
  _bypass_cooldown=1
  echo "[$(ts)] [rag-compact] compact-needed 플래그 감지 — 쿨다운 우회" >> "$LOG"
fi

# 6h 쿨다운 체크
if [ "$_bypass_cooldown" -eq 0 ] && [ -f "$COOLDOWN_FILE" ]; then
  last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  elapsed=$(( now - last ))
  if (( elapsed < COOLDOWN_SEC )); then
    remaining=$(( (COOLDOWN_SEC - elapsed) / 60 ))
    echo "[$(ts)] [rag-compact] 쿨다운 중 (${elapsed}s 경과, 잔여 ${remaining}m) — compact 건너뜀" >> "$LOG"
    exit 0
  fi
fi

# rag-index가 실행 중이면 compact 건너뜀
if pgrep -f "rag-index.mjs" > /dev/null 2>&1; then
  echo "[$(ts)] [rag-compact] rag-index 실행 중 — compact 건너뜀" >> "$LOG"
  exit 0
fi

# lock 파일이 있으면 건너뜀
if [ -f "$LOCK_FILE" ]; then
  echo "[$(ts)] [rag-compact] write lock 있음 — compact 건너뜀" >> "$LOG"
  exit 0
fi

# 쿨다운 타임스탬프 기록
mkdir -p "$(dirname "$COOLDOWN_FILE")"
date +%s > "$COOLDOWN_FILE"

echo "[$(ts)] [rag-compact] compact 시작" >> "$LOG"
set +e
node "${RAG_ROOT}/bin/rag-compact.mjs" >> "$LOG" 2>&1
compact_exit=$?
set -e

if [ $compact_exit -ne 0 ]; then
  echo "[$(ts)] [rag-compact] compact 실패 (exit $compact_exit) — 쿨다운 리셋" >> "$LOG"
  rm -f "$COOLDOWN_FILE"
else
  if [ -f "$COMPACT_FLAG" ]; then
    rm -f "$COMPACT_FLAG"
    echo "[$(ts)] [rag-compact] compact-needed 플래그 삭제 완료" >> "$LOG"
  fi
fi
