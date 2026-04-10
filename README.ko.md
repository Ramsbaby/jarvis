# Jarvis

<p align="center">
  <strong>24/7 스스로 관리되는 AI 운영 플랫폼</strong><br>
  Discord 봇 + RAG 지식 베이스 + 자동화 인프라
</p>

<p align="center">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">
  <img src="https://img.shields.io/badge/Node.js-18+-green.svg" alt="Node.js">
  <img src="https://img.shields.io/badge/Ollama-Required-orange.svg" alt="Ollama">
  <img src="https://img.shields.io/badge/Privacy-100%25_Local-brightgreen.svg" alt="Privacy">
</p>

<p align="center">
  <img src="docs/img/discord-dev-chat.png" alt="Discord 봇 — 개발자 채팅" width="700">
</p>
<p align="center"><em>Discord 봇: 코드 리뷰 + 인라인 수정 제안</em></p>

<p align="center">
  <img src="docs/img/discord-auto-briefing.png" alt="Discord 봇 — 자동 브리핑" width="700">
</p>
<p align="center"><em>자동화: 일일 AI/Tech 뉴스 브리핑</em></p>

---

## Jarvis가 뭔가요?

**AI 운영 플랫폼** — Claude 기반 Discord 봇, 장기 기억을 위한 RAG 지식 베이스, 110+ 자동 관리 스크립트. 모든 것이 내 컴퓨터에서 로컬로 돌아갑니다.

```
                    ┌─────────────────┐
                    │    사용자 접점    │
                    └────────┬────────┘
                ┌────────────┼────────────┐
                ▼                         ▼
          💬 Discord                🔧 자동화
        텍스트 채팅 24/7           크론 + 에이전트
                │                         │
                └────────────┼────────────┘
                             ▼
               ┌────────────────────────┐
               │     Jarvis Core        │
               │                        │
               │  📚 RAG (LanceDB)      │
               │  🔌 MCP (연동)         │
               │  🤖 멀티 페르소나       │
               └────────────────────────┘
```

| | 기능 | 설명 |
|---|------|------|
| 💬 | **Discord 봇** | 24/7 텍스트 채팅. 스트리밍 응답, 채널별 페르소나, 슬래시 명령어 |
| 📚 | **RAG 지식 베이스** | 장기 기억. LanceDB + Ollama 하이브리드 검색 |
| 🧠 | **인사이트 레이어** | 매일 자동 생성되는 행동 분석 리포트 — 활동 추세, 집중 전환, 상황 맥락 감지 |
| 🔧 | **자가 복구 자동화** | 110+ 스크립트. 자동 복구, 워치독, 새벽 코드 감사, 헬스 모니터링 |
| 🔒 | **100% 로컬** | 클라우드 없음. 구독 없음. 모든 데이터가 내 컴퓨터에 |
| 🔌 | **MCP 연동** | Home Assistant, GitHub, Slack, Notion 등 [MCP 생태계](https://github.com/topics/mcp-server) 연결 |

## 빠른 시작

```bash
git clone https://github.com/Ramsbaby/jarvis.git && cd jarvis
```

### 1단계: RAG — 장기 기억

```bash
python scripts/setup_rag.py
```

> **필요**: [Ollama](https://ollama.com/download), Node.js 18+

### 2단계: Discord 봇 + 자동화

```bash
python scripts/setup_infra.py
```

> **필요**: Node.js 18+, Discord 봇 토큰, Anthropic API 키

## Discord 봇

| 기능 | 설명 |
|------|------|
| **스트리밍** | Claude가 생각하는 동안 실시간 메시지 업데이트 |
| **페르소나** | 채널별 다른 성격 (`personas.json`) |
| **슬래시 명령어** | `/search`, `/memory`, `/status`, `/alert` |
| **RAG 연동** | 지식 베이스 컨텍스트 자동 주입 |
| **가족 모드** | 가족 구성원을 위한 별도 데이터 경계 |

## RAG 지식 베이스 + 인사이트 레이어

두 레이어가 함께 동작합니다 — RAG가 사실을 검색하고, 인사이트 레이어가 맥락을 이해합니다.

```
📊 인사이트 레이어 (매일, ~1.2KB)                📚 RAG 레이어 (쿼리별)
  "커리어 토픽 534배 급증"                          10,000+ 인덱싱된 문서에서
  "인프라에서 면접 준비로 집중 전환"                  시맨틱 검색
              │                                              │
              └──────────────┬───────────────────────────────┘
                             ▼
                    Claude가 사용자의 현재 상황을
                    완전히 파악한 채 응답
```

**인사이트 레이어** — 매일 04:15 자동 생성되는 행동 분석:

| 단계 | 스크립트 | LLM | 비용 |
|------|---------|:---:|:----:|
| 메트릭 수집 | `insight-metrics.mjs` | 불필요 | $0 |
| 해석 | `insight-distill.mjs` | Claude | ~$0.03 |

감지 항목: 토픽 빈도 변화, 도메인 간 상관관계, 엔티티 모멘텀, 일별 활동 패턴.
결과: `~/.jarvis/context/insight-report.md` — 모든 system prompt에 자동 포함.

**RAG** — 하이브리드 검색: BM25 + Ollama 벡터 유사도 (`snowflake-arctic-embed2`, 1024-dim).

자세한 내용: [`rag/README.md`](rag/README.md)

## 자가 복구 자동화

<p align="center">
  <img src="docs/img/discord-system-health.png" alt="시스템 헬스체크" width="700">
</p>
<p align="center"><em>자동 시스템 점검: 10개 서비스를 6시간마다 모니터링</em></p>

<p align="center">
  <img src="docs/img/discord-auto-insight.png" alt="자동 인사이트" width="700">
</p>
<p align="center"><em>AI/Tech 뉴스 분석 + 실행 가능한 dev-queue 제안</em></p>

Jarvis는 실행만 하는 게 아니라 **스스로 복구합니다.** 110+ 스크립트, 11개 LaunchAgent, 40+ 크론 작업:

| | 하는 일 | 주기 |
|---|---|---|
| 🔄 | **자동 복구** — 워치독이 죽은 서비스 감지, 재시작. Guardian이 3분마다 언로드된 데몬 재등록 | 24/7 |
| 🔍 | **새벽 코드 감사** — 크론 상태, RAG 무결성, 봇 상태 스캔. 이상 발견 시 Discord로 알림 | 매일 06:00 |
| 📊 | **인사이트 리포트** — 행동 메트릭(토픽 추세, 엔티티 모멘텀) 분석 → 상황 인식 컨텍스트 생성 | 매일 04:15 |
| 📚 | **RAG 파이프라인** — 증분 인덱싱(4시간), 엔티티 그래프 재구축(03:45), 주간 압축(일요일 04:00) | 스케줄 |
| 📡 | **시스템 헬스** — 10개 서비스 모니터링, 디스크/메모리 알림. 임계값 초과 시 Discord + 푸시 알림 | 6시간마다 |
| 🚀 | **안전 배포** — 스모크 테스트, 무중단 재시작, 로그 로테이션 | 수동 |
| 📰 | **뉴스 브리핑** — AI/Tech 뉴스 큐레이션 + dev-queue 제안 | 매일 |

크론 템플릿: `infra/templates/crontab.example`

## 프로젝트 구조

```
jarvis/
├── rag/                 # RAG 모듈 (LanceDB + Ollama)
├── infra/               # 인프라 & 자동화
│   ├── discord/         # Discord 봇 + 30개 핸들러
│   ├── lib/             # 핵심 라이브러리
│   ├── bin/             # 크론 실행 파일
│   ├── scripts/         # 자동화 스크립트
│   ├── config/          # 설정 템플릿
│   └── templates/       # 크론 & LaunchAgent 템플릿
├── scripts/             # 셋업 위자드
└── docs/img/            # 스크린샷
```

## 라이선스

[MIT](LICENSE)

---

<p align="center">
  <a href="README.md">🇺🇸 English</a>
</p>
