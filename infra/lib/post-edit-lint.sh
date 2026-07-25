#!/bin/bash
# post-edit-lint.sh — 한영병기·HTML 업로드 규칙 검증
#
# 역할: 교육 콘텐츠 편집 후 선언된 규칙(한영병기, HTML 업로드, 동기화)
#       의 실제 적용 여부를 자동 검증하는 post-edit 가드
#
# 사용: post-edit-lint.sh <file-path> [--strict]
#       --strict: 모든 규칙 위반 시 exit 1 (default는 경고만)

set -euo pipefail

FILE_PATH="${1:-.}"
STRICT_MODE="${2:-}"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# 결과 추적
LINT_ERRORS=()
LINT_WARNINGS=()
LINT_PASSED=()

# 로그 함수
log_error() {
  LINT_ERRORS+=("$1")
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
  LINT_WARNINGS+=("$1")
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_pass() {
  LINT_PASSED+=("$1")
  echo -e "${GREEN}[PASS]${NC} $1"
}

# 규칙 1: 한영병기 검증
# 문법 표가 있는 경우, 영어 해석이 반드시 포함되어야 함
check_bilingual_grammar_tables() {
  local file="$1"

  # 파일 존재 확인
  if [[ ! -f "$file" ]]; then
    log_pass "규칙 1: 파일 없음 (검증 스킵)"
    return 0
  fi

  # 문법 표 또는 한국어 관련 키워드 확인
  if ! grep -qi 'grammar\|table\|기본형\|문법.*표\|<table>\|<tr>' "$file" 2>/dev/null; then
    log_pass "규칙 1: 문법 표 없음 (검증 스킵)"
    return 0
  fi

  # 문법 표가 있다면 영어 설명 확인
  # 영어 키워드: English, base form, interpretation, translation, meaning 등
  if grep -qi 'English\|base form\|interpretation\|translation\|의미\|해석' "$file" 2>/dev/null; then
    log_pass "규칙 1: 한영병기 일관성 검증 완료 (영어 해석 포함됨)"
    return 0
  else
    log_error "규칙 1: 문법 표가 있으나 영어 해석 누락 — 한영병기 규칙 위반"
    return 1
  fi
}

# 규칙 2: HTML 업로드 규칙
# 파일 확장자가 .html이고 업로드 대상인 경우, 경로 명시 필요
check_html_upload_rule() {
  local file="$1"

  # HTML 파일인지 확인
  if [[ ! "$file" =~ \.html?$ ]]; then
    log_pass "규칙 2: HTML 파일 아님 (검증 스킵)"
    return 0
  fi

  # HTML 업로드 경로 명시 여부 확인
  # 패턴: "upload", "deploy", "path", "destination" 등과 함께 경로 표기
  if grep -qi 'upload\|deploy\|destination\|path:.*/' "$file" 2>/dev/null; then
    log_pass "규칙 2: HTML 업로드 경로 명시됨 (검증 완료)"
    return 0
  else
    log_error "규칙 2: HTML 파일의 업로드 경로 미명시 — SSoT 규칙 위반"
    return 1
  fi
}

# 규칙 3: 동기화 규칙
# 여러 소스를 동시 수정하는 경우, 동기화 완료 명시 필요
check_synchronization_rule() {
  local file="$1"

  # 파일이 실제로 존재하는지 확인
  if [[ ! -f "$file" ]]; then
    log_warning "규칙 3: 파일이 실제로 존재하지 않음 (경로: $file)"
    return 0
  fi

  # 여러 데이터소스 참조 패턴 확인
  local source_count=0
  local count1=$(grep -c 'update\|sync\|import\|source' "$file" 2>/dev/null | tr -d ' \n' || echo 0)
  local count2=$(grep -c 'database\|cache\|remote' "$file" 2>/dev/null | tr -d ' \n' || echo 0)
  local count3=$(grep -c 'version\|revision' "$file" 2>/dev/null | tr -d ' \n' || echo 0)

  [[ "$count1" -gt 3 ]] && ((source_count++))
  [[ "$count2" -gt 0 ]] && ((source_count++))
  [[ "$count3" -gt 0 ]] && ((source_count++))

  if [ "$source_count" -lt 2 ]; then
    log_pass "규칙 3: 단일 소스 변경 (동기화 검증 스킵)"
    return 0
  fi

  # 동기화 완료 명시 확인
  if grep -qi 'sync.*complete\|sync.*done\|동기화.*완료\|verified\|confirmed' "$file" 2>/dev/null; then
    log_pass "규칙 3: 동기화 완료 명시됨"
    return 0
  else
    log_warning "규칙 3: 다중 소스 변경이나 동기화 완료 명시 부재 (수동 확인 권장)"
    return 0
  fi
}

# 규칙 4: 규칙 실행 여부 자동 기록
record_lint_execution() {
  local audit_log="$HOME/jarvis/runtime/state/lint-execution.jsonl"
  mkdir -p "$(dirname "$audit_log")"

  local timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local error_count=$((${#LINT_ERRORS[@]:-0}))
  local warn_count=$((${#LINT_WARNINGS[@]:-0}))
  local pass_count=$((${#LINT_PASSED[@]:-0}))

  local status="pass"
  [[ $error_count -gt 0 ]] && status="fail"
  [[ $warn_count -gt 0 && $error_count -eq 0 ]] && status="warn"

  # 배열 내용 안전하게 변환
  local error_list='[]'
  local warn_list='[]'
  local pass_list='[]'

  if [[ ${#LINT_ERRORS[@]:-0} -gt 0 ]]; then
    error_list=$(printf '%s\n' "${LINT_ERRORS[@]}" | jq -Rs '.' | jq -s '.')
  fi

  if [[ ${#LINT_WARNINGS[@]:-0} -gt 0 ]]; then
    warn_list=$(printf '%s\n' "${LINT_WARNINGS[@]}" | jq -Rs '.' | jq -s '.')
  fi

  if [[ ${#LINT_PASSED[@]:-0} -gt 0 ]]; then
    pass_list=$(printf '%s\n' "${LINT_PASSED[@]}" | jq -Rs '.' | jq -s '.')
  fi

  local audit_entry=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "file": "$FILE_PATH",
  "status": "$status",
  "errors": $error_count,
  "warnings": $warn_count,
  "passed": $pass_count
}
EOF
  )

  echo "$audit_entry" >> "$audit_log"
}

# 메인 실행
main() {
  if [[ ! -f "$FILE_PATH" && ! -d "$FILE_PATH" ]]; then
    log_error "파일 또는 디렉토리가 존재하지 않음: $FILE_PATH"
    exit 1
  fi

  echo "🔍 Post-edit lint 검사 시작: $FILE_PATH"
  echo ""

  # 모든 규칙 실행
  check_bilingual_grammar_tables "$FILE_PATH"
  check_html_upload_rule "$FILE_PATH"
  check_synchronization_rule "$FILE_PATH"

  # 결과 기록
  record_lint_execution

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Lint 결과 요약:"
  echo "  ✅ PASS: ${#LINT_PASSED[@]}"
  echo "  ⚠️  WARN: ${#LINT_WARNINGS[@]}"
  echo "  ❌ ERROR: ${#LINT_ERRORS[@]}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # 엄격 모드에서 에러 있으면 exit 1
  if [[ "$STRICT_MODE" == "--strict" && ${#LINT_ERRORS[@]} -gt 0 ]]; then
    echo ""
    log_error "Strict 모드: 규칙 위반으로 인한 종료"
    exit 1
  fi

  exit 0
}

main "$@"
