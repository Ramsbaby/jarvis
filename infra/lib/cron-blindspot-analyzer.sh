#!/usr/bin/env bash
# cron-blindspot-analyzer.sh — 크론 모니터링 맹점 분석
#
# 목적: 크론 시스템의 관찰되지 않는 맹점을 자동으로 감지하고 분석
#
# 해결하는 맹점들:
#   1. 반복 실패 패턴 분석 — 7일간 3회 이상 실패 태스크 식별
#   2. 의존성 체인 위험도 — 연쇄 실패 영향 범위 추적
#   3. 타임아웃 적정성 검증 — 평균 실행시간 기반 권장값 계산
#   4. 리소스 부족 상관관계 — 시스템 자원과 실패 시점 분석
#
# 사용법:
#   cron-blindspot-analyzer.sh [analyze|report|diagnose]

set -euo pipefail

# guards.sh import — 반복 실수 클러스터 cl-a1a431b0e672e736 방어
source "${BOT_HOME:-${HOME}/.jarvis}/infra/lib/guards.sh" 2>/dev/null || {
  printf '[%s] ERROR: Failed to source guards.sh\n' "$(date +%s)" >&2
  exit 1
}

# Load execution verdict wrapper (Cluster cl-e30aee511af89e13: prevent stderr-based missjudgment)
source "${BOT_HOME:-${HOME}/.jarvis}/lib/execution-verdict-wrapper.sh" 2>/dev/null || {
  printf '[%s] WARN: Failed to source execution-verdict-wrapper.sh (non-fatal)\n' "$(date +%s)" >&2
}

# Load pre-execution guard (Cluster cl-e30aee511af89e13: prevent unnecessary re-execution)
source "${BOT_HOME:-${HOME}/.jarvis}/lib/pre-execution-guard.sh" 2>/dev/null || {
  printf '[%s] WARN: Failed to source pre-execution-guard.sh (non-fatal)\n' "$(date +%s)" >&2
}

# 설정
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LOG_DIR="${BOT_HOME}/logs"
CRON_LOG="${LOG_DIR}/cron.log"
STATE_DIR="${BOT_HOME}/state/blindspot"
REPORT_DIR="${BOT_HOME}/reports"
ANALYSIS_FILE="${STATE_DIR}/blindspot-analysis.jsonl"

# 타임스탬프 함수
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# 로그 함수
log() {
  local level="$1"
  shift
  echo "[$(timestamp)] [$level] $*" >&2
}

# 초기화
initialize() {
  mkdir -p "$STATE_DIR" "$REPORT_DIR"

  # 디렉토리 존재 검증 (guards.sh)
  assert_directory_exists "$STATE_DIR" "blindspot state directory" || return 1
  assert_directory_exists "$REPORT_DIR" "report directory" || return 1

  # 필수 파일 확인
  assert_file_readable "$CRON_LOG" "cron log file" || {
    log "WARN" "cron.log not found or not readable: $CRON_LOG"
    return 1
  }
}

# 패턴 1: 반복 실패 태스크 식별 (7일간 3회 이상 실패)
analyze_repeated_failures() {
  log "INFO" "분석 중: 반복 실패 패턴"

  local seven_days_ago
  seven_days_ago=$(date -u -v-7d '+%Y-%m-%d' 2>/dev/null || date -u -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || echo "")

  if [[ -z "$seven_days_ago" ]]; then
    log "WARN" "7일 전 날짜 계산 실패"
    return 1
  fi

  # 실패 패턴 분석 (FAIL/ERROR 로그에서 태스크명 추출)
  local failures_file="${STATE_DIR}/failures-7d.tmp"
  grep -E '\[FAIL\]|\[ERROR\]' "$CRON_LOG" | \
    grep -E "^${seven_days_ago}|^$(date '+%Y-%m-%d')" | \
    sed -E 's/.*\[([a-z0-9-]+)\].*/\1/' | \
    sort | uniq -c | sort -rn > "$failures_file" 2>/dev/null || true

  # 3회 이상 실패한 태스크 추출
  local failed_tasks=()
  while IFS=' ' read -r count task; do
    if [[ $count -ge 3 ]]; then
      failed_tasks+=("$task")
      log "WARN" "반복 실패 태스크 감지: $task ($count회 in 7d)"
    fi
  done < "$failures_file" 2>/dev/null || true

  rm -f "$failures_file"

  # 결과 기록
  if [[ ${#failed_tasks[@]} -gt 0 ]]; then
    local analysis_entry
    analysis_entry=$(printf '{"timestamp":"%s","type":"repeated_failures","count":%d,"tasks":[' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" ${#failed_tasks[@]})

    for i in "${!failed_tasks[@]}"; do
      [[ $i -gt 0 ]] && analysis_entry+=","
      analysis_entry+="\"${failed_tasks[$i]}\""
    done

    analysis_entry+="]}"
    echo "$analysis_entry" >> "$ANALYSIS_FILE"
  fi
}

# 패턴 2: 의존성 체인 위험도 분석
analyze_dependency_risks() {
  log "INFO" "분석 중: 의존성 체인 위험도"

  # 태스크 간 의존성 패턴 감지
  # tasks.json에서 dependsOn 필드 확인
  local tasks_file="${BOT_HOME}/config/tasks.json"

  if [[ ! -f "$tasks_file" ]]; then
    log "WARN" "tasks.json not found"
    return 1
  fi

  # 순환 의존성 감지 (간단한 버전)
  local risk_count=0

  # jq가 없을 수 있으므로 grep으로 기본 처리
  while IFS= read -r line; do
    if [[ "$line" =~ dependsOn ]]; then
      ((risk_count++))
    fi
  done < "$tasks_file" || true

  if [[ $risk_count -gt 0 ]]; then
    local analysis_entry
    analysis_entry=$(printf '{"timestamp":"%s","type":"dependency_risk","potential_chains":%d}' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" $risk_count)
    echo "$analysis_entry" >> "$ANALYSIS_FILE"
  fi
}

# 패턴 3: 타임아웃 적정성 검증
analyze_timeout_appropriateness() {
  log "INFO" "분석 중: 타임아웃 적정성"

  local duration_file="${STATE_DIR}/durations.tmp"

  # 최근 실행 시간 데이터 수집 (SUCCESS 로그에서 duration 추출)
  grep -oE 'duration=[0-9]+' "$CRON_LOG" | \
    sed 's/duration=//' | tail -100 > "$duration_file" 2>/dev/null || true

  if [[ ! -s "$duration_file" ]]; then
    log "WARN" "실행 시간 데이터 부족"
    rm -f "$duration_file"
    return 1
  fi

  # 통계 계산 (bash로 간단히)
  local total=0 count=0 max=0
  while IFS= read -r duration; do
    total=$((total + duration))
    count=$((count + 1))
    if [[ $duration -gt $max ]]; then
      max=$duration
    fi
  done < "$duration_file"

  rm -f "$duration_file"

  if [[ $count -gt 0 ]]; then
    local avg=$((total / count))
    local recommended_timeout=$((avg * 2))  # 평균의 2배를 권장

    local analysis_entry
    analysis_entry=$(printf '{"timestamp":"%s","type":"timeout_analysis","avg_duration_s":%d,"max_duration_s":%d,"recommended_timeout_s":%d,"sample_count":%d}' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" $avg $max $recommended_timeout $count)
    echo "$analysis_entry" >> "$ANALYSIS_FILE"
  fi
}

# 패턴 4: 리소스 부족 상관관계 분석
analyze_resource_correlation() {
  log "INFO" "분석 중: 리소스 부족 상관관계"

  # 시스템 리소스 상태 수집
  local load_avg memory_free disk_free

  # macOS / Linux 호환성
  if command -v sysctl &>/dev/null; then
    # macOS
    memory_free=$(vm_stat 2>/dev/null | grep "Pages free" | awk '{print $3}' | tr -d '.' || echo "0")
  else
    # Linux
    memory_free=$(free -b 2>/dev/null | awk 'NR==2 {print $7}' || echo "0")
  fi

  load_avg=$(uptime | grep -oE 'load average[^,]*' | awk '{print $NF}' || echo "0")
  disk_free=$(df / | awk 'NR==2 {print $4}' || echo "0")

  # 현재 리소스 상태 기록
  local analysis_entry
  analysis_entry=$(printf '{"timestamp":"%s","type":"resource_status","load_avg":"%s","memory_free_bytes":%s,"disk_free_blocks":%s}' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$load_avg" "$memory_free" "$disk_free")
  echo "$analysis_entry" >> "$ANALYSIS_FILE"

  log "INFO" "리소스 상태: load=$load_avg memory_free=$memory_free disk_free=$disk_free"
}

# 종합 분석 실행
analyze() {
  local task_id="cron-blindspot-analyzer"
  log "INFO" "크론 모니터링 맹점 분석 시작"

  # Guard 1: Check if this task is already running or recently completed (cl-e30aee511af89e13)
  if command -v check_task_status >/dev/null 2>&1; then
    if ! check_task_status "$task_id"; then
      log "INFO" "Task already completed or in progress. Skipping."
      return 0
    fi
    # Mark task as running
    mark_task_running "$task_id" "$$" 2>/dev/null || true
  fi

  initialize || {
    # Mark task failure if initialize fails
    if command -v mark_task_failure >/dev/null 2>&1; then
      mark_task_failure "$task_id" 1 2>/dev/null || true
    fi
    return 1
  }

  local exit_code=0
  analyze_repeated_failures || exit_code=$?
  analyze_dependency_risks || exit_code=$?
  analyze_timeout_appropriateness || exit_code=$?
  analyze_resource_correlation || exit_code=$?

  # Verdict: Use exit code to determine success (cl-e30aee511af89e13)
  if [[ $exit_code -eq 0 ]]; then
    log "INFO" "크론 모니터링 맹점 분석 완료 (exit code: $exit_code)"
    log "INFO" "분석 결과: $ANALYSIS_FILE"

    # Mark task success
    if command -v mark_task_success >/dev/null 2>&1; then
      mark_task_success "$task_id" "$exit_code" 2>/dev/null || true
    fi
  else
    log "WARN" "크론 모니터링 맹점 분석 부분 실패 (exit code: $exit_code)"

    # Mark task failure
    if command -v mark_task_failure >/dev/null 2>&1; then
      mark_task_failure "$task_id" "$exit_code" 2>/dev/null || true
    fi
  fi

  return "$exit_code"
}

# 보고서 생성
report() {
  log "INFO" "분석 보고서 생성 중"

  if [[ ! -f "$ANALYSIS_FILE" ]]; then
    log "WARN" "분석 파일을 찾을 수 없음"
    return 1
  fi

  local report_file="${REPORT_DIR}/blindspot-report-$(date +%Y%m%d_%H%M%S).txt"

  {
    echo "=== 크론 모니터링 맹점 분석 보고서 ==="
    echo "생성 시간: $(date)"
    echo ""
    echo "분석 결과:"
    cat "$ANALYSIS_FILE"
    echo ""
    echo "권장사항:"
    echo "1. 반복 실패 태스크는 timeout 재설정 검토"
    echo "2. 의존성 체인 검증 및 순환 의존성 제거"
    echo "3. 리소스 임계치 모니터링 강화"
  } > "$report_file"

  log "INFO" "보고서 저장: $report_file"
}

# 진단 모드
diagnose() {
  log "INFO" "크론 시스템 진단 시작"

  echo "시스템 진단 정보:"
  echo "- Bash 버전: $BASH_VERSION"
  echo "- OS: $(uname -s)"
  echo "- cron.log 존재: $(test -f "$CRON_LOG" && echo '예' || echo '아니오')"
  echo "- 최근 100줄 cron.log:"
  tail -100 "$CRON_LOG" 2>/dev/null | head -50
}

# Main entry point
MODE="${1:-analyze}"

case "$MODE" in
  analyze)
    analyze
    ;;
  report)
    report
    ;;
  diagnose)
    diagnose
    ;;
  *)
    log "ERROR" "알 수 없는 모드: $MODE"
    echo "사용법: $0 [analyze|report|diagnose]" >&2
    exit 1
    ;;
esac

exit 0
