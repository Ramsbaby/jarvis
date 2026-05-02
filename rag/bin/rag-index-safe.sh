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

# Single-instance 가드 (mkdir atomic lock — macOS 호환, flock 불요)
# LaunchAgent(매시 30분)와 crontab(30 */4) 동시 발동 시 LanceDB concurrent write 차단.
LOCK_DIR="${INFRA_HOME}/state/rag-index.lock.d"
mkdir -p "$(dirname "$LOCK_DIR")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  owner_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")
  if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [rag-index-safe] 이미 실행 중 (PID $owner_pid) — 건너뜀" >> "$LOG"
    exit 0
  fi
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [rag-index-safe] stale lock (owner=${owner_pid:-unknown}) — 재획득" >> "$LOG"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || { echo "[rag-index-safe] lock 획득 실패" >> "$LOG"; exit 1; }
fi
echo $$ > "${LOCK_DIR}/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

COMPACT_FLAG="${INFRA_HOME}/state/rag-compact-needed"
COMPACT_SH="${RAG_ROOT}/scripts/rag-compact-safe.sh"

# Ollama 임베딩 헬스체크 (재시작 직후 모델 미로드 시 CPU/Disk 폭주 방지)
# 증상: 서킷브레이커 OPEN 상태로 13K+ 파일 zero-vector 인덱싱 → CPU 100%+ + Disk 27MB/s (2026-05-02 사고)
EMBED_MODEL="snowflake-arctic-embed2"
embed_check=$(curl -s --max-time 8 http://localhost:11434/api/embed \
  -d "{\"model\":\"${EMBED_MODEL}\",\"input\":\"hi\"}" 2>/dev/null)
if ! echo "$embed_check" | grep -q '"embeddings"'; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [rag-index-safe] SKIP: Ollama 임베딩 불가 (모델 미로드 또는 서비스 다운) — 다음 실행 시 재시도" >> "$LOG"
  exit 0
fi

# stdout은 rag-index.mjs 내부의 appendFileSync가 직접 파일에 씀.
# 여기서 stdout도 리다이렉트하면 같은 줄이 2번 기록됨 — stderr만 연결.
# OS 레벨 하드캡: fresh rebuild 4h + 여유 30m = 4.5h (내부 타임아웃 미발동 시 2차 방어)
timeout 16200 node \
  --max-old-space-size=512 \
  "${RAG_ROOT}/bin/rag-index.mjs" "$@" \
  2>> "$LOG"
node_exit=$?
if [ $node_exit -eq 124 ]; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [rag-index-safe] FATAL: OS timeout(16200s) 발동 — 내부 타임아웃 미작동. 강제 종료." >> "$LOG"
fi

# 리빌드 완료 후 자동 컴팩션 트리거
if [ -f "$COMPACT_FLAG" ] && [ -f "$COMPACT_SH" ]; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [rag-index-safe] compact-needed 플래그 감지 → rag-compact 백그라운드 트리거" >> "$LOG"
  bash "$COMPACT_SH" &
fi

exit $node_exit
