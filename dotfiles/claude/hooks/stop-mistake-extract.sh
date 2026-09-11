#!/usr/bin/env bash
# stop-mistake-extract.sh — Claude Code 세션 종료 후 오답노트 실시간 추출
#
# 흐름:
#   stop-session-save.sh (async)가 세션을 .md로 덤프
#     └─ ~/.jarvis/context/claude-code-sessions/{project}/{ts}.md
#   이 훅은 최대 8초 poll로 세션 .md 출현 확인 후
#   사전 필터(자기정정 신호 grep)를 통과한 경우에만
#   infra/scripts/mistake-extractor.mjs --file <path> 로 Haiku 추출 → 오답노트 append
#
# 배치 (일 1회 03:15)와 이 훅의 관계:
#   - 배치: session-summaries/ 디렉토리의 '요약' 파일들을 스캔 (일 단위 state 진전)
#   - 이 훅: 세션 '원본' .md 한 건을 state와 무관하게 즉시 처리
#   - extractor --file 모드는 state를 건드리지 않아 두 경로가 충돌하지 않음
#
# 비용 절감:
#   자기정정 패턴(정정합니다|오해|놓친|실수|확인하지 못 등)이 세션에 없으면 Haiku 호출 skip.
#   평균 세션 중 ~30%만 실수 신호를 포함 → 일 단위로 Haiku 호출 60~70% 절감 예상.
#
# 실패는 exit 0으로 흡수 (세션 저장 파이프라인 비차단).
#
# Stop hook (async, timeout 90s — Haiku 왕복 60초 여유 + 버퍼)

set -euo pipefail

LOG_DIR="${HOME}/.jarvis/logs"
LOG="${LOG_DIR}/stop-mistake-extract.log"
SCRIPT="${HOME}/.openclaw-data/jarvis/infra/scripts/mistake-extractor.mjs"
SESSION_BASE="${HOME}/.jarvis/context/claude-code-sessions"

mkdir -p "$LOG_DIR"

log() { printf '[%s] [stop-mistake-extract] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

# ── 입력 JSON 파싱 (cwd만 사용) ──────────────────────────────────────────────
INPUT=$(cat || true)
CWD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

log "start cwd=${CWD:-EMPTY}"

# ── extractor 스크립트 존재 확인 ─────────────────────────────────────────────
if [[ ! -f "$SCRIPT" ]]; then
  log "SKIP: extractor not found: $SCRIPT"
  exit 0
fi

# ── 프로젝트 슬러그 (stop-session-save.sh와 동일 로직) ──────────────────────
PROJECT=$(basename "${CWD:-unknown}" | tr ' ' '-' | tr '/' '-')
if [[ -z "$PROJECT" || "$PROJECT" == "-" ]]; then
  PROJECT="unknown"
fi

SESSION_DIR="${SESSION_BASE}/${PROJECT}"

# ── 세션 .md 출현까지 짧게 poll (stop-session-save.sh가 먼저 써야 함) ──────
LATEST=""
for _i in 1 2 3 4 5 6 7 8; do
  if [[ -d "$SESSION_DIR" ]]; then
    CANDIDATE=$(ls -t "$SESSION_DIR"/*.md 2>/dev/null | head -1 || true)
    if [[ -n "$CANDIDATE" && -f "$CANDIDATE" ]]; then
      NOW=$(date +%s)
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
  log "SKIP: no fresh session .md within 8s (project=${PROJECT})"
  exit 0
fi

# ── 파일 크기 최소 기준 (extractor 내부에도 체크 있으나 여기서 선 필터) ──
SIZE=$(wc -c < "$LATEST" | tr -d ' ')
if [[ "$SIZE" -lt 300 ]]; then
  log "SKIP: session too small (${SIZE} bytes): $LATEST"
  exit 0
fi

# ── 사전 필터: 자기정정 신호 존재 여부 (없으면 Haiku 호출 절약) ────────────
if ! grep -qiE "정정합니다|정정하겠|오해했|오해하였|놓친|놓쳤|실수했|실수하였|잘못 판단|미확인|확인하지 못|재검토|재확인|재진행|죄송" "$LATEST"; then
  log "SKIP: no self-correction signal in session (size=${SIZE}): $LATEST"
  exit 0
fi

log "signal detected, invoking extractor --file: $LATEST"

# ── 메모리 압박 게이트 (2026-08-01 커널 패닉 재발 방지) ─────────────────────
# rag-index-safe.sh와 동일 기준 재사용. Haiku 서브프로세스 spawn 전 확인.
GUARD_LIB="${HOME}/.claude/hooks/lib/mem-pressure-gate.sh"
if [[ -f "$GUARD_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$GUARD_LIB"
  if reason=$(mem_pressure_should_skip); then
    log "SKIP: ${reason} — 오답노트 추출 연기 (다음 트리거에서 재시도)"
    exit 0
  fi
fi

# ── 교차 동시성 슬롯 (2026-08-01 패닉 재발 방지) ────────────────────────────
# rag-index-safe.sh / vera-autosummon-runner와 전역 2슬롯 공유. 슬롯 없으면 즉시 skip.
SLOT_LIB="${HOME}/.claude/hooks/lib/heavy-hook-slot.sh"
if [[ -f "$SLOT_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SLOT_LIB"
  if ! heavy_slot_acquire "mistake-extract"; then
    log "SKIP: 교차 동시성 슬롯 없음(다른 무거운 훅 실행 중) — 다음 트리거에서 재시도"
    exit 0
  fi
  trap 'heavy_slot_release' EXIT
fi

# ── Homebrew PATH (훅 컨텍스트 node 해상 보험) ──────────────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── extractor 실행 (--file 단일 파일 모드) ──────────────────────────────────
if ! RESULT=$(node "$SCRIPT" --file "$LATEST" 2>>"$LOG"); then
  log "WARN: extractor exited non-zero (session file may be malformed)"
  exit 0
fi

log "result: ${RESULT}"

# ── Discord 알림 (추출 건수 > 0 일 때만, 스팸 방지) ─────────────────────────
# extractor stdout 포맷: "🤖 오답노트 자동 추출 — **N건 추가**"
COUNT=$(printf '%s\n' "$RESULT" | grep -oE '\*\*[0-9]+건 추가\*\*' | grep -oE '[0-9]+' | head -1 || true)
if [[ -n "${COUNT:-}" && "$COUNT" -gt 0 ]]; then
  TITLES=$(printf '%s\n' "$RESULT" | grep -E '^- \*\*' | head -3 | sed -e 's/^- \*\*//' -e 's/\*\*$//' | tr '\n' '|' | sed 's/|$//' || true)
  VISUAL="${HOME}/.jarvis/scripts/discord-visual.mjs"

  # 2026-07-27 소음 감축: 하루 1회로 묶는다.
  # 실측 — 이 알림이 7일 111회(일 16회)로 단일 항목 최다였다. 추출 자체는 정상 동작이고
  # 오답은 원장에 그대로 쌓이므로, 세션마다 카드를 받을 이유가 없다(받아도 할 행동이 없다).
  # 억제된 사이의 건수는 다음 발송 때 함께 표시한다.
  _AG="${HOME}/.openclaw-data/jarvis/infra/lib/alert-gate.sh"
  # shellcheck source=/dev/null
  [[ -f "$_AG" ]] && source "$_AG" 2>/dev/null || true
  if declare -F alert_ratelimit >/dev/null 2>&1; then
    if ! alert_ratelimit "mistake-extract-session" 86400; then
      log "Discord 억제 — 하루 1회 정책 (count=${COUNT}, 대기 $(alert_ratelimit_pending mistake-extract-session)건)"
      exit 0
    fi
    PENDING=$(alert_ratelimit_pending mistake-extract-session)
  else
    PENDING=0
  fi

  if [[ -f "$VISUAL" ]]; then
    DATA=$(jq -cn \
      --arg count "${COUNT}건" \
      --arg titles "${TITLES:-(제목 없음)}" \
      --arg source "Stop 훅 (하루 1회 요약)" \
      --arg pending "${PENDING:-0}회 (억제된 이전 세션)" \
      --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
      '{title:"🧠 오답노트 추출 — 일일 요약", data:{"추출":$count, "항목":$titles, "경로":$source, "그사이":$pending}, timestamp:$ts}' 2>>"$LOG" || echo '{}')
    if ! node "$VISUAL" --type stats --data "$DATA" --channel jarvis-retro >>"$LOG" 2>&1; then
      log "WARN: Discord 송출 실패 (exit 0 유지)"
    else
      log "Discord 송출 완료 (count=${COUNT})"
    fi
  else
    log "SKIP Discord: visual script not found: $VISUAL"
  fi
fi

exit 0
