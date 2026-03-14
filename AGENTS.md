# AGENTS.md — Jarvis 에이전트 협업 플레이북

> 작성: 2026-03-14 | 버전: 1.0

---

## 팀 구조

| 에이전트 ID        | 역할                          | 주요 도구                     |
|--------------------|-------------------------------|-------------------------------|
| recon              | 외부 정보 수집 및 업계 동향   | web_search, web_fetch         |
| system-health      | 시스템 상태 모니터링          | Bash, computer_use            |
| github-monitor     | PR/이슈 변경사항 감지         | mcp__github, Bash             |
| infra-daily        | 인프라 점검 및 비용 추적      | Bash, mcp__github             |
| tqqq-monitor       | 시장 데이터 감시 및 알림      | web_search, Bash              |
| board-meeting      | 주간/월간 보드 미팅 진행      | Bash (report aggregation)     |

---

## 협업 규칙

1. **금지 영역**: `discord-bot.js`, `.env`, `state/` 디렉토리는 에이전트가 수정하지 않는다.
2. **출력 포맷**: 모든 태스크 출력은 Discord 채널 라우팅을 위해 간결하게 유지한다 (maxChars 준수).
3. **실패 처리**: circuit breaker OPEN 상태(연속 3회 실패)에서는 60분 대기 후 재시도한다.
4. **인시던트 기록**: 이상 감지 시 `rag/incidents.md`에 자동 append한다.
5. **불확실성**: 확인되지 않은 정보는 [미확인] 태그를 붙여 보고한다.

---

## 긴급 연락 체계

- L1 (자동 복구): retry-wrapper.sh — 최대 3회 재시도
- L2 (알림): bot-watchdog.sh → Discord #jarvis-system
- L3 (수동 개입): rag/l3-requests/ → 대표님 검토

---

## 모델 정책 (2026-03-14 기준)

- 경량 태스크: `claude-haiku-4-5`
- 고품질 판단: `claude-sonnet-4-6`
- Haiku 3 (`claude-3-haiku-20240307`): 2026-04-19 퇴역 — 사용 금지
