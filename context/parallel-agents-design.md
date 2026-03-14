# 병렬 멀티에이전트 팀 실행 설계

_작성: 2026-03-14_

## 현황 분석

### company-agent.mjs 실행 구조
- 각 `company-agent.mjs --team X` 호출은 **독립적인 Node.js 프로세스**
- 프로세스 내부에서 `query()` (SDK)를 한 번 호출 → 단일 Claude 세션
- `runTeam()` 함수가 직렬(sequential) 실행: 한 팀 완료 후 다음 팀 시작
- `dispatchEvent()` 내 이벤트→팀 라우팅도 `for...of` 직렬 루프

### board-meeting.sh 실행 구조
- `llm_gateway.sh`의 `llm_call`을 통해 **단일 CEO 에이전트** 실행
- company-agent.mjs를 직접 호출하지 않음 (board-meeting은 별도 CLI 기반)
- 팀들은 각자의 cron 스케줄로 독립 실행됨

### 병렬화 가능성 분석

**프로세스 간 의존성 검토:**
- `council` 팀: context-bus.md를 **쓴다** (다른 팀이 읽음) → 선행 실행 필요
- `infra`, `brand`, `career`, `record`, `trend`, `academy`: context-bus.md를 **읽는다** → council 후 실행
- `standup`: 여러 팀 보고서를 집계 → 모든 팀 완료 후 실행

**결론**: `council → [infra, brand, career, record, trend, academy] 병렬 → standup` 순서가 최적

### SDK `query()` 동시 실행 가능성
- `@anthropic-ai/claude-agent-sdk`의 `query()`는 내부적으로 `claude` 바이너리를 subprocess로 실행
- 동일 프로세스 내 여러 `query()` 동시 실행 시 `CLAUDECODE` env var 충돌 위험 있음
- **안전한 방법**: 별도 프로세스(`company-agent.mjs`)를 병렬로 spawn

---

## 구현 방안: parallel-teams.sh

### 핵심 패턴
```bash
# 독립 팀들을 백그라운드 실행 후 모두 wait
node company-agent.mjs --team infra &
node company-agent.mjs --team brand &
wait  # 모든 백그라운드 작업 완료 대기
```

### 실행 순서 (의존성 기반)
```
Phase 1: council (context-bus.md 생성)
Phase 2: [infra, brand, career, record, trend, academy] 병렬
Phase 3: standup (전체 집계)
```

### 예상 시간 절약
- 직렬(현재): 6팀 × ~3분 = ~18분
- 병렬(신규): Phase1(3분) + Phase2(3분 병렬) + Phase3(3분) = ~9분
- 약 50% 단축

---

## 파일 경로
- 스크립트: `/Users/ramsbaby/.jarvis/bin/parallel-teams.sh`
- 로그: `/Users/ramsbaby/.jarvis/logs/parallel-teams.log`
- company-agent: `/Users/ramsbaby/.jarvis/discord/lib/company-agent.mjs`

---

## 주의사항

1. **LanceDB 동시 쓰기**: 여러 팀이 동시에 RAG 인덱싱 시 rag-engine.mjs의 cross-process lock이 보호함 (mkdir-based lock 이미 구현됨)
2. **Discord 웹훅 레이트 리밋**: 병렬로 여러 팀이 동시에 Discord 전송 시 429 가능 → 각 팀 내 500ms 지연이 이미 있음
3. **Claude Max 동시 세션**: 병렬 6개 Claude 세션은 Claude Max 정책상 문제없음 (rate limit 720/5h 기준 6회 추가)
4. **context-bus.md 읽기 타이밍**: Phase 2 팀들이 Phase 1(council) 완료 전에 시작하면 이전 context-bus 읽음 → `wait` 기반 phase 구분으로 해결
