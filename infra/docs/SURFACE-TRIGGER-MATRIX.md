# Surface Trigger Matrix — 스킬 자동 트리거 표면별 지원 현황

> **정의**: Jarvis 스킬을 **자연어 발화만으로** 자동 실행하는 기능의 표면별 지원 매트릭스.
> Jarvis 단일 뇌 철학 — 뇌(위키·RAG·learned-mistakes)는 단일, 표면(Claude Code CLI / Discord / macOS 앱)은 다중.
>
> **SSoT**: 본 문서. 트리거 변경 시 `~/jarvis/infra/discord/lib/skill-trigger.js` 와 `~/.claude/hooks/sensor-skill-trigger.sh` 양쪽에 반영 후 본 매트릭스 갱신.

## 표면별 아키텍처

| 표면 | 트리거 엔진 | 호출 경로 | 응답 컨텍스트 |
|------|-------------|-----------|--------------|
| Claude Code CLI | `~/.claude/hooks/sensor-skill-trigger.sh` (UserPromptSubmit hook) | system-reminder 주입 → BLOCKING REQUIREMENT → Skill tool invoke | Bash/Read/Write/Grep 전체 도구 사용 가능 |
| Discord 봇 | `infra/discord/lib/skill-trigger.js` (정규식 매칭) | `handlers.js:497` → `skill-runner.js` → Claude SDK query (allowedTools=[]) | **텍스트 응답만** (tool 사용 불가) |
| Claude macOS 앱 | ❌ 미지원 | — | — |

## 스킬별 표면 매트릭스

| 스킬 | CLI 트리거 | Discord 트리거 | Discord 적합성 | 비고 |
|------|:---------:|:-------------:|:-------------|------|
| `/doctor` | ✅ | ✅ | ⚠️ 부분 — bash 의존 섹션은 "CLI 재실행 안내" 답변 | 20 섹션 중 텍스트 가능: 3 (RAG 개요·정책·설계) |
| `/status` | ✅ | ✅ | ⚠️ 부분 — 현재 수치 조회 불가 | CLI 안내 위주 응답 |
| `/brief` | ✅ | ✅ | ⚠️ 부분 — 일정·시장 조회 불가 | 일반 원리 답변 가능 |
| `/tqqq` | ✅ | ✅ | ⚠️ 부분 — 현재가 조회 불가 | 트리거만 받아 CLI 안내 |
| `/retro` | ✅ | ✅ | ⚠️ 부분 — 파일 쓰기 불가, 드래프트만 | Discord 드래프트 → CLI append |
| `/oops` | ✅ | ✅ | ⚠️ 부분 — learned-mistakes.md append 불가 | 드래프트 초안만 |
| `/autoplan` | ✅ | ✅ | ⚠️ 부분 — 플랜 생성 가능, 결재 버튼 UX 후속 | 텍스트 응답으로 충분 |
| `/crisis` | ✅ | ✅ | ⚠️ 부분 — 현 환경 openclaw 레거시 오염, skill-runner가 Jarvis로 해석 지시 | 프로토콜 안내만 |
| `/deploy` | ✅ | ✅ (Owner 제한) | ⚠️ 부분 — 실제 배포 불가, 주인님께 CLI 안내 | Owner 권한 필수 (senderIsOwner) |
| `/verify` | ✅ | ❌ 제외 | 감사관 Agent 10분+ 소요 · Discord 30초 timeout | CLI 전용 |
| `/review` | ✅ | ❌ 제외 | Dev+Reviewer 2 Agent 병렬 · Discord 환경 부적합 | CLI 전용 |
| `/investigate` | ✅ | ❌ 제외 | 5 Why 근본 원인 추적 필요 · bash 조사 필수 | CLI 전용 |

**판정 기호**: ✅ 완전 지원 · ⚠️ 부분 지원 (제약 있음) · ❌ 미지원

## Discord 트리거 매트릭스 (정규식 매핑)

```
/doctor   — 뭐 문제 없 · 시스템 (건강|점검) · 서비스 점검 · 점검 (해줘|좀)
/status   — 서비스 상태 · 다 돌아가 · 전체 현황 · 대시보드
/brief    — 브리핑 해줘 · 오늘 뭐 있 · 일일 요약
/tqqq     — tqqq 상태 · 주식 모니터 · 시장 모니터링
/retro    — 회고 (해|록|하자|하지) · 작업 정리 해줘 · retrospective
/oops     — 오답노트에 추가 · 실수 기록 · 오답 기재
/autoplan — 자동 계획 · 플랜 세워 · 계획 수립 · autoplan
/crisis   — 긴급 상황 · 장애 대응 · 봇이 죽
/deploy   — 배포 해줘 · 업데이트 진행 · 최신화 해줘 (Owner 전용)
```

**명시적 `/skill` 입력**: 모든 스킬 최고 신뢰도 (1.0) 즉시 매칭.

## 오탐 방지 가드 (NEGATIVE_PATTERNS)

일상 대화에서 키워드 우연 포함 시 트리거 억제:
- 가족·사람 건강/점검: 아이들·애들·딸·아들·엄마·아빠·우리 애·할머니·할아버지·남편·아내
- 반려동물: 강아지·고양이·개·댕댕이·냥이·반려
- 사물·장소: 화분·식물·꽃·카페·식당·가게·여행
- 메타 대화: 농담·예시·예를 들어·만약에·가령
- 인용문: 전체 따옴표 감싼 문장

## 환경 제어 레버

| 변수 | 기본값 | 설명 |
|------|-------|------|
| `DISCORD_SKILL_TRIGGER_ENABLED` | `1` | `0` 시 전체 트리거 비활성 (Kill switch) |
| `DISCORD_SKILL_DAILY_CAP` | `50` | 스킬별 일일 호출 상한 |

## 비용·관측

- **일일 캡**: `~/jarvis/runtime/state/discord-skill-quota.json` 영속 (봇 재시작 시 유지)
- **audit log**: `handlers.js` 내 `log('info', 'Skill trigger detected', ...)` 구조화 JSON
- **응답 시간**: SDK query 30~60초 (maxTurns=10 기준). Discord 초기 placeholder + 8초 주기 typing indicator로 UX 커버

## 재발 방지 (오답노트 매치)

- 2026-04-24: Discord 감사관 Task B가 할루시네이션(`PID 56097`, `크론 113개` 창작) 적발 → `skill-runner.js` system prompt에 "구체 수치 창작 금지" 강력 지시 주입
- 2026-04-24: `maxTurns:1` 하드코드 버그로 `/doctor`·`/deploy` exception → `maxTurns: 10` 수정
- 2026-04-24: NEGATIVE_PATTERNS 한국어 구어체 미커버 → 가족·반려·사물·메타·인용 5 카테고리 확장

## 참조

- 트리거 엔진: `infra/discord/lib/skill-trigger.js`
- 실행 파이프: `infra/discord/lib/skill-runner.js`
- 진입점 수정: `infra/discord/lib/handlers.js:497`
- Unit test: `infra/discord/test/skill-trigger.test.js` (48 assertions)
- CLI hook SSoT: `~/.claude/hooks/sensor-skill-trigger.sh`
- Surface Memory Boundary 룰: `~/jarvis/CLAUDE.md` → "Surface Memory Boundary"
