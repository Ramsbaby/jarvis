# Windsurf Memories 스타일 세션 간 컨텍스트 자동 지속 — 설계 문서

_작성일: 2026-03-14_

---

## 1. 현재 세션 관리 구조

```
Discord 메시지 수신
        │
        ▼
handlers.js
  ├─ sessionId 있음? ──YES──► createClaudeSession(prompt, {sessionId, ...})
  │                               └─ isResuming = true
  │                                   └─ 시스템 프롬프트 재주입 (항상)
  │                                   └─ promptVersion 해시 검사 → 불일치 시 세션 강제 리셋
  └─ 없음 ──────────────────► createClaudeSession(prompt, {sessionId:null, ...})
                                  └─ isResuming = false
                                  └─ 전체 시스템 프롬프트 빌드

createClaudeSession 내부 시스템 프롬프트 구성:
  ┌────────────────────────────────────────────────┐
  │ STABLE (해시 계산 대상)                         │
  │  buildIdentitySection()                        │
  │  buildLanguageSection()                        │
  │  buildPersonaSection()                         │
  │  buildPrinciplesSection()                      │
  │  buildFormatSection()                          │
  │  buildToolsSection()                           │
  │  buildSafetySection()                          │
  │  buildUserContextSection()  ← user-profile.md │
  ├────────────────────────────────────────────────┤
  │ DYNAMIC (해시 계산 제외 — 세션 연속성 유지)      │
  │  buildPreplySection()  (조건부)                │
  │  userMemory.getPromptSnippet(userId)  ← ★     │
  │  usageSummary  (80% 초과 시)                   │
  └────────────────────────────────────────────────┘

메모리 저장 경로:
  ~/.jarvis/state/users/{userId}.json
    facts[]        ← string(레거시) 또는 {text, addedAt}
    preferences[]
    corrections[]
    plans[]

  ~/.jarvis/context/discord-history/{date}.md       ← RAG 인덱싱용
  ~/.jarvis/context/discord-history/user-memory-{userId}.md  ← RAG 메모리 마크다운
  ~/.jarvis/state/session-summaries/{threadId}-{userId}.md   ← 세션 대화 기록

메모리 주입 흐름:
  대화 완료 → autoExtractMemory(userId, userMsg, botMsg)
    │  ├─ 10분 쿨다운 + botMsg 150자 이상 조건
    │  ├─ ANTHROPIC_API_KEY 없으면 비활성화 (Claude Max 구독제 환경)
    │  └─ Anthropic API 직접 호출 → JSON 배열 파싱 → userMemory.addFact()
    │       └─ _syncUserMemoryMarkdown() → RAG 인덱싱
    │       └─ _syncOwnerProfileMarkdown() (오너 전용)
    │
    └─ 다음 세션 시작 시: userMemory.getPromptSnippet() → 시스템 프롬프트 DYNAMIC 섹션에 주입
```

---

## 2. 현재 구현 vs. Windsurf Memories 핵심 갭

| 항목 | Windsurf Memories | 현재 Jarvis | 갭 |
|------|------------------|------------|-----|
| 세션 종료 훅 | 대화 종료 시 자동 추출 실행 | autoExtractMemory (fire-and-forget, 쿨다운 10분) | 쿨다운으로 동일 세션 내 반복 대화 시 누락 가능 |
| 메모리 타임스탬프 | 모든 메모리에 생성 시각 | facts[]는 string 배열 (타임스탬프 없음) | **2026-03-14 개선 완료** — {text, addedAt} 형식 도입 |
| 최신 기억 우선 | 최근 N일 우선 주입 | slice(-20) 단순 자르기 | **2026-03-14 개선 완료** — 7일 이내 10개 + 이전 5개 |
| 기억 관련성 필터 | 현재 쿼리와 유사도 계산 후 선택적 주입 | 전체 N개 일괄 주입 | 미구현 (RAG rag_search 도구는 있으나 자동 아님) |
| 세션 요약 | 대화 종료 시 자동 요약 생성 | session-summaries/*.md에 원문 저장 | 구조화 요약 없음 |
| 기억 만료/정리 | 오래된/관련 없는 기억 자동 아카이빙 | 삭제 메커니즘 없음 (계속 축적) | 미구현 |
| Claude Max 환경 | N/A | API 키 없으면 autoExtract 비활성화 | Claude Max 구독제에서 자동 추출 불가 |

---

## 3. Windsurf Memories 완전 구현 3단계 로드맵

### Phase 1: 기억 품질 향상 (즉시~1주, 저위험)

**이미 완료 (2026-03-14):**
- facts에 `{text, addedAt}` 타임스탬프 도입 (`user-memory.js` addFact 수정)
- `getPromptSnippet`: 최근 7일 10개 + 이전 5개 = 최대 15개로 개선
- `_syncUserMemoryMarkdown`: 새 형식 하위 호환 처리

**남은 Phase 1 작업:**
- [ ] `processFeedback`의 correction/remember도 `{text, addedAt}` 형식으로 저장 (10줄)
- [ ] 기억 만료 정책: 90일 이상 + 마지막 언급 없는 facts → `archived_facts[]`로 이동하는 주간 크론 (30줄)
- 예상 작업량: ~40줄 / 위험도: 낮음

### Phase 2: 쿼리 관련성 기반 선택적 주입 (1~2주, 중간 위험)

**목표:** Windsurf처럼 현재 대화 쿼리와 의미적으로 관련된 기억만 시스템 프롬프트에 주입

**구현 방법:**
```
getRelevantMemories(userId, currentPrompt, topN=8)
  ├─ facts 전체 로드
  ├─ 간단한 키워드 오버랩 스코어링 (TF-IDF 불필요, 단순 교집합)
  │    score = (prompt 단어 ∩ fact 단어).size / fact 단어.size
  ├─ 최신성 가중치: 7일 이내 +0.3 보너스
  └─ topN 선택 후 반환
```

- `user-memory.js`에 `getRelevantMemories(userId, prompt, topN)` 추가 (~30줄)
- `claude-runner.js`에서 `getPromptSnippet` 대신 `getRelevantMemories(userId, prompt)` 호출 (~5줄 변경)
- 예상 작업량: ~35줄 / 위험도: 중간 (프롬프트 내용 변화 → 세션 해시 미포함이므로 안전)

### Phase 3: Claude Max 환경 자동 추출 + 세션 요약 (2~4주, 중간 위험)

**문제:** Claude Max 구독제 환경에서 `ANTHROPIC_API_KEY` 없어 `autoExtractMemory` 비활성화됨

**해결 방안 A — SDK 내부 호출로 추출:**
```javascript
// autoExtractMemory에서 Claude Max 환경 감지 시
// 현재 세션 context에서 직접 추출 요청 (별도 API 호출 없음)
// query()에 'extract_memories' 서브태스크로 위임
```
- 구현 난이도: 높음 (SDK query 흐름 변경 필요)
- 예상 작업량: ~80줄 / 위험도: 높음

**해결 방안 B — 세션 종료 시 요약 크론:**
```
bot-cron.sh 매일 새벽 03:00:
  node ~/.jarvis/discord/lib/session-summarizer.mjs
    ├─ 오늘 session-summaries/*.md 읽기
    ├─ 정규식 패턴으로 사실 후보 추출 (날짜, 이름, 금액, 기술명)
    └─ userMemory.addFact() 저장
```
- 구현 난이도: 낮음 (API 호출 없음, 패턴 매칭만)
- 예상 작업량: ~60줄 신규 파일 / 위험도: 낮음
- 단점: 즉각 반영 아님 (다음날 새벽 반영)

**세션 요약 구조화:**
- session-summaries를 현재 원문 저장 → `{turns, summary, extractedFacts, date}` JSON으로 전환
- 예상 작업량: ~50줄 변경 / 위험도: 중간

---

## 4. 아키텍처 다이어그램 (완전 구현 후 목표 상태)

```
Discord 메시지
      │
      ▼
┌─────────────────────┐
│   handlers.js       │
│  (세션 관리)         │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────────────────────┐
│   createClaudeSession()                      │
│                                             │
│  시스템 프롬프트 빌드:                        │
│  [STABLE] 정체성/페르소나/도구/안전           │
│  [DYNAMIC] ← getRelevantMemories(prompt)    │  Phase 2
│             (쿼리 관련 기억 최대 8개)         │
└──────────────────────────────────────────────┘
           │
           ▼ (대화 완료)
┌─────────────────────────────────────────────┐
│   autoExtractMemory()                        │
│   ├─ API Key 있음: Anthropic API 직접        │
│   └─ API Key 없음(Claude Max):               │  Phase 3
│       방안B: 패턴 매칭 크론 (다음날 반영)     │
└──────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────┐
│   userMemory {text, addedAt}[]               │
│   ├─ 7일 이내 10개 우선 주입 (Phase 1 완료)  │
│   ├─ 이전 기억 5개                           │
│   └─ 90일 이상 미언급 → archived (Phase 1)   │
└──────────────────────────────────────────────┘
```

---

## 5. 즉시 확인 가능한 개선 효과

현재 오너 facts 15개 중:
- `"오늘(목요일) 수업 일정: 08:00 minji..."` — 3일 전 데이터, 매일 덮어쓰여야 할 휘발성 정보
- `"오늘 총 수입 $77.49 USD (5건)"` — 같은 문제

Phase 1 개선 완료 후: addedAt 기준 7일 이내가 아닌 이런 항목들은 "이전 기억" 섹션으로 분류되거나, 90일 만료 정책 적용 시 아카이빙됨.

Phase 2 완료 후: "수업 일정" 관련 쿼리가 들어올 때만 해당 기억을 주입, 코딩 관련 쿼리 시에는 제외 → 토큰 효율 향상.
