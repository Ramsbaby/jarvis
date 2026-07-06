#!/bin/bash
################################################################################
# post-save-file-guard.sh — 파일 저장/업로드 후 자동 검증 가드
#
# 역할: 파일 저장 직후 검증을 자동으로 실행하고, 검증 실패 시 보고 및 복구
#
# 클러스터 ID: cl-dcd8ff3443b1f052 (최근 7일 재발 118건)
# 문제 패턴:
#   - 파일 상태 확인 없이 재작업 제안 (경로 미검증)
#   - 파일 업로드 대상 채널 오류 (검증 미실시)
#   - 파일 내용 미검증 후 보고 (한글만 있는데 영어로 완성)
#   - API timeout으로 인한 파일 손상 후 불완전한 상태 인식 지연
#
# 사용 예:
#   source ~/jarvis/infra/lib/post-save-file-guard.sh
#   validate_and_report_file "/path/to/file.pdf" "ko" "discord-upload"
#   # or
#   post_save_file_guard "/path/to/file.pdf" "ko" "task-name"
#
# Exit codes:
#   0   검증 성공
#   1   검증 실패 - 보고 및 복구 수행
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
COMPLETION_VALIDATOR="${JARVIS_LIB}/completion-file-validator-guard.sh"
LOG_DIR="${HOME}/jarvis/logs"
VALIDATION_LEDGER="${LOG_DIR}/file-validation-ledger.jsonl"

# 로그 생성
mkdir -p "$LOG_DIR" 2>/dev/null || true

#################################################################################
# 로깅 함수
#################################################################################
_psfg_log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')

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

  printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >> "$LOG_DIR/post-save-file-guard.log" 2>/dev/null || true
}

#################################################################################
# 검증 결과를 Ledger에 기록
#################################################################################
_record_validation() {
  local file_path="$1"
  local status="$2"  # "success" or "failure"
  local reason="${3:-}"
  local context="${4:-}"

  local entry
  entry=$(jq -cn \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg file "$file_path" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg context "$context" \
    '{ts:$ts, file:$file, status:$status, reason:$reason, context:$context}' 2>/dev/null || true)

  if [[ -n "$entry" ]]; then
    echo "$entry" >> "$VALIDATION_LEDGER" 2>/dev/null || true
  fi
}

#################################################################################
# 파일 검증 수행
#################################################################################
_validate_saved_file() {
  local file_path="$1"
  local expect_lang="${2:-}"
  local context="${3:-}"

  _psfg_log INFO "파일 검증 시작: $file_path (lang=$expect_lang, context=$context)"

  if ! [[ -x "$FILE_VALIDATOR" ]]; then
    _psfg_log WARN "file-validator.sh를 찾을 수 없음: $FILE_VALIDATOR"
    return 0  # 검증 스크립트 없을 때는 통과 (graceful)
  fi

  # 검증 실행
  local validator_exit=0
  if "$FILE_VALIDATOR" "$file_path" ${expect_lang:+--expect-lang "$expect_lang"} 2>&1; then
    _psfg_log INFO "✓ 파일 검증 성공: $file_path"
    _record_validation "$file_path" "success" "" "$context"
    return 0
  else
    validator_exit=$?
    _psfg_log ERROR "✗ 파일 검증 실패: $file_path (exit $validator_exit)"
    _record_validation "$file_path" "failure" "validation_failed" "$context"
    return 1
  fi
}

#################################################################################
# 검증 실패 시 복구/보고
#################################################################################
_handle_validation_failure() {
  local file_path="$1"
  local expect_lang="${2:-}"
  local context="${3:-}"

  _psfg_log ERROR "파일 검증 실패 처리: $file_path"

  # [1] 파일 상태 진단
  if [[ ! -e "$file_path" ]]; then
    _psfg_log ERROR "파일이 존재하지 않음: $file_path"
    _record_validation "$file_path" "failure" "file_not_exist" "$context"
    return 1
  fi

  local file_size=0
  if [[ -f "$file_path" ]]; then
    file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo 0)
  fi

  _psfg_log WARN "파일 크기: $file_size bytes"

  # [2] 언어 비율 진단 (있으면)
  if [[ -n "$expect_lang" ]]; then
    if command -v python3 &> /dev/null; then
      local content
      if [[ "$file_path" == *.pdf ]]; then
        content=$(pdftotext "$file_path" - 2>/dev/null || echo "")
      else
        content=$(cat "$file_path" 2>/dev/null || echo "")
      fi

      local lang_info
      lang_info=$(python3 -c "
import re
content = '''${content}'''
ko_pattern = re.compile(r'[\uac00-\ud7a3]')
en_pattern = re.compile(r'[a-zA-Z]')
ko_count = len(ko_pattern.findall(content))
en_count = len(en_pattern.findall(content))
total = len(content)
if total > 0:
  ko_ratio = int(ko_count * 100 / total)
  en_ratio = int(en_count * 100 / total)
  print(f'{ko_ratio}% ko, {en_ratio}% en')
else:
  print('empty file')
" 2>/dev/null || echo "")

      _psfg_log WARN "언어 비율: $lang_info"
    fi
  fi

  # [3] 알림 발송 (선택사항: Discord 채널에 알림)
  if command -v discord_route &> /dev/null; then
    discord_route critical "파일 검증 실패 — cl-dcd8ff3443b1f052" \
      "파일=${file_path},크기=${file_size},기대언어=${expect_lang}" 2>/dev/null || true
  fi

  return 1
}

#################################################################################
# 메인 함수: 파일 저장 후 검증
#################################################################################
validate_and_report_file() {
  local file_path="${1:?Usage: validate_and_report_file <file_path> [expect_lang] [context]}"
  local expect_lang="${2:-}"
  local context="${3:-}"

  _psfg_log INFO "Post-save validation guard activated"
  _psfg_log DEBUG "file_path=$file_path, expect_lang=$expect_lang, context=$context"

  # 검증 수행
  if _validate_saved_file "$file_path" "$expect_lang" "$context"; then
    return 0
  else
    # 검증 실패 시 진단 및 보고
    _handle_validation_failure "$file_path" "$expect_lang" "$context"
    return 1
  fi
}

#################################################################################
# 단축 별칭
#################################################################################
post_save_file_guard() {
  validate_and_report_file "$@"
  return $?
}

#################################################################################
# Batch validation (여러 파일 한번에 검증)
#################################################################################
validate_multiple_files() {
  local -a file_paths=("$@")
  local failed_count=0
  local total_count=${#file_paths[@]}

  _psfg_log INFO "배치 파일 검증 시작: $total_count개 파일"

  for file_path in "${file_paths[@]}"; do
    if ! validate_and_report_file "$file_path"; then
      ((failed_count++)) || true
    fi
  done

  _psfg_log INFO "배치 검증 완료: 성공 $((total_count - failed_count))/$total_count, 실패 $failed_count"

  if [[ $failed_count -gt 0 ]]; then
    return 1
  fi

  return 0
}

#################################################################################
# CLI 엔트리포인트
#################################################################################
main() {
  if [[ $# -lt 1 ]]; then
    cat >&2 <<EOF
Usage: post-save-file-guard.sh <file_path> [expect_lang] [context]

역할: 파일 저장/업로드 직후 자동 검증 및 실패 보고

Examples:
  post-save-file-guard.sh /path/to/file.pdf
  post-save-file-guard.sh /path/to/file.pdf ko
  post-save-file-guard.sh /path/to/file.pdf ko "discord-upload"

Exit codes:
  0   검증 성공
  1   검증 실패

Environment:
  JARVIS_VALIDATOR_DEBUG=1   Enable debug output
EOF
    return 1
  fi

  local file_path="$1"
  local expect_lang="${2:-}"
  local context="${3:-}"

  validate_and_report_file "$file_path" "$expect_lang" "$context"
  return $?
}

# 스크립트 직접 실행인 경우
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
