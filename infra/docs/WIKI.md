# LLM Wiki — Jarvis 지식 축적 시스템

> Karpathy LLM Wiki 3-layer 패턴 기반. Discord봇 + Board + Map 공유 SSoT.

## 개요

기존 RAG(검색 시점 재처리)와 달리, LLM이 **구조화된 마크다운 위키를 직접 작성·유지**하는 패턴.
지식이 복리처럼 축적되고, 매 세션마다 재검색 비용이 감소한다.

```
"Obsidian is the IDE, the LLM is the programmer, the wiki is the codebase"
— Andrej Karpathy
```

## 3-Layer 아키텍처

| Layer | 위치 | 역할 | 쓰기 권한 |
|-------|------|------|-----------|
| **Raw** | session-summaries, user-memory, RAG LanceDB | 원본 소스 (불변) | 기존 시스템 |
| **Wiki** | `~/.jarvis/wiki/` | LLM이 합성한 구조화 지식 | wiki-ingest 크론 |
| **Schema** | `~/.jarvis/wiki/schema.md` | 위키 규칙, 페이지 타입, 워크플로우 | 수동 |

## 디렉토리 구조

```
~/.jarvis/wiki/
├── schema.md          # 위키 규칙 정의
├── index.md           # 전체 페이지 카탈로그 (자동 갱신)
├── log.jsonl          # 변경 이력 (append-only)
├── career/            # 커리어·면접·기술성장
├── trading/           # 투자·TQQQ·시장분석
├── ops/               # 크론·인프라·장애이력
├── knowledge/         # 기술트렌드·아키텍처결정
├── briefings/         # 일일/주간 브리핑
├── family/            # 가족 루틴·일정
├── health/            # 건강·운동
└── meta/              # 위키 자체 관리
```

## Operations

### Ingest (야간 크론, 매일 03:30 KST)
```
session-summaries → 도메인 분류 → 기존 위키 페이지 업데이트 or 신규 생성
user-memory facts → 재분류 → 위키 승격 (promoted 플래그)
index.md 재생성 + log.jsonl 기록
```

### Query (Discord봇 / Board / Map NPC)
```
프롬프트 도메인 감지 → 해당 _summary.md + 관련 페이지 → 최대 2,000자 컨텍스트 주입
```

### Lint (주간, 일요일 04:00 KST)
```
모순 탐지 / 고아 페이지 / confidence 재평가 / decay 처리
```

## 소비자별 연동

| 소비자 | 연동 포인트 | 상태 |
|--------|------------|------|
| Discord봇 | `buildWikiContextSection()` → prompt-sections.js | 계획 |
| Board | `/api/wiki/*` API + CronDetailPopup 확장 | 계획 |
| Map NPC | `gatherTeamContext()` 위키 주입 | 계획 |

## 기존 시스템과의 관계

- **RAG 대체 아님** — RAG는 raw layer, wiki는 curated view
- **user-memory 점진 마이그레이션** — facts → wiki 승격 후 `promoted:true` 플래그
- **session-summary 유지** — wiki-ingest의 입력 소스로 읽기만

## 참고

- [Karpathy LLM Wiki Gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
- [LLM Wiki v2 확장](https://gist.github.com/rohitg00/2067ab416f7bbe447c1977edaaa681e2)
