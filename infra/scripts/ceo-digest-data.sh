#!/bin/bash
# ceo-daily-digest 용 데이터 수집 최적화 스크립트
# 모든 쿼리를 배치로 실행해서 API 호출 최소화

set -uo pipefail

TODAY=$(date +%Y-%m-%d)

# Step 1: 크론 성공/실패
CRON_SUCCESS=$(grep "$TODAY" ~/.jarvis/logs/cron.log 2>/dev/null | grep -cE "SUCCESS|DONE" || echo "0")
CRON_FAIL=$(grep "$TODAY" ~/.jarvis/logs/cron.log 2>/dev/null | grep -cE "FAIL|ERROR" || echo "0")

# Step 2: 시스템 상태
HEALTH_UPDATE=$(cat ~/.jarvis/state/health.json 2>/dev/null | node -e "const d=require('fs').readFileSync(0,'utf8'); try{const j=JSON.parse(d); console.log(j.updated_at+' | '+j.disk_usage_pct+'%')}catch{console.log('N/A')}" 2>/dev/null | tr -d '\n' || echo "N/A")

# Step 3: Discord 활동 (wc -l 의 추가 공백 제거)
DISCORD_COUNT=$(grep "$TODAY" ~/.jarvis/logs/discord-bot.jsonl 2>/dev/null | wc -l | xargs || echo "0")

# Step 4+6: DB 요약 (간단 버전)
DB_SUMMARY=$(node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs fsm-summary 2>/dev/null | head -5 | tr '\n' ' ' || echo "N/A")

# Step 5: 주요 에러 (최상단 1개만)
TOP_ERRORS=$(grep "$TODAY" ~/.jarvis/logs/cron.log 2>/dev/null | grep -E "FAIL|ERROR" | sed 's/.*\[\(.*\)\].*/\1/' | sort | uniq -c | sort -rn | head -1 | awk '{printf "%s (%s건)", $2, $1}' || echo "없음")

# 간단한 텍스트 출력으로 변경 (JSON 파싱 에러 회피)
cat << 'EOF'
=== CEO DIGEST DATA ===
EOF
echo "Date: $TODAY"
echo "Cron: Success=$CRON_SUCCESS, Fail=$CRON_FAIL"
echo "System: $HEALTH_UPDATE"
echo "Discord: $DISCORD_COUNT"
echo "DB: $DB_SUMMARY"
echo "TopError: $TOP_ERRORS"
echo "=== END DATA ==="
