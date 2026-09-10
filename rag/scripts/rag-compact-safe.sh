#!/usr/bin/env bash

# [오픈클로 이식 2026-09-10 · 회차5 2단계] 이관 완료 — crontab 경로를 막는다.
# 오픈클로 jarvis-rag-compact-weekly(일 04:00)·jarvis-rag-compact-gate(매시)로 이관. 실행 검증 완료.
# 오픈클로 잡은 OPENCLAW_JOB=1 로 통과한다. 재개: rm ~/.openclaw-data/jarvis/runtime/state/stopped/rag-compact-safe
if [[ -f "${HOME}/.openclaw-data/jarvis/runtime/state/stopped/rag-compact-safe" ]] && [[ "${OPENCLAW_JOB:-}" != "1" ]]; then
    echo "[rag-compact-safe] 중지 플래그 있음 — 오픈클로로 이관됨"
    exit 0
fi

set -euo pipefail

# [2026-07-09] LaunchAgent/cron 환경 PATH에 homebrew(node) 미포함 → 'node: command not found'(exit 127)로
#   compact가 매시간 실패, fragment 6700+ 누적되던 결함 수리. rag-index-safe.sh:8과 동일 표준 PATH.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin:${PATH}"

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
# ── B안 (2026-08-05): 디스크 여유 게이트 ──
# 사고: 조각 2,041 <= 5,000 이라 매시간 skip 하는 동안 디스크가 100%(여유 274MB)까지 찼다.
# 그 상태에서 강제 압축을 걸었더니 optimize가 "No space left on device"로 실패했다 —
# 압축은 조각을 새로 써야 해서 임시 공간이 필요하고, 꽉 찬 뒤에는 이미 늦는다.
# 실측 회수량: 버전 4,329개 / 14.9GB. 이만한 누적이 조각 수 지표에는 전혀 안 잡혔다.
# 조각 수는 '파편화'를 재고 디스크 여유는 '누적'을 잰다. 다른 축이라 둘 다 봐야 한다.
DISK_FREE_GB_MIN="${RAG_DISK_FREE_GB_MIN:-20}"
_free_gb=$(df -g "$RAG_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
_free_gb="${_free_gb:-999}"

if [ "${_frag_count:-0}" -gt "$FRAGMENT_THRESHOLD" ]; then
  _bypass_cooldown=1
  echo "[$(ts)] [rag-compact] fragment ${_frag_count} > ${FRAGMENT_THRESHOLD} — 자동 압축 트리거" >> "$LOG"
elif [ "${_free_gb}" -lt "$DISK_FREE_GB_MIN" ]; then
  _bypass_cooldown=1
  echo "[$(ts)] [rag-compact] 디스크 여유 ${_free_gb}GB < ${DISK_FREE_GB_MIN}GB — 압축 트리거(조각 ${_frag_count})" >> "$LOG"
elif [ "${RAG_FRAGMENT_GATE_ONLY:-0}" = "1" ]; then
  echo "[$(ts)] [rag-compact] gate-only: fragment ${_frag_count} <= ${FRAGMENT_THRESHOLD}, 여유 ${_free_gb}GB — skip" >> "$LOG"
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
