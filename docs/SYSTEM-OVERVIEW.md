# Jarvis 시스템 개요

> 🤖 **자동 생성 문서** — 직접 편집 금지
> Generated: 2026-03-18 15:37:32 | Commit: `e131f4c` (`main`)
> 업데이트: `scripts/gen-system-overview.sh` (매일 04:05 + git commit 시)

---

## 1. 한 줄 요약

> **"Claude AI를 두뇌로 쓰는 완전 자율 AI 회사. 매일 알아서 돌아간다."**

| 항목 | 내용 |
|------|------|
| 오너 | ${JARVIS_OWNER_NAME:-Your Name} |
| 인프라 | Mac Mini (macOS, 24/7 무중단) |
| 비용 | 월 ~$20 (Claude Max 구독) — API 직접 대비 90% 절약 |
| 자율화율 | 일상 루틴 100% 자동, 장애 복구 95% 자동 |
| 핵심 기술 | claude -p + LanceDB RAG + Nexus MCP + LaunchAgent |

---

## 2. 5층 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│  5층  Discord Bot           discord-bot.js                      │ ← 사람이 말 거는 창구
├─────────────────────────────────────────────────────────────────┤
│  4층  크론 자동화 엔진       jarvis-cron.sh + tasks.json         │ ← 매일 자동 실행
│       morning-standup / board-meeting / tqqq / news / doctor…   │
├─────────────────────────────────────────────────────────────────┤
│  3층  AI 두뇌                claude -p (ask-claude.sh)          │ ← 실제 생각하는 곳
│       7팀 페르소나 시스템     RAG 컨텍스트 자동 주입              │
├─────────────────────────────────────────────────────────────────┤
│  2층  장기기억                RAG Engine (LanceDB)              │ ← 과거 기억 검색
│       BM25 + Vector 하이브리드  Obsidian Vault 실시간 인덱싱     │
├─────────────────────────────────────────────────────────────────┤
│  1층  인프라                  Nexus MCP + macOS LaunchAgent     │ ← 서버, 파일, 명령
│       launchd 자동재시작       Circuit Breaker 보호              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 핵심 컴포넌트 상세

### 3.1 Discord Bot (`discord/discord-bot.js`)

사람이 자비스와 대화하는 유일한 창구.

```
사용자 메시지 (텍스트 / 이미지 / PDF)
  ↓
discord-bot.js  → 채널명으로 페르소나 선택 (personas.json)
  ↓
claude-runner.js → RAG 컨텍스트 자동 주입 (Nexus rag_search)
  ↓
claude -p "페르소나 + 기억 + 질문"
  ↓
스트리밍 응답 → Discord 스레드 (1900자 단위 청크)
```

| 기능 | 설명 |
|------|------|
| 채널별 페르소나 | jarvis-ceo → CEO, jarvis-infra → 인프라 담당 |
| PDF 첨부 처리 | pdftotext 추출 → 컨텍스트 주입 |
| 스트리밍 | 긴 응답도 라이브 편집으로 자연스럽게 |
| 자동 복구 | 15분 침묵 → bot-watchdog.sh 재시작 |
| 메모리 보호 | `pendingNext` 패턴으로 90s 타임아웃 경계 응답 유실 방지 |

### 3.2 크론 자동화 (`bin/jarvis-cron.sh`)

tasks.json 기반 스케줄 실행 엔진.

```
crontab → jarvis-cron.sh → tasks.json 파싱
                          ↓
             script 필드? → bash 직접 실행
             prompt 필드? → ask-claude.sh 경유 (claude -p)
```

**현재 등록된 태스크:**

> ✅ 활성 **55개** / 비활성 0개

| 태스크 ID | 스케줄 | 채널 | 설명 |
|-----------|--------|------|------|
| `session-sync` | `*/15 * * * *` | - | 최근 30분 내 대화 활동 감지 시 context-bus 즉시 갱신 |
| `tqqq-monitor` | `*/15 22-23 * * 1-5` | jarvis-market | TQQQ 모니터링 |
| `rate-limit-check` | `*/30 * * * *` | - | Rate Limit 체크 |
| `update-usage-cache` | `*/30 * * * *` | - | /usage 명령 stale 방지 — 30분마다 ~/.claude/usage-cache.jso |
| `stale-task-watcher` | `*/30 * * * *` | - | Stale 태스크 감지 및 자동 전이 |
| `calendar-alert` | `*/5 * * * *` | jarvis | 일정 선제 알림 |
| `system-health` | `0 * * * *` | jarvis-system | 시스템 헬스체크 |
| `github-monitor` | `0 * * * *` | jarvis-system | GitHub 알림 모니터 |
| `vault-sync` | `0 */6 * * *` | jarvis | Obsidian Vault 동기화 |
| `token-sync` | `0 1 * * *` | - | 토큰 동기화 |
| `career-weekly` | `0 18 * * 5` | jarvis-dev | 커리어 주간 리포트 |
| `memory-cleanup` | `0 2 * * *` | - | 메모리 정리 |
| `daily-summary` | `0 20 * * *` | jarvis | 일일 요약 |
| `academy-support` | `0 20 * * 0` | jarvis-ceo | 학습팀 주간 보고 (Academy) |
| `ceo-daily-digest` | `0 22 * * *` | jarvis-ceo | 일일 CEO 다이제스트 |
| `dev-event-watcher` | `0 23 * * *` | - |  |
| `rag-health` | `0 3 * * *` | jarvis-system | RAG 건강 체크 |
| `memory-expire` | `0 3 * * 1` | - | 기억 만료 아카이브 |
| `doc-supervisor` | `0 5 * * *` | jarvis-system | 문서화 시스템 감독 (Doc Supervisor) |
| `weekly-code-review` | `0 5 * * 0` | jarvis-system | 주간 LLM 코드 리뷰 |
| `finance-monitor` | `0 8 * * 1-5` | jarvis-ceo | 평일 08:00 재무/시장 모니터링. finance/team.yml 기반으로 실행. |
| `brand-weekly` | `0 8 * * 2` | jarvis-ceo | 브랜드팀 주간 보고 (Brand) |
| `infra-daily` | `0 9 * * *` | jarvis-ceo | 인프라팀 일일 점검 (Infra) |
| `cost-monitor` | `0 9 * * 0` | jarvis-ceo | 비용 모니터링 |
| `weekly-usage-stats` | `0 9 * * 1` | jarvis-system | Discord 주간 활용도 통계 |
| `recon-weekly` | `0 9 * * 1` | jarvis-ceo | 매주 월요일 AI/기술/시장 정보탐험. recon/team.yml 기반으로 실행. |
| `jira-sync` | `0 9 * * 1` | jarvis-ceo | JIRA 커리어 히스토리 동기화 |
| `monthly-review` | `0 9 1 * *` | jarvis-ceo | 월간 회고 |
| `disk-alert` | `10 * * * *` | jarvis-system | 디스크 사용량 경고 |
| `board-meeting-am` | `10 8 * * *` | jarvis-ceo | Board Meeting (아침) |
| `morning-standup` | `15 9 * * *` | jarvis | 모닝 스탠드업 |
| `agent-batch-commit` | `20 8,22 * * *` | - | 에이전트 산출물 일괄 커밋 |
| `career-extractor` | `30 0 * * *` | - | 커리어 인사이트 자동 추출 |
| `security-scan` | `30 2 * * *` | jarvis-system | 보안 스캔 |
| `bot-quality-check` | `30 2 * * *` | jarvis-system | 봇 응답 품질 분석 |
| `record-daily` | `30 22 * * *` | jarvis-ceo | 기록팀 일일 마감 (Record) |
| `skill-eval` | `30 4 * * 0` | jarvis-ceo | 스킬 자동 평가 |
| `memory-sync` | `30 4 * * 1` | jarvis-system | 메모리 자동 동기화 |
| `vault-auto-link` | `30 6 * * *` | jarvis | Vault 자동 링크 생성 |
| `boram-daily-schedule` | `30 7 * * *` | jarvis-boram | 매일 07:30 KST ${FAMILY_MEMBER_NAME:-가족}님 Preply 수업 일정을 #${FAMILY_CHANNEL:-jarvis-family} 채널로 자동  |
| `weekly-kpi` | `30 8 * * 1` | jarvis-ceo | 주간 KPI 리포트 |
| `bot-self-critique` | `45 2 * * *` | jarvis-system | 봇 자가 품질 점검 |
| `code-auditor` | `45 4 * * *` | jarvis-system | 코드 품질 감사 |
| `connections-weekly-insight` | `45 9 * * 1` | jarvis-ceo | Connections 주간 인사이트 |
| `weekly-report` | `5 20 * * 0` | jarvis-ceo | 주간 리포트 |
| `council-insight` | `5 23 * * *` | jarvis-ceo | 감사팀 일일 점검 (Council) |
| `market-alert` | `5 9,13,16 * * 1-5` | jarvis-market | 시장 급변 알림 |
| `dev-runner` | `50 22 * * *` | jarvis-system | 자율 개발 큐 러너 |
| `dev-event-bus` | `50 22 * * *` | - |  |
| `news-briefing` | `50 7 * * *` | jarvis | 뉴스 브리핑 |
| `board-meeting-pm` | `55 21 * * *` | jarvis-ceo | Board Meeting (저녁) |
| `auto-diagnose` | `(event/manual)` | jarvis-system | 자동 실패 진단 |
| `github-pr-handler` | `(event/manual)` | jarvis-dev | github.pr_opened 이벤트 발생 시 PR 요약 및 Discord 알림 전송. |
| `discord-mention-handler` | `(event/manual)` | jarvis-alerts | discord.mention 이벤트 발생 시 즉시 Discord 알림 채널에 응답. |
| `cost-alert-handler` | `(event/manual)` | jarvis-alerts | system.cost_alert 이벤트 발생 시 비용 초과 경보를 Discord로 즉시 전송. |

### 3.3 AI 두뇌 (`bin/ask-claude.sh`)

`claude -p`의 래퍼. 모든 크론 태스크와 Discord 대화의 실제 두뇌.

**컨텍스트 조립 순서:**
```
1. 시스템 페르소나   (채널/태스크별 역할 정의)
2. RAG 장기기억      (관련 Obsidian 노트 자동 검색)
3. Cross-team        (depends 필드 태스크의 최근 결과 자동 주입)
4. 현재 프롬프트     (질문 또는 태스크 지시)
```

**팀 페르소나 시스템:**

| 파일 | 역할 |
|------|------|
| `discord/personas.json` | 채널ID → 페르소나 매핑 |
| `agents/*.md` | CEO, 인프라팀장, 전략고문 등 에이전트 정의 |
| `teams/*.yaml` | YAML 기반 팀 설정 (`{{VAR}}` 템플릿 지원) |

### 3.4 RAG 장기기억 (`lib/rag-engine.mjs`)

Obsidian Vault의 모든 노트를 검색 가능한 장기기억으로 변환.

```
Obsidian Vault (~/Jarvis-Vault/)
  ↓ rag-watch.mjs (chokidar 실시간 감시)
LanceDB (rag/lancedb/)
  ├── Vector Index  (text-embedding-3-small)
  └── FTS Index     (BM25 전문검색)
  ↓ 하이브리드 검색 (1순위 BM25 + 보조 Vector)
결과 → Jina 리랭킹 → claude -p 컨텍스트 주입
```

| 특성 | 내용 |
|------|------|
| 인덱싱 | 변경 즉시 (chokidar) + 매시간 증분 |
| 중복 방지 | `mergeInsert()` upsert 방식 |
| 검색 방식 | BM25 키워드 우선 + Vector 의미 보조 |

### 3.5 Nexus MCP Gateway (`lib/mcp-nexus.mjs`)

Claude Code와 자비스 시스템을 연결하는 MCP 도구 허브.

> ✅ **15개 MCP 도구** (4개 게이트웨이)

| 게이트웨이 | 도구명 | 용도 |
|-----------|--------|------|
| `exec` | `exec` | 커스텀 bash — 전용 도구 없을 때만 (마지막 수단) |
| `exec` | `scan` | 다중 명령 병렬 실행 |
| `exec` | `cache_exec` | TTL 캐시 실행 (ps/df/uptime 등 반복 명령) |
| `exec` | `log_tail` | 로그 파일 전용 읽기 (tail/cat 대체) |
| `exec` | `file_peek` | 파일 패턴 검색 (grep 대체) |
| `extras` | `discord_send` | Discord 채널 메시지 전송 |
| `extras` | `run_cron` | 크론 잡 즉시 트리거 |
| `extras` | `get_memory` | RAG 검색 (외부 클라이언트용) |
| `extras` | `list_crons` | 크론 잡 목록 조회 |
| `extras` | `dev_queue` | 개발 태스크 큐 조회 |
| `extras` | `context_bus` | 팀 공용 게시판 read/append |
| `extras` | `emit_event` | 이벤트 발행 (event-watcher 트리거) |
| `extras` | `usage_stats` | Claude API 토큰 사용량 통계 |
| `health` | `health` | 시스템 전체 상태 단일 조회 |
| `rag` | `rag_search` | Obsidian 장기기억 하이브리드 검색 (BM25+Vector) |

**보안 모델:**

| 방어 레이어 | 내용 |
|------------|------|
| `validateCommand()` | 15개 위험 패턴 차단 (rm -rf, killall, .env 접근 등) |
| `validatePath()` | BOT_HOME, /tmp/ 밖 파일 접근 차단 |
| Circuit Breaker | 5분 내 동일 명령 2회 타임아웃 → 10분 자동 차단 |
| Timeout 복구 | 타임아웃 시 수집된 부분 출력 반환 (전체 폐기 없음) |

**MCP Resources (읽기 전용):**
- `jarvis://health` — 실시간 헬스 상태
- `jarvis://logs` — 최근 로그
- `jarvis://cache/stats` — exec 캐시 통계

---

## 4. 7팀 AI 회사

```
         ┌─────────────────────────────────────────────────┐
         │   Board Meeting  (08:10 아침 / 21:55 저녁)      │
         │   CEO(Claude)가 전팀 보고 수집 → 의사결정       │
         │   → context-bus.md 전체 공유                    │
         └──────────────────┬──────────────────────────────┘
                            │ 모든 팀이 읽음
         ┌──────────────────┼──────────────────┐
         │                  │                  │
      전략팀             성장팀             기록팀
     (council)          (career)           (record)
         │                                     │
      브랜드팀                              학술팀
      (brand)                             (academy)

              인프라팀(infra) → 모든 팀에 데이터 공급
```

**팀 간 정보 흐름:**

```
각 팀 결과물 → rag/teams/reports/{team}-*.md (RAG 인덱싱)
board-meeting → context-bus.md           (전체 요약, 모든 크론 읽음)
council       → shared-inbox/            (긴급 브로드캐스트)
depends 필드  → Cross-team Context 자동 주입
```

**Board Meeting 산출물 4종:**

| 파일 | 내용 |
|------|------|
| `state/context-bus.md` | 전체 요약 (모든 크론이 읽음) |
| `state/board-minutes/{날짜}.md` | 회의록 |
| `state/decisions/{날짜}.jsonl` | 의사결정 감사 로그 |
| `config/goals.json` | OKR KR 진척도 자동 갱신 |

---

## 5. 자기복구 메커니즘 (5단계 방어선)

```
① LaunchAgent KeepAlive=true
  → OS 레벨 1차 재시작 (launchd)

② Watchdog (180초 주기, ai.jarvis.watchdog)
  → 로그 freshness 감시, 봇 침묵 15분 시 재시작

③ launchd-guardian.sh (cron */3)
  → LaunchAgent 언로드 감지 → 자동 재등록

④ pre-cron-auth-check.sh (매일 07:00)
  → 아침 크론 전 Claude 인증 확인
  → 만료 시 ntfy 푸시 + Discord 즉시 알림

⑤ system-doctor.sh (매일 06:00)
  → 전체 8개 항목 점검 → Discord jarvis-system 리포트
```

**알림 경로:**

| 채널 | 용도 |
|------|------|
| Discord `jarvis-system` | 상세 리포트, WARN/FAIL 항목 |
| ntfy (Galaxy 폰) | 긴급 알림 (인증 만료, 네트워크 오류) |
| Uptime Kuma | 외부 모니터링 (`http://<LOCAL_SERVER_IP>:3001`) |

---

## 6. 특장점

### 💰 비용 효율 (~$20/월)
```
Claude Max 구독으로 Opus급 무제한 사용
API 직접 방식이면 월 $200~400 예상 → 실질 90% 절약
현재 rate limit 17% 수준 사용 (여유 있음)
```

### 🧠 장기기억이 진짜로 작동
```
"저번에 말했던 투자 얘기" → Obsidian에서 실제로 찾아냄
BM25(키워드 정확도) + Vector(의미 유사도) 하이브리드
Jina 리랭킹으로 결과 정확도 추가 향상
```

### 🔄 완전 자동 복구
```
5단계 방어선으로 사람 개입 없이 대부분 자가복구
장애 시 Galaxy 폰 ntfy 알림으로 즉시 인지
```

### 🏢 멀티팀 컨텍스트 공유
```
7개 AI 팀이 context-bus.md를 통해 간접 협업
팀 간 직접 통신 없이도 CEO(Claude)가 전체 조율
Cross-team Context로 의존 태스크 결과 자동 주입
```

### 🛡️ 보안 샌드박스 (Nexus)
```
15개 위험 명령 패턴 자동 차단
BOT_HOME 밖 파일 접근 원천 차단
Circuit Breaker로 반복 타임아웃 자동 차단
```

### 📊 자기진단 (`nexus_stats`)
```
넥서스 도구 사용 패턴 실시간 분석
타임아웃 명령어 추적 (cmd 필드 기록)
"쁨뻥이짓" 탐지 → exec 독점 경고
```

---

## 7. 한계점

| 한계 | 원인 | 현황 |
|------|------|------|
| Claude 구독 의존 | claude -p 기반 구조 | pre-cron-auth-check 감시 중 |
| 팀 에이전트 순차 실행 | sub-agent spawn 10분+ 소요 | board-meeting은 단일 claude -p로 우회 |
| Obsidian Vault → Mac Mini 종속 | 로컬 파일 기반 | iCloud 동기화 미구현 |
| Galaxy 직접 편집 불가 | SSH/Discord 명령만 가능 | 운영 불편 수준 |
| rate limit (아침 클러스터) | claude -p 동시 실행 제한 | 현재 여유 있음, 병렬 증가 시 위험 |
| 외부 공개 불가 | 구독 claude -p 재배포 금지 | 오픈소스화 시 API 버전 분리 필요 |

---

## 8. 로드맵

### 단기 (1~2개월)
- [ ] exec 독점 해소 확인 — `nexus_stats`로 주기적 모니터링
- [ ] Claude 토큰 자동갱신 — 현재 수동 `claude login` 의존
- [ ] Circuit Breaker 통계 Discord 리포트 — slow_cmds 패턴 주기 알림
- [ ] Agent Teams 병렬 실행 재시도 — 현재 10분+ 소요 해결

### 중기 (3~6개월)
- [ ] Multi-provider LLM 폴백 — Claude 만료 시 Gemini/GPT 자동 전환
- [ ] Vault → iCloud/GitHub 백업 — Mac Mini 단일 장애점 해소
- [ ] 이벤트 드리븐 전환 — 크론 → `emit_event` 기반 (조건 충족 시 즉시 실행)
- [ ] 오픈소스 공개 준비 — API 버전 분리, jarvis init 설치 스크립트

### 장기 (6개월+)
- [ ] 진짜 멀티에이전트 — 팀별 독립 프로세스 + 메시지 큐
- [ ] 모바일 네이티브 클라이언트 — Galaxy용 Jarvis 앱
- [ ] 자기개선 루프 — 실패 패턴 → 자동 프롬프트 최적화
- [ ] GitHub 2K~5K stars — "AI Company-in-a-Box" 포지셔닝

---

## 9. 주요 파일 맵

| 파일 | 줄 수 | 역할 |
|------|-------|------|
| `discord/discord-bot.js` | 693 | Discord 봇 메인 |
| `lib/mcp-nexus.mjs` | 156 | Nexus MCP 오케스트레이터 |
| `lib/nexus/exec-gateway.mjs` | 332 | exec 게이트웨이 + Circuit Breaker |
| `lib/nexus/extras-gateway.mjs` | 308 | extras 게이트웨이 (discord/cron/stats) |
| `lib/nexus/rag-gateway.mjs` | 90 | RAG 게이트웨이 |
| `lib/nexus/health-gateway.mjs` | 95 | 헬스 게이트웨이 |
| `lib/rag-engine.mjs` | 694 | RAG 하이브리드 검색 엔진 |
| `bin/ask-claude.sh` | 244 | claude -p 래퍼 (크론 진입점) |
| `bin/jarvis-cron.sh` | 252 | 크론 실행 엔진 |
| `config/tasks.json` | 1205 | 크론 태스크 설정 |
| `discord/personas.json` | 12 | 채널 페르소나 설정 |
| `scripts/vault-sync.sh` | 388 | Obsidian Vault 동기화 |

**디렉토리 구조:**
```
~/.jarvis/
├── bin/           크론 진입점 (ask-claude.sh, jarvis-cron.sh, route-result.sh)
├── config/        tasks.json, monitoring.json, goals.json
├── discord/       봇 코드, personas.json, node_modules/
├── lib/           RAG 엔진, Nexus MCP, LLM Gateway, 팀 로더
│   └── nexus/     4개 게이트웨이 (exec / rag / health / extras)
├── logs/          모든 서비스 로그 (cron.log, nexus-telemetry.jsonl 등)
├── rag/           LanceDB 데이터 + 팀 보고서
├── scripts/       자동화 스크립트 (watchdog, doctor, sync, gen-overview 등)
├── state/         context-bus.md, health.json, board-minutes/, decisions/
├── agents/        팀 에이전트 프로필 (*.md)
├── teams/         팀 YAML 정의 (*.yaml)
├── adr/           Architecture Decision Records (ADR-001~010)
└── docs/          아키텍처 문서 (이 파일 포함)
```

---

## 10. 현재 서비스 상태

| 서비스 | 상태 | PID |
|--------|------|-----|
| ai.jarvis.watchdog | 🟢 실행중 | 72437 |
| ai.jarvis.orchestrator | 🟢 실행중 | 28860 |
| ai.openclaw.glances | 🟢 실행중 | 764 |
| ai.jarvis.webhook-listener | 🟢 실행중 | 7140 |
| ai.jarvis.discord-bot | 🟢 실행중 | 23404 |
| ai.jarvis.boram-briefing | 🔴 중지 | - |
| ai.jarvis.session-summarizer | 🔴 중지 | - |
| ai.jarvis.daily-restart | 🔴 중지 | - |
| ai.jarvis.rag-watcher | 🟢 실행중 | 96014 |
| ai.jarvis.event-watcher | 🟢 실행중 | 89744 |
| ai.jarvis.boot-auth-check | 🔴 중지 | - |

> 마지막 확인: 2026-03-18 15:37:32

---

## 11. 최근 변경

- `ddac94d` docs(ko): rename claude-discord-bridge → jarvis, v1 범위 및 로드맵 확장 명시
- `dc65425` docs: rename claude-discord-bridge → jarvis, clarify v1 scope + roadmap expansion
- `314dd78` docs: add awesome-openclaw badge
- `c296e66` ux: move Prerequisites section below Architecture to reduce bounce rate
- `c196149` fix(docker): ~/.jarvis 심볼릭 링크 + crontab 자동 생성 추가 (Windows/Linux 스케줄 미실행 수정)
- `1b25d79` feat(docker): tasks.json → /etc/crontabs/root 자동 생성 (Docker cron 미실행 버그 수정)
- `c9319f9` security: remove hardcoded Discord webhook URL from boram scripts
- `52dfe55` rename: knowledge-synthesizer → insight-extractor + rag-engine compact fix
- `e0d4cc4` feat: P1~P3 개선사항 구현 — 신뢰성·확장성·이식성 강화
- `ea2a60c` fix(readme-ko): 30개→49개 크론 schedule footer, 8팀→11팀 company-agent 주석, 중복 구분선 제거

---

*🤖 Generated by [`scripts/gen-system-overview.sh`](../scripts/gen-system-overview.sh) |
[Documentation Index](INDEX.md) | [ADR Index](../adr/ADR-INDEX.md)*
