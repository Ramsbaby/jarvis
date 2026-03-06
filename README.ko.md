<p align="center">
  <img src="https://img.shields.io/badge/추가비용-월_$0-brightgreen?style=flat-square" alt="$0/month">
  <img src="https://img.shields.io/badge/E2E_테스트-43%2F44-brightgreen?style=flat-square" alt="Tests">
  <img src="https://img.shields.io/badge/컨텍스트_압축-98%25-blueviolet?style=flat-square" alt="98% 압축">
  <img src="https://img.shields.io/badge/세션_지속-3시간+-blue?style=flat-square" alt="3+ hours">
  <img src="https://img.shields.io/badge/플랫폼-macOS%20%7C%20Linux-lightgrey?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/라이선스-MIT-blue?style=flat-square" alt="License">
</p>

<h1 align="center">Jarvis — AI Company-in-a-Box</h1>

<p align="center">
  <strong>Claude Max 구독은 하루 23시간 놀고 있습니다.<br>이것을 7개 AI 팀이 운영하는 24/7 AI 운영 시스템으로 만들어 줍니다 — 추가 비용 $0.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="ROADMAP.md">로드맵</a> · <a href="discord/SETUP.md">설치 가이드</a>
</p>

---

<p align="center">
  <img src="docs/demo.gif" alt="데모: Discord 대화, 스트리밍 응답, 툴 사용 표시" width="700">
  <br>
  <sub>실시간 스트리밍 · 툴 사용 이모지 표시 · 스레드 세션 지속</sub>
</p>

---

## 한눈에 보기

| | |
|---|---|
| **무엇** | `claude -p` (Claude Code CLI)를 백엔드로 한 자체 호스팅 Discord 봇 |
| **누구를 위해** | Claude Max 구독자 중 추가 API 비용 없이 쓰고 싶은 분 |
| **어떻게** | 메시지마다 `claude -p` 프로세스를 생성, 응답을 Discord에 실시간 스트리밍 |
| **왜** | 반응형 채팅 + 24개 예약 크론 태스크, 3시간+ 세션, 자가복구 인프라 |

```
Discord에 메시지 입력  →  claude -p 응답  →  스레드에 실시간 스트리밍
08:05 크론 실행       →  모닝 브리핑 작성  →  #bot-daily 자동 게시
당신이 자는 동안. API 청구서 없이. 컨텍스트 한계 없이.
```

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

Nexus CIG가 모든 툴 호출 결과를 Claude 컨텍스트에 들어가기 전에 인터셉트. 대용량 JSON 출력 등 헤비한 케이스에서 315 KB → 5.4 KB (98%) 압축이 측정됨. 실제 절감률은 출력 유형에 따라 다름.

</td>
<td align="center" width="33%">

### 3시간+
*세션 지속 시간*

툴 출력이 많은 작업에서 압축 없이는 약 30분에 컨텍스트가 포화됨. Nexus CIG를 툴 헤비 워크로드에 적용 시 멀티턴 스레드가 수 시간 동안 유지됨.

</td>
</tr>
</table>

---

## 자는 동안 하는 일들

일반 봇은 **반응형** — 당신이 타이핑할 때까지 대기. 이 봇은 **능동형**:

```
 당신          봇
 ───────────────────────────────────────────────────────────
 03:00  zzz   → 서버 정비 스캔                  #bot-system
 08:05  zzz   → 모닝 스탠드업 브리핑             #bot-daily
 09:00  ☕    ← 일어나보면 브리핑이 이미 올라와 있음
 09:15        → 커스텀 모니터 (15분마다)          #bot-market
 10:00        ↔ 실시간 Discord 채팅 (채팅하면 답변)
 12:00  🍜    → 시스템 헬스 체크                 로그
 15:30        → 알림: 임계값 초과               #bot-market + 📱
 18:00        ← 채팅 종료
 20:00  zzz   → 일일 요약                       #bot-daily
 00:30  zzz   → 로그 로테이션 + 백업 정리
 01:00  zzz   → RAG 인덱스 재빌드 (매시간, 증분)
 ───────────────────────────────────────────────────────────
              24개 태스크. 수동 개입 없음.
```

모든 태스크에 **지수 백오프 재시도** (3회), **레이트 리밋 인식** (5시간 슬라이딩 윈도우), **실패 알림** ([ntfy](https://ntfy.sh) 푸시)이 내장되어 있습니다.

---

## 다른 봇과 비교

### 월간 비용

| | **이 봇** | **Clawdbot** (60K ⭐) | **일반 API 봇** |
|---|---|---|---|
| AI 비용 | **$0 추가** | ~$36+/월 | $5 – $50+/월 |
| 필요 조건 | Claude Max 구독 | Anthropic API 키 | API 키 + 과금 |
| 모델 품질 | Opus / Sonnet (전체) | Claude (API 경유) | 다양 |

### 기능 비교

| | **이 봇** | API 기반 봇 | Clawdbot |
|---|---|---|---|
| 동작 방식 | **능동형** (24개 크론 태스크) | 반응형만 | 반응형만 |
| 컨텍스트 관리 | **Nexus CIG** (98% 압축) | 없음 / 기본 | 기본 |
| RAG / 메모리 | LanceDB (벡터 + BM25 하이브리드) | 드물게 | 플러그인 의존 |
| 자가복구 | 3계층 워치독 | 수동 재시작 | 다양 |
| 세션 연속성 | `--resume` 멀티턴 스레드 | 메시지별 | 다양 |
| E2E 테스트 | **43/44** 자동화 | 드물게 | 일부 |
| 지원 메신저 | Discord | Discord | 25+ 플랫폼 |

---

## 빠른 시작

### 사전 요구사항

- **Node.js ≥ 20** — `node -v`
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **Claude Max 구독** — `claude -p` 헤드리스 모드 필수
- **Discord 봇 토큰** — [Discord Developer Portal](https://discord.com/developers/applications)
- **OpenAI API 키** — RAG 임베딩용 (`text-embedding-3-small`, 저렴)

### A안: Docker (가장 간단)

```bash
git clone https://github.com/YOUR_USERNAME/jarvis ~/.jarvis
cd ~/.jarvis
cp discord/.env.example discord/.env
# discord/.env 편집 — 토큰 입력
docker compose up -d
```

`docker compose logs -f`로 로그 확인.

### B안: 직접 설치 (macOS / Linux)

```bash
# 1. 클론
git clone https://github.com/YOUR_USERNAME/jarvis ~/.jarvis
cd ~/.jarvis

# 2. 설치 스크립트 실행
./install.sh --local

# 3. 설정
# discord/.env 편집 (discord/.env.example 참고)
# discord/personas.json 편집 (선택, 채널별 시스템 프롬프트)

# 4. 실행
node discord/discord-bot.js
```

macOS에서 24/7 상시 운영하려면 LaunchAgent 등록:

```bash
launchctl load ~/Library/LaunchAgents/ai.discord-bot.plist
```

전체 단계별 가이드는 [discord/SETUP.md](discord/SETUP.md) 참조.

---

## 설정

### `discord/.env` (필수)

```env
BOT_NAME=MyBot                       # Discord에 표시되는 봇 이름
BOT_LOCALE=ko                        # 봇 언어: 'ko' (기본값) 또는 'en'
DISCORD_TOKEN=your_bot_token
GUILD_ID=your_server_id
CHANNEL_IDS=channel_id_1,channel_id_2
OWNER_NAME=YourName
OPENAI_API_KEY=your_key              # RAG 임베딩용
NTFY_TOPIC=your_ntfy_topic          # 선택: 모바일 푸시 알림
```

### `discord/personas.json` (선택)

채널 ID를 키로 한 채널별 시스템 프롬프트:

```json
{
  "123456789": "당신은 시니어 개발자입니다. 간결하고 기술적으로 답하세요.",
  "987654321": "당신은 창의적인 글쓰기 도우미입니다. 위트 있게 소통하세요."
}
```

### `config/tasks.json` (크론 자동화용)

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

`config/tasks.json.example`에서 3개 시작용 예시 태스크(morning-standup, daily-summary, system-health)를 확인하고, 자신의 태스크로 확장할 수 있습니다.

---

## 아키텍처

```
Discord 메시지
      │
      ▼
discord-bot.js ──► lib/handlers.js ──► lib/claude-runner.js
                         │                      │
                         │              createClaudeSession()
                         │              @anthropic-ai/claude-agent-sdk
                         │                      │
                  StreamingMessage         async 이벤트 스트림
                  (실시간 편집,                  │
                  1900자 청킹)           RAG: MCP 툴 호출로 검색
                         │              (LanceDB 하이브리드 검색)
                         ▼
                  formatForDiscord()
                  (format-pipeline.js)
                  테이블→리스트, 헤딩 정규화,
                  링크 미리보기 억제, 타임스탬프 변환
                         │
                         ▼
                  Discord 스레드 답변
                         │
                         ▼
              saveConversationTurn()
                         │
                         ▼
              context/discord-history/YYYY-MM-DD.md
                         │
                         ▼
              매시간 RAG 인덱서 (rag-index.mjs)
                         │
                         ▼
      ┌──────────────────────────────────────────┐
      │         Nexus CIG (MCP 서버)             │
      │  모든 툴 출력을 인터셉트.                  │
      │  315 KB 원본 → 5.4 KB 압축.              │
      │  Claude는 노이즈 아닌 신호만 봄.           │
      └──────────────────────────────────────────┘
```

### Nexus CIG — 컨텍스트 인텔리전스 게이트웨이

로컬 MCP 서버(`lib/mcp-nexus.mjs`)로 구현. Claude와 모든 시스템 명령 사이에 위치해 출력 유형을 분류하고 컨텍스트 윈도우 진입 전 압축합니다.

| 툴 | 기능 |
|------|-------------|
| `exec(cmd, max_lines)` | 명령 실행 후 압축 출력 반환 |
| `scan(items[])` | 병렬 다중 명령, 단일 응답 |
| `cache_exec(cmd, ttl)` | 캐싱 실행 (기본 30초 TTL) |
| `log_tail(name, lines)` | 로그 이름으로 빠른 접근 |
| `health()` | 단일 호출로 시스템 전체 상태 요약 |
| `file_peek(path, pattern)` | 패턴 인식 부분 파일 읽기 |

JSON → 키 추출 · 로그 → 중복 제거 + 테일 · 프로세스 테이블 → 컬럼 필터링

---

## 슬래시 커맨드

| 커맨드 | 기능 |
|---------|-------------|
| `/search <쿼리>` | RAG 지식베이스 시맨틱 검색 |
| `/status` | 시스템 헬스 + 레이트 리밋 현황 |
| `/tasks` | 크론 태스크 목록 |
| `/run <task_id>` | 크론 태스크 수동 트리거 |
| `/schedule <task_id> <지연시간>` | 지정한 시간 이후에 태스크 실행 예약 |
| `/threads` | 최근 대화 스레드 목록 |
| `/alert <메시지>` | Discord + ntfy 푸시 알림 전송 |
| `/memory` | 현재 세션 메모리 보기 |
| `/remember <텍스트>` | 영구 메모리 항목 저장 |
| `/usage` | 토큰 사용량 + 레이트 리밋 통계 |
| `/clear` | 세션 컨텍스트 초기화 |
| `/stop` | 진행 중인 `claude -p` 프로세스 중단 |

---

## 자가복구 인프라

3개 독립 레이어. 하나가 실패해도 나머지가 보완:

```
레이어 1: launchd  (KeepAlive = true)
  └─ discord-bot.js 종료 시 즉시 자동 재시작

레이어 2: cron */5분  →  bot-watchdog.sh
  ├─ 로그 신선도 확인 (15분 침묵 = 비정상)
  ├─ 멈춘 claude -p 프로세스 종료
  └─ 봇 미응답 시 재시작

레이어 3: cron */3분  →  launchd-guardian.sh
  ├─ 언로드된 LaunchAgent 감지
  └─ 자동 재등록
```

**레이트 리밋:** `state/rate-tracker.json` 공유 — 5시간 900 요청 한도를 봇과 크론이 나눠 씀.

---

## LanceDB 하이브리드 RAG

봇은 모든 것을 기억합니다. 모든 대화 턴, 크론 결과, 컨텍스트 파일이 로컬 LanceDB에 인덱싱:

- **벡터 검색** — OpenAI `text-embedding-3-small` (1536차원)
- **전문 검색** — BM25 키워드 매칭
- **리랭킹** — RRF(Reciprocal Rank Fusion)로 두 신호 결합

RAG 엔진은 매시간 증분 인덱싱. 질문 시 관련 컨텍스트를 `claude -p` 프롬프트에 자동 주입 — 추가 컨텍스트 윈도우 소비 없이.

---

## 파일 구조

```
~/.jarvis/
├── discord/
│   ├── discord-bot.js          # Discord 클라이언트, 슬래시 커맨드
│   ├── locales/
│   │   ├── en.json             # 영어 로케일 문자열
│   │   └── ko.json             # 한국어 로케일 문자열 (기본값)
│   └── lib/
│       ├── i18n.js             # t() — 로케일 로더 (BOT_LOCALE)
│       ├── handlers.js         # handleMessage — 핵심 메시지 로직
│       ├── claude-runner.js    # createClaudeSession() Agent SDK 기반
│       ├── format-pipeline.js  # formatForDiscord() — 8개 출력 변환
│       ├── session.js          # SessionStore, RateTracker, Semaphore
│       └── user-memory.js      # 유저별 영구 메모리 (/remember)
├── bin/
│   ├── ask-claude.sh           # claude -p 래퍼 (RAG + 토큰 격리)
│   ├── bot-cron.sh             # 크론 태스크 러너 (세마포어, 재시도, 라우팅)
│   ├── board-meeting.sh        # Board Meeting CEO 에이전트 (08:10, 21:55)
│   ├── decision-dispatcher.sh  # 결정사항 자동 실행 + 팀 성과 평가
│   └── rag-index.mjs           # 증분 RAG 인덱서
├── lib/
│   ├── rag-engine.mjs          # LanceDB 하이브리드 검색 엔진
│   └── mcp-nexus.mjs           # Nexus CIG MCP 서버
├── config/
│   ├── tasks.json.example      # 3개 시작용 크론 태스크 예시
│   └── monitoring.json.example # 웹훅 라우팅 설정
├── scripts/
│   ├── watchdog.sh             # 봇 헬스 모니터
│   ├── launchd-guardian.sh     # LaunchAgent 자동 복구
│   └── e2e-test.sh             # 43개 E2E 테스트
├── context/                    # 태스크별 배경 지식 파일
├── results/                    # 크론 태스크 결과 이력
├── agents/                    # 팀장 에이전트 프로필 (CEO, Infra Chief 등)
└── state/                      # sessions.json, rate-tracker.json
    ├── team-scorecard.json     # 팀 성과표 (공적/벌점/상태)
    ├── decisions/              # Board Meeting 의사결정 감사 로그
    ├── board-minutes/          # Board Meeting 회의록
    └── dispatch-results/       # 결정 실행 결과 + 크론 분석
```

---

## 플랫폼 참고

| 기능 | macOS (네이티브) | Linux (Docker) |
|---------|---------------|----------------|
| 프로세스 감독 | `launchd` KeepAlive | Docker `restart: always` |
| 워치독 / 가디언 | cron + bash | 동일 (컨테이너 내 실행) |
| 전원 관리 | `pmset` 슬립 비활성화 | 해당 없음 |
| Apple 연동 | Notes, Reminders (선택) | 미지원 |

---

## 기여하기

```bash
# 1. Fork + 클론
git clone https://github.com/YOUR_USERNAME/jarvis

# 2. 변경 작업

# 3. 테스트 실행
bash scripts/e2e-test.sh
# → 43 passed, 0 failed

# 4. Pull Request 제출
```

예정 기능은 [ROADMAP.md](ROADMAP.md) 참조. 현재 완성도: **82%**, 목표: **90%**.

---

## 라이선스

MIT — [LICENSE](LICENSE) 참조

---

<p align="center">
  <a href="README.md">English README →</a>
</p>
