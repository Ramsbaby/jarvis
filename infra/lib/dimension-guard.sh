#!/usr/bin/env bash
# dimension-guard.sh — 차원별 완료 플래그 가드
#
# 클러스터 ID: cl-2ff130add97125ec (최근 7일 재발 28건)
# 반복 실수: 배치/크기/순서 차원 중 일부만 처리 후 '완료' 선언
#
# 용도:
#   requirement-parser.sh 가 생성한 상태 파일(*.env)을 읽어
#   각 차원(배치/공간, 크기/폰트, 순서/위치)이 모두 완료 처리됐는지 검증한다.
#   하나라도 미완료이면 exit 1 을 반환한다.
#
# 사용법:
#   # 1. 완료 플래그 설정
#   dimension-guard.sh set-done <task_id> layout|size|order
#
#   # 2. 전체 검증 (미완료 차원 있으면 exit 1)
#   dimension-guard.sh check <task_id>
#
#   # 3. 상태 확인 (현재 플래그 상태 표시)
#   dimension-guard.sh status <task_id>
#
# 환경변수:
#   DIMENSION_STATE_DIR — 상태 파일 디렉토리 (기본: ~/.jarvis/state/dimensions)
#   DIM_GUARD_SKIP_UNDETECTED=1 — 미감지 차원은 skip (기본: 0, 미감지 차원도 강제)
#
# exit 코드:
#   0 — 모든 (감지된) 차원 완료
#   1 — 미완료 차원 존재

set -uo pipefail

# ── 상수 ─────────────────────────────────────────────────────────────────────
readonly CLUSTER_ID="cl-2ff130add97125ec"
readonly DIMENSION_STATE_DIR="${DIMENSION_STATE_DIR:-${HOME}/.jarvis/state/dimensions}"
readonly LOG_FILE="${HOME}/jarvis/runtime/logs/dimension-guard.jsonl"

# ── 초기화 ────────────────────────────────────────────────────────────────────
mkdir -p "$DIMENSION_STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ── 유틸 ─────────────────────────────────────────────────────────────────────
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_escape_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

_log() {
  local event_type="$1" details="${2:-}"
  local entry
  entry="{\"ts\":\"$(_ts)\",\"cluster\":\"$CLUSTER_ID\",\"event\":\"$event_type\""
  [[ -n "$details" ]] && entry="$entry,\"details\":\"$(_escape_json "$details")\""
  entry="$entry}"
  echo "$entry" >> "$LOG_FILE" 2>/dev/null || true
}

_state_file() {
  local task_id="$1"
  echo "${DIMENSION_STATE_DIR}/${task_id}.env"
}

# ── 상태 파일 로드 ────────────────────────────────────────────────────────────
_load_state() {
  local task_id="$1"
  local sf
  sf=$(_state_file "$task_id")

  if [[ ! -f "$sf" ]]; then
    echo "오류: 상태 파일 없음 — task_id='$task_id'" >&2
    echo "  먼저 requirement-parser.sh 를 실행하세요." >&2
    echo "  예: TASK_ID=$task_id requirement-parser.sh \"<요구사항>\"" >&2
    return 1
  fi

  # shellcheck source=/dev/null
  source "$sf"
  return 0
}

# ── set-done 서브커맨드 ───────────────────────────────────────────────────────
cmd_set_done() {
  local task_id="${1:-}"
  local dimension="${2:-}"

  if [[ -z "$task_id" || -z "$dimension" ]]; then
    echo "사용법: dimension-guard.sh set-done <task_id> layout|size|order" >&2
    exit 1
  fi

  _load_state "$task_id" || exit 1

  local sf
  sf=$(_state_file "$task_id")

  case "$dimension" in
    layout|배치)
      sed -i '' 's/^DIM_LAYOUT_DONE=.*/DIM_LAYOUT_DONE=1/' "$sf" 2>/dev/null \
        || sed -i    's/^DIM_LAYOUT_DONE=.*/DIM_LAYOUT_DONE=1/' "$sf"
      echo "✓ 배치/공간 완료 플래그 설정" >&2
      _log "set_done" "task=$task_id,dim=layout"
      ;;
    size|크기)
      sed -i '' 's/^DIM_SIZE_DONE=.*/DIM_SIZE_DONE=1/' "$sf" 2>/dev/null \
        || sed -i    's/^DIM_SIZE_DONE=.*/DIM_SIZE_DONE=1/' "$sf"
      echo "✓ 크기/폰트 완료 플래그 설정" >&2
      _log "set_done" "task=$task_id,dim=size"
      ;;
    order|순서)
      sed -i '' 's/^DIM_ORDER_DONE=.*/DIM_ORDER_DONE=1/' "$sf" 2>/dev/null \
        || sed -i    's/^DIM_ORDER_DONE=.*/DIM_ORDER_DONE=1/' "$sf"
      echo "✓ 순서/위치 완료 플래그 설정" >&2
      _log "set_done" "task=$task_id,dim=order"
      ;;
    *)
      echo "오류: 알 수 없는 차원 '$dimension' (layout|size|order 중 하나)" >&2
      exit 1
      ;;
  esac
}

# ── check 서브커맨드 ─────────────────────────────────────────────────────────
cmd_check() {
  local task_id="${1:-}"

  if [[ -z "$task_id" ]]; then
    echo "사용법: dimension-guard.sh check <task_id>" >&2
    exit 1
  fi

  _load_state "$task_id" || exit 1

  local skip_undetected="${DIM_GUARD_SKIP_UNDETECTED:-0}"
  local failed=()

  # 배치/공간 검사
  if [[ "${DIM_LAYOUT_DETECTED:-0}" == "1" ]] || [[ "$skip_undetected" != "1" ]]; then
    if [[ "${DIM_LAYOUT_DONE:-0}" != "1" ]]; then
      failed+=("배치/공간(layout)")
    fi
  fi

  # 크기/폰트 검사
  if [[ "${DIM_SIZE_DETECTED:-0}" == "1" ]] || [[ "$skip_undetected" != "1" ]]; then
    if [[ "${DIM_SIZE_DONE:-0}" != "1" ]]; then
      failed+=("크기/폰트(size)")
    fi
  fi

  # 순서/위치 검사
  if [[ "${DIM_ORDER_DETECTED:-0}" == "1" ]] || [[ "$skip_undetected" != "1" ]]; then
    if [[ "${DIM_ORDER_DONE:-0}" != "1" ]]; then
      failed+=("순서/위치(order)")
    fi
  fi

  if (( ${#failed[@]} > 0 )); then
    echo "" >&2
    echo "✗ DIMENSION GUARD: 미완료 차원 감지" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "Task: $task_id" >&2
    echo "미완료 차원:" >&2
    for dim in "${failed[@]}"; do
      echo "  ✗ $dim" >&2
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "해결: dimension-guard.sh set-done $task_id <차원>" >&2
    echo "" >&2

    _log "check_failed" "task=$task_id,missing=${failed[*]}"
    exit 1
  else
    echo "✓ 모든 차원 완료 확인됨 (task=$task_id)" >&2
    _log "check_passed" "task=$task_id"
    exit 0
  fi
}

# ── status 서브커맨드 ─────────────────────────────────────────────────────────
cmd_status() {
  local task_id="${1:-}"

  if [[ -z "$task_id" ]]; then
    echo "사용법: dimension-guard.sh status <task_id>" >&2
    exit 1
  fi

  _load_state "$task_id" || exit 1

  local layout_detected="${DIM_LAYOUT_DETECTED:-0}"
  local size_detected="${DIM_SIZE_DETECTED:-0}"
  local order_detected="${DIM_ORDER_DETECTED:-0}"
  local layout_done="${DIM_LAYOUT_DONE:-0}"
  local size_done="${DIM_SIZE_DONE:-0}"
  local order_done="${DIM_ORDER_DONE:-0}"
  local parse_ts="${DIM_PARSE_TS:-(unknown)}"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "DIMENSION GUARD 상태 — task: $task_id"
  echo "파싱 시각: $parse_ts"
  echo "───────────────────────────────────────────────"
  echo "  [배치/공간] $([ "$layout_detected" == "1" ] && echo "감지" || echo "미감지") | $([ "$layout_done" == "1" ] && echo "✓ 완료" || echo "✗ 미완료")"
  echo "  [크기/폰트] $([ "$size_detected"   == "1" ] && echo "감지" || echo "미감지") | $([ "$size_done"   == "1" ] && echo "✓ 완료" || echo "✗ 미완료")"
  echo "  [순서/위치] $([ "$order_detected"  == "1" ] && echo "감지" || echo "미감지") | $([ "$order_done"  == "1" ] && echo "✓ 완료" || echo "✗ 미완료")"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  _log "status_check" "task=$task_id"
}

# ── 진입점 ────────────────────────────────────────────────────────────────────
main() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    set-done) cmd_set_done "$@" ;;
    check)    cmd_check    "$@" ;;
    status)   cmd_status   "$@" ;;
    "")
      echo "사용법: dimension-guard.sh <set-done|check|status> <task_id> [차원]" >&2
      echo ""                                                                     >&2
      echo "서브커맨드:"                                                          >&2
      echo "  set-done <task_id> layout|size|order  — 차원 완료 플래그 설정"    >&2
      echo "  check    <task_id>                    — 전체 검증 (미완료 시 exit 1)" >&2
      echo "  status   <task_id>                    — 현재 상태 표시"            >&2
      exit 1
      ;;
    *)
      echo "오류: 알 수 없는 서브커맨드 '$subcmd'" >&2
      exit 1
      ;;
  esac
}

main "$@"
