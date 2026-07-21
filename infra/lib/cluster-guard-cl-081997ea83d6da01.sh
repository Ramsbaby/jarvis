#!/bin/bash
# cluster-guard-cl-081997ea83d6da01.sh — 멱등성 가드 클러스터 관리 스크립트
#
# 역할:
#   1. 클러스터 cl-081997ea83d6da01 가드 초기화 및 상태 관리
#   2. 멱등성 체크 통합
#   3. 재실행 방지 모니터링
#   4. 메트릭 리포팅

set -euo pipefail

CLUSTER_ID="cl-081997ea83d6da01"
JARVIS_HOME="${HOME}/.jarvis"
LIB_DIR="${JARVIS_HOME}/lib"
STATE_DIR="${JARVIS_HOME}/runtime/state"
CLUSTER_GUARDS_DIR="${STATE_DIR}/cluster-guards"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
  local level=$1
  shift
  local msg="$*"
  case $level in
    info) echo -e "${BLUE}ℹ️ ${msg}${NC}" ;;
    success) echo -e "${GREEN}✅ ${msg}${NC}" ;;
    warn) echo -e "${YELLOW}⚠️  ${msg}${NC}" ;;
    error) echo -e "${RED}❌ ${msg}${NC}" ;;
  esac
}

# 클러스터 가드 초기화
init_cluster_guard() {
  log info "Initializing cluster guard for ${CLUSTER_ID}..."

  mkdir -p "${CLUSTER_GUARDS_DIR}"

  # mistake-cluster-guard.mjs로 초기화
  node "${LIB_DIR}/mistake-cluster-guard.mjs" init "${CLUSTER_ID}" > /dev/null 2>&1 || true

  log success "Cluster guard initialized"
}

# 가드 상태 조회
show_guard_status() {
  log info "Guard status for ${CLUSTER_ID}:"

  if [[ -f "${CLUSTER_GUARDS_DIR}/${CLUSTER_ID}.json" ]]; then
    echo ""
    cat "${CLUSTER_GUARDS_DIR}/${CLUSTER_ID}.json" | jq '.' 2>/dev/null || \
      cat "${CLUSTER_GUARDS_DIR}/${CLUSTER_ID}.json"
  else
    log warn "No guard state found. Run 'init' first."
  fi
}

# 멱등성 메트릭 조회
show_idempotency_metrics() {
  log info "Idempotency metrics (last 24h):"
  echo ""

  node "${LIB_DIR}/idempotency-guard.mjs" metrics 2>/dev/null | jq '.' || \
    log warn "No metrics available"
}

# 실행 로그 조회
show_execution_log() {
  local count=${1:-10}
  log info "Recent execution logs (last ${count}):"
  echo ""

  if [[ -f "${STATE_DIR}/execution-log.jsonl" ]]; then
    tail -n "${count}" "${STATE_DIR}/execution-log.jsonl" | jq '.'
  else
    log warn "No execution logs found"
  fi
}

# 재실행 감지 통계
show_reexecution_stats() {
  log info "Re-execution prevention statistics:"
  echo ""

  if [[ ! -f "${STATE_DIR}/idempotency-metrics.jsonl" ]]; then
    log warn "No metrics file found"
    return
  fi

  # 총 실행 횟수
  local total_execs=$(grep -c '"metric_type":"execution_recorded"' "${STATE_DIR}/idempotency-metrics.jsonl" || echo 0)

  # 중복 감지 횟수
  local dups_detected=$(grep -c '"duplicate_detected_on_rerun":true' "${STATE_DIR}/idempotency-metrics.jsonl" || echo 0)

  # 멱등성 테스트 통과
  local tests_passed=$(grep -c '"is_idempotent":true' "${STATE_DIR}/idempotency-metrics.jsonl" || echo 0)

  # 작업 유형별 분석
  local by_operation=$(grep '"metric_type":"execution_recorded"' "${STATE_DIR}/idempotency-metrics.jsonl" | \
    jq -r '.operation_type' | sort | uniq -c | awk '{print "  "$2": "$1}')

  cat <<EOF
Total executions: ${total_execs}
Duplicates detected (prevented): ${dups_detected}
Idempotency tests passed: ${tests_passed}
Prevention rate: $(awk "BEGIN {if (${total_execs} > 0) print int(${dups_detected}*100/${total_execs})\"%\" ; else print \"N/A\"}")

Executions by operation type:
${by_operation}
EOF
}

# 멱등성 테스트 실행
run_idempotency_test() {
  log info "Running idempotency test suite..."

  # 로그 초기화 (깨끗한 테스트를 위해)
  rm -f "${STATE_DIR}/execution-log.jsonl" "${STATE_DIR}/idempotency-metrics.jsonl"

  cd "${LIB_DIR}" && node idempotency-guard-test.mjs
}

# 상태 초기화
clear_logs() {
  log warn "Clearing execution logs and metrics..."
  rm -f "${STATE_DIR}/execution-log.jsonl" "${STATE_DIR}/idempotency-metrics.jsonl"
  log success "Logs cleared"
}

# 상태 리포트
generate_report() {
  log info "Generating cluster report for ${CLUSTER_ID}..."

  local report_file="${STATE_DIR}/cluster-report-${CLUSTER_ID}-$(date +%Y%m%d-%H%M%S).json"

  cat > "${report_file}" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "Idempotency Violation - Duplicate Side Effects on Re-execution",
  "report_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "guard_status": $(cat "${CLUSTER_GUARDS_DIR}/${CLUSTER_ID}.json" 2>/dev/null | jq -c '.'),
  "idempotency_metrics": $(node "${LIB_DIR}/idempotency-guard.mjs" metrics 2>/dev/null | jq -c '.')
}
EOF

  log success "Report generated: ${report_file}"
  cat "${report_file}" | jq '.'
}

# 사용법
usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  init              Initialize cluster guard for ${CLUSTER_ID}
  status            Show guard status
  metrics           Show idempotency metrics (last 24h)
  logs [COUNT]      Show execution logs (default: 10)
  stats             Show re-execution prevention statistics
  test              Run full idempotency test suite
  report            Generate cluster report
  clear             Clear execution logs and metrics
  help              Show this message

Examples:
  $(basename "$0") init
  $(basename "$0") status
  $(basename "$0") metrics
  $(basename "$0") stats
  $(basename "$0") test
  $(basename "$0") report
EOF
}

# 메인
main() {
  local cmd=${1:-help}

  case "$cmd" in
    init)
      init_cluster_guard
      ;;
    status)
      show_guard_status
      ;;
    metrics)
      show_idempotency_metrics
      ;;
    logs)
      show_execution_log "${2:-10}"
      ;;
    stats)
      show_reexecution_stats
      ;;
    test)
      run_idempotency_test
      ;;
    report)
      generate_report
      ;;
    clear)
      clear_logs
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      log error "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
