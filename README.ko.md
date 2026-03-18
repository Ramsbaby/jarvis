<p align="center">
  <a href="https://github.com/Ramsbaby/jarvis/actions/workflows/ci.yml">
    <img src="https://github.com/Ramsbaby/jarvis/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
  <a href="https://github.com/Ramsbaby/jarvis/stargazers">
    <img src="https://img.shields.io/github/stars/Ramsbaby/jarvis?style=flat-square" alt="Stars">
  </a>
  <img src="https://img.shields.io/badge/추가비용-월_$0-brightgreen?style=flat-square" alt="$0/month">
  <img src="https://img.shields.io/badge/컨텍스트_압축-98%25-blueviolet?style=flat-square" alt="98% 압축">
  <img src="https://img.shields.io/badge/세션_지속-3시간+-blue?style=flat-square" alt="3+ hours">
  <img src="https://img.shields.io/badge/라이선스-MIT-blue?style=flat-square" alt="License">
</p>

<h1 align="center">Jarvis — AI Company-in-a-Box</h1>

<p align="center">
  <strong>Claude Max 구독은 하루 23시간 놀고 있습니다.<br>Jarvis는 그걸 24/7 AI 운영 시스템으로 바꿔줍니다 — 12개 AI 팀, 49개 크론 태스크, 영구 기억 — 추가 비용 $0.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="ROADMAP.md">로드맵</a> · <a href="discord/SETUP.md">설치 가이드</a> · <a href="docs/INDEX.md">문서</a>
</p>

<p align="center">
  <img src="docs/demo.gif" alt="Jarvis 데모" width="700">
</p>

---

## 왜 $0인가? — 가장 큰 차별점

대부분의 Discord 봇과 AI 자동화 도구는 Anthropic API를 직접 호출합니다. 메시지마다 돈이 나갑니다:

- API로 Claude Opus 호출: 메시지당 약 $0.015–$0.075
- 월 500건 메시지를 처리하는 봇: **매달 $7–$37 추가 청구**

**Jarvis는 다르게 작동합니다.** `claude -p`를 사용합니다. 이것은 Claude Code CLI의 헤드리스(비대화형) 모드입니다. Claude Code는 Anthropic이 공식 제공하는 개발자 도구로, Claude Max 또는 Pro 구독에 추가 비용 없이 포함되어 있습니다. Jarvis는 이 도구를 Discord, 크론 작업, 메모리 시스템에 연결하는 껍데기(harness)입니다.

> 쉽게 비유하면: 이미 헬스장 월정액을 내고 있는 상태입니다. Jarvis는 그 헬스장을 실제로 매일, 심지어 자는 동안에도 쓰게 해주는 퍼스널 트레이너입니다.

### 나란히 비교

| | **Jarvis** | **API 기반 봇** | **OpenClaw / Clawdbot** |
|---|---|---|---|
| 월 추가 비용 | **$0** | $5–$50+ | API 키 필요 |
| Claude 호출 방식 | `claude -p` (구독에 포함) | Anthropic API (토큰 종량제) | Anthropic API (토큰 종량제) |
| 자동화 방식 | 49개 크론 + 12개 AI 팀 (능동형) | 반응형만 | 반응형만 |
| 자가복구 | 4계층 자동 복구 | 없음 | 없음 |
| 기억 (RAG) | LanceDB 하이브리드 벡터 + BM25 | 드물게 | 없음 |
| 세션 연속성 | 3시간+ (98% 압축) | 메시지별 | 기본 수준 |

### `claude -p`가 뭔가요?

`claude -p`는 Claude Code의 "출력 모드"입니다. 프롬프트를 주면 Claude가 실행되어 답변을 출력하고 종료됩니다. Anthropic은 이를 자동화 파이프라인에서 Claude Code를 사용하는 권장 방식으로 공식 문서에서 소개합니다. 기존 구독 하에 실행되기 때문에 호출당 요금이 없습니다.

Jarvis는 모든 Discord 메시지, 모든 크론 태스크, 모든 AI 팀 보고서에 `claude -p`를 호출합니다. 평소에 대화창에서 쓰던 것과 똑같은 Claude Opus 또는 Sonnet이, 이제 추가 비용 없이 24/7 일해 줍니다.

---

## 핵심 지표

<table>
<tr>
<td align="center" width="33%">

### 월 $0
*추가 비용*

이미 내고 있는 Claude Max 구독에 포함. API 키 불필요, 종량제 없음.

</td>
<td align="center" width="33%">

### 최대 98% 압축
*컨텍스트 절감*

Nexus CIG가 모든 툴 호출 결과를 Claude 컨텍스트에 들어가기 전에 인터셉트. 대용량 케이스에서 315 KB → 5.4 KB (98%) 압축 측정.

</td>
<td align="center" width="33%">

### 3시간+
*세션 지속 시간*

압축 없이는 약 30분에 컨텍스트 포화. Nexus CIG 적용 시 멀티턴 스레드가 수 시간 동안 유지.

</td>
</tr>
</table>

---

## 자는 동안 하는 일들

일반 봇은 당신이 입력할 때까지 기다립니다. Jarvis는 스스로 일합니다:

```
 당신          Jarvis
 ────────────────────────────────────────────────────────────
 03:00  zzz   → 서버 정비 스캔                  #bot-system
 04:45  zzz   → 코드 감사 스캔 (전체 스크립트)   내부
 07:50  zzz   → 트렌드팀: 모닝 브리핑            #bot-daily
 08:00  zzz   → Board Meeting: CEO가 전팀 리뷰   #bot-ceo
 08:05  zzz   → 스마트 스탠드업 (당신 기다림)     #bot-daily
 09:00  ☕    ← 일어나면 브리핑이 이미 올라와 있음
 10:00        ↔ 실시간 Discord 채팅 (타이핑하면 답변)
 18:00        ← 채팅 종료
 20:00  zzz   → 기록팀: 일일 아카이브            내부
 00:30  zzz   → 로그 로테이션 + 백업 정리
 01:00  zzz   → RAG 인덱스 + Vault 동기화 (매시간)
 ────────────────────────────────────────────────────────────
              49개 크론 태스크 + 12개 AI 팀. 수동 개입 없음.
```

모든 태스크에 **지수 백오프 재시도** (3회), **레이트 리밋 인식**, **실패 알림** ([ntfy](https://ntfy.sh) 폰 푸시)이 내장되어 있습니다.

---

## 핵심 기능

### 1. 추가 비용 $0
`claude -p`는 Claude Max 구독 안에서 실행됩니다. 어차피 $100/월을 내고 있다면, Jarvis는 그 구독이 키보드 앞에 있을 때만이 아니라 24/7 일하게 만들어 줍니다.

### 2. AI 팀 조직
12개 가상팀이 각자의 역할과 스케줄로 움직입니다. 따로 시킬 필요가 없습니다:

| 팀 | 하는 일 |
|------|-------------|
| **전략팀 (Council)** | 팀 간 종합 분석, 일일 우선순위 정리 |
| **인프라팀 (Infra)** | 서버 상태, 비용 모니터링 |
| **성장팀 (Career)** | 주간 성장 회고 |
| **기록팀 (Record)** | 매일 활동 아카이빙 |
| **브랜드팀 (Brand)** | 콘텐츠 및 포지셔닝 추적 |
| **학술팀 (Academy)** | 리서치 및 지식 관리 |
| **트렌드팀 (Trend)** | 아침 뉴스 및 시장 브리핑 |

### 3. 자가복구 인프라 (4계층)
봇이 죽어도 새벽에 깨울 일 없습니다:

```
계층 0: bot-preflight.sh  — 콜드 스타트마다 설정 검증
          오류 발견 → Claude AI가 로그를 읽고 파일을 직접 수정
계층 1: launchd KeepAlive — 종료 즉시 OS 레벨에서 재시작 (macOS)
계층 2: cron 5분마다 → watchdog.sh — 로그 신선도 확인, 멈춘 프로세스 종료
계층 3: cron 3분마다 → launchd-guardian.sh — 언로드된 LaunchAgent 재등록
```

### 4. 영구 기억 (RAG)
모든 대화, 크론 결과, 문서가 로컬 LanceDB에 인덱싱됩니다. "지난주에 TQQQ 뭐라 했지?"라고 물어보면 찾아줍니다. 클라우드 없음, 추가 비용 없음.

- **벡터 검색** — 의미 유사도 (OpenAI `text-embedding-3-small`, 1536차원)
- **전문 검색** — BM25 키워드 매칭
- **리랭킹** — RRF(Reciprocal Rank Fusion)로 두 신호 결합

### 5. 98% 컨텍스트 압축
Nexus CIG(컨텍스트 인텔리전스 게이트웨이) MCP 서버가 Claude와 모든 시스템 명령 사이에 위치합니다. 출력 유형을 분류해 컨텍스트 윈도우에 들어가기 전에 압축합니다. 315 KB JSON 덩어리가 5.4 KB가 됩니다. 30분 만에 토큰이 소진되던 멀티턴 스레드가 이제 3시간 이상 유지됩니다.

---

## 빠른 시작

> **사전 요구사항**
> - **Claude Max 구독** ($100/월) — 모든 응답과 크론 태스크가 `claude -p`를 호출합니다. 구독 없이는 봇이 시작만 되고 아무것도 하지 않습니다.
> - **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code` 후 `claude`로 인증
> - **Node.js 20+**, **jq**, [discord.com/developers](https://discord.com/developers)에서 발급한 **Discord 봇 토큰**

**A안 — Docker (가장 간단):**

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
cp discord/.env.example discord/.env
# discord/.env 편집 — 토큰 입력
docker compose up -d
```

**B안 — 직접 설치 (macOS / Linux):**

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
./install.sh --local
# discord/.env 편집
node discord/discord-bot.js
```

macOS에서 24/7 상시 운영하려면:
```bash
launchctl load ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist
```

전체 단계별 가이드는 [discord/SETUP.md](discord/SETUP.md) 참조.

---

## 아키텍처

```
Discord 메시지
      │
      ▼
discord-bot.js ──► handlers.js ──► claude-runner.js
                                         │
                                   claude -p (구독 포함)
                                         │
                                   Nexus CIG (MCP 서버)
                                   98% 압축
                                         │
                                   formatForDiscord()
                                         │
                                   Discord 스레드 답변
                                         │
                                   RAG 인덱스 (LanceDB)
                                   이후 컨텍스트로 재사용
```

**크론 경로:**
```
jarvis-cron.sh → bot-cron.sh → ask-claude.sh → claude -p
                                     │
                               depends[] 태스크의
                               크로스팀 컨텍스트 자동 주입
                                     │
                               결과 → Discord + Vault + RAG
```

---

## 설정

### `discord/.env` (필수)

```env
BOT_NAME=MyBot
BOT_LOCALE=ko                        # 'ko' (기본값) 또는 'en'
DISCORD_TOKEN=your_bot_token
GUILD_ID=your_server_id
CHANNEL_IDS=channel_id_1,channel_id_2
OWNER_NAME=YourName
OPENAI_API_KEY=your_key              # 선택: RAG 벡터 임베딩 전용
NTFY_TOPIC=your_ntfy_topic          # 선택: 모바일 푸시 알림
```

### `discord/personas.json` (선택)

채널별 시스템 프롬프트 (채널 ID를 키로):

```json
{
  "123456789": "당신은 시니어 개발자입니다. 간결하고 기술적으로 답하세요.",
  "987654321": "당신은 창의적인 글쓰기 도우미입니다. 위트 있게 소통하세요."
}
```

### `config/tasks.json` (크론 자동화)

```json
{
  "id": "morning-standup",
  "name": "모닝 스탠드업",
  "schedule": "5 8 * * *",
  "prompt": "오늘의 주요 의제를 요약해줘...",
  "output": ["discord"],
  "discordChannel": "bot-daily",
  "retry": { "max": 3, "backoff": "exponential" }
}
```

`config/tasks.json.example`에서 morning-standup, daily-summary, system-health 3개 예시 태스크로 시작할 수 있습니다.

---

## 슬래시 커맨드

| 커맨드 | 기능 |
|---------|-------------|
| `/search <쿼리>` | RAG 지식베이스 시맨틱 검색 |
| `/status` | 시스템 헬스 + 레이트 리밋 현황 |
| `/tasks` | 크론 태스크 목록 |
| `/run <task_id>` | 크론 태스크 수동 트리거 |
| `/threads` | 최근 대화 스레드 목록 |
| `/alert <메시지>` | Discord + ntfy 푸시 알림 전송 |
| `/usage` | 토큰 사용량 + 레이트 리밋 통계 |
| `/remember <텍스트>` | 영구 메모리 항목 저장 |
| `/clear` | 세션 컨텍스트 초기화 |
| `/stop` | 진행 중인 `claude -p` 프로세스 중단 |

---

## 파일 구조

```
~/.jarvis/
├── discord/          # Discord 클라이언트, 핸들러, 포매팅
├── bin/              # 진입점: ask-claude.sh, bot-cron.sh 등
├── lib/              # 핵심: rag-engine, mcp-nexus, llm-gateway
├── config/           # tasks.json, monitoring.json, anti-patterns.json
├── scripts/          # 워치독, 감사, vault-sync, KPI, E2E 테스트
├── teams/            # 12개 팀 정의 (YAML + 시스템 프롬프트)
├── plugins/          # 파일 컨벤션 플러그인 시스템
├── context/          # 태스크별 배경 지식 파일
├── results/          # 크론 태스크 결과 이력
├── rag/              # LanceDB + 팀 보고서
├── agents/           # CEO, 인프라 팀장 등 에이전트 프로필
├── adr/              # Architecture Decision Records
├── docs/             # 아키텍처, 운영, 팀 문서
└── state/            # 세션, 레이트 트래커, 의사결정, 트리거
```

---

## 로드맵

| 페이즈 | 상태 | 설명 |
|-------|--------|-------------|
| Phase 0 | 완료 | 버그 수정, 구조화 로깅, 자가복구 |
| Phase 1 | 완료 | LLM Gateway, Bash/Node 모듈 분리 |
| Phase 2 | 완료 | 플러그인 시스템, Lite/Company 모드, Team YAML, jarvis init |
| Phase 3 | 완료 | 오픈소스 체크리스트 12/12 |
| Phase 4 | 예정 | 다국어 지원, 웹 대시보드, Slack 어댑터 |

자세한 내용은 [ROADMAP.md](ROADMAP.md) 참조.

---

## 문서

| 문서 | 설명 |
|----------|-------------|
| [docs/INDEX.md](docs/INDEX.md) | 문서 허브 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 아키텍처, Nexus CIG, 자가복구 |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | 크론, 모니터링, 인시던트 대응 |
| [docs/TEAMS.md](docs/TEAMS.md) | 12개 AI 팀 개요 |
| [adr/ADR-INDEX.md](adr/ADR-INDEX.md) | Architecture Decision Records |
| [CHANGELOG.md](CHANGELOG.md) | 릴리스 이력 |
| [ROADMAP.md](ROADMAP.md) | 예정 기능 |

---

## 플랫폼 참고

| 기능 | macOS (네이티브) | Linux (Docker) |
|---------|---------------|----------------|
| 프로세스 감독 | `launchd` KeepAlive | Docker `restart: always` |
| 워치독 / 가디언 | cron + bash | 동일 (컨테이너 내 실행) |
| Apple 연동 | Notes, Reminders (선택) | 미지원 |

---

## 기여하기

```bash
git clone https://github.com/Ramsbaby/jarvis
# 변경 작업
bash scripts/e2e-test.sh   # 로컬 프로덕션 검증 (실행 중인 봇 필요)
# Pull Request 제출
```

예정 기능은 [ROADMAP.md](ROADMAP.md) 참조.

---

## 라이선스

MIT — [LICENSE](LICENSE) 참조

---

<p align="center">
  <a href="README.md">English README →</a><br><br>
  프로젝트가 유용하다면 별표 하나가 다른 사람들이 발견하는 데 도움이 됩니다.
</p>
