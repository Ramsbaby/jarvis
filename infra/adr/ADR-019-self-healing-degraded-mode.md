# ADR-019: Self-healing Degraded Mode (L3-L4)

## 상태
ACCEPTED (2026-03-31)

## 컨텍스트
현재 자가치유: L1(재시도) + L2(대체경로) = watchdog/guardian 구조.
Task #16-17에서 L3(기능저하) + L4(에스컬레이션) 추가 예정.

## 결정
### L3 Degraded Mode
- 트리거: Discord bot 연속 3회 재시작 실패
- 동작: 핵심 알림 기능만 유지 (ntfy direct push), 고급 기능 일시 중단
- 스크립트: ~/.jarvis/scripts/bot-degraded-mode.sh
- 복구: 5분 간격 health check → 정상 시 자동 복구

### L4 에스컬레이션
- 트리거: L3 진입 후 30분 경과 또는 디스크 90% 이상
- 동작: Discord + ntfy 즉시 알림 (쿨다운 30분)
- 원인 분류: NETWORK / PROCESS / DISK / API_LIMIT / UNKNOWN
- 자동 해소: 원인 해결 감지 시 L4 해제 알림

## 구현 계획
1. bot-watchdog.sh에 연속 실패 카운터 추가
2. bot-degraded-mode.sh 신설
3. alert.sh에 L4 에스컬레이션 로직 추가
4. launchd-guardian.sh에 L3/L4 상태 감지 연동
