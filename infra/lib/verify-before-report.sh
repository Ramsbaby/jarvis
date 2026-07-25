#!/bin/bash
# verify-before-report.sh — 상태 보고 전 검증 가드
#
# 역할: 거짓 상태 보고를 방지하기 위해 실제 파일·출력·완료 여부를 검증
#
# 특징:
#   1. 선언된 규칙 실행 여부를 audit log에서 확인
#   2. 파일·경로의 실제 존재 여부 검증
#   3. 규칙 위반 사건이 있으면 보고 차단
#   4. verify-passed 플래그 없으면 report 실행 불가
#
# 사용:
#   verify-before-report.sh --check <cluster-id> <status-msg>
#   verify-before-report.sh --clear-flag
#   verify-before-report.sh --status

set -euo pipefail

CLUSTER_ID="${CLUSTER_ID:-cl-5f04f13d1c3d759d}"
STATE_DIR="${HOME}/jarvis/runtime/state"
VERIFY_FLAG="${STATE_DIR}/.verify-passed-${CLUSTER_ID}"
AUDIT_LOG="${STATE_DIR}/rule-execution-audit.jsonl"
VIOLATIONS_LOG="${STATE_DIR}/rule-violations.jsonl"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# 함수들
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_success() {
  echo -e "${GREEN}[OK]${NC} $1"
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

# 규칙 실행 여부 확인 (audit log에서)
check_rule_execution() {
  local rule_id="$1"

  if [[ ! -f "$AUDIT_LOG" ]]; then
    log_warning "규칙 1: Audit log 없음 (초기 실행 상태)"
    return 1
  fi

  # 최근 규칙 실행 여부 확인
  local last_status=$(tail -20 "$AUDIT_LOG" | \
    grep "\"rule_id\":\"$rule_id\"" | \
    tail -1 | \
    grep -o '"status":"[^"]*"' | \
    cut -d'"' -f4)

  if [[ -z "$last_status" ]]; then
    log_warning "규칙 '${rule_id}' 실행 기록 없음"
    return 1
  fi

  if [[ "$last_status" == "pass" ]]; then
    log_success "규칙 '${rule_id}' 검증 완료 (status=$last_status)"
    return 0
  elif [[ "$last_status" == "fail" ]]; then
    log_error "규칙 '${rule_id}' 실패 (status=$last_status)"
    return 1
  else
    log_warning "규칙 '${rule_id}' 상태: $last_status"
    return 0
  fi
}

# 파일 존재 여부 검증
verify_file_existence() {
  local file_path="$1"
  local description="$2"

  if [[ -z "$file_path" ]]; then
    log_warning "검증: 파일 경로 비어있음"
    return 0
  fi

  if [[ -f "$file_path" ]]; then
    log_success "파일 검증: $description 존재 ($file_path)"
    return 0
  else
    log_error "파일 검증: $description 미존재 ($file_path)"
    return 1
  fi
}

# 규칙 위반 사건 확인
check_violations() {
  if [[ ! -f "$VIOLATIONS_LOG" ]]; then
    log_success "규칙 위반: 없음"
    return 0
  fi

  # 최근 1시간 내 위반 사건 확인
  local one_hour_ago=$(date -u -d '1 hour ago' +'%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-1H +'%Y-%m-%dT%H:%M:%S')
  local recent_violations=$(grep -c "\"cluster\":\"$CLUSTER_ID\"" "$VIOLATIONS_LOG" 2>/dev/null || echo 0)

  if [[ $recent_violations -gt 0 ]]; then
    log_error "규칙 위반: 최근 $recent_violations건 감지됨"
    return 1
  else
    log_success "규칙 위반: 없음"
    return 0
  fi
}

# 상태 보고 전 전체 검증
verify_before_report() {
  local cluster_id="$1"
  local status_msg="$2"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 상태 보고 전 검증 시작"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  mkdir -p "$STATE_DIR"

  local all_pass=true

  # 검증 1: 규칙 실행 여부
  echo "🔍 [검증 1/3] 규칙 실행 여부 확인..."
  local rules=("bilingual-grammar-tables" "html-upload-path" "synchronization-complete")
  local passed_rules=0

  for rule in "${rules[@]}"; do
    if check_rule_execution "$rule"; then
      ((passed_rules++))
    fi
  done

  if [[ $passed_rules -lt 2 ]]; then
    log_warning "규칙: 최소 2개 이상 통과 필요 ($passed_rules/3 통과)"
    all_pass=false
  else
    log_success "규칙: 충분한 규칙 검증 완료 ($passed_rules/3)"
  fi

  echo ""

  # 검증 2: 규칙 위반 확인
  echo "🔍 [검증 2/3] 규칙 위반 사건 확인..."
  if ! check_violations; then
    all_pass=false
  fi

  echo ""

  # 검증 3: 상태 메시지 일관성
  echo "🔍 [검증 3/3] 상태 메시지 일관성 확인..."
  if [[ -z "$status_msg" ]]; then
    log_error "상태 메시지 비어있음"
    all_pass=false
  else
    # 상태 메시지에 구체적인 수치나 완료 명시가 있는지 확인
    if [[ "$status_msg" =~ ([0-9]+/[0-9]+|완료|PASS|✅) ]]; then
      log_success "상태 메시지 형식 검증: OK"
    else
      log_warning "상태 메시지에 구체적인 완료 지표 부재 (권장: N/M 형식 또는 '완료' 명시)"
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ "$all_pass" == true ]]; then
    log_success "✅ 모든 검증 통과 — 상태 보고 가능"
    echo "⏱️  verify-passed 플래그 생성 (유효시간: 30분)"
    echo "$cluster_id:$(date +%s)" > "$VERIFY_FLAG"
    chmod 600 "$VERIFY_FLAG"
    return 0
  else
    log_error "❌ 검증 실패 — 상태 보고 차단"
    return 1
  fi
}

# verify-passed 플래그 확인
check_verify_flag() {
  if [[ ! -f "$VERIFY_FLAG" ]]; then
    log_error "verify-passed 플래그 없음"
    return 1
  fi

  local flag_time=$(cut -d: -f2 "$VERIFY_FLAG")
  local current_time=$(date +%s)
  local age=$((current_time - flag_time))

  if [[ $age -gt 1800 ]]; then # 30분
    log_warning "verify-passed 플래그 만료 (생성 후 $(( age / 60 ))분)"
    rm -f "$VERIFY_FLAG"
    return 1
  fi

  log_success "verify-passed 플래그 유효 (남은 시간: $(( (1800 - age) / 60 ))분)"
  return 0
}

# 상태 출력
print_status() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📊 검증 상태"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "클러스터: $CLUSTER_ID"
  echo "Audit Log: $AUDIT_LOG"
  echo "Violations Log: $VIOLATIONS_LOG"
  echo "Verify Flag: $VERIFY_FLAG"

  if [[ -f "$VERIFY_FLAG" ]]; then
    local flag_time=$(cut -d: -f2 "$VERIFY_FLAG")
    local current_time=$(date +%s)
    local age=$((current_time - flag_time))
    echo ""
    echo "✅ verify-passed 플래그 상태:"
    echo "   생성 시간: $(date -d @$flag_time +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
    echo "   경과 시간: $(( age / 60 ))분"
    echo "   상태: $([ $age -lt 1800 ] && echo 'VALID (유효)' || echo 'EXPIRED (만료)')"
  else
    echo ""
    echo "❌ verify-passed 플래그: 없음"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 플래그 초기화
clear_flag() {
  if [[ -f "$VERIFY_FLAG" ]]; then
    rm -f "$VERIFY_FLAG"
    log_success "verify-passed 플래그 삭제됨"
  else
    log_warning "verify-passed 플래그 없음"
  fi
}

# 메인
main() {
  local cmd="${1:-}"

  case "$cmd" in
    --check)
      local cluster_id="${2:-$CLUSTER_ID}"
      local status_msg="${3:-}"
      CLUSTER_ID="$cluster_id"
      verify_before_report "$cluster_id" "$status_msg"
      ;;

    --can-report)
      if check_verify_flag; then
        exit 0
      else
        exit 1
      fi
      ;;

    --clear-flag)
      clear_flag
      ;;

    --status)
      print_status
      ;;

    *)
      echo "Usage:"
      echo "  verify-before-report.sh --check <cluster-id> <status-msg>"
      echo "  verify-before-report.sh --can-report"
      echo "  verify-before-report.sh --clear-flag"
      echo "  verify-before-report.sh --status"
      ;;
  esac
}

main "$@"
