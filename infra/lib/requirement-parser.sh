#!/usr/bin/env bash
# requirement-parser.sh — 요구사항 차원 파싱 가드
#
# 클러스터 ID: cl-2ff130add97125ec (최근 7일 재발 28건)
# 반복 실수: 요구사항 수신 시 '배치/공간', '크기/폰트', '순서/위치' 차원 혼동
#
# 용도:
#   요구사항 텍스트를 입력받아 3개 차원(배치, 크기, 순서)으로 분리·출력한다.
#   각 차원별 키워드 매칭 결과를 표준출력으로 내보내고,
#   dimension-guard.sh 와 연동하여 완료 기준 체크에 사용한다.
#
# 사용법:
#   requirement-parser.sh "<요구사항 텍스트>"
#   또는 파이프: echo "<요구사항>" | requirement-parser.sh -
#
# 환경변수:
#   REQ_PARSER_STRICT=1  — 차원 미감지 시 exit 1 (기본값: 0, 경고만)
#   REQ_PARSER_JSON=1    — JSON 출력 모드 (기본값: 0, 사람이 읽을 수 있는 텍스트)
#
# 출력 형식 (REQ_PARSER_JSON=0):
#   [배치/공간] <감지된 항목 목록 또는 "(없음)">
#   [크기/폰트] <감지된 항목 목록 또는 "(없음)">
#   [순서/위치] <감지된 항목 목록 또는 "(없음)">
#
# exit 코드:
#   0 — 정상 (3개 차원 모두 감지 또는 strict 모드 아님)
#   1 — strict 모드에서 하나 이상의 차원 미감지

set -uo pipefail

# ── 상수 ─────────────────────────────────────────────────────────────────────
readonly CLUSTER_ID="cl-2ff130add97125ec"
readonly LOG_FILE="${HOME}/jarvis/runtime/logs/requirement-parser.jsonl"
readonly DIMENSION_STATE_DIR="${HOME}/.jarvis/state/dimensions"

# ── 초기화 ────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")" "$DIMENSION_STATE_DIR" 2>/dev/null || true

# ── 차원별 키워드 사전 ──────────────────────────────────────────────────────
# 배치/공간 차원: 공간 배분, 레이아웃, 여백, 정렬 등
LAYOUT_KEYWORDS=(
  "배치" "공간" "레이아웃" "layout" "여백" "margin" "padding" "너비" "width"
  "높이" "height" "크기조절" "배분" "확대" "축소" "container" "컨테이너"
  "gap" "간격" "정렬" "align" "flex" "grid" "display" "position"
  "분리" "구분" "영역" "area" "섹션" "section"
)

# 크기/폰트 차원: 텍스트 크기, 폰트, 글꼴, 글씨 등
SIZE_KEYWORDS=(
  "폰트" "font" "글씨" "글자" "텍스트" "text" "크기" "size"
  "pt" "px" "em" "rem" "vw" "vh" "font-size" "font_size"
  "글꼴" "typeface" "서체" "bold" "굵기" "weight" "line-height"
  "줄간격" "letter-spacing" "자간" "scale" "스케일" "확대" "작게" "크게"
  "small" "large" "medium" "tiny" "big"
)

# 순서/위치 차원: 순서, 위치, 단계, 우선순위 등
ORDER_KEYWORDS=(
  "순서" "order" "위치" "position" "단계" "step" "먼저" "나중" "before" "after"
  "first" "last" "next" "이전" "다음" "앞" "뒤" "상단" "하단" "top" "bottom"
  "left" "right" "좌" "우" "우선" "priority" "순번" "번호" "1번" "2번"
  "차례" "절차" "flow" "흐름" "sequence" "시퀀스" "z-index" "layer" "레이어"
)

# ── 유틸 함수 ─────────────────────────────────────────────────────────────────
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_escape_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

_log_event() {
  local event_type="$1" details="${2:-}"
  local entry
  entry="{\"ts\":\"$(_ts)\",\"cluster\":\"$CLUSTER_ID\",\"event\":\"$event_type\""
  [[ -n "$details" ]] && entry="$entry,\"details\":\"$(_escape_json "$details")\""
  entry="$entry}"
  echo "$entry" >> "$LOG_FILE" 2>/dev/null || true
}

# ── 차원 매칭 함수 ────────────────────────────────────────────────────────────
# 입력 텍스트에서 키워드 목록(공백 구분 문자열)과 대조하여 일치 항목 반환
# 인수: <text> <space-separated-keywords>
_match_keywords_list() {
  local text="$1"
  shift
  local found=()
  local text_lower
  text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  for kw in "$@"; do
    local kw_lower
    kw_lower=$(echo "$kw" | tr '[:upper:]' '[:lower:]')
    if [[ "$text_lower" == *"$kw_lower"* ]]; then
      found+=("$kw")
    fi
  done

  if (( ${#found[@]} > 0 )); then
    echo "${found[*]}"
  else
    echo ""
  fi
}

# ── 상태 파일 저장 (dimension-guard.sh 연동용) ───────────────────────────────
_save_dimension_state() {
  local task_id="$1"
  local dim_layout="$2"    # detected 또는 empty
  local dim_size="$3"
  local dim_order="$4"

  local state_file="${DIMENSION_STATE_DIR}/${task_id}.env"
  {
    echo "DIM_LAYOUT_DETECTED=$([ -n "$dim_layout" ] && echo 1 || echo 0)"
    echo "DIM_SIZE_DETECTED=$([ -n "$dim_size" ] && echo 1 || echo 0)"
    echo "DIM_ORDER_DETECTED=$([ -n "$dim_order" ] && echo 1 || echo 0)"
    echo "DIM_LAYOUT_DONE=0"
    echo "DIM_SIZE_DONE=0"
    echo "DIM_ORDER_DONE=0"
    echo "DIM_PARSE_TS=$(_ts)"
    echo "DIM_CLUSTER=$CLUSTER_ID"
  } > "$state_file"

  echo "$state_file"
}

# ── 출력 함수 ─────────────────────────────────────────────────────────────────
_print_text() {
  local dim_layout="$1" dim_size="$2" dim_order="$3"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "[배치/공간] $([ -n "$dim_layout" ] && echo "$dim_layout" || echo "(없음)")"
  echo "[크기/폰트] $([ -n "$dim_size"   ] && echo "$dim_size"   || echo "(없음)")"
  echo "[순서/위치] $([ -n "$dim_order"  ] && echo "$dim_order"  || echo "(없음)")"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_print_json() {
  local dim_layout="$1" dim_size="$2" dim_order="$3" task_id="$4"
  printf '{"cluster":"%s","task_id":"%s","dimensions":{"layout":"%s","size":"%s","order":"%s"}}\n' \
    "$CLUSTER_ID" \
    "$(_escape_json "$task_id")" \
    "$(_escape_json "$dim_layout")" \
    "$(_escape_json "$dim_size")" \
    "$(_escape_json "$dim_order")"
}

# ── 메인 ──────────────────────────────────────────────────────────────────────
main() {
  local input_text=""
  local task_id="${TASK_ID:-req-$(date +%s)}"

  # 입력 읽기: 인수 또는 stdin(-)
  if [[ "${1:-}" == "-" ]]; then
    input_text=$(cat)
  elif [[ -n "${1:-}" ]]; then
    input_text="$1"
  else
    echo "usage: requirement-parser.sh \"<요구사항>\" | -" >&2
    echo "       또는 TASK_ID=xxx requirement-parser.sh \"<요구사항>\"" >&2
    exit 1
  fi

  _log_event "parse_start" "task=$task_id,len=${#input_text}"

  # 차원 매칭
  local dim_layout dim_size dim_order
  dim_layout=$(_match_keywords_list "$input_text" "${LAYOUT_KEYWORDS[@]}")
  dim_size=$(_match_keywords_list   "$input_text" "${SIZE_KEYWORDS[@]}")
  dim_order=$(_match_keywords_list  "$input_text" "${ORDER_KEYWORDS[@]}")

  # 상태 파일 저장 (dimension-guard.sh 연동)
  local state_file
  state_file=$(_save_dimension_state "$task_id" "$dim_layout" "$dim_size" "$dim_order")

  # 출력
  if [[ "${REQ_PARSER_JSON:-0}" == "1" ]]; then
    _print_json "$dim_layout" "$dim_size" "$dim_order" "$task_id"
  else
    _print_text "$dim_layout" "$dim_size" "$dim_order"
    echo "상태 파일: $state_file" >&2
  fi

  # 감지 결과 집계
  local undetected=()
  [[ -z "$dim_layout" ]] && undetected+=("배치/공간")
  [[ -z "$dim_size"   ]] && undetected+=("크기/폰트")
  [[ -z "$dim_order"  ]] && undetected+=("순서/위치")

  if (( ${#undetected[@]} > 0 )); then
    _log_event "parse_warn" "task=$task_id,undetected=${undetected[*]}"
    if [[ "${REQ_PARSER_STRICT:-0}" == "1" ]]; then
      echo "⚠  미감지 차원: ${undetected[*]}" >&2
      echo "   strict 모드: 요구사항에 해당 차원을 명시적으로 포함하세요." >&2
      exit 1
    fi
  else
    _log_event "parse_ok" "task=$task_id,all_dims_detected=1"
  fi

  return 0
}

main "$@"
