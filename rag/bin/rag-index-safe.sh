#!/usr/bin/env bash
# rag-index-safe.sh — OMP 스레드 제한 래퍼
# rag-index.mjs는 ESM hoisting 때문에 process.env 설정이 불가.
# 반드시 이 래퍼를 통해 실행해야 ONNX 스레드 제한이 적용됨.

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"
export ORT_NUM_THREADS="${ORT_NUM_THREADS:-2}"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

# RAG 스크립트 위치 자동 감지 (이 스크립트 기준 상대경로)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# INFRA_HOME 결정: BOT_HOME > ~/.local/share/jarvis
INFRA_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"

# .env 로드 (존재하면)
if [[ -f "${INFRA_HOME}/discord/.env" ]]; then
  set -a; source "${INFRA_HOME}/discord/.env"; set +a
fi

LOG="${INFRA_HOME}/logs/rag-index.log"
mkdir -p "$(dirname "$LOG")"

COMPACT_FLAG="${INFRA_HOME}/state/rag-compact-needed"
COMPACT_SH="${RAG_ROOT}/scripts/rag-compact-safe.sh"

# stdout은 rag-index.mjs 내부의 appendFileSync가 직접 파일에 씀.
# 여기서 stdout도 리다이렉트하면 같은 줄이 2번 기록됨 — stderr만 연결.
node \
  --max-old-space-size=512 \
  "${RAG_ROOT}/bin/rag-index.mjs" "$@" \
  2>> "$LOG"
node_exit=$?

# 리빌드 완료 후 자동 컴팩션 트리거
if [ -f "$COMPACT_FLAG" ] && [ -f "$COMPACT_SH" ]; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [rag-index-safe] compact-needed 플래그 감지 → rag-compact 백그라운드 트리거" >> "$LOG"
  bash "$COMPACT_SH" &
fi

exit $node_exit
