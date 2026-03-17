# 🔍 자비스 정보탐험 미션 — {{DATE}}

> **최종 목표:** Jarvis를 **직접 업그레이드**한다.
> 보고서만 남기는 게 아니라 Quick Win은 이번 실행에서 바로 구현하고 결과를 보고한다.
> 추측 금지. 실제 검색/확인된 내용만. 확인 불가는 "미확인"으로 표기.

---

## Phase 0: 현황 진단 — 검색 전 필수 (Analyst)

> **검색을 시작하기 전에 Jarvis가 지금 무엇에 어려움을 겪고 있는지 파악합니다.**
> Phase 0 결과가 Phase 1 검색 키워드에 반영됩니다.

### 0-1. 이전 미완료 항목 로드
`cat {{BOT_HOME}}/state/recon-tracker.md`
- 미완료 MT/LT 항목이 있으면 → 이번 실행의 **최우선 과제**
- CEO 피드백(승인/거절)이 있으면 → 승인된 건 이번에 구현, 거절된 건 제거
- 반복 발견 패턴 → Phase 1 검색에 집중 영역으로 반영

### 0-2. 실제 시스템 문제 진단
`grep -i "failed\|error\|timeout\|CRITICAL" {{BOT_HOME}}/logs/cron.log | tail -30`
`tail -5 {{BOT_HOME}}/state/health.json`
`cat {{BOT_HOME}}/state/results/system-health/$(ls -t {{BOT_HOME}}/results/system-health/ | head -1) 2>/dev/null | head -20`

수집 결과:
- 현재 실패 중인 크론 태스크
- 시스템 이상 징후 (메모리, 디스크, 봇 상태)
- 최근 24시간 에러 패턴

### 0-3. 대표 지정 관심 영역
`cat {{BOT_HOME}}/state/recon-search-focus.md`
- "대표 지정 관심 영역" 섹션에 항목이 있으면 → Phase 1에서 해당 영역 **우선 검색**

### 0-4. 검색 전략 수립
Phase 0 결과를 종합하여:
- 🔴 **긴급** — 현재 실패 중인 문제 해결책 검색 (Phase 1에서 최우선)
- 🟡 **중점** — 이전 MT/LT 후속 + 대표 관심 영역
- 🟢 **일반** — 정기 스캔 (시간이 남으면)

이 전략을 보고서 상단에 "이번 회차 검색 전략" 섹션으로 기록합니다.

---

## Phase 1: 정찰 (Scout) — 적응형 웹 수집

> Phase 0에서 도출한 긴급/중점 영역을 **먼저** 검색합니다.
> 일반 스캔은 시간과 Rate Limit 여유가 있을 때만.

### 1-🔴 긴급 검색 (Phase 0 문제 기반)
Phase 0-2에서 발견한 실패/에러와 관련된 해결책을 검색합니다.
- 에러 메시지 키워드로 직접 검색
- 관련 라이브러리/도구 업데이트 확인
- 커뮤니티 해결 사례 검색

### 1-🟡 중점 검색 (이전 미완료 + 대표 관심)
tracker에서 가져온 미완료 항목 + 대표 지정 영역에 대해 후속 조사.

### 1-A. Anthropic / Claude 공식 변경사항
검색 쿼리:
1. `anthropic claude API changelog {{MONTH}} {{YEAR}}`
2. `site:npmjs.com @anthropic-ai/claude-agent-sdk` → 현재 최신 버전 확인
3. `anthropic new model release {{YEAR}}`
4. `anthropic claude code CLI update {{MONTH}} {{YEAR}}`

수집 항목:
- Claude API 파라미터/가격/한도 변경
- @anthropic-ai/claude-agent-sdk 최신 버전 vs 현재 Jarvis 버전 (`grep claude-agent-sdk {{BOT_HOME}}/discord/package.json`)
- 신규 모델 출시 / deprecation 공지
- Claude Code 신규 기능 중 Jarvis에 즉시 활용 가능한 것

### 1-B. 경쟁사 — 훔쳐올 기능 위주
검색 쿼리:
1. `openai new features update {{MONTH}} {{YEAR}}`
2. `cursor AI update {{MONTH}} {{YEAR}} new features`
3. `windsurf AI IDE features {{YEAR}}`
4. `cline AI agent github update {{MONTH}} {{YEAR}}`

수집 핵심:
- **"Jarvis에 적용 가능한 기능"만** — 일반 뉴스 불필요
- 구체적 구현 방식이 공개된 것 우선

### 1-C. 오픈소스 벤치마킹
검색 쿼리:
1. `github.com anthropic claude agent bot open source stars:>100`
2. `github trending AI assistant automation {{MONTH}} {{YEAR}}`
3. `MCP server awesome list github new {{MONTH}} {{YEAR}}`

### 1-D. 커뮤니티 인사이트
검색 쿼리:
1. `site:reddit.com/r/ClaudeAI best prompts workflow {{MONTH}} {{YEAR}}`
2. `claude system prompt best practices {{YEAR}}`

### ⚠️ WebSearch 실패 폴백
- 429 → 30초 대기 후 1회 재시도 → 재실패 시 "수집 불가" 표기 후 다음 쿼리
- 검색 불가 시 → 최근 보고서 참조 (반드시 "과거 보고서 기반" 명시)

---

## Phase 2: 분석 (Analyst) — Jarvis 현황 대조

### 2-1. 버전 갭
`grep -E '"@anthropic|"discord|"claude' {{BOT_HOME}}/discord/package.json`

### 2-2. 이전 보고서 대비 변화 (Δ 분석)
`ls -t {{BOT_HOME}}/rag/teams/reports/recon-*.md | head -1` → 직전 보고서와 비교
- 새로 발견된 것만 보고 (이미 보고된 항목은 "전회 보고 참조" 한 줄 처리)
- 상태 변화가 있는 것은 업데이트 ("MT-3 진행률: 미착수→설계 중")

### 2-3. 적용 가능성 분류
- **🟢 즉시 (QW)** — 코드 20줄 이내, 리스크 없음, 롤백 용이
- **🟡 1주 (MT)** — 구조 변경, 테스트 필요
- **🔴 장기 (LT)** — 아키텍처 변경, 사이드이펙트 큼

---

## Phase 3: 보고서 작성 (Architect)

Quick Win 구현 전에 전체 보고서를 먼저 작성합니다.

### 출력 형식

⚠️ 코드블록(```) 절대 사용 금지 — 코드 스니펫은 저장 파일에만 포함. Discord 전송본은 인라인 `backtick`만.

보고서 구조 (마크다운, 아래 순서 준수):

1. **🎯 이번 회차 검색 전략** — Phase 0에서 도출한 긴급/중점/일반 영역 요약 (3줄)

2. **📡 AI 업계 핵심 변경사항** — 실제 확인된 것만, URL 포함
   - 신규 발견만. 이전 보고 항목은 "전회 참조" 처리
   - **[항목]** · [URL] · Jarvis 영향: 높음/중간/낮음

3. **🔄 이전 미완료 항목 현황** — tracker에서 로드한 MT/LT 진행 상태
   - MT/LT-N: 상태(미착수/진행중/완료/거절) + 이번 회차 업데이트

4. **🎯 Quick Win** (이번 실행에서 자동 구현 예정)
   - QW-N: 제목 / 파일 / 변경 설명 / 효과 / 리스크 / 구현 상태

5. **📋 Medium-term** (1주 이내 — 대표님 지시 후 구현)
   - MT-N: 제목 / 작업 단계 / 효과 / 리스크

6. **🔮 Long-term** (설계 필요)
   - LT-N: 비전 / 필요 변경

7. **🏆 벤치마킹 TOP 3**
   - 기능명 · URL · 핵심 · Jarvis 적용법 · 난이도

8. **📊 수집 품질** — 성공 쿼리 수, Rate Limit 건수, 미확인 항목

---

## Phase 4: 자율 구현 (Architect) — 핵심 단계

> **이 Phase가 정보탐험의 핵심입니다.**
> Quick Win으로 분류된 항목 중 아래 조건을 모두 충족하면 **지금 바로 직접 구현**합니다.

### 자율 구현 허용 조건 (전부 충족해야 함)
1. 변경 파일이 1개
2. 변경 코드가 30줄 이내
3. 기존 기능 삭제 없음 (추가 또는 수정만)
4. 설정/프롬프트/컨텍스트 파일 변경 (`.md`, `.json`, `.yml`) **또는** 명확히 안전한 코드 수정
5. 롤백 방법이 명확함

### 자율 구현 절차
```bash
# 1. 변경 전 백업
cp [대상파일] [대상파일].recon-backup-{{DATE}}

# 2. 변경 적용 (Edit 또는 Write 도구 사용)

# 3. 구문 오류 확인 (json이면 jq, js이면 node --check)

# 4. 결과 확인
```

### 구현 후 보고서 업데이트
구현 성공 시 → 해당 QW 항목의 "구현 상태"를 "✅ 구현 완료 ({{DATE}})"로 업데이트
구현 실패 시 → "❌ 실패: [이유]"로 표기 후 Medium-term으로 이동

### 자율 구현 금지 영역 (절대 건드리지 않음)
- `discord-bot.js`, `claude-runner.js` (핵심 봇 로직)
- `handlers.js`, `commands.js`, `prompt-sections.js` (봇 명령/프롬프트)
- `streaming.js`, `session-summary.js`, `format-pipeline.js` (출력 처리)
- `company-agent.mjs`, `team-loader.mjs` (팀 에이전트 엔진)
- `rag-engine.mjs`, `mcp-nexus.mjs` (RAG/MCP 핵심)
- `bot-cron.sh` (크론 엔진)
- `.env` 파일
- `state/` 디렉토리 (`recon-tracker.md`, `recon-search-focus.md` 제외)
- `discord/lib/` 하위 전체
- 30줄 초과 변경

---

## Phase 5: Tracker 업데이트 — 반드시 실행

> **이 Phase를 빠뜨리면 다음 실행이 백지 출발합니다.**

### 5-1. recon-tracker.md 업데이트
`{{BOT_HOME}}/state/recon-tracker.md` 파일을 업데이트합니다:

- **미완료 MT/LT 항목**: 이번 회차에서 새로 제안한 MT/LT 항목 추가
  - 형식: `- [ ] MT-N: 제목 ({{DATE}} 제안)`
- **완료된 항목**: QW 구현 완료건 + 이전 MT/LT 중 해결된 건 → "완료된 항목" 섹션으로 이동
- **반복 발견 패턴**: 이전 보고서에서도 등장한 이슈 → 패턴 기록
  - 형식: `- [이슈 키워드] — N회 발견 (최초 YYYY-MM-DD)`

### 5-2. recon-search-focus.md 업데이트
`{{BOT_HOME}}/state/recon-search-focus.md`의 "시스템 기반 우선순위" 섹션을 갱신:
- Phase 0에서 발견한 시스템 문제
- 이번 회차에서 해결 못한 긴급 이슈
- 대표 지정 영역은 건드리지 않음

---

## 저장 및 전송
```bash
REPORT="{{BOT_HOME}}/rag/teams/reports/recon-{{DATE}}.md"
ls -lh "$REPORT"  # 저장 확인
```
