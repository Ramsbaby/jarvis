# Jarvis Human/AI 결정 경계 정책

> **버전**: 1.0.0 | **최초 작성**: 2026-03-14 | **SSoT**: 이 파일

AI가 자율적으로 결정할 수 있는 범위와 반드시 사람의 승인이 필요한 범위를 명문화합니다.

---

## 1. AI 자율 결정 영역 (승인 불필요)

### 1-1. 읽기 / 조회
- 파일 읽기, 로그 조회, 시스템 상태 확인
- RAG 인덱스 검색, Obsidian Vault 조회
- git log, git diff (읽기 전용)
- 외부 API 읽기 (날씨, 뉴스, 주가 조회 — 비용 없는 GET)

### 1-2. 로컬 상태 쓰기
- `~/.jarvis/state/` 파일 생성/수정 (context-bus.md, health.json 등)
- `~/.jarvis/context/` 컨텍스트 파일 갱신
- `~/.jarvis/logs/` 로그 기록
- RAG 인덱스 업데이트 (로컬 LanceDB)
- 캐시 파일 갱신 (`state/usage-cache.json` 등)

### 1-3. 크론 / 자동화
- 정해진 schedule의 크론 태스크 실행
- Discord bot 재시작 (watchdog 범위 내)
- LaunchAgent 재등록 (guardian 범위 내)

### 1-4. 인사이트 / 분석
- 팀 보고서 작성 (`teams/*/results/`)
- 인사이트 파일 갱신 (`state/insights.md`)
- 의사결정 감사 로그 (`state/decisions/*.jsonl`)

---

## 2. 사람 승인 필요 영역

### 2-1. 외부 전송 (HIGH)
| 행동 | 이유 |
|------|------|
| Discord 메시지 발송 | 공개 채널 — 되돌릴 수 없음 |
| ntfy 푸시 알림 | 폰 알림 — 방해 가능 |
| 이메일 발송 | 외부 수신자 존재 |
| GitHub Issue/PR 생성 | 공개 기록 |

> **예외**: 시스템 장애 alert, 헬스체크 실패 알림은 자율 발송 허용 (monitoring.json 임계값 초과 시)

### 2-2. 코드 / 설정 변경 (HIGH)
- `~/.jarvis/config/tasks.json` 수정 (크론 스케줄 변경)
- Discord bot 코드(`discord/`) 수정
- LaunchAgent plist 수정
- `.env` 파일 수정
- crontab 변경

### 2-3. 데이터 삭제 / 되돌리기 어려운 작업 (CRITICAL)
- 파일 삭제 (`rm`)
- git commit, git push
- Docker 이미지 빌드 / 배포
- DB 데이터 삭제 또는 재인덱싱

### 2-4. 금융 / 개인정보 (CRITICAL)
- 주식 매매 API 호출
- 개인정보 포함 파일 외부 전송
- API 키 / 토큰 변경 또는 재생성

### 2-5. 예산 초과 판단 (HIGH)
- `~/.jarvis/config/team-budget.json` 초과 예상 시
- 비용이 발생하는 외부 API 호출 (OpenAI, Google Maps 유료 등)

---

## 3. 에스컬레이션 절차

```
AI 판단 불가 상황 발생
        │
        ▼
1. Discord #jarvis 채널에 상황 보고 (alert.sh 사용)
2. state/escalation.md 에 내용 기록
3. 작업 중단 (partial commit 금지)
4. 사람 응답 대기
```

**에스컬레이션 트리거 조건**:
- 규칙 충돌: 두 정책이 상반된 행동을 요구
- 임계값 불명확: "중요한" 파일인지 판단 불가
- 비용 추정 불가: 외부 API 호출 비용 불명확
- 보안 우려: 자격증명 노출 가능성

---

## 4. 감사 로그

AI가 승인 영역의 행동을 취할 때는 반드시 기록:

```jsonl
{"ts":"2026-03-14T09:00:00Z","action":"discord_send","channel":"jarvis-dev","trigger":"system_alert","approved_by":"auto","rule":"monitoring_threshold"}
```

위치: `~/.jarvis/state/decisions/YYYY-MM-DD.jsonl`

---

## 5. 정책 갱신

이 문서는 분기별 검토. 변경 시 `company-dna.md`에 링크 업데이트 필요.

관련 문서:
- `~/.jarvis/config/monitoring.json` — 자동 발송 임계값
- `~/.jarvis/config/team-budget.json` — 팀별 예산 한도
- `~/.jarvis/adr/ADR-INDEX.md` — 아키텍처 결정 기록
