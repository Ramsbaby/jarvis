# Teams → Crons Reverse Index

> Navigation: [TASKS-INDEX.md](TASKS-INDEX.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [CONFIG.md](CONFIG.md)
>
> Per-team cron ownership. Team definitions come from `~/jarvis-board/lib/map/team-registry.ts` (SSoT, read-only for this repo). Task assignments come from `TASKS-INDEX.md` (auto-generated).
>
> **Hand-maintained.** When a cron moves teams, update here AND `gen-tasks-index.mjs` keyword list.

---

## 회의실 · 모닝 스탠드업 (`standup`) — 1 cron

Morning broadcast. 단일 엔트리이지만 여기서 매일 업무가 시작된다.

| Task ID | Schedule | 설명 |
|---|---|---|
| `morning-standup` | 매일 06:10 | 캘린더·Tasks·시스템·시장 요약 → `#jarvis` |

---

## 대표실 · Owner (`president`) — 13 crons

CEO / 이사회 / KPI / 주간-월간 리뷰. 의사결정·정산 루프가 여기 모인다.

| Task ID | Schedule | 설명 |
|---|---|---|
| `board-meeting-am` | 매일 06:05 | 오전 이사회 (사전 데이터 수집 후 에이전트 실행) |
| `board-meeting-pm` | 매일 21:55 | 저녁 이사회 |
| `board-topic-proposer` | 매일 08-21시 :00 | 시간별 토픽 제안자 |
| `board-conclude` | 5분마다 | 이사회 결론 수집·정산 |
| `board-perf-review` | 매일 18:00 | 이사회 성과 리뷰 (`team: council`) |
| `council-insight` | 매일 23:05 | 카운슬 인사이트 추출 |
| `ceo-daily-digest` | 매일 23:15 | CEO 일일 다이제스트 → `#jarvis-ceo` |
| `daily-summary` | 매일 20:00 | 하루 요약 |
| `weekly-kpi` | 월요일 08:30 | 주간 KPI 검토 |
| `weekly-report` | 일요일 20:05 | 주간 종합 리포트 |
| `weekly-roi` | 일요일 23:55 | 주간 ROI 정산 |
| `monthly-review` | 매월 1일 09:00 | 월간 회고 |
| `connections-weekly-insight` | 월요일 09:45 | 크로스팀 신호 집계 |

---

## SRE실 · 이준혁 (`infra-lead`) — 16 crons

시스템 신뢰성, 메모리·디스크·런타임 가드레일. 전체 인프라의 예방선.

| Task ID | Schedule | 설명 |
|---|---|---|
| `morning-standup` → 공유 | 06:10 | (참고: 회의실 소관) |
| `infra-daily` | 매일 09:00 | 인프라팀 일일 점검 → `#jarvis-ceo` |
| `system-doctor` | 매일 06:00 | 시스템 종합 진단 |
| `system-health` | 60분마다 | 경량 헬스체크 |
| `disk-alert` | *:10 (매시간) | 디스크 사용량 경고 |
| `rate-limit-check` | 30분마다 | API rate limit 카운트 |
| `memory-cleanup` | 매일 02:00 | 메모리 정리 |
| `memory-expire` | 월요일 03:00 | 기억 만료 아카이브 |
| `memory-sync` | 월요일 04:30 | 메모리 자동 동기화 |
| `rag-health` | 매일 03:00 | RAG 건강 체크 |
| `token-sync` | 매일 01:00 | 토큰 동기화 |
| `stale-task-watcher` | 30분마다 | 장기 stale 태스크 감시 |
| `log-cleanup` | event-triggered | 로그 회전 |
| `bot-crash-classifier` | event-triggered | 봇 크래시 분류 |
| `cost-alert-handler` | event-triggered | 비용 경보 처리 |
| `discord-mention-handler` | event-triggered | Discord 멘션 → 작업 라우팅 |
| `env-restore-notifier` | event-triggered | .env 복원 알림 |

---

## 재무실 · 장원석 (`finance`) — 8 crons

AI 운영 비용 + 시장 포지션 + 개인 수입 (tutoring). 숫자 단위 정확성이 핵심.

| Task ID | Schedule | 설명 |
|---|---|---|
| `finance-monitor` | 평일 08:00 | 종합 재무 리포트 → `#jarvis-ceo` |
| `market-alert` | 평일 09·13·16시 :05 | 시장 경보 |
| `tqqq-monitor` | 평일 22-23시 15분마다 | TQQQ/SOXL/NVDA 시세 → `#jarvis-market` |
| `macro-briefing` | 일-목 23:30 | 매크로 브리핑 |
| `cost-monitor` | 일요일 09:00 | 주간 AI 비용 정산 |
| `daily-usage-check` | 매일 05:55 | 일일 토큰 사용량 점검 |
| `update-usage-cache` | 30분마다 | 사용량 캐시 갱신 |
| `personal-schedule-daily` | 매일 07:30 | 오너 tutoring 일정 동기화 |

---

## 전략기획실 · 강나연 (`trend-lead`) — 6 crons

뉴스·트렌드·GitHub 동향. 시장/주식은 절대 다루지 않는다 (재무실 소관).

| Task ID | Schedule | 설명 |
|---|---|---|
| `news-briefing` | 매일 06:00 | 아침 뉴스 브리핑 |
| `calendar-alert` | 5분마다 | 임박한 일정 알림 |
| `github-monitor` | 매시간 | GitHub 트렌드 모니터 |
| `recon-weekly` | 월요일 09:00 | 주간 딥리서치 |
| `oss-recon` | 월요일 10:30 | OSS 동향 정찰 |
| `github-pr-handler` | event-triggered | PR 이벤트 핸들러 |

---

## 데이터실 · 한소희 (`record-lead`) — 5 crons

일일 대화 기록, RAG 인덱싱, Vault 아카이빙. 백엔드 담당.

| Task ID | Schedule | 설명 |
|---|---|---|
| `record-daily` | 매일 22:30 | 일일 대화/활동 기록 |
| `session-sync` | 15분마다 | Claude 세션 → 저장소 동기화 |
| `vault-sync` | 6시간마다 | Obsidian Vault 동기화 |
| `vault-auto-link` | 매일 06:30 | Vault 자동 백링크 생성 |
| `private-sync` | event-triggered | private 리포 동기화 |

> **주의**: `rag-index` / `rag-compact` 는 LaunchAgent (`ai.jarvis.rag-watcher`, `ai.jarvis.rag-compact`) 로 구동되며 tasks.json 에 엔트리가 없다. [CONFIG.md](CONFIG.md#5-launchagents) 참조.

---

## 자료실 · 문지아 (`library`) — 1 cron

RAG 프론트엔드 품질 담당 (사용자 검색 경험).

| Task ID | Schedule | 설명 |
|---|---|---|
| `rag-bench` | 일요일 03:00 | 주간 RAG 검색 품질 벤치마크 |

---

## 인재개발실 · 김서연 (`growth-lead`) — 4 crons

커리어·학습 통합. 스터디·학습 스케줄이 한 팀으로 합쳐져 있다.

| Task ID | Schedule | 설명 |
|---|---|---|
| `career-extractor` | 매일 00:30 | 커리어 추출 (jobs, resume 변경 감지) |
| `career-weekly` | 금요일 18:00 | 주간 커리어 리포트 → `#jarvis-dev` |
| `academy-support` | 일요일 20:00 | 학습 큐레이션 |
| `boram-daily-schedule` | 매일 07:30 | 가족 일일 스케줄 |

---

## 마케팅실 · 정하은 (`brand-lead`) — 5 crons

OSS·블로그·GitHub 성장. 외부 가시성 담당.

| Task ID | Schedule | 설명 |
|---|---|---|
| `oss-maintenance` | 매일 09:15 | OSS 리포 정비 (이슈·PR·라벨) |
| `oss-docs` | 수요일 11:00 | OSS 문서 갱신 |
| `oss-promo` | 금요일 17:00 | OSS 프로모션 스케줄링 |
| `brand-visibility-check` | 6시간마다 | 브랜드 가시성 체크 |
| `brand-weekly` | 화요일 08:00 | 주간 브랜드 리포트 → `#jarvis-blog` |

---

## QA실 · 류태환 (`audit-lead`) — 13 crons

품질 · 감사 · 문서 정합성 · E2E. 같은 부류 결함의 재발을 구조적으로 막는 팀.

| Task ID | Schedule | 설명 |
|---|---|---|
| `security-scan` | 매일 02:30 | 코드 시크릿/취약점 스캔 |
| `code-auditor` | 매일 04:45 | 코드 감사 |
| `cron-auditor` | 매일 05:30 | 크론 실행 결과 감사 |
| `doc-supervisor` | 매일 05:00 | 문서 감독 (drift 감지) |
| `doc-sync-auditor` | 매일 23:20 | 문서 동기화 감사 |
| `gen-system-overview` | 매일 04:05 | SYSTEM-OVERVIEW.md 자동 생성 |
| `gen-gotchas` | 월요일 03:00 | 개발 주의사항 자동 정리 |
| `schedule-coherence` | 월요일 04:00 | 일정 정합성 점검 |
| `token-ledger-audit` | 일요일 08:30 | 주간 토큰 원장 감사 |
| `tune-task-params` | 일요일 08:35 | 태스크 파라미터 자동 튜닝 |
| `weekly-code-review` | 일요일 05:00 | 주간 코드 리뷰 |
| `weekly-perf-agent` | 일요일 21:00 | 주간 성능 리뷰 |
| `jira-sync` | 월요일 09:00 | Jira 동기화 |

---

## 컨시어지 · 자비스 봇 (`secretary`) — 10 crons

Discord 24/7, 봇 품질 자가 점검, 자동 코딩 루프. 봇이 죽으면 전사 CS 가 멈춘다.

| Task ID | Schedule | 설명 |
|---|---|---|
| `bot-quality-check` | 매일 02:30 | 봇 품질 측정 |
| `bot-self-critique` | 매일 02:45 | 봇 스스로 평가 |
| `skill-eval` | 일요일 04:30 | Skill 평가 |
| `weekly-usage-stats` | 월요일 09:00 | 주간 사용량 통계 |
| `agent-batch-commit` | 매일 08:30 | 에이전트 배치 커밋 |
| `dev-runner` | 매일 22:55 | 자동 개발 러너 |
| `dev-event-bus` | 매일 22:50 | 개발 이벤트 버스 |
| `dev-event-watcher` | 매일 23:00 | 개발 이벤트 감시자 |
| `auto-diagnose` | event-triggered | 자동 진단 |
| `jarvis-coder` | event-triggered | Jarvis Coder (수동 호출) |

---

## 없는 팀 (미매핑)

현재 0. `gen-tasks-index.mjs` 가 모든 82개 태스크를 분류한다.

새 태스크 추가 시 `id` 에 팀 키워드 (예: `infra-*`, `board-*`, `finance-*`) 를 포함시키거나, 키워드가 애매하면 `gen-tasks-index.mjs` 의 `TEAM_REGISTRY` 키워드 배열에 추가해 분류를 명시한다.
