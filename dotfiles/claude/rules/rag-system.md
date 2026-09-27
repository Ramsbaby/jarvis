---
paths:
  - "**/*rag*"
  - "**/*vector*"
  - "**/*lancedb*"
  - "**/*index*"
  - "**/*embed*"
---

# RAG 시스템 규칙

## RAG DB 보호 정책

> **경고**: RAG DB는 2번 파기된 이력이 있습니다. 아래 규칙을 반드시 준수하세요.

### 파기 근본 원인 (2번 모두 동일 패턴)

`rag-compact` 스크립트와 `cron-fix` 작업이 **동시에 실행**되어 LanceDB 파일에 쓰기 충돌 발생.
- rag-compact: 전체 인덱스 재압축 (장시간 쓰기 잠금)
- cron-fix: rag-watcher가 중단 없이 새 파일 인덱싱 시도 → 충돌 → 인덱스 손상

### compact 전 필수 절차

```bash
# 1. rag-watcher 일시 중단
launchctl unload ~/Library/LaunchAgents/ai.jarvis.rag-watcher.plist

# 2. 백업 생성
cp -r ~/.jarvis/data/lancedb ~/.jarvis/data/lancedb.bak.$(date +%Y%m%d_%H%M%S)

# 3. compact 실행
node ~/.jarvis/scripts/rag-compact.mjs

# 4. rag-watcher 재시작
launchctl load ~/Library/LaunchAgents/ai.jarvis.rag-watcher.plist
```

### cron 수정 시 주의

crontab에서 rag 관련 항목 수정 시, `ai.jarvis.rag-watcher` LaunchAgent를 **먼저 unload** 후 작업하고 완료 후 reload.

---

## 인덱싱 규칙

### LanceDB 설정

- **WAL 모드** 필수: 쓰기 중 충돌 복구 가능성 확보
- 동시 쓰기 금지: rag-watcher와 rag-compact는 절대 동시 실행 불가

### 인덱싱 주기

| 주기 | 작업 | 스크립트 |
|------|------|----------|
| 6시간마다 | 증분 인덱싱 (신규/변경 파일만) | `rag-index.mjs --incremental` |
| 매주 일요일 03:00 | Full compact | `rag-compact.mjs` (rag-watcher 중단 후) |

### index-state.json 체크

인덱싱 작업 전 반드시 상태 확인:

```bash
cat ~/.jarvis/data/index-state.json
# last_indexed, chunk_count, status 확인
# status가 "running"이면 절대 compact 실행 금지
```

> **주의**: `status: "running"` 상태에서 compact를 실행하면 DB 손상 위험 있음.

---

## Serena 코드 탐색 우선 원칙

> **중요**: Serena는 Claude Code CLI에서만 동작합니다. Jarvis Gateway(ask-claude.sh)에서는 MCP 미지원.

### 탐색 우선순위

1. `find_symbol` — 심볼 위치 파악 (함수, 클래스, 변수)
2. `get_symbols_overview` — 파일/모듈 전체 구조 파악
3. `find_referencing_symbols` — 참조 관계 추적
4. 필요한 심볼 본문만 `read_symbol_body` — 전체 파일 Read보다 토큰 ~70% 절약
5. **파일 전체 Read는 최후 수단** — 심볼 탐색으로 해결 안 될 때만

### 프로젝트 설정

- Serena 프로젝트 경로: `~/.jarvis`
- `/mcp-profile coding` 또는 `/mcp-profile jarvis` 활성화 시 사용 가능

```bash
# 심볼 탐색 예시
find_symbol("rag-index", "~/.jarvis/scripts/rag-index.mjs")
get_symbols_overview("~/.jarvis/scripts/")
```

---

## RAG 쿼리 원칙

### 권장 파라미터

```javascript
const results = await ragQuery({
  query: "검색 쿼리",
  chunkSize: 512,        // 권장: 512 토큰
  topK: 5,               // 기본: 5개, 최대: 10개
  metadataFilter: {      // 메타데이터 필터 적극 활용
    source: "특정_파일_또는_도메인",
    date: { $gte: "2026-01-01" }
  }
});
```

### 품질 원칙

- **청크 크기**: 512 토큰 권장 (128 너무 짧음, 1024 컨텍스트 오염)
- **상위 K**: 5-10개 결과 (10개 초과 시 노이즈 증가)
- **메타데이터 필터**: 도메인/날짜로 먼저 좁힌 후 벡터 검색 → 정확도 향상
- **임베딩 모델**: 변경 시 전체 재인덱싱 필수 (모델 버전 index-state.json에 기록)

---

## 향후 업그레이드 경로

단계적으로 진행. 이전 단계 안정화 후 다음 단계 진행.

```
1단계 (현재): Dense Vector 검색 (LanceDB + 임베딩)
     ↓
2단계: Hybrid 검색 — BM25(키워드) + Dense(벡터) 결합
     ↓
3단계: ColBERT 재랭킹 — 상위 결과를 정밀 재정렬
     ↓
4단계: HyDE — 가상 문서 생성 후 유사 문서 검색
     ↓
5단계: GraphRAG — 엔티티 관계 그래프 기반 검색
```

> **5단계 주의 (2026-09-27)**: 동시출현 그래프를 검색 결과에 자동으로 덧붙이던 옛 구현은 효과 0(질의 16개 중 0개 변화)이라 걷어냈다.
> 다시 들일 때는 검색에 섞지 말고 **AI가 따로 부르는 도구**로 준다 — 관계(누가 누구를)를 저장하고, 여러 단계를 따라가야 하는 질문이 실제로 실패할 때만.

> **참고**: 각 단계 업그레이드 전 반드시 현재 DB 백업 + rag-watcher 중단 절차 준수.
