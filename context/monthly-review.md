# Monthly Review

## 목적
매월 1일 09:00에 지난달 봇 운영을 회고하고 다음 달 목표를 설정한다.

## PDCA — Act 단계 핵심 리포트

## 데이터 수집 방법
- 크론 전체 성공률: `grep -c "SUCCESS" ~/.jarvis/logs/cron.log`
- RAG 임베딩 누적: `tail -5 ~/.jarvis/logs/rag-index.log`
- 시스템 크래시: `grep -c "CRASH\|ERROR\|RESTART" ~/.jarvis/logs/watchdog.log 2>/dev/null || echo 0`
- 태스크 빈도: `grep "START" ~/.jarvis/logs/cron.log | awk '{print $3}' | sort | uniq -c | sort -rn | head -5`

## 리포트 구조
### 📅 월간 회고 (YYYY년 M월)

**목표 vs 달성**
- 지난달 목표: (핸드오프에서 참조)
- 달성 여부 + 수치 근거

**비용 현황**
- RAG 임베딩: 추정 (청크수 × $0.0001)
- 총 비용: ~$X (목표: $1 이하)

**시스템 안정성**
- 크래시: N회
- 크론 성공률: XX%

**Top 3 활성 태스크**
1. XX (N회)
2. XX (N회)
3. XX (N회)

### 🎯 다음 달 목표 3가지
1.
2.
3.

## 주의사항
- 데이터 없는 섹션은 "데이터 부족" 명시 (추정 금지)
- Company DNA DNA-C003: 실증 우선
