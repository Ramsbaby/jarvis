#!/usr/bin/env bash
# weekly-roi.sh — 주간 ROI 집계 스크립트
# 매주 일요일 23:55에 실행되어 지난주 태스크들의 ROI를 집계

set -euo pipefail

WEEK=$(date +%Y-W%V)
ROI_DIR="$HOME/jarvis/runtime/rag/roi-reports"
LOG_FILE="$HOME/jarvis/runtime/logs/weekly-roi.log"
AGGREGATOR="$HOME/jarvis/runtime/scripts/weekly-roi-aggregator.mjs"

# 디렉토리 생성
mkdir -p "$ROI_DIR"

# 로그 헤더
{
  echo "$(date '+%Y-%m-%d %H:%M:%S') — weekly-roi.sh 시작 (Week: $WEEK)"
} >> "$LOG_FILE"

# aggregator.mjs 실행
if [[ ! -f "$AGGREGATOR" ]]; then
  echo "ERROR: $AGGREGATOR 파일을 찾을 수 없음" >> "$LOG_FILE"
  exit 1
fi

if ! node "$AGGREGATOR" "$WEEK" >> "$LOG_FILE" 2>&1; then
  echo "ERROR: aggregator 실행 실패" >> "$LOG_FILE"
  exit 1
fi

# 리포트 생성 확인
REPORT="$ROI_DIR/roi-report-$WEEK.md"
if [[ -f "$REPORT" ]]; then
  echo "SUCCESS: ROI 리포트 생성 완료 ($REPORT)" >> "$LOG_FILE"
  cat "$REPORT"
else
  echo "ERROR: ROI 리포트 생성 실패" >> "$LOG_FILE"
  exit 1
fi