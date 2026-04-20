# Jarvis

> **⚠️ 마이그레이션 공지 (2026-04-17)**: 런타임 데이터 위치 변경 `~/.jarvis/` → `~/jarvis/runtime/`.
> 기존 설치: `~/.jarvis` 는 **2026-10-17까지** 호환성 심링크로 유지.
> 신규 설치: `~/jarvis/runtime/` 직접 사용. [docs/A2-MIGRATION.md](infra/docs/A2-MIGRATION.md) (작성 예정).

<p align="center">
  <strong>24/7 스스로 관리되는 AI 운영 플랫폼</strong><br>
  Discord 봇 + RAG 지식 베이스 + 인사이트 레이어 + 자가 복구 자동화
</p>

<p align="center">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">
  <img src="https://img.shields.io/badge/Node.js-18+-green.svg" alt="Node.js">
  <img src="https://img.shields.io/badge/Ollama-Required-orange.svg" alt="Ollama">
  <img src="https://img.shields.io/badge/Privacy-100%25_Local-brightgreen.svg" alt="Privacy">
</p>

<p align="center">
  <img src="docs/img/jarvis-demo-chat-ko.png" alt="Jarvis — AI 행동 분석 대화 + 인사이트 리포트" width="700">
</p>
<p align="center"><em>자비스에게 물어보면 행동 패턴을 분석해서 응답 + 매일 자동 생성되는 인사이트 리포트</em></p>

<p align="center">
  <img src="docs/img/jarvis-demo-system-ko.png" alt="Jarvis — 시스템 점검 + 승인 워크플로우" width="700">
</p>
<p align="center"><em>새벽 자동 시스템 점검 (10개 서비스) + L3 자율 작업 승인 워크플로우</em></p>

---

## Jarvis가 뭔가요?

> **"자는 동안에도 시스템을 점검하고, 뉴스를 분석하고, 코드를 짜는 AI 비서."**

Discord에 말 걸면 대화하고, 음성 메시지를 보내면 알아듣고, 파일을 던지면 기억합니다.
밤새 크론이 99개 자동화 스크립트를 돌리고, 서비스가 죽으면 3분 안에 스스로 복구합니다.
매일 새벽 당신의 행동 패턴을 분석해서 "지금 뭐에 집중하고 있는지" 파악한 채로 응답합니다.
API 과금 없이 Claude 구독만으로 돌아갑니다. 데이터는 100% 내 컴퓨터에.

**한 마디로**: 나만을 위한 AI 운영 플랫폼. 24시간 돌아가고, 부서지면 고치고, 쓸수록 똑똑해집니다.

### 구조

| 계층 | 구성 | 역할 |
|:---:|------|------|
| **접점** | Discord (텍스트 + 음성) | 24/7 대화 인터페이스. 16+ 슬래시 커맨드, 버튼, 음성 인식 |
| **두뇌** | Claude + 8개 AI 에이전트 팀 | 대화, 분석, 코드 작성, 의사결정 |
| **하네스** | Prompt Harness + Progressive Compaction + Session Handoff | 계층형 프롬프트 로딩 (토큰 77% 절약), 3단계 컨텍스트 관리 (40K/60K/80K), 세션 간 구조화된 상태 전달 |
| **기억** | RAG (LanceDB) + **LLM Wiki** + 인사이트 레이어 + **중요도 게이트** | 10,000+ 문서 검색 + Stateful 위키 + 행동 메트릭 + Mem0 패턴 점수 기반 필터링 (score ≥ 3만 저장) |
| **방어** | BoundedMap + Error Ledger + API Semaphore + Failure Rule Engine | 메모리 누수 방지, 에러 원장, API 동시 호출 보호, 실패 패턴 자동 학습 |
| **자동화** | 99 스크립트 + 40+ 크론 (macOS: LaunchAgent, Linux: PM2) | 자가 복구, 새벽 감사, 뉴스 브리핑, 코드 자동 실행 |
| **연동** | MCP + Google Calendar + GitHub | 외부 서비스 통합 |

## 핵심 기능

| | 기능 | 설명 |
|---|------|------|
| 💬 | **Discord 봇** | 24/7 채팅. 스트리밍 응답, 음성 인식(Whisper STT), 채널별 페르소나, 16+ 슬래시 커맨드 |
| 👥 | **멀티유저** | 유저별 격리된 메모리, 페어링 코드로 신규 유저 등록, 가족 모드(프라이버시 경계) |
| 📚 | **RAG 지식 베이스** | 장기 기억. BM25 + 벡터 하이브리드 검색, 10,000+ 문서 |
| 🗂️ | **LLM Wiki** | [Karpathy 3-layer 패턴](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) (Raw/Wiki/Schema) 기반. 4개 인제스트 경로: 실시간 키워드 라우팅, 백그라운드 LLM 소화(Haiku), 야간 배치 합성(03:30), 주간 린트(일요일 04:00). 도메인 위키(`career`/`trading`/`ops`/`knowledge`) + 사용자별 페이지. Discord봇·Board API·Map NPC가 위키를 참조. 지식이 복리로 축적 — 새 정보가 기존 페이지를 업데이트 |
| 🧠 | **인사이트 레이어** | 매일 자동 생성되는 행동 분석 리포트 — 활동 추세, 집중 전환, 상황 맥락 감지 |
| 📋 | **Dev-Queue** | AI가 추출한 작업 항목을 자동 큐잉 → `jarvis-coder.sh`가 자동 실행 — 손 안 대고 개발 |
| 🤖 | **8개 AI 팀** | Council, Infra, Record, Brand, Career, Academy, Trend, Recon — 전문 에이전트 |
| 🔧 | **자가 복구** | 워치독 자동 재시작, LaunchAgent 가디언(3분), 새벽 코드 감사, 크론 실패 추적 |
| 🏗️ | **프롬프트 하네스** | [Anthropic 하네스 엔지니어링](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — Tier 0(핵심, 항상 <3KB) / Tier 1(맥락적, 키워드 트리거). Progressive Compaction 40K/60K/80K 3단계. 시스템 프롬프트 77% 감소 |
| 🛡️ | **방어 레이어** | BoundedMap(메모리 누수 방지), Error Ledger(JSONL 에러 원장), API Semaphore(동시 호출 보호), Failure Rule Engine(실패 패턴 자동 학습), Symlink Health Check(매시간 검증) |
| 📢 | **알림 포맷터** | 크론 메시지에 자동 헤더(`> 🟢/🟡/🔴 태스크명 · HH:MM KST`), 노이즈 게이트(순수 성공 전송 생략), 심각도 기반 Discord Embed(Uptime Kuma 패턴) |
| 🔒 | **100% 로컬** | 클라우드 없음. 구독 없음. 모든 데이터가 내 컴퓨터에 |
| 🔌 | **MCP 연동** | Home Assistant, GitHub, Slack, Notion 등 [MCP 생태계](https://github.com/topics/mcp-server) |

## 다른 AI 메모리 시스템과 비교

|  | **Jarvis** | **Claude Memory** | **ChatGPT Memory** | **[OpenClaw](https://docs.openclaw.ai) Dreaming** |
|---|:---:|:---:|:---:|:---:|
| **메모리 구조** | RAG + **LLM Wiki** + 인사이트 레이어 (메트릭 기반) | 파일 기반 (CLAUDE.md + Auto Dream) | 전량 주입 (모든 메모리를 매번 로드) | 3단계 수면 사이클 (Light → REM → Deep) |
| **트렌드 감지** | O (토픽 빈도 변화, 엔티티 모멘텀) | X | X | O (REM 단계에서 패턴 추출) |
| **자동화/크론** | 99 스크립트 + 자가 복구 | X (CLI 도구) | X | 크론 1개 (dreaming sweep) |
| **자율 코딩** | O (Dev-Queue → jarvis-coder) | X | X | X |
| **멀티유저** | O (격리 메모리 + 가족 모드) | X (단일 사용자) | X (단일 사용자) | X (단일 에이전트) |
| **비용** | $0 (Claude 구독 내) | $0 (구독 포함) | $0 (무료 포함) | $0 (오픈소스) |
| **데이터 위치** | 100% 로컬 | 로컬 (CLI) / 클라우드 (웹) | 클라우드 (OpenAI 서버) | 로컬 |
| **인터페이스** | Discord (텍스트 + 음성) | 터미널 / 웹 | 웹 / 앱 | 터미널 / 웹 |

**Jarvis가 다른 점**: 단순히 기억하는 게 아니라 **행동한다**. 기억 + 분석 + 자동화 + 자가 복구가 하나의 시스템. 다른 도구들은 메모리 레이어에 머물지만, Jarvis는 메모리를 기반으로 코드를 짜고, 서비스를 복구하고, 리포트를 만든다.

## 플랫폼 지원

| 플랫폼 | 상태 | 서비스 관리 |
|--------|:----:|------------|
| **macOS** (주 환경) | 완전 지원 | LaunchAgents + cron |
| **Linux / WSL2** | 완전 지원 | PM2 + cron |
| **Docker** | 완전 지원 | PM2 (`ecosystem.config.cjs`) |
| **Windows (네이티브)** | 미지원 | WSL2 또는 Docker 사용 |

> 크로스플랫폼 추상화: `lib/compat.sh`가 OS를 자동 감지하여 서비스 명령을 라우팅 (macOS: `launchctl`, Linux/WSL2: `pm2`).

## 빠른 시작

### 어떤 구성을 선택할까?

| 구성 | 기능 | AI 요구사항 | 비용 |
|------|------|-----------|------|
| **표준** | Discord 봇 + 80개 크론 자동화 | Claude Max 또는 Pro 구독 | $20/월(Pro) 또는 $100/월(Max) |
| **풀** | 표준 + RAG 장기 기억 | Claude 구독 + Ollama (무료, 로컬) | 동일 + 0 |

> **Claude Max** = 무제한, 24/7 봇 운영에 최적. **Claude Pro** = 정상 작동하나 사용량 많으면 제한 걸릴 수 있음.
> **Ollama** = 무료 오픈소스 AI, 로컬에서 실행. RAG(문서 검색 + 기억) 전용. 봇 자체는 Claude로 동작.

---

### 0단계: 사전 준비

1. **Claude Code CLI** (두뇌)
   ```bash
   npm install -g @anthropic-ai/claude-code
   claude   # 브라우저가 열리면 Anthropic 계정으로 로그인
   ```
2. **Node.js 22+** 와 **Python 3.10+**
   ```bash
   node -v   # 22 이상이어야 함
   python3 --version
   ```

### 1단계: Discord 봇 토큰 발급

> 이미 토큰이 있으면 2단계로 건너뛰세요.

1. [Discord 개발자 포털](https://discord.com/developers/applications) 접속
2. **"New Application"** 클릭 → 이름 입력 (예: "Jarvis") → **Create**
3. 왼쪽 메뉴 → **"Bot"** 탭 → **"Reset Token"** 클릭 → **토큰 복사** (저장해두세요!)
4. 아래로 스크롤 → **"Message Content Intent"** 토글 ON → Save
5. 왼쪽 메뉴 → **"OAuth2"** → **"URL Generator"**:
   - Scopes: `bot`, `applications.commands`
   - Bot permissions: `Send Messages`, `Read Message History`, `Attach Files`, `Use Slash Commands`
6. 생성된 URL 복사 → 브라우저에서 열기 → 봇을 내 Discord 서버에 초대

### 2단계: 클론 & 셋업

```bash
git clone https://github.com/Ramsbaby/jarvis.git && cd jarvis
python scripts/setup_infra.py    # Discord 토큰 입력하라고 나오면 1단계에서 복사한 것 붙여넣기
```

셋업 마법사가 자동으로:
- Node.js 확인, 데이터 디렉토리 생성
- **Discord 봇 토큰** 입력 요청 (1단계에서 복사한 것)
- 의존성 설치 및 봇 설정

> **상세 가이드**: [`infra/CLAUDE-SETUP-GUIDE.md`](infra/CLAUDE-SETUP-GUIDE.md) — MCP 서버, 페르소나, 컨텍스트 설정, 문제 해결

### 3단계: RAG — 장기 기억 (선택, 권장)

자비스가 과거 대화와 문서를 검색할 수 있게 해줍니다.

```bash
# 먼저 Ollama 설치 (무료, 로컬 AI — 임베딩 전용)
# macOS:
brew install ollama && ollama serve

# Linux:
curl -fsSL https://ollama.com/install.sh | sh && ollama serve

# RAG 셋업 실행:
python scripts/setup_rag.py    # ~400MB 임베딩 모델 다운로드, 2-5분 소요
```

### 플랫폼별 시작

**macOS** — LaunchAgent로 자동 시작 (setup_infra.py가 설정함)

**WSL2 / Linux** — PM2 사용:
```bash
npm install -g pm2
pm2 start infra/ecosystem.config.cjs
pm2 startup && pm2 save   # 부팅 시 자동 시작
```

## Discord 봇

Claude 기반 24/7 인터페이스.

### 슬래시 커맨드

| 커맨드 | 설명 |
|--------|------|
| `/search <쿼리>` | RAG 하이브리드 검색 |
| `/remember <내용>` | 장기 기억에 저장 (자동 분류: 투자/업무/가족/여행/건강) |
| `/memory` | 저장된 사실, 선호도, 수정사항 조회 |
| `/team <이름>` | AI 팀 소환 (Council/Infra/Career/Academy/Trend/Recon...) |
| `/run <작업>` | 크론 작업 수동 실행 (자동완성) |
| `/schedule <작업> <후>` | 30분/1시간/2시간/4시간/8시간 후 실행 예약 |
| `/status` | 시스템 상태 대시보드 (디스크/메모리/크론) |
| `/doctor` | 전체 점검 + 자동 수정 (오너 전용) |
| `/approve [초안]` | 문서 초안 승인 → 자동 적용 |
| `/commitments` | 자비스가 감지한 미이행 약속 목록 |
| `/usage` | API 비용 & 사용량 대시보드 |
| `/alert <메시지>` | Discord + 푸시 알림 (ntfy.sh) |
| `/lounge` | 실행 중인 작업 라이브 피드 |

### 음성 인식

Discord 음성 메시지를 **OpenAI Whisper** (한국어 + 다국어)로 자동 변환. 변환된 텍스트는 RAG 컨텍스트와 함께 Claude가 처리합니다. 자연스럽게 말하면 AI가 응답합니다.

### 파일 업로드 → 자동 인덱싱

Discord에 파일을 드롭하면 자동으로 RAG에 인덱싱됩니다. 채팅하면서 지식 베이스가 자동으로 커집니다.

### 자동 메모리 추출

자비스가 대화에서 중요한 정보를 자동 감지하여 장기 메모리에 추출 — 선호도, 사실, 수정사항. `/remember` 수동 입력 불필요.

### 인터랙티브 버튼

모든 응답에 상황별 액션 버튼:
- **Cancel** — 진행 중인 작업 중단
- **Regen** — 마지막 쿼리 재실행
- **Summarize** — 응답 요약
- **Approve / Reject** — L3 자율 작업 승인 워크플로우

### 멀티유저 & 가족 모드

- 각 Discord 유저는 **격리된 메모리** (사실, 선호도, 수정사항, 계획)
- 신규 유저는 **페어링 코드**로 등록 (6자리, 10분 TTL, 오너 승인)
- **가족 채널**에서는 오너의 개인 데이터(설정 가능한 민감 도메인) 자동 필터링
- 채널별 **페르소나** — 채널마다 다른 성격 (`personas.json`)
- **메시지 디바운싱** — 연속 메시지를 묶어서(1.5초) 단일 Claude 호출

## 메모리 아키텍처

세 레이어가 함께 동작 — LLM Wiki가 구조화된 지식을 축적하고, RAG가 원본 컨텍스트를 검색하며, 인사이트 레이어가 행동 패턴을 이해합니다.

```
🗂️  LLM Wiki (매일 소화)              📚 RAG 레이어 (쿼리별)           📊 인사이트 레이어 (매일)
  profile.md / work.md /               10,000+ 문서에서                  "특정 토픽 빈도 변화 감지"
  trading.md / projects.md             시맨틱 검색                        "도메인 집중 전환 감지"
  (Stateful — 페이지가 업데이트됨,              │                                   │
   단순 추가가 아님)                           │                                   │
              │                               │                                   │
              └───────────────┬───────────────┘───────────────────────────────────┘
                              ▼
                     Claude가 현재 상황을 파악한 채 응답
```

### LLM Wiki

[Andrej Karpathy의 LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)에서 영감받아 구현. 대화 세션을 **Stateful하고 복리로 축적되는 지식 베이스**로 변환합니다.

| | 전통 RAG | LLM Wiki |
|---|---|---|
| **저장 방식** | 원본 텍스트 청크 | 구조화된 `.md` 위키 페이지 |
| **상태** | Stateless (매 쿼리 재검색) | Stateful (페이지가 업데이트됨) |
| **처리 방식** | 인덱스 → 검색 | Claude Haiku 소화 → 기존 페이지 통합 |
| **지식 성장** | 독립적 누적 | 복리 — 새 정보가 기존 지식을 업데이트 |

**7개 위키 카테고리** (`~/.jarvis/wiki/pages/{userId}/`):

| 페이지 | 저장 내용 |
|--------|----------|
| `profile.md` | 이름, 직업, 가족 기본 정보 |
| `work.md` | 기술 스택, 업무 컨텍스트, 전문 목표 |
| `trading.md` | 포트폴리오, 투자 전략, 관심 종목 |
| `projects.md` | 진행 중인 프로젝트 (Jarvis 봇, 사이드 프로젝트) |
| `preferences.md` | 습관, 선호도, 루틴 |
| `health.md` | 운동, 건강, 수면 패턴 |
| `travel.md` | 여행 기록 및 계획 |

**작동 방식**: 매일 새벽 3시, session-summarizer가 오늘 대화를 Claude Haiku로 소화 → 적절한 위키 페이지에 라우팅 → 기존 내용과 병합 업데이트 → 다음 세션 시스템 프롬프트에 위키 컨텍스트 주입.

### RAG 지식 베이스 + 인사이트 레이어

두 추가 레이어 — RAG가 원본 사실을 검색하고, 인사이트 레이어가 맥락을 이해합니다.

```
📊 인사이트 레이어 (매일, ~1.2KB)                📚 RAG 레이어 (쿼리별)
  "특정 토픽 빈도 변화 감지"                        10,000+ 문서에서
  "도메인 집중 전환 감지"                           시맨틱 검색
              │                                              │
              └──────────────┬───────────────────────────────┘
                             ▼
                    Claude가 현재 상황을 파악한 채 응답
```

### 인사이트 레이어

매일 04:15 자동 생성되는 행동 분석:

| 단계 | 스크립트 | LLM | 비용 |
|------|---------|:---:|:----:|
| 메트릭 수집 | `insight-metrics.mjs` | 불필요 | $0 |
| 해석 | `insight-distill.mjs` | Claude | ~$0.03 |

감지 항목: 토픽 빈도 변화, 도메인 간 상관관계, 엔티티 모멘텀, 일별 활동 패턴. Google Calendar 연동으로 D-day 인식.

### RAG

BM25 + Ollama 벡터 하이브리드 검색 (`snowflake-arctic-embed2`, 1024-dim).

| 사양 | 값 |
|------|------|
| **벡터 DB** | LanceDB (로컬, 임베디드) |
| **인덱싱** | 증분 4시간, 엔티티 그래프 매일 |
| **검색** | BM25 + 벡터 하이브리드 (RRF k=60) + GraphRAG 확장 |
| **스마트 필터** | 개발 문서 자동 제외, 가족 채널 민감 데이터 필터링 |

자세한 내용: [`rag/README.md`](rag/README.md)

## Dev-Queue — 자율 개발

자비스는 채팅만 하지 않습니다 — **코드도 짭니다**.

1. **인사이트 추출기**가 작업 결과와 뉴스를 분석, 우선순위 높은 액션 아이템을 자동 추출
2. **SQLite 태스크 스토어**에 FSM 상태 추적으로 큐잉 (PENDING → RUNNING → SUCCESS/FAILED)
3. **`jarvis-coder.sh`**가 대기 중인 작업을 Claude로 실행 — 자동 커밋, 수정, 개선
4. 재귀 자기 수정 방지 패턴 (수동 작업, 자기 참조 항목 필터링)

## 자가 복구 자동화

<p align="center">
  <img src="docs/img/discord-system-health.png" alt="시스템 헬스체크" width="700">
</p>
<p align="center"><em>자동 시스템 점검: 10개 서비스를 6시간마다 모니터링</em></p>

Jarvis는 실행만 하지 않습니다 — **스스로 복구합니다.** 99개 스크립트, 11개 LaunchAgent, 40+ 크론, 4층 자가 복구 (`bot-heal` → `process-recovery` → `cron-auditor` → `auto-diagnose`):

| | 하는 일 | 주기 |
|---|---|---|
| 🔄 | **자동 복구** — 워치독이 죽은 서비스 감지, 재시작. Guardian이 3분마다 언로드된 데몬 재등록 | 24/7 |
| 🔍 | **새벽 감사** — 크론 상태, RAG 무결성, 봇 상태 스캔. `jarvis-auditor.sh` + `scorecard-enforcer.sh`로 이상 보고 | 매일 06:00 |
| 📊 | **인사이트 리포트** — 행동 메트릭 분석 → 모든 응답에 상황 인식 컨텍스트 주입 | 매일 04:15 |
| 🧪 | **E2E 테스트** — `e2e-test.sh`로 50개 시스템 컴포넌트 검증. `weekly-code-review.sh`로 코드 품질 감사 | 주간 |
| 📚 | **RAG 파이프라인** — 증분 인덱싱(4h), 엔티티 그래프(03:45), 주간 압축(일 04:00), 파일 워처로 실시간 감지 | 스케줄 |
| 📡 | **헬스 모니터** — 10개 서비스, 디스크/메모리 알림. Discord + ntfy.sh 푸시 | 6시간마다 |
| 📈 | **크론 실패 추적** — 성공률 추적, 성능 저하 추세 감지 | 상시 |
| 🚀 | **안전 배포** — 스모크 테스트, 무중단 재시작, 로그 로테이션 | 수동 |
| 📰 | **뉴스 브리핑** — AI/Tech 뉴스 큐레이션 + dev-queue 제안 | 매일 |

### 8개 AI 에이전트 팀

`/team <이름>`으로 전문 팀 소환:

| 팀 | 역할 |
|----|------|
| **Council** | CEO급 시스템 리뷰 — 안정성 + 시장 + OKR 의사결정 |
| **Infra** | 인프라 책임자 — 크론/LaunchAgent/디스크/메모리 감사 |
| **Record** | 회의록 + 의사결정 감사 로그 |
| **Brand** | 블로그 콘텐츠 + 포트폴리오 관리 |
| **Career** | 전문 성장 + 학습 계획 |
| **Academy** | 학습 계획 + 스킬 개발 |
| **Trend** | 시장 시그널 + 기술 트렌드 분석 |
| **Recon** | 정찰 — 경쟁사 인텔리전스 |

### Board Meeting AI

자동화된 경영 회의 시스템. 4개 AI 에이전트가 매일 회의:

| 에이전트 | 역할 |
|---------|------|
| **CEO** | 최종 의사결정 — 시스템 안정성 + 시장 + OKR 진척 |
| **Infra Chief** | 가동률, 에러율, 성능 지표 |
| **Strategy Advisor** | 시장 시그널, 투자 분석, 전략 기획 |
| **Record Keeper** | 회의록, 의사결정 감사 로그 |

산출물: `context-bus.md` (공유 컨텍스트) + `decisions/{날짜}.jsonl` + `board-minutes/{날짜}.md`

### 스마트 기능

| 기능 | 설명 |
|------|------|
| **제로 비용 자동화** | 모든 크론 작업이 `claude -p` (구독)로 실행 — 토큰당 과금 없음 |
| **약속 추적** | Claude 응답에서 약속 자동 감지, 이행 추적 |
| **L3 승인 워크플로우** | 자율 작업이 Discord 버튼으로 인간 승인 요청 (24시간 TTL) |
| **컨텍스트 버짓** | 프롬프트 복잡도 자동 분류, 사고 깊이 조절 |
| **비주얼 생성** | 차트(ChartJS) + 테이블(Puppeteer) → 이미지 렌더링, SHA256 캐시 |
| **통계 카드** | "디스크?", "RAG 상태?" → 비주얼 임베드 카드 자동 생성 |
| **Langfuse 관측성** | 프롬프트 추적, 비용 모니터링, 에러율, 레이턴시 |
| **레이트 리미팅** | 유저별 토큰 버짓 + 세마포어 동시 제어 (최대 3) |
| **다국어** | 한국어 + 다국어 지원 |

## 프로젝트 구조

```
jarvis/
├── rag/                 # RAG 모듈 (LanceDB + Ollama + 인사이트 레이어)
│   ├── lib/             # 코어 엔진, 쿼리, 경로
│   └── bin/             # 인덱서, 메트릭, 디스틸러, 수리
├── infra/               # 인프라 & 자동화
│   ├── discord/         # Discord 봇 + 30개 핸들러
│   │   └── lib/
│   │       ├── wiki-engine.mjs    # LLM Wiki CRUD + 7개 카테고리 스키마
│   │       └── wiki-ingester.mjs  # Claude Haiku 세션 소화 파이프라인
│   ├── lib/             # 핵심 라이브러리 (MCP, task-store, insight-extractor)
│   ├── bin/             # 크론 실행 (jarvis-cron, jarvis-coder, bot-cron)
│   ├── scripts/         # 감사, E2E 테스트, 코드 리뷰, 배포
│   ├── config/          # 작업, 페르소나, 채널, 모니터링
│   ├── agents/          # 8개 AI 팀 프로필
│   └── templates/       # 크론 & LaunchAgent 템플릿
├── scripts/             # 셋업 위자드
└── docs/img/            # 스크린샷
```

**런타임 위키 저장 경로** (`~/.jarvis/wiki/`):
```
~/.jarvis/wiki/
  schema.json            # 위키 구조 규칙
  pages/{userId}/
    profile.md / work.md / trading.md / projects.md
    preferences.md / health.md / travel.md
```

<details>
<summary><strong>보안</strong></summary>

- **gitleaks** 프리커밋 훅으로 매 커밋 전 시크릿 스캔
- **`private/`** 디렉토리 git 제외 (민감 데이터)
- 가족 채널 프라이버시 경계 (오너 데이터 필터링)
- TTL 페어링 코드로 신규 유저 온보딩

</details>

<details>
<summary><strong>트러블슈팅</strong></summary>

- **Discord 봇 안 뜸** — `.env`에 `DISCORD_TOKEN` 확인
- **RAG 결과 없음** — `cd rag && npm run stats`로 DB 상태 확인
- **크론 안 돌아감** — `crontab -l` 확인, 로그: `~/.local/share/jarvis/logs/`
- **인사이트 리포트 없음** — `BOT_HOME=~/.jarvis node rag/bin/insight-distill.mjs`

</details>

## 라이선스

[MIT](LICENSE)

---

<p align="center">
  <a href="README.md">🇺🇸 English</a>
</p>
