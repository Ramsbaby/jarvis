#!/bin/bash
# cluster-guard-cl-0bae9367746da340.sh — 슬랭/신조어 검증 가드
#
# 문제: 존재하지 않는 슬랭 의미 조합 후 카드뉴스 제작 (재발 12건/7일)
# 솔루션: 슬랭/신조어 포함 콘텐츠 생성 시 WebSearch 기반 검증 강제
#
# 동작:
#   1. 콘텐츠 추출 → 잠재적 슬랭 감지
#   2. Claude + WebSearch 검증
#   3. 미확인 슬랭 → 작업 중단 + UNVERIFIED_SLANG 표시
#
# 사용:
#   source ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh
#   validate_slang_in_content "카드뉴스 내용"
#   get_guard_status

set -euo pipefail

# 상수
readonly CLUSTER_ID="cl-0bae9367746da340"
readonly JARVIS_HOME="${HOME}/.jarvis"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
readonly LIB_DIR="${JARVIS_HOME}/lib"
readonly STATE_DIR="${JARVIS_RUNTIME}/state/cluster-guards"
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
  mkdir -p "$STATE_DIR"
}

_init_guard_state() {
  _ensure_dirs

  if [[ ! -f "$GUARD_STATE" ]]; then
    cat > "$GUARD_STATE" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "존재하지 않는 슬랭 의미 조합 후 카드뉴스 제작",
  "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_validations": 0,
  "passed": 0,
  "failed": 0,
  "unverified_slangs": []
}
EOF
    log ok "가드 상태 초기화됨"
  fi
}

_update_guard_state() {
  local validation_result=$1

  _ensure_dirs

  # jq로 상태 업데이트
  local passed failed
  passed=$(echo "$validation_result" | jq -r '.status' | grep -q "PASSED" && echo "1" || echo "0")
  failed=$((1 - passed))

  jq \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".total_validations += 1 | .passed += $passed | .failed += $failed | .last_validation_at = \$now" \
    "$GUARD_STATE" > "${GUARD_STATE}.tmp"
  mv "${GUARD_STATE}.tmp" "$GUARD_STATE"
}

_record_validation() {
  local content=$1
  local validation_result=$2

  _ensure_dirs

  local record=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster_id": "${CLUSTER_ID}",
  "content_hash": "$(echo -n "$content" | sha256sum | awk '{print $1}')",
  "validation_result": $validation_result
}
EOF
  )

  echo "$record" >> "$VALIDATION_LOG"
}

# ============================================================================
# 슬랭 검증 로직
# ============================================================================

# 콘텐츠의 슬랭 검증 (slang-validator.mjs 호출)
validate_slang_in_content() {
  local content=$1
  local timeout=${2:-30}

  log info "슬랭 검증 시작 (콘텐츠 길이: ${#content}자)"

  # slang-validator.mjs 존재 확인
  if [[ ! -f "${LIB_DIR}/slang-validator.mjs" ]]; then
    log err "slang-validator.mjs 없음"
    return 1
  fi

  # 검증 실행 (타임아웃 적용)
  local validation_output
  validation_output=$(timeout "$timeout" node "${LIB_DIR}/slang-validator.mjs" \
    validate "$content" "--cluster-id=${CLUSTER_ID}" 2>&1 || true)

  local exit_code=$?

  if [[ $exit_code -eq 124 ]]; then
    log err "검증 타임아웃 (${timeout}초)"
    echo "{\"status\":\"TIMEOUT\",\"error\":\"validation_timeout\"}"
    return 1
  fi

  # 결과 파싱
  if ! echo "$validation_output" | jq empty 2>/dev/null; then
    log err "검증 결과 파싱 실패"
    echo "{\"status\":\"ERROR\",\"error\":\"invalid_json\",\"raw\":\"$validation_output\"}"
    return 1
  fi

  local status
  status=$(echo "$validation_output" | jq -r '.status // "UNKNOWN"')

  # 결과 기록
  _record_validation "$content" "$validation_output"
  _update_guard_state "$validation_output"

  if [[ "$status" == "PASSED" ]]; then
    log ok "슬랭 검증 통과"
    echo "$validation_output"
    return 0
  else
    local unverified_count
    unverified_count=$(echo "$validation_output" | jq '.unverifiedTerms | length')
    log err "미확인 슬랭 ${unverified_count}개 감지"
    echo "$validation_output"
    return 1
  fi
}

# 검증 결과를 PASS/FAIL 신호로 변환
should_proceed_with_content() {
  local validation_result=$1

  local status
  status=$(echo "$validation_result" | jq -r '.status // "UNKNOWN"')

  if [[ "$status" == "PASSED" ]]; then
    return 0  # 통과: 계속 진행
  else
    return 1  # 실패: 작업 중단
  fi
}

# 검증 실패 시 호출 — 콘텐츠에 UNVERIFIED_SLANG 마크 추가
mark_content_unverified() {
  local content=$1
  local validation_result=$2

  local unverified_terms
  unverified_terms=$(echo "$validation_result" | jq -r '.unverifiedTerms[] | .term' | tr '\n' ',' | sed 's/,$//')

  local marked_content
  marked_content=$(cat <<EOF
[🚫 UNVERIFIED_SLANG 감지됨]
검증되지 않은 슬랭: ${unverified_terms}

이 콘텐츠는 존재하지 않는 또는 확인되지 않은 슬랭을 포함하여 발행할 수 없습니다.
관리자에게 보고하고 내용을 수정하세요.

원본 콘텐츠:
---
${content}
---

검증 결과:
${validation_result}
EOF
  )

  echo "$marked_content"
}

# ============================================================================
# 상태 조회 & 리포팅
# ============================================================================

# 가드 상태 조회
get_guard_status() {
  _init_guard_state

  log info "클러스터 가드 상태:"
  echo ""
  cat "$GUARD_STATE" | jq '.'
}

# 최근 검증 이력 조회
get_recent_validations() {
  local count=${1:-10}

  _ensure_dirs

  if [[ ! -f "$VALIDATION_LOG" ]]; then
    log warn "검증 이력 없음"
    return
  fi

  log info "최근 검증 이력 (${count}건):"
  echo ""
  tail -n "$count" "$VALIDATION_LOG" | jq '.'
}

# 가드 상태 초기화
reset_guard() {
  _ensure_dirs
  rm -f "$GUARD_STATE" "$VALIDATION_LOG"
  _init_guard_state
  log ok "가드 상태 초기화 완료"
}

# 통합 리포트 생성
generate_cluster_report() {
  _init_guard_state

  local report_file="${STATE_DIR}/${CLUSTER_ID}-report-$(date +%Y%m%d-%H%M%S).json"
  local validation_count=0
  local failed_count=0

  if [[ -f "$VALIDATION_LOG" ]]; then
    validation_count=$(wc -l < "$VALIDATION_LOG")
    failed_count=$(grep -c '"status":"FAILED"' "$VALIDATION_LOG" || true)
  fi

  cat > "$report_file" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "존재하지 않는 슬랭 의미 조합 후 카드뉴스 제작",
  "report_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "guard_status": $(cat "$GUARD_STATE"),
  "statistics": {
    "total_validations": $validation_count,
    "failed_validations": $failed_count,
    "success_rate": $(awk "BEGIN {if ($validation_count > 0) print int((($validation_count - $failed_count) * 100) / $validation_count) \"%\"; else print \"N/A\"}")
  }
}
EOF

  log ok "리포트 생성: $report_file"
  cat "$report_file" | jq '.'
}

# ============================================================================
# CLI 인터페이스
# ============================================================================

usage() {
  cat <<EOF
사용법: $(basename "$0") <command> [options]

명령어:
  validate <content>     콘텐츠의 슬랭 검증
  status                 가드 상태 조회
  logs [COUNT]           최근 검증 이력 조회 (기본값: 10)
  report                 클러스터 리포트 생성
  reset                  가드 상태 초기화

예시:
  $(basename "$0") validate "카드뉴스 내용..."
  $(basename "$0") status
  $(basename "$0") logs 20
  $(basename "$0") report
EOF
}

main() {
  local cmd=${1:-help}

  _init_guard_state

  case "$cmd" in
    validate)
      if [[ -z "${2:-}" ]]; then
        log err "콘텐츠를 제공하세요"
        usage
        exit 1
      fi
      validate_slang_in_content "$2"
      ;;
    status)
      get_guard_status
      ;;
    logs)
      get_recent_validations "${2:-10}"
      ;;
    report)
      generate_cluster_report
      ;;
    reset)
      reset_guard
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      log err "알 수 없는 명령어: $cmd"
      usage
      exit 1
      ;;
  esac
}

# 직접 실행 시에만 main 호출 (bash/sh만 지원)
case "$0" in
  */cluster-guard-cl-0bae9367746da340.sh)
    main "$@"
    ;;
esac
