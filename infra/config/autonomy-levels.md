# 자율처리 레벨 (Autonomy Levels)

> 4단계 자율처리 체계. 작업 전 반드시 레벨 확인.
> SSoT: 이 파일. company-dna.md와 함께 봇 거버넌스의 핵심.

## 레벨 정의

| 레벨 | 이름 | 설명 | 승인 필요 | 예시 |
|------|------|------|----------|------|
| **L1** | 자동 실행 | 로그만 남김, 보고 없음 | ❌ 불필요 | 로그 정리, 디스크 체크, RAG 인덱싱, rate-limit-check |
| **L2** | 보고 실행 | 자동 실행 + Discord 결과 보고 | ❌ 불필요 | 모닝 브리핑, 뉴스, 시세 모니터링, 주간 KPI |
| **L3** | 확인 실행 | 실행 전 Discord에서 확인 요청 | ✅ 오너 확인 | 파일 삭제, 설정 변경, 크론 수정, 서비스 재시작 |
| **L4** | 명령 실행 | 실행 불가. 오너 직접 명령 필요 | ✅ 오너 명령 | 토큰 갱신, 배포, GitHub push, 외부 서비스 계정 변경 |

## 태스크별 레벨 분류

### L1 (자동, 무보고)
- `rate-limit-check` — 파일 읽기만
- `disk-alert` — 이상 없으면 출력 없음
- `system-health` — 정상이면 로그만
- `memory-cleanup` — 7일 초과 파일 자동 삭제
- `rag-index` (크론) — 변경 파일 인덱싱

### L2 (자동, Discord 보고)
- `morning-standup` — 매일 08:05
- `news-briefing` — 매일 07:50
- `stock-monitor` (예시) — 평일 장중 주기적 실행
- `market-alert` (예시) — 급변 시 L3 에스컬레이션
- `daily-summary` — 매일 20:00
- `weekly-report` — 매주 일요일 20:05
- `weekly-kpi` — 매주 월요일 08:30
- `monthly-review` — 매월 1일 09:00
- `github-monitor` — 매시간

### L3 (Discord 확인 후 실행)
- 설정 파일 수정 (tasks.json, company-dna.md 등)
- 크론 스케줄 변경
- 서비스 재시작 (launchctl kickstart)
- `token-sync` — Claude Max 토큰 갱신

### L4 (명령 대기)
- GitHub push / PR 생성
- 외부 API 키 변경
- 배포 (launchd plist 교체)
- 시스템 구조 변경

## Discord Bot 적용 규칙

1. 사용자가 L3/L4 작업을 요청하면 → 먼저 확인 메시지 전송
2. 손절선 하회 (DNA-C001) → 레벨 무관 즉시 CRITICAL 알림
3. 23:00~08:00 (DNA-C002) → L2 결과는 새벽 무음, L1은 계속 실행

## 에스컬레이션 규칙

- L1 3회 연속 실패 → L2로 에스컬레이션 (Discord 보고)
- L2 실패 → Discord 에러 메시지
- L3 확인 30분 무응답 → 작업 취소 + Discord 재알림
