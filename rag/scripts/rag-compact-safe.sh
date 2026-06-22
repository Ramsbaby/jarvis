#!/usr/bin/env bash
set -euo pipefail

# RAG 스크립트 위치 자동 감지 (symlink chain resolve — runtime/scripts에서 호출돼도 rag/scripts 기준으로)
# runtime/rag/bin/과 rag/bin/은 별개 디렉토리이며 node_modules는 rag/에만 있음.
_self="$0"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in
    /*) _self="$_link" ;;
    *)  _self="$(dirname "$_self")/$_link" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
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

# ── A안 (2026-06-19): fragment 폭증 자동 압축 게이트 ──
# 조각(fragment)이 임계 초과 시 쿨다운을 우회해 자동 압축한다.
# gate-only 모드(매시간 감시 cron)는 임계 미달이면 압축 없이 즉시 종료 — 정기 압축과 빈도 분리.
FRAGMENT_THRESHOLD="${RAG_FRAGMENT_THRESHOLD:-5000}"
_frag_data_dir="${RAG_HOME}/lancedb/documents.lance/data"
_frag_count=0
if [ -d "$_frag_data_dir" ]; then
  _frag_count=$(find "$_frag_data_dir" -maxdepth 1 -name '*.lance' 2>/dev/null | wc -l | tr -d ' ')
fi
if [ "${_frag_count:-0}" -gt "$FRAGMENT_THRESHOLD" ]; then
  _bypass_cooldown=1
  echo "[$(ts)] [rag-compact] fragment ${_frag_count} > ${FRAGMENT_THRESHOLD} — 자동 압축 트리거" >> "$LOG"
elif [ "${RAG_FRAGMENT_GATE_ONLY:-0}" = "1" ]; then
  echo "[$(ts)] [rag-compact] gate-only: fragment ${_frag_count} <= ${FRAGMENT_THRESHOLD} — skip" >> "$LOG"
  exit 0
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
if pgrep -f "/rag-index.mjs" > /dev/null 2>&1; then
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
