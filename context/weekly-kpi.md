# Weekly KPI Report

## 목적
매주 월요일 08:30에 지난 한 주간 봇 시스템 운영 KPI를 집계하고 Discord에 전송한다.

## PDCA — Plan 단계 핵심 리포트
이 리포트를 읽고 이번 주 목표를 설정한다.

## 데이터 수집 방법
- 크론 성공/실패: `grep -E "SUCCESS|FAILED" ~/.jarvis/logs/cron.log | tail -500`
- RAG 통계: `tail -1 ~/.jarvis/logs/rag-index.log`
- Discord 응답 건수: `wc -l < ~/.jarvis/logs/discord-bot.jsonl`
- 에러 빈도: `grep "ERROR\|FAILED" ~/.jarvis/logs/cron.log | wc -l`

## 리포트 구조
### 📊 이번 주 KPI

| 지표 | 목표 | 실제 | 상태 |
|------|------|------|------|
| 크론 성공률 | 90%+ | XX% | ✅/⚠️ |
| RAG 청크 수 | 증가 | XXXX | ✅/⚠️ |
| Discord 응답 | - | XX건 | - |

### ⚠️ 주요 실패 태스크
(실패 태스크 ID + 빈도)

### 💡 개선 제안
(최대 2개, 실행 가능한 것 우선)

## 주의사항
- 1800자 이내 Discord 전송
- 수치 없는 칭찬 금지 — 데이터로만 말하기
- Company DNA DNA-C004: 크론 성공률 90% 미달 시 반드시 원인 명시
