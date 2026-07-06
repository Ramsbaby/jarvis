#!/usr/bin/env bash
# guard-completion-check.sh — 오답승격 방어 가드 (완료 선언 전 파일 열람 검증)
#
# 클러스터 ID  : cl-d062d5d4b813f265 (최근 7일 재발 32건)
# 반복 패턴    : 경로 코드 미열람 후 하드코딩 단언 / 용량·파일 존재 추정 후 단언
#               / 이미지 미확인 후 '확인했어요' 단언 / 사용자 전체 요청 미파악 후 부분 작업 완료 선언
# 목적         : 응답 생성 전 단계에서 '완료 선언 키워드' 감지 시 직전 도구 호출 목록에
#               해당 파일·경로 열람 기록이 있는지 자동 검사
#
# 스크립트 역할:
#   1. 사용자 요청 텍스트에서 완료 선언 키워드 감지 (완료, 확인했어요, 했어요, 완료됨 등)
#   2. 도구 호출 히스토리에서 파일/경로 열람 기록 확인 (Read, Glob, Bash ls/cat)
#   3. 열람 기록 없으면 경고 로그 + 완료 선언 문구 차단 신호 반환
#   4. 기존 Claude Code 명령어에 영향 없음 (조용한 검사)
#
# 사용법:
#   source ~/jarvis/infra/lib/guard-completion-check.sh
#
#   # 사용자 요청 텍스트와 도구 호출 히스토리를 전달
#   check_completion_safety "$user_message" "$tool_history_json"
#
#   # 반환값:
#   # 0 = 안전함 (완료 선언이 없거나 열람 기록이 있음)
#   # 1 = 위험함 (완료 선언이 있으나 열람 기록이 없음)

set -euo pipefail

# ═════════════════════════════════════════════════════════════════════════════════
# [1] 완료 선언 키워드 패턴 (한국어·영어·혼합)
# ═════════════════════════════════════════════════════════════════════════════════

# 완료 선언 키워드 리스트 (순서대로 우선순위 높음)
declare -a COMPLETION_KEYWORDS=(
  "완료했습니다"
  "완료했어요"
  "완료됐어요"
  "완료됐습니다"
  "완료됨"
  "완료"
  "확인했어요"
  "확인했습니다"
  "확인했다"
  "확인됨"
  "확인"
  "했어요"
  "했습니다"
  "했다"
  "됩니다"
  "done"
  "completed"
  "verified"
)

# 파일/경로 열람 도구 목록
declare -a READ_TOOLS=("Read" "Glob" "Bash" "Grep")

# ═════════════════════════════════════════════════════════════════════════════════
# [2] 로깅 함수
# ═════════════════════════════════════════════════════════════════════════════════

_guard_completion_log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')

  # 로그 디렉토리 생성
  local log_dir="${HOME}/jarvis/logs"
  mkdir -p "$log_dir" 2>/dev/null || return 0

  local log_file="$log_dir/guard-completion-check.log"
  printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >> "$log_file" 2>/dev/null || true
}

# ═════════════════════════════════════════════════════════════════════════════════
# [3] 완료 선언 키워드 감지 함수
# ═════════════════════════════════════════════════════════════════════════════════

_detect_completion_keyword() {
  local text="$1"

  # 텍스트가 비어있으면 완료 선언 없음
  if [[ -z "$text" ]]; then
    return 1
  fi

  # 각 키워드에 대해 검사 (case-insensitive)
  local text_lower
  text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  for keyword in "${COMPLETION_KEYWORDS[@]}"; do
    local keyword_lower
    keyword_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
    # 대소문자 무시하고 검사
    if [[ "$text_lower" =~ $keyword_lower ]]; then
      echo "$keyword"  # 감지된 키워드 반환
      return 0
    fi
  done

  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════
# [4] 도구 호출 히스토리에서 파일/경로 열람 기록 추출
# ═════════════════════════════════════════════════════════════════════════════════

_extract_read_paths_from_history() {
  local history_json="$1"

  # JSON이 비어있으면 빈 배열 반환
  if [[ -z "$history_json" ]]; then
    return 1
  fi

  # jq로 파일 경로 추출
  # 예: tool_calls[].invoke.file_path, .invoke.path 등
  local paths
  paths=$(echo "$history_json" | jq -r '
    [
      ..[].invoke.file_path? // empty,
      ..[].invoke.path? // empty,
      ..[].invoke.pattern? // empty,
      ..[].invoke.command? // empty
    ] | .[]' 2>/dev/null || echo "")

  if [[ -z "$paths" ]]; then
    return 1
  fi

  echo "$paths"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [5] 도구 호출 히스토리에서 Read/Glob/Grep 도구 사용 여부 확인
# ═════════════════════════════════════════════════════════════════════════════════

_has_read_tool_usage() {
  local history_json="$1"

  if [[ -z "$history_json" ]]; then
    return 1
  fi

  # jq로 Read, Glob, Grep 도구 호출 확인
  local has_read
  has_read=$(echo "$history_json" | jq '
    .tool_calls[]? |
    select(.name == "Read" or .name == "Glob" or .name == "Grep") |
    .name' 2>/dev/null | wc -l)

  [[ "$has_read" -gt 0 ]]
}

# ═════════════════════════════════════════════════════════════════════════════════
# [6] 도구 호출 히스토리에서 파일 관련 매개변수 추출
# ═════════════════════════════════════════════════════════════════════════════════

_extract_file_params_from_history() {
  local history_json="$1"

  if [[ -z "$history_json" ]]; then
    return 1
  fi

  # 모든 가능한 파일 경로 매개변수 추출
  # tool_calls 배열에서 file_path, path, pattern 등 추출
  local params
  params=$(echo "$history_json" | jq -r '
    .tool_calls[]? |
    [
      .parameters.file_path? // empty,
      .parameters.path? // empty,
      .parameters.pattern? // empty,
      .invoke.file_path? // empty,
      .invoke.path? // empty,
      .invoke.pattern? // empty
    ] | .[] | select(. != null and . != "")' 2>/dev/null || echo "")

  if [[ -z "$params" ]]; then
    return 1
  fi

  echo "$params"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [7] 사용자 요청에서 파일/경로 언급 추출
# ═════════════════════════════════════════════════════════════════════════════════

_extract_paths_from_message() {
  local message="$1"

  if [[ -z "$message" ]]; then
    return 1
  fi

  # 절대경로, 상대경로, 파일명이 언급된 부분 추출
  local paths
  paths=$(echo "$message" | grep -oE '(/[^ "]*|~/[^ "]*|[a-zA-Z0-9_\-\.]+\.(sh|json|md|txt|yaml|yml))' 2>/dev/null || echo "")

  if [[ -z "$paths" ]]; then
    return 1
  fi

  echo "$paths"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [8] 경로 정규화 및 매칭
# ═════════════════════════════════════════════════════════════════════════════════

_normalize_path() {
  local path="$1"
  # ~를 $HOME으로 확장
  path="${path/#\~/$HOME}"
  # 상대경로 정규화
  if [[ ! "$path" =~ ^/ ]]; then
    path="$(cd "${2:-.}" 2>/dev/null && pwd)/$path" || echo "$path"
  fi
  echo "$path"
}

_paths_match() {
  local requested="$1"
  local accessed="$2"

  # 정규화
  requested=$(_normalize_path "$requested")
  accessed=$(_normalize_path "$accessed")

  # 정확 매치 또는 접두사 매치
  [[ "$accessed" == "$requested" || "$requested" == "$accessed"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════════
# [9] 메인 검사 함수
# ═════════════════════════════════════════════════════════════════════════════════

check_completion_safety() {
  local user_message="${1:-}"
  local tool_history_json="${2:-}"

  # 완료 선언 키워드 감지
  local detected_keyword
  detected_keyword=$(_detect_completion_keyword "$user_message") || {
    # 완료 선언이 없으면 안전함
    _guard_completion_log "INFO" "No completion keyword detected — safety check passed"
    return 0
  }

  _guard_completion_log "WARN" "Completion keyword detected: '$detected_keyword'"

  # 도구 호출 히스토리가 없으면 위험함
  if [[ -z "$tool_history_json" ]]; then
    _guard_completion_log "ALERT" "No tool history provided with completion keyword — BLOCKING completion claim"
    return 1
  fi

  # Read/Glob/Grep 도구 사용 여부 확인
  if ! _has_read_tool_usage "$tool_history_json"; then
    _guard_completion_log "ALERT" "No Read/Glob/Grep tool usage detected with completion keyword — BLOCKING completion claim"
    return 1
  fi

  # 사용자 요청에서 언급된 파일/경로 추출
  local requested_paths
  requested_paths=$(_extract_paths_from_message "$user_message") || {
    # 경로가 명시되지 않은 경우 → 파일 도구 호출이 있다면 안전
    _guard_completion_log "INFO" "No specific paths in user message but Read/Glob/Grep was used — safety check passed"
    return 0
  }

  # 도구 호출 히스토리에서 접근한 경로 추출
  local accessed_paths
  accessed_paths=$(_extract_file_params_from_history "$tool_history_json") || {
    _guard_completion_log "ALERT" "No file parameters extracted from tool history with completion keyword — BLOCKING completion claim"
    return 1
  }

  # 모든 요청된 경로가 접근 경로에 포함되는지 확인
  local all_paths_checked=true
  while IFS= read -r req_path; do
    local path_found=false
    while IFS= read -r acc_path; do
      if _paths_match "$req_path" "$acc_path"; then
        path_found=true
        break
      fi
    done <<< "$accessed_paths"

    if [[ "$path_found" != true ]]; then
      all_paths_checked=false
      _guard_completion_log "ALERT" "Requested path not accessed: '$req_path'"
      break
    fi
  done <<< "$requested_paths"

  if [[ "$all_paths_checked" != true ]]; then
    _guard_completion_log "ALERT" "Some requested paths were not accessed — BLOCKING completion claim"
    return 1
  fi

  _guard_completion_log "INFO" "All requested paths were accessed — safety check passed"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [10] 배포 테스트 모드 (standalone 테스트용)
# ═════════════════════════════════════════════════════════════════════════════════

# 테스트 모드는 외부 스크립트에서 호출하도록 변경

# ═════════════════════════════════════════════════════════════════════════════════
# [11] 통합 래퍼: ask-claude.sh 호출용 (도구 호출 목록 + 사용자 메시지 전달)
# ═════════════════════════════════════════════════════════════════════════════════

check_completion_safety_from_claude_output() {
  local user_message="${1:-}"
  local raw_output_json="${2:-}"
  local task_id="${3:-}"

  # JSON 응답이 유효한지 확인
  if [[ -z "$raw_output_json" ]]; then
    _guard_completion_log "WARN" "[task=$task_id] No raw output JSON provided"
    return 0  # 데이터 없으면 통과 (false positive 방지)
  fi

  # tool_calls 배열 추출
  local tool_calls_json
  tool_calls_json=$(echo "$raw_output_json" | jq -r '.tool_calls // empty' 2>/dev/null || echo "")

  if [[ -z "$tool_calls_json" ]]; then
    # 도구 호출이 없으면 완료 선언 검사 스킵
    _guard_completion_log "INFO" "[task=$task_id] No tool calls in response"
    return 0
  fi

  # 사용자 메시지에서 완료 선언 감지
  local detected_keyword
  detected_keyword=$(_detect_completion_keyword "$user_message") || {
    _guard_completion_log "INFO" "[task=$task_id] No completion keyword in user message"
    return 0
  }

  _guard_completion_log "WARN" "[task=$task_id] Completion keyword detected: '$detected_keyword' — verifying tool calls"

  # tool_calls에서 Read/Glob/Grep 도구 사용 여부 확인
  local has_read_tools
  has_read_tools=$(echo "$tool_calls_json" | jq '[.[] | select(.name == "Read" or .name == "Glob" or .name == "Grep")] | length' 2>/dev/null || echo "0")

  if [[ "$has_read_tools" -eq 0 ]]; then
    _guard_completion_log "ALERT" "[task=$task_id] Completion keyword detected but NO Read/Glob/Grep tool calls — POTENTIAL SAFETY ISSUE"
    return 1
  fi

  # 도구 호출 경로 추출
  local accessed_paths
  accessed_paths=$(echo "$tool_calls_json" | jq -r '
    .[] |
    [
      .parameters.file_path? // empty,
      .parameters.path? // empty,
      .parameters.pattern? // empty
    ] | .[] | select(. != null and . != "")' 2>/dev/null || echo "")

  if [[ -z "$accessed_paths" ]]; then
    _guard_completion_log "WARN" "[task=$task_id] Read tools used but no file paths extracted — may be intentional (globbing, searching)"
    return 0  # 글로빙/검색은 허용
  fi

  # 사용자 메시지에서 언급된 경로 추출
  local requested_paths
  requested_paths=$(_extract_paths_from_message "$user_message") || {
    _guard_completion_log "INFO" "[task=$task_id] No specific paths mentioned in user message — Read tool usage sufficient"
    return 0
  }

  # 경로 매칭: 요청된 모든 경로가 접근 목록에 포함되는지 확인
  local all_matched=true
  while IFS= read -r req_path; do
    local found=false
    while IFS= read -r acc_path; do
      if _paths_match "$req_path" "$acc_path"; then
        found=true
        break
      fi
    done <<< "$accessed_paths"

    if [[ "$found" != true ]]; then
      all_matched=false
      _guard_completion_log "ALERT" "[task=$task_id] Requested path not accessed: '$req_path'"
      break
    fi
  done <<< "$requested_paths"

  if [[ "$all_matched" != true ]]; then
    _guard_completion_log "ALERT" "[task=$task_id] Some paths requested but not accessed — POTENTIAL SAFETY ISSUE"
    return 1
  fi

  _guard_completion_log "INFO" "[task=$task_id] Completion safety check PASSED — all tools/paths verified"
  return 0
}
