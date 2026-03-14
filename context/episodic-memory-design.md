# 에피소딕 메모리 레이어 설계 (LanceDB 기반, mem0ai 없이)

_작성: 2026-03-14_

## 현황 분석

### mem0ai 설치 여부
`package.json`에 `mem0ai` 없음 → 미설치. 설치 없이 현재 스택으로 구현.

### 현재 메모리 저장 흐름 (이미 동작 중)
```
대화 발생
  ↓
saveConversationTurn()  → discord-history/YYYY-MM-DD.md  (대화 이력)
autoExtractMemory()     → userMemory.addFact()
                          → _syncUserMemoryMarkdown()
                            → discord-history/user-memory-{userId}.md  (추출 사실)
rag-watch.mjs           → 두 파일 모두 LanceDB에 자동 인덱싱 (inotify watch)
```

### 현재 검색 흐름 (`execRagAsync`)
```
execRagAsync(query)
  → lib/rag-query.mjs 별도 프로세스
  → RAGEngine.search(query, limit=5)
  → BM25 + vector hybrid 검색 (전체 소스 대상)
  → 대화 이력 포함되지만 일반 문서와 동일 가중치
```

### 핵심 갭 (Gap)
1. **소스 우선순위 없음**: discord-history의 에피소딕 정보가 일반 문서에 묻힘
2. **시간 감쇠 없음**: 오래된 대화 기록이 최근 기억과 동등하게 취급됨
3. **사용자별 격리 없음**: 다른 사용자의 대화가 함께 검색됨

---

## 즉시 구현 가능한 경량 대안

### Option A: source 필터링으로 에피소딕 우선 검색 (30줄 이내, 즉시 구현 가능)

`rag-query.mjs`에 `--episodic` 플래그 추가:
- `source LIKE '%discord-history%'` 조건으로 LanceDB 쿼리 필터링
- `execRagAsync(query, { episodic: true })`로 호출 시 대화 이력만 검색
- 일반 검색 결과에 에피소딕 결과 prepend

### Option B: 에피소딕 2-phase 검색 (현재 구조 최소 수정)

`createClaudeSession()` 내에서 RAG 주입 시:
1. Phase 1: `episodic` 검색 → `discord-history/user-memory-{userId}.md` 소스만
2. Phase 2: 일반 RAG 검색
3. 합산 후 시스템 프롬프트에 주입

### Option C: rag-watch에 에피소딕 테이블 분리 (중간 규모 변경)
- LanceDB에 `episodic` 테이블 별도 생성
- `discord-history/*.md` → episodic 테이블
- `source = 'discord-history'` 라벨로 검색 시 우선 조회
- **단점**: rag-engine.mjs TABLE_NAME 상수 변경 필요, 마이그레이션 비용

---

## 추천 구현 방향

### 즉시 실행: Option A (소스 필터)

**rag-query.mjs** 수정 포인트:
```js
// 인자: node rag-query.mjs "쿼리" [--episodic] [--user-id <id>]
const isEpisodic = process.argv.includes('--episodic');
const userIdArg = process.argv[process.argv.indexOf('--user-id') + 1];

// episodic 모드: discord-history 소스만 검색
if (isEpisodic) {
  results = await engine.table
    .query()
    .fullTextSearch(query, { columns: ['text'] })
    .where(`source LIKE '%discord-history%'`)
    .limit(10)
    .toArray();
}
```

**claude-runner.js** `execRagAsync` 수정:
```js
export async function execRagAsync(query, opts = {}) {
  const args = [join(BOT_HOME, 'lib', 'rag-query.mjs'), query];
  if (opts.episodic) args.push('--episodic');
  if (opts.userId) args.push('--user-id', opts.userId);
  // ... 기존 execFile 로직
}
```

**createClaudeSession** 내 주입 로직:
```js
// 에피소딕 메모리 먼저 검색 (사용자 개인 대화 이력)
if (userId) {
  const episodicCtx = await execRagAsync(prompt, { episodic: true, userId });
  if (episodicCtx) systemParts.push('', '--- 관련 대화 기억 ---', episodicCtx);
}
// 일반 RAG 검색 (기존)
const ragCtx = ragContext || await execRagAsync(prompt);
```

---

## 미래 확장 (mem0ai 도입 시)

mem0ai는 내부적으로:
1. LLM으로 사실 추출 (현재 autoExtractMemory와 동일)
2. 벡터 DB에 저장 (현재 LanceDB와 동일)
3. 유사도 검색으로 메모리 조회 (현재 execRagAsync와 동일)

→ **현재 구조가 이미 mem0ai의 핵심 기능을 직접 구현하고 있음**.
mem0ai 추가 가치는 자동 중복 제거(deduplication)와 메모리 업데이트(CRUD) 뿐.
이 두 기능이 필요해질 때 점진적 도입 검토.

---

## 파일 맵

| 역할 | 파일 경로 |
|------|-----------|
| RAG 검색 | `/Users/ramsbaby/.jarvis/lib/rag-query.mjs` |
| RAG 엔진 | `/Users/ramsbaby/.jarvis/lib/rag-engine.mjs` |
| 메모리 추출/저장 | `/Users/ramsbaby/.jarvis/discord/lib/claude-runner.js` |
| 파일 감시→인덱싱 | `/Users/ramsbaby/.jarvis/lib/rag-watch.mjs` |
| 에피소딕 소스 디렉토리 | `/Users/ramsbaby/.jarvis/context/discord-history/` |
