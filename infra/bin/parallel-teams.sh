#!/usr/bin/env bash
# parallel-teams.sh — 자비스 컴퍼니 팀 병렬 실행 래퍼
#
# 실행 순서 (의존성 기반 3-phase):
#   Phase 1: council (context-bus.md 생성 → 다른 팀이 읽음)
#   Phase 2: infra brand career record trend academy (병렬 실행)
#   Phase 3: standup (전체 보고서 집계)
#
# 사용법:
#   parallel-teams.sh                         # 전체 실행 (3-phase)
#   parallel-teams.sh --phase2                # Phase 2만 (병렬 팀들)
#   parallel-teams.sh --teams "infra brand"   # 지정 팀만 병렬 실행
#   parallel-teams.sh --dry-run               # 실행 없이 순서 출력
#
# 크론 예시 (크론 이후 팀 병렬 실행):
#   30 8 * * * $HOME/.jarvis/bin/parallel-teams.sh >> $HOME/.jarvis/logs/parallel-teams.log 2>&1

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
AGENT="${BOT_HOME}/discord/lib/company-agent.mjs"
LOG_DIR="${BOT_HOME}/logs"
LOG_FILE="${LOG_DIR}/parallel-teams.log"
NODE="${NODE:-node}"

# Phase 2 팀 목록 (council에 의존하지 않는 팀은 여기 추가 가능)
PHASE2_TEAMS=(infra brand career record trend academy)

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Args parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
PHASE_ONLY=""
CUSTOM_TEAMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true ;;
    --phase2)     PHASE_ONLY="phase2" ;;
    --phase3)     PHASE_ONLY="phase3" ;;
    --teams)      IFS=' ' read -r -a CUSTOM_TEAMS <<< "$2"; shift ;;
    --teams=*)    IFS=' ' read -r -a CUSTOM_TEAMS <<< "${1#*=}" ;;
    *) echo "[parallel-teams] Unknown arg: $1" >&2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local msg="[$(date -u +%FT%TZ)] [parallel-teams] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run a single team (background-safe)
# ---------------------------------------------------------------------------
run_team() {
  local team="$1"
  local t0
  t0=$(date +%s)
  log "START  $team"
  if $DRY_RUN; then
    log "DRY-RUN $team (skipped)"
    return 0
  fi
  # 각 팀 stderr를 팀별 로그 파일로 분리
  local team_log="${LOG_DIR}/parallel-team-${team}.log"
  if "$NODE" "$AGENT" --team "$team" >> "$team_log" 2>&1; then
    local elapsed=$(( $(date +%s) - t0 ))
    log "OK     $team (${elapsed}s)"
    return 0
  else
    local exit_code=$?
    local elapsed=$(( $(date +%s) - t0 ))
    log "FAIL   $team (exit $exit_code, ${elapsed}s) — see $team_log"
    return $exit_code
  fi
}

# ---------------------------------------------------------------------------
# Run a list of teams in parallel, collect exit codes
# ---------------------------------------------------------------------------
run_parallel() {
  local teams=("$@")
  local pids=()
  local names=()

  for team in "${teams[@]}"; do
    run_team "$team" &
    pids+=($!)
    names+=("$team")
  done

  local failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      log "PARALLEL FAIL: ${names[$i]} (pid ${pids[$i]})"
      (( failed++ )) || true
    fi
  done
  return $failed
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
TOTAL_START=$(date +%s)
log "=== parallel-teams.sh 시작 ==="

# 커스텀 팀 지정 시 지정 팀만 병렬 실행
if [[ ${#CUSTOM_TEAMS[@]} -gt 0 ]]; then
  log "커스텀 병렬 실행: ${CUSTOM_TEAMS[*]}"
  if ! run_parallel "${CUSTOM_TEAMS[@]}"; then
    log "WARN: 일부 팀 실패 (계속 진행)"
  fi
  TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
  log "=== 완료 (${TOTAL_ELAPSED}s) ==="
  exit 0
fi

# Phase 지정 시 해당 phase만 실행
if [[ "$PHASE_ONLY" == "phase2" ]]; then
  log "Phase 2만 실행: ${PHASE2_TEAMS[*]}"
  run_parallel "${PHASE2_TEAMS[@]}" || log "WARN: Phase 2 일부 실패"
  TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
  log "=== Phase 2 완료 (${TOTAL_ELAPSED}s) ==="
  exit 0
fi

if [[ "$PHASE_ONLY" == "phase3" ]]; then
  log "Phase 3만 실행: standup"
  run_team "standup" || log "WARN: standup 실패"
  TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
  log "=== Phase 3 완료 (${TOTAL_ELAPSED}s) ==="
  exit 0
fi

# 전체 3-phase 실행
# --- Phase 1: council (context-bus.md 생성) ---
log "--- Phase 1: council ---"
if ! run_team "council"; then
  log "ERROR: council 실패 — Phase 2/3 계속 진행 (이전 context-bus.md 사용)"
fi

# --- Phase 2: 독립 팀 병렬 실행 ---
log "--- Phase 2: 병렬 실행 (${PHASE2_TEAMS[*]}) ---"
if ! run_parallel "${PHASE2_TEAMS[@]}"; then
  log "WARN: Phase 2 일부 팀 실패 — Phase 3 계속 진행"
fi

# --- Phase 3: standup (전체 보고서 집계) ---
log "--- Phase 3: standup ---"
run_team "standup" || log "WARN: standup 실패"

TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
log "=== 전체 완료 (${TOTAL_ELAPSED}s) ==="
