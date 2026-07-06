#!/bin/bash
################################################################################
# completion-file-validator-guard.sh — 완료 선언 전 파일 검증 가드
#
# 클러스터 ID: cl-dcd8ff3443b1f052 (최근 7일 재발 118건)
# 반복 패턴:
#   - 파일 상태 확인 없이 재작업 제안 (경로 미검증)
#   - 파일 업로드 대상 채널 오류 — 검증 미실시
#   - 파일 내용 미검증 후 보고 — 한글만 있는데 영어로 완성되었다고 암묵적 가정
#   - 파일 검증 완료 선언 후 같은 도메인에서 표준 미내재화
#   - API timeout으로 인한 파일 손상 후 불완전한 상태 인식 지연
#
# 목적:
#   완료 선언 시점에 파일 검증을 자동으로 실행하고, 검증 실패 시
#   완료 선언 진행을 차단하는 구조적 가드
#
# 작동:
#   1. 사용자 메시지에서 "완료" 키워드 감지
#   2. 최근 도구 호출 히스토리에서 파일 저장/업로드 작업 찾기
#   3. 저장된 파일에 대해 file-validator.sh 자동 실행
#   4. 검증 실패 시 경고 반환 & exit 1
#   5. 검증 성공 시 진행 허용
#
# 사용법 (task runner 통합):
#   source ~/jarvis/infra/lib/completion-file-validator-guard.sh
#   check_completion_with_file_validation "$user_message" "$context_json"
#   # exit code: 0 = 안전, 1 = 위험
#
################################################################################

set -euo pipefail

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 상수
JARVIS_LIB="${HOME}/jarvis/infra/lib"
FILE_VALIDATOR="${JARVIS_LIB}/file-validator.sh"
LOG_DIR="${HOME}/jarvis/logs"

# 로그 생성
mkdir -p "$LOG_DIR" 2>/dev/null || true

#################################################################################
# 로깅 함수
#################################################################################
_log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')

  # 콘솔 출력
  case "$level" in
    ERROR)
      echo -e "${RED}[ERROR]${NC} $message" >&2
      ;;
    WARN)
      echo -e "${YELLOW}[WARN]${NC} $message" >&2
      ;;
    INFO)
      echo -e "${GREEN}[INFO]${NC} $message" >&2
      ;;
    DEBUG)
      echo -e "${BLUE}[DEBUG]${NC} $message" >&2
      ;;
  esac

  # 파일에 기록
  printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >> \
    "${LOG_DIR}/completion-file-validator-guard.log" 2>/dev/null || true
}

#################################################################################
# 완료 선언 키워드 감지
#################################################################################
_has_completion_keyword() {
  local text="$1"

  # 한글/영어 완료 키워드
  local keywords=(
    "완료했습니다" "완료했어요" "완료됐어요" "완료됐습니다" "완료됨" "완료"
    "확인했어요" "확인했습니다" "확인했다" "확인됨" "확인"
    "했어요" "했습니다" "했다"
    "done" "completed" "finished" "verified"
  )

  local text_lower
  text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  for keyword in "${keywords[@]}"; do
    local keyword_lower
    keyword_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
    if [[ "$text_lower" =~ $keyword_lower ]]; then
      _log INFO "완료 선언 키워드 감지: '$keyword'"
      return 0
    fi
  done

  return 1
}

#################################################################################
# Context JSON에서 파일 경로 추출
#################################################################################
_extract_file_paths_from_context() {
  local context_json="$1"

  # context_json이 비어있거나 유효하지 않으면 빈 결과 반환
  if [[ -z "$context_json" ]]; then
    return 0
  fi

  # JSON에서 파일 경로들을 추출 (예: "file_path": "/path/to/file", "saved_to": "/path/to/file")
  # jq가 있으면 사용, 없으면 grep으로 간단히 처리
  if command -v jq &> /dev/null; then
    echo "$context_json" | jq -r \
      '.files[]? // .file_paths[]? // .saved_files[]? // empty | select(. | type == "string")' \
      2>/dev/null || true
  else
    # 간단한 문자열 추출 (jq 없을 때)
    echo "$context_json" | grep -oE '"(file_path|saved_to|file|path)":"[^"]*"' | \
      sed 's/.*:"\([^"]*\)".*/\1/' || true
  fi
}

#################################################################################
# 도구 호출 히스토리에서 최근 파일 저장 작업 찾기
#################################################################################
_find_recent_file_save_in_history() {
  local tool_history="$1"

  if [[ -z "$tool_history" ]]; then
    return 0
  fi

  # tool_history 형식: JSON 배열 또는 텍스트
  # 찾는 패턴: Write, Bash (cat, cp, mv 등), Edit
  if command -v jq &> /dev/null; then
    echo "$tool_history" | jq -r \
      '.[] | select(.tool | test("Write|Edit|Bash"; "i")) | .result // .params // empty' \
      2>/dev/null || true
  else
    # 간단한 문자열 검사
    echo "$tool_history" | grep -iE '(Write|Edit|save|write)' || true
  fi
}

#################################################################################
# 파일 검증 수행
#################################################################################
_validate_saved_files() {
  local file_paths="$1"
  local expect_lang="${2:-}"

  # 파일 경로가 비어있으면 통과
  if [[ -z "$file_paths" ]]; then
    _log WARN "저장된 파일 경로를 찾을 수 없음. 검증 스킵."
    return 0
  fi

  local validation_failed=0
  local validation_count=0

  # 각 파일 경로에 대해 검증 실행
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue

    validation_count=$((validation_count + 1))
    _log INFO "파일 검증 시작: $file_path"

    # file-validator.sh 실행
    if [[ -x "$FILE_VALIDATOR" ]]; then
      if "$FILE_VALIDATOR" "$file_path" ${expect_lang:+--expect-lang "$expect_lang"} 2>&1; then
        _log INFO "✓ 파일 검증 성공: $file_path"
      else
        _log ERROR "✗ 파일 검증 실패: $file_path"
        validation_failed=1
      fi
    else
      _log WARN "file-validator.sh를 찾을 수 없음: $FILE_VALIDATOR"
    fi
  done <<< "$file_paths"

  if [[ $validation_count -eq 0 ]]; then
    _log WARN "검증할 파일을 찾을 수 없음"
    return 0
  fi

  return $validation_failed
}

#################################################################################
# 주요 함수: 완료 선언 전 파일 검증
#################################################################################
check_completion_with_file_validation() {
  local user_message="${1:-}"
  local context_json="${2:-}"
  local tool_history="${3:-}"

  if [[ -z "$user_message" ]]; then
    _log WARN "사용자 메시지가 비어있음"
    return 0
  fi

  _log INFO "완료 선언 검증 시작"
  _log DEBUG "사용자 메시지: $user_message"

  # [1] 완료 선언 키워드 감지
  if ! _has_completion_keyword "$user_message"; then
    _log DEBUG "완료 선언 키워드 없음. 통과."
    return 0
  fi

  _log WARN "완료 선언 감지됨. 파일 검증 수행 중..."

  # [2] context JSON에서 파일 경로 추출
  local file_paths
  file_paths=$(_extract_file_paths_from_context "$context_json")

  # [3] 파일 경로가 없으면 도구 히스토리에서 찾기
  if [[ -z "$file_paths" ]]; then
    file_paths=$(_find_recent_file_save_in_history "$tool_history")
  fi

  # [4] 파일 검증 수행
  if ! _validate_saved_files "$file_paths"; then
    _log ERROR "❌ 파일 검증 실패. 완료 선언 진행 차단!"
    echo -e "${RED}⚠️  경고: 저장된 파일의 검증에 실패했습니다. 파일 상태를 다시 확인해주세요.${NC}" >&2
    return 1
  fi

  _log INFO "✅ 모든 검증 통과. 완료 선언 허용."
  return 0
}

#################################################################################
# CLI 엔트리포인트
#################################################################################
main() {
  if [[ $# -lt 1 ]]; then
    cat >&2 <<EOF
Usage: completion-file-validator-guard.sh <user_message> [context_json] [tool_history]

역할: 완료 선언 시점에 파일 검증을 자동으로 수행하고, 검증 실패 시 진행 차단

Examples:
  $0 "작업 완료했습니다"
  $0 "작업 완료했습니다" '{"files": ["/path/to/file.pdf"]}'

Exit codes:
  0   검증 통과 또는 완료 선언 없음
  1   검증 실패 - 완료 선언 진행 차단
EOF
    return 1
  fi

  local user_message="$1"
  local context_json="${2:-}"
  local tool_history="${3:-}"

  check_completion_with_file_validation "$user_message" "$context_json" "$tool_history"
  return $?
}

# 스크립트 직접 실행인 경우
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
