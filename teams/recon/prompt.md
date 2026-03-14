# 🔍 자비스 정보탐험 미션 — {{DATE}}

> **최종 목표:** 웹에서 최신 정보를 수집하고, Jarvis를 **직접 업그레이드**한다.
> 보고서만 남기는 게 아니라 Quick Win은 이번 실행에서 바로 구현하고 결과를 보고한다.
> 추측 금지. 실제 검색/확인된 내용만. 확인 불가는 "미확인"으로 표기.

---

## Phase 1: 정찰 (Scout) — 웹 수집

### 1-A. Anthropic / Claude 공식 변경사항
검색 쿼리:
1. `anthropic claude API changelog {{MONTH}} {{YEAR}}`
2. `site:npmjs.com @anthropic-ai/claude-agent-sdk` → 현재 최신 버전 확인
3. `anthropic new model release {{YEAR}}`
4. `anthropic claude code CLI update {{MONTH}} {{YEAR}}`

수집 항목:
- Claude API 파라미터/가격/한도 변경
- @anthropic-ai/claude-agent-sdk 최신 버전 vs 현재 Jarvis 버전 (`cat {{BOT_HOME}}/discord/package.json | grep claude-agent-sdk`)
- 신규 모델 출시 / deprecation 공지
- Claude Code 신규 기능 중 Jarvis에 즉시 활용 가능한 것

### 1-B. 경쟁사 — 훔쳐올 기능 위주
검색 쿼리:
1. `openai new features update {{MONTH}} {{YEAR}}`
2. `cursor AI update {{MONTH}} {{YEAR}} new features`
3. `windsurf AI IDE features {{YEAR}}`
4. `cline AI agent github update {{MONTH}} {{YEAR}}`
5. `AI personal assistant discord bot open source {{YEAR}}`

수집 핵심:
- **"Jarvis에 적용 가능한 기능"만** — 일반 뉴스 불필요
- 구체적 구현 방식이 공개된 것 우선
- 예: "Cursor의 Subagents가 병렬 실행하는 방식은 X" → Jarvis 적용 가능 여부

### 1-C. 오픈소스 벤치마킹 — 핵심 영역
검색 쿼리:
1. `github.com anthropic claude agent bot open source stars:>100`
2. `github trending AI assistant automation {{MONTH}} {{YEAR}}`
3. `site:github.com jarvis AI discord personal assistant`
4. `awesome-claude-prompts github {{YEAR}}`
5. `MCP server awesome list github new {{MONTH}} {{YEAR}}`

수집 항목:
- **GitHub에서 Jarvis와 유사한 오픈소스 프로젝트** — 우리보다 잘 구현된 기능 파악
- **인기 MCP 서버** 중 Jarvis 미적용 것 (GitHub stars 기준)
- 우리가 모르는 Claude 활용 패턴

### 1-D. Claude Hub / 커뮤니티 인사이트
검색 쿼리:
1. `site:reddit.com/r/ClaudeAI best prompts workflow {{MONTH}} {{YEAR}}`
2. `claude hub popular prompts automation`
3. `hacker news claude agent workflow tips {{YEAR}}`
4. `claude system prompt best practices {{YEAR}}`

수집 항목:
- 사용자들이 발견한 Claude 활용 패턴 (Jarvis 적용 가능한 것)
- 인기 프롬프트 구조 (우리 system.md/context 파일 개선에 활용)
- 알려진 Claude 한계 회피 방법

### ⚠️ WebSearch 실패 폴백
- 429 → 30초 대기 후 1회 재시도 → 재실패 시 "수집 불가" 표기 후 다음 쿼리
- 검색 불가 시 → `ls {{BOT_HOME}}/rag/teams/reports/recon-*.md | tail -3`으로 최근 보고서 참조 (반드시 "과거 보고서 기반" 명시)

---

## Phase 2: 분석 (Analyst) — Jarvis 현황 대조

Phase 1 결과를 현재 Jarvis 코드베이스와 대조합니다.

### 2-1. 버전 갭
```bash
cat {{BOT_HOME}}/discord/package.json | grep -E '"@anthropic|"discord|"claude'
```

### 2-2. 최근 실패/이슈 연계
```bash
grep -i "failed\|error\|timeout\|SKIPPED" {{BOT_HOME}}/logs/cron.log | tail -30
```
→ 수집된 정보 중 현재 실패를 해결할 수 있는 것 → Quick Win 최우선

### 2-3. 오픈소스 대비 갭 분석
Phase 1-C에서 수집한 오픈소스 프로젝트 중:
- Jarvis에 없는 기능 → Long-term 후보
- Jarvis에 이미 있는 기능이지만 구현이 더 나은 것 → Medium 후보
- 즉시 프롬프트/설정 수준에서 복사 가능한 것 → Quick Win 후보

### 2-4. 적용 가능성 분류
- **🟢 즉시 (QW)** — 코드 20줄 이내, 리스크 없음, 롤백 용이
- **🟡 1주 (MT)** — 구조 변경, 테스트 필요
- **🔴 장기 (LT)** — 아키텍처 변경, 사이드이펙트 큼

---

## Phase 3: 보고서 작성 (Architect)

Quick Win 구현 전에 전체 보고서를 먼저 작성합니다.

### 출력 형식

```markdown
# 🚀 Jarvis 업그레이드 리포트 — {{DATE}}

## 📡 이번 주 AI 업계 핵심 변경사항
(실제 확인된 것만. URL 포함. 미확인은 명시)

- **[항목]** · [URL] · Jarvis 영향: 높음/중간/낮음
  - 내용 2~3줄

---

## 🎯 Quick Win (이번 실행에서 자동 구현 예정)

### QW-1: [제목]
- **파일:** `{{BOT_HOME}}/경로/파일명`
- **현재 코드:** (라인 번호 포함)
  ```
  // 현재
  ```
- **변경 후:**
  ```
  // 변경
  ```
- **효과:** [구체적 수치 또는 동작 변화]
- **리스크:** 🟢 낮음 — [이유]
- **구현 상태:** [실행 전 / 구현 완료 / 실패: 이유]

---

## 📋 Medium-term (1주 이내 — 대표님 지시 후 구현)

### MT-1: [제목]
- **작업:** [단계별]
- **효과:** [수치]
- **리스크:** 🟡 중간 — [이유]

---

## 🔮 Long-term (설계 필요)

### LT-1: [제목]
- **비전:** [한 줄]
- **필요 변경:** [아키텍처 레벨]

---

## 🏆 오픈소스 / 경쟁사 벤치마킹 TOP 3

1. **[기능/프로젝트명]** · [출처 URL]
   - 핵심: [무엇이 좋은가]
   - Jarvis 적용: [어떻게 가져올 수 있는가]
   - 난이도: ⭐~⭐⭐⭐⭐⭐

---

## 📊 수집 품질
- 성공 쿼리: X / 18
- Rate Limit: X건
- 미확인 항목: [나열]
```

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
- `bot-cron.sh` (크론 엔진)
- `.env` 파일
- `state/` 디렉토리
- 30줄 초과 변경

---

## 저장 및 전송
```bash
REPORT="{{BOT_HOME}}/rag/teams/reports/recon-{{DATE}}.md"
ls -lh "$REPORT"  # 저장 확인
```
