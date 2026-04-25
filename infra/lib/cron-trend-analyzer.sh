#!/usr/bin/env bash
# cron-trend-analyzer.sh — 크론 트렌드 분석 엔진
#
# 목적: 크론 태스크의 성공/실패 추세를 분석하고 장기 트렌드 제공
#
# 기능:
#   1. 단기 트렌드 (1시간): 최근 실행 패턴 분석
#   2. 일일 트렌드: 하루 단위 성공/실패 통계
#   3. 주간 트렌드: 7일간 추이 분석
#   4. 트렌드 지표: 성공률, 평균 실행시간, 실패 패턴
#
# 사용법:
#   cron-trend-analyzer.sh [daily|short_term|weekly] [task_name]

set -euo pipefail

# 설정
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LOG_DIR="${BOT_HOME}/logs"
CRON_LOG="${LOG_DIR}/cron.log"
STATE_DIR="${BOT_HOME}/state/trend-analysis"
REPORT_DIR="${BOT_HOME}/reports/trend-analysis"
ANALYSIS_FILE="${STATE_DIR}/bot-cron-trend-data.json"
TREND_TYPE="${1:-daily}"
TASK_FILTER="${2:-bot-cron}"

# 타임스탬프 함수
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# 로그 함수
log() {
  local level="$1"
  shift
  echo "[$(timestamp)] [trend-analyzer] [$level] $*" >&2
}

# 초기화
initialize() {
  mkdir -p "$STATE_DIR" "$REPORT_DIR"

  # 필수 파일 확인
  if [[ ! -f "$CRON_LOG" ]]; then
    log "WARN" "cron.log not found: $CRON_LOG"
    return 1
  fi
}

# 트렌드 분석 시작 메시지
log "INFO" "크론 트렌드 분석 시작 (타입: $TREND_TYPE)"

# 초기화
initialize

# 태스크별 트렌드 분석
analyze_task_trend() {
  local task_name="$1"
  local trend_type="$2"

  log "INFO" "태스크 '$task_name' 트렌드 분석 시작 ($trend_type)"

  # 시간 윈도우 설정
  local start_time
  case "$trend_type" in
    daily)
      start_time=$(date -u -v-1d '+%Y-%m-%d' 2>/dev/null || date -u -d '1 day ago' '+%Y-%m-%d' 2>/dev/null || date -u '+%Y-%m-%d')
      ;;
    short_term)
      start_time=$(date -u -v-1H '+%Y-%m-%d %H' 2>/dev/null || date -u -d '1 hour ago' '+%Y-%m-%d %H' 2>/dev/null || date -u '+%Y-%m-%d %H')
      ;;
    weekly)
      start_time=$(date -u -v-7d '+%Y-%m-%d' 2>/dev/null || date -u -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -u '+%Y-%m-%d')
      ;;
    *)
      start_time=$(date -u -v-1d '+%Y-%m-%d' 2>/dev/null || date -u -d '1 day ago' '+%Y-%m-%d' 2>/dev/null || date -u '+%Y-%m-%d')
      ;;
  esac

  log "INFO" "태스크 '$task_name' 트렌드 데이터 수집 중 (24시간 윈도우)"

  # 트렌드 데이터 수집
  local total=0
  local success=0
  local fail=0
  local total_duration=0
  local samples=0

  # 임시 파일로 데이터 수집
  local tmp_file="/tmp/trend-${task_name}-$$.tmp"
  trap "rm -f '$tmp_file'" EXIT

  # 로그에서 해당 태스크의 데이터 추출 (최근 1000줄)
  tail -1000 "$CRON_LOG" 2>/dev/null | grep "\[$task_name\]" > "$tmp_file" 2>/dev/null || true

  if [[ ! -s "$tmp_file" ]]; then
    log "WARN" "태스크 '$task_name' 트렌드 데이터 없음"
    return 1
  fi

  # 통계 계산
  while IFS= read -r line; do
    total=$((total + 1))

    if [[ "$line" =~ \[SUCCESS\] ]]; then
      success=$((success + 1))
    elif [[ "$line" =~ \[FAIL\]|\[ERROR\] ]]; then
      fail=$((fail + 1))
    fi

    # duration 추출 (있을 경우)
    if [[ "$line" =~ duration=([0-9]+) ]]; then
      total_duration=$((total_duration + ${BASH_REMATCH[1]}))
      samples=$((samples + 1))
    fi
  done < "$tmp_file"

  # 성공률 계산
  local success_rate=0
  if [[ $total -gt 0 ]]; then
    success_rate=$((success * 100 / total))
  fi

  # 평균 실행시간 계산
  local avg_duration=0
  if [[ $samples -gt 0 ]]; then
    avg_duration=$((total_duration / samples))
  fi

  log "INFO" "태스크 '$task_name' 트렌드 지표 계산"

  if [[ $total -eq 0 ]]; then
    log "WARN" "태스크 '$task_name' 트렌드 지표 계산 실패"
    return 1
  fi

  # 트렌드 데이터 저장
  local trend_entry
  trend_entry=$(printf '{"timestamp":"%s","task":"%s","type":"%s","total":%d,"success":%d,"fail":%d,"success_rate":%d,"avg_duration":%d}' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$task_name" "$trend_type" "$total" "$success" "$fail" "$success_rate" "$avg_duration")

  echo "$trend_entry" >> "$ANALYSIS_FILE"

  log "INFO" "태스크 '$task_name' 트렌드 분석 완료 (성공률: ${success_rate}%)"

  rm -f "$tmp_file"
}

# 트렌드 분석 실행
success_count=0
fail_count=0

if analyze_task_trend "$TASK_FILTER" "$TREND_TYPE"; then
  success_count=$((success_count + 1))
else
  fail_count=$((fail_count + 1))
fi

log "INFO" "트렌드 분석 완료: 성공 $success_count, 실패 $fail_count"

exit 0
