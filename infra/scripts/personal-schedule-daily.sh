#!/usr/bin/env bash
set -euo pipefail

# personal-schedule-daily.sh — Preply 수업 일정 조회 및 포맷팅

# 1단계: 수업 데이터 조회
TODAY=$(date +%F)
LESSONS_JSON=$(bash ~/jarvis/runtime/private/scripts/preply-today.sh "$TODAY")

# 2단계: 환율 조회
EXCHANGE_RATE=$(bash ~/jarvis/runtime/private/scripts/get-exchange-rate.sh)

# 3단계: Claude에 프롬프트 전달 (jq로 JSON 추출 및 포맷팅)
claude -p - << 'EOF' "$LESSONS_JSON" "$EXCHANGE_RATE"
다음 JSON 데이터를 보고 오늘(M/D 요일) Preply 수업 일정을 정리해서 보내줘.

JSON 데이터:
$1

환율(₩/$):
$2

출력 형식 (코드블록 없이 일반 텍스트):
오늘(M/D 요일) 수업 브리핑 📅✨
총 N개 수업 · 총 수입 $XXX.XX (~₩XXX,XXX) 💰

🕐 HH:MM · 학생이름 · $XX.XX (~₩XX,XXX)
🕐 HH:MM · 학생이름 · $XX.XX (~₩XX,XXX)
...

환율: ₩X,XXX/$

scheduledCount가 0이면: 오늘은 수업이 없어요! 😊

취소 처리(Preply 규칙: 12시간 이내 취소는 수업료를 그대로 받음):
cancelledCount > 0이면 취소 보상 금액을 별도 표시하고, 예정 수업 합계에 더해 '총 수입'을 낸다.
EOF
