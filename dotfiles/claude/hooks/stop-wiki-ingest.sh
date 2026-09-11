#!/usr/bin/env bash
# stop-wiki-ingest.sh — Claude Code 세션 종료 후 위키 실시간 주입
#
# 흐름:
#   stop-session-save.sh (병렬 async)가 세션을 .md로 덤프
#     └─ ~/.jarvis/context/claude-code-sessions/{project}/{ts}.md
#   이 훅은 최대 8초 짧게 poll하여 해당 세션 .md 출현 확인 후
#   infra/scripts/wiki-ingest-claude-session.mjs 를 호출해 Haiku로 facts를 추출,
#   wiki-engine.addFactToWiki(source: 'claude-code-cli')로 주입한다.
#
# 디스코드의 autoExtractMemory → wikiAddFact 파이프라인과 동등한 역할을
# Claude Code CLI 표면에서 수행. 실패는 exit 0으로 흡수 (세션 저장 파이프라인 비차단).
#
# Stop hook (async, timeout 45s)

set -euo pipefail

LOG_DIR="${HOME}/.jarvis/logs"
LOG="${LOG_DIR}/wiki-ingest-claude.log"
SCRIPT="${HOME}/.openclaw-data/jarvis/infra/scripts/wiki-ingest-claude-session.mjs"
SESSION_BASE="${HOME}/.jarvis/context/claude-code-sessions"

mkdir -p "$LOG_DIR"

log() { printf '[%s] [stop-wiki-ingest] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

# ── 입력 JSON 파싱 (cwd 만 사용) ──────────────────────────────────────────────
INPUT=$(cat || true)
CWD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

log "start cwd=${CWD:-EMPTY}"

# ── ingester 스크립트 존재 확인 ──────────────────────────────────────────────
if [[ ! -f "$SCRIPT" ]]; then
  log "SKIP: ingester not found: $SCRIPT"
  exit 0
fi

# ── 프로젝트 슬러그 계산 (stop-session-save.sh와 동일 로직) ─────────────────
PROJECT=$(basename "${CWD:-unknown}" | tr ' ' '-' | tr '/' '-')
if [[ -z "$PROJECT" || "$PROJECT" == "-" ]]; then
  PROJECT="unknown"
fi

SESSION_DIR="${SESSION_BASE}/${PROJECT}"

# ── stop-session-save.sh와 경합 방지: 세션 .md 출현까지 짧게 poll ───────────
# 두 훅 모두 async이므로 순서 보장 없음. 60초 이내 생성된 파일만 유효.
LATEST=""
for _i in 1 2 3 4 5 6 7 8; do
  if [[ -d "$SESSION_DIR" ]]; then
    # -t: mtime 내림차순 정렬, 첫 줄이 최신
    CANDIDATE=$(ls -t "$SESSION_DIR"/*.md 2>/dev/null | head -1 || true)
    if [[ -n "$CANDIDATE" && -f "$CANDIDATE" ]]; then
      NOW=$(date +%s)
      # macOS: stat -f %m, Linux: stat -c %Y
      MTIME=$(stat -f %m "$CANDIDATE" 2>/dev/null || stat -c %Y "$CANDIDATE" 2>/dev/null || echo 0)
      AGE=$((NOW - MTIME))
      if [[ "$AGE" -le 60 ]]; then
        LATEST="$CANDIDATE"
        break
      fi
    fi
  fi
  sleep 1
done

if [[ -z "$LATEST" ]]; then
  log "SKIP: no fresh session .md appeared within 8s (project=${PROJECT})"
  exit 0
fi

log "ingesting: $LATEST"

# ── 메모리 압박 게이트 (2026-08-01 커널 패닉 재발 방지) ─────────────────────
# rag-index-safe.sh와 동일 기준 재사용. Haiku 서브프로세스 spawn 전 확인.
GUARD_LIB="${HOME}/.claude/hooks/lib/mem-pressure-gate.sh"
if [[ -f "$GUARD_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$GUARD_LIB"
  if reason=$(mem_pressure_should_skip); then
    log "SKIP: ${reason} — Haiku 호출 연기 (다음 트리거에서 재시도)"
    exit 0
  fi
fi

# ── 교차 동시성 슬롯 (2026-08-01 패닉 재발 방지) ────────────────────────────
# rag-index-safe.sh / vera-autosummon-runner와 전역 2슬롯 공유. 슬롯 없으면 즉시 skip.
SLOT_LIB="${HOME}/.claude/hooks/lib/heavy-hook-slot.sh"
if [[ -f "$SLOT_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SLOT_LIB"
  if ! heavy_slot_acquire "wiki-ingest"; then
    log "SKIP: 교차 동시성 슬롯 없음(다른 무거운 훅 실행 중) — 다음 트리거에서 재시도"
    exit 0
  fi
  trap 'heavy_slot_release' EXIT
fi

# ── Homebrew PATH (크론 경로는 아니지만 node 해상 보험) ─────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── ingester 실행. stdout은 JSON 1줄, 실패 시에도 exit 0 하도록 설계됨 ─────
if ! RESULT=$(node "$SCRIPT" "$LATEST" 2>>"$LOG"); then
  log "WARN: ingester exited non-zero (unexpected)"
  exit 0
fi

log "result: ${RESULT}"
exit 0
