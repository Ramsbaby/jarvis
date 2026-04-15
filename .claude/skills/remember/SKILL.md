---
name: remember
description: |
  오너가 방금 말한/확정한 사실을 Jarvis 위키(`~/.jarvis/wiki/`)에 즉시 주입합니다.
  디스코드·Claude Code CLI·macOS 앱 어디서 호출하든 동일한 뇌에 쌓이며, source 태그로
  호출 표면이 자동 구분됩니다. 오너의 명시적 "기억해" 요청이나 대화 중 확정된
  사실·결정·선호를 즉시 영속시킬 때 사용합니다.
argument-hint: <기억할 사실> (생략 시 최근 대화에서 핵심 사실 자동 추출)
---

# 🧠 /remember — 표면 통합 기억 주입

**핵심**: 자비스는 **뇌 하나**다. 디스코드/CLI/macOS 앱은 그 뇌의 여러 입·출력 단말일 뿐.
이 스킬은 **쓰기(write) 대칭**을 담당한다. 읽기는 이미 `rag_search` / `get_memory` /
`get_wiki_context` 등으로 표면 무관하게 동일.

---

## 사용 모드

### 모드 A — 명시적 사실 (`$ARGUMENTS` 있음)

```
/remember 2026-04-15 PR #24 머지 — 표면 통합 메모리 Phase 1 완료
```

1. `$ARGUMENTS`를 `fact`로 그대로 취해 `mcp__nexus__wiki_add_fact` MCP 도구를 호출한다.
2. 파라미터 구성:
   - `fact`: `$ARGUMENTS` (trim 후 5~500자 범위, 필요 시 분할 요청)
   - `source`: `"claude-code-remember"` (명시적 플러시 구분 태그)
   - `domain`: 명시 금지 (wiki-engine의 키워드 기반 자동 감지를 신뢰)
3. 도구 응답의 `domain` 필드를 오너에게 1줄로 확인 응답:
   ```
   ✅ 위키 `{domain}` 도메인에 기록 완료.
   ```
4. 호출 실패 시 에러 메시지를 투명하게 전달하고 **재시도는 1회만**.

### 모드 B — 최근 대화 자동 추출 (`$ARGUMENTS` 빈 문자열)

1. 직전 3~5턴의 사용자·어시스턴트 메시지에서 **미래 세션에 유용한 사실**만 1~5개로 압축 추출한다.
2. 각 사실에 대해 `mcp__nexus__wiki_add_fact`를 개별 호출 (병렬 금지 — 순차).
3. 종료 후 요약 보고:
   ```
   ✅ 위키에 {N}개 주입:
   - {domain1}: {n1}개
   - {domain2}: {n2}개
   ```

**추출 기준 (모드 B)**:

| 주입 | 스킵 |
|---|---|
| ✅ 구체적 기술 결정 + 왜 | ❌ "~를 했다" 식 행동 요약 (git log 중복) |
| ✅ 프로젝트 구조 확정 사실 | ❌ diff / 코드 라인 / 변수명 |
| ✅ 오너 선호·규칙·금지사항 | ❌ 일반 상식 / 프로그래밍 기초 |
| ✅ 재발 방지용 제약·주의사항 | ❌ 임시 디버깅 출력 / 스택트레이스 |
| ✅ 진행 중 작업의 중요 맥락 | ❌ 150자 넘는 긴 문장 (분할) |

---

## 표면별 동작 보장

이 스킬은 MCP `wiki_add_fact` 도구를 통하기 때문에 **MCP 클라이언트가 nexus를 로드한 환경**에서만 동작한다:

| 표면 | 동작 | 비고 |
|---|---|---|
| Claude Code CLI (이 repo) | ✅ `~/.mcp.json`에 nexus 등록됨 | Phase 1 자동 수렴 + Phase 2 수동 주입 모두 가능 |
| Claude macOS 앱 | ✅ `~/Library/Application Support/Claude/claude_desktop_config.json`에 nexus 등록 필요 | **유일한 기억 입금 창구** (Phase 1 자동 경로 불가) |
| 디스코드 봇 | ✅ 이미 `claude-runner.js`의 `wikiAddFact` 래퍼로 자동 주입 중 | 이 스킬 호출 불필요 (예외: 봇이 세션 중 명시적으로 쓰고 싶을 때) |

nexus 미로드 환경이면 이 스킬은 에러를 반환하고 **대안 경로를 제시하지 않는다** — fallback은
약속할 수 없는 기능을 약속하는 땜질이기 때문 (오너가 나중에 "왜 안 쌓였지?" 배신감).

---

## 실패 처리

- MCP 도구 `wiki_add_fact` 호출 실패 → 오너에게 에러 메시지 그대로 전달, 재시도 1회, 2회 실패 시 abort
- fact 길이 검증(5~500자) 실패 → 오너에게 분할 요청 (예: "사실이 너무 김 — 3개로 분할해주세요")
- 중복 사실 (`addFactToWiki`가 내부에서 중복 감지하여 silent skip) → "이미 기록됨" 안내
