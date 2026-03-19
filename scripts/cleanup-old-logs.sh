#!/usr/bin/env bash
# cleanup-old-logs.sh — 오래된 로그 아카이브 및 정리
# Level1 자율 처리: infra-daily에서 디스크 >85% 또는 로그 >500MB 시 자동 호출
# 30일 이상 된 로그 gzip 압축, 60일 이상 된 압축 파일 삭제

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
LOG_DIR="$BOT_HOME/logs"

if [ ! -d "$LOG_DIR" ]; then
  echo "로그 디렉토리 없음: $LOG_DIR"
  exit 0
fi

before=$(du -sh "$LOG_DIR" | awk '{print $1}')

# 30일 이상 된 .log 파일 gzip 압축 (이미 압축된 것 제외)
find "$LOG_DIR" -name "*.log" -mtime +30 -exec gzip {} \;

# 60일 이상 된 .gz 파일 삭제
find "$LOG_DIR" -name "*.gz" -mtime +60 -delete

# 7일 이상 된 .jsonl 항목 정리 (파일 자체가 7일+ 이상인 경우)
find "$LOG_DIR" -name "*.jsonl" -mtime +7 -delete

after=$(du -sh "$LOG_DIR" | awk '{print $1}')

echo "정리 완료: $(date)"
echo "로그 크기: ${before} → ${after}"
