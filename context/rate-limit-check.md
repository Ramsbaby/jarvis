# Rate Limit Check

## 목적
30분마다 Claude Max rate limit 사용량을 확인하고 80% 초과 시 경고한다.

## 지시사항
1. `~/.jarvis/state/rate-tracker.json` 읽기
2. 파일이 타임스탬프 배열 형식이거나 사용량 데이터 없으면: `Rate limit: 정상 (사용량 데이터 없음)` 출력
3. 사용량 객체가 있으면 `current / max * 100` 계산:
   - 80% 미만: `Rate limit: 정상 (XX%)`
   - 80~89%: `⚠️ Rate limit 경고: XX% — optional 태스크 스킵 권고`
   - 90% 이상: `🚨 Rate limit 위험: XX% — critical 태스크만 실행`

## 주의사항
- Read 도구만 사용 (파일 읽기만)
- 계산 불가 시 "정상"으로 처리 (오탐 방지)
