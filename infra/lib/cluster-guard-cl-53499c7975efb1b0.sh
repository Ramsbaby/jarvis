#!/bin/bash
# cluster-guard-cl-53499c7975efb1b0.sh — 문서 내부 불일치 검증 가드
#
# 문제: 문서 내부 불일치 미감지 — 합계표와 코멘트 숫자 교차 검증 누락
# 재발: 최근 7일 10건
#
# 솔루션:
#   1. 문서 내 숫자가 여러 위치에 분산될 때 자동 교차검증
#   2. 본교재 수정 시 요약본·숙제 등 연관 파일 동기화 강제
#   3. pre-submit 훅 연동으로 불일치 감지 시 업로드 차단
#
# 동작:
#   1. 문서 파일 스캔 → 숫자 패턴 추출
#   2. 합계/소계 실제값 비교
#   3. 번호 연속성 및 참조 일관성 검증
#   4. 불일치 시 상세 리포트 + UNVERIFIED_CONSISTENCY 표시
#
# 사용:
#   source ~/jarvis/infra/lib/cluster-guard-cl-53499c7975efb1b0.sh
#   validate_document_consistency "교재_파일"
#   validate_related_files "교재_파일" "요약본" "숙제"
#   get_guard_status

set -euo pipefail

# ============================================================================
# 설정
# ============================================================================

readonly CLUSTER_ID="cl-53499c7975efb1b0"
readonly JARVIS_HOME="${HOME}/jarvis"
readonly STATE_DIR="${JARVIS_HOME}/runtime/state/cluster-guards"
readonly GUARD_STATE="${STATE_DIR}/${CLUSTER_ID}-state.json"
readonly VALIDATION_LOG="${STATE_DIR}/${CLUSTER_ID}-validations.jsonl"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# 유틸리티
# ============================================================================

log() {
  local level=$1
  shift
  local msg="$*"
  case $level in
    info) echo -e "${BLUE}[${CLUSTER_ID}] ℹ️  ${msg}${NC}" ;;
    ok) echo -e "${GREEN}[${CLUSTER_ID}] ✅ ${msg}${NC}" ;;
    warn) echo -e "${YELLOW}[${CLUSTER_ID}] ⚠️  ${msg}${NC}" ;;
    err) echo -e "${RED}[${CLUSTER_ID}] ❌ ${msg}${NC}" ;;
  esac
}

_ensure_dirs() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

_init_guard_state() {
  _ensure_dirs

  if [[ ! -f "$GUARD_STATE" ]]; then
    cat > "$GUARD_STATE" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "문서 내부 불일치 미감지 — 합계표와 코멘트 숫자 교차 검증 누락",
  "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_validations": 0,
  "passed": 0,
  "failed": 0,
  "last_validation_at": null,
  "unverified_documents": []
}
EOF
    log ok "가드 상태 초기화됨"
  fi
}

_update_guard_state() {
  local validation_result=$1
  local is_passed=$2

  _ensure_dirs

  local passed_val=$([[ "$is_passed" == "true" ]] && echo "1" || echo "0")
  local failed_val=$([[ "$is_passed" == "true" ]] && echo "0" || echo "1")

  jq \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".total_validations += 1 | .passed += $passed_val | .failed += $failed_val | .last_validation_at = \$now" \
    "$GUARD_STATE" > "${GUARD_STATE}.tmp" 2>/dev/null || true
  mv "${GUARD_STATE}.tmp" "$GUARD_STATE" 2>/dev/null || true
}

_record_validation() {
  local file=$1
  local validation_result=$2
  local is_passed=$3

  _ensure_dirs

  local record=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster_id": "${CLUSTER_ID}",
  "file": "$(basename "$file")",
  "file_path": "$file",
  "status": "$([[ "$is_passed" == "true" ]] && echo "PASSED" || echo "FAILED")",
  "details": $(printf '%s\n' "$validation_result" | jq -Rs '.')
}
EOF
)
  echo "$record" >> "$VALIDATION_LOG" 2>/dev/null || true
}

# ============================================================================
# 핵심 검증 로직
# ============================================================================

# 합계/소계 검증
_validate_sums() {
  local file="$1"
  local issues=""

  # 패턴: "소계 X개" + 실제 항목 개수 비교
  if grep -qi "소계\|합계\|총" "$file" 2>/dev/null; then
    local summary_counts
    summary_counts=$(grep -oiE '(소계|합계|총)[^0-9]*([0-9]+)' "$file" 2>/dev/null | grep -oE '[0-9]+$' | sort -u || true)

    if [[ -n "$summary_counts" ]]; then
      # 실제 항목 개수 계산 (마크다운 리스트)
      local item_count
      item_count=$(grep -cE '^\s*[-*]\s' "$file" 2>/dev/null || echo 0)

      while read -r summary_val; do
        [[ -z "$summary_val" ]] && continue
        if [[ "$summary_val" -ne "$item_count" ]]; then
          issues+="[소계 불일치] 선언된 개수: $summary_val개, 실제 항목 수: $item_count개\n"
        fi
      done <<< "$summary_counts"
    fi
  fi

  echo -e "$issues"
}

# 번호 연속성 검증
_validate_numbering() {
  local file="$1"
  local issues=""

  # 번호 추출: (1), ①, 1번 등
  local numbers
  numbers=$(grep -oE '\([0-9]+\)|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[0-9]+번' "$file" 2>/dev/null | grep -oE '[0-9]+' | sort -n | uniq || true)

  if [[ -n "$numbers" ]]; then
    local prev=0
    while read -r num; do
      [[ -z "$num" ]] && continue
      if [[ $prev -gt 0 ]] && [[ $((num - prev)) -gt 1 ]]; then
        issues+="[번호 갭] $prev 다음이 $num (갭 크기: $((num - prev - 1)))\n"
      fi
      prev=$num
    done <<< "$numbers"
  fi

  echo -e "$issues"
}

# 참조 일관성 검증
_validate_references() {
  local file="$1"
  local issues=""

  # 참조된 번호와 실제 정의 비교
  local references
  references=$(grep -oiE '\[(그림|표|예문|섹션)\s+([0-9]+|[①-⑩])\]' "$file" 2>/dev/null | sort -u || true)

  while read -r ref; do
    [[ -z "$ref" ]] && continue
    local ref_text
    ref_text=$(echo "$ref" | sed 's/\[//g; s/\]//g')

    # 실제 정의 확인
    if ! grep -qi "^[#*\-]*\s*$ref_text" "$file" 2>/dev/null && ! grep -qi "$ref_text:" "$file" 2>/dev/null; then
      issues+="[미정의 참조] $ref_text 이(가) 정의되지 않음\n"
    fi
  done <<< "$references"

  echo -e "$issues"
}

# ============================================================================
# 공개 API
# ============================================================================

# 단일 문서 일관성 검증
validate_document_consistency() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    log err "파일을 찾을 수 없음: $file"
    return 1
  fi

  log info "문서 검증: $(basename "$file")"

  local issues=""

  # 합계 검증
  local sum_issues
  sum_issues=$(_validate_sums "$file")
  [[ -n "$sum_issues" ]] && issues+="$sum_issues"

  # 번호 연속성 검증
  local numbering_issues
  numbering_issues=$(_validate_numbering "$file")
  [[ -n "$numbering_issues" ]] && issues+="$numbering_issues"

  # 참조 검증
  local ref_issues
  ref_issues=$(_validate_references "$file")
  [[ -n "$ref_issues" ]] && issues+="$ref_issues"

  # 결과 처리
  if [[ -z "$issues" ]]; then
    log ok "문서 내부 일관성 검증 성공"
    _update_guard_state "" "true"
    _record_validation "$file" "" "true"
    return 0
  else
    log err "문서 내부 불일치 감지:"
    echo -e "$issues" | sed 's/^/  /'
    _update_guard_state "$issues" "false"
    _record_validation "$file" "$issues" "false"
    return 1
  fi
}

# 관련 파일 동기화 검증
# 교재 수정 시 요약본, 숙제 등이 동기화되었는지 확인
validate_related_files() {
  local main_file="$1"
  shift
  local related_files=("$@")

  if [[ ! -f "$main_file" ]]; then
    log err "메인 파일을 찾을 수 없음: $main_file"
    return 1
  fi

  log info "관련 파일 동기화 검증: $(basename "$main_file")"

  local main_mtime
  main_mtime=$(stat -f%m "$main_file" 2>/dev/null || stat -c%Y "$main_file" 2>/dev/null || echo 0)

  local outdated_files=""

  for related_file in "${related_files[@]}"; do
    if [[ ! -f "$related_file" ]]; then
      log warn "관련 파일을 찾을 수 없음: $related_file"
      continue
    fi

    local related_mtime
    related_mtime=$(stat -f%m "$related_file" 2>/dev/null || stat -c%Y "$related_file" 2>/dev/null || echo 0)

    # 관련 파일이 메인 파일보다 오래되었으면 불일치
    if [[ "$related_mtime" -lt "$main_mtime" ]]; then
      outdated_files+="[오래된 파일] $(basename "$related_file"): 메인 파일보다 $(( (main_mtime - related_mtime) / 3600 ))시간 더 오래됨\n"
    fi
  done

  if [[ -z "$outdated_files" ]]; then
    log ok "관련 파일 동기화 확인 완료"
    _update_guard_state "" "true"
    return 0
  else
    log err "관련 파일 동기화 미확인:"
    echo -e "$outdated_files" | sed 's/^/  /'
    _update_guard_state "$outdated_files" "false"
    return 1
  fi
}

# 가드 상태 조회
get_guard_status() {
  _ensure_dirs
  _init_guard_state

  if [[ -f "$GUARD_STATE" ]]; then
    cat "$GUARD_STATE"
  else
    echo "{\"status\": \"not_initialized\"}"
  fi
}

# 초기화
_ensure_dirs
_init_guard_state
