# 🔍 자비스 정보탐험 미션 — {{DATE}}

> **실행 원칙:** Phase 1 완료 후, Phase 2(Analyst)와 Phase 3 초안(Architect)을 Agent 도구로 병렬 실행하세요.
> 추측 금지. 실제 검색/확인된 내용만 작성. 확인 불가 항목은 "미확인"으로 표기.

---

## Phase 1: 정찰 (Scout) — 웹 수집

아래 4개 영역을 검색하세요. 각 쿼리는 순서대로 시도하고 결과가 있으면 다음 쿼리로 이동합니다.

### 1-A. Anthropic / Claude 공식
검색 쿼리 (순서대로):
1. `anthropic claude API changelog {{MONTH}} {{YEAR}}`
2. `site:npmjs.com @anthropic-ai/claude-agent-sdk` (최신 버전 확인)
3. `anthropic new model release {{YEAR}}`
4. `claude code CLI changelog latest`

수집:
- Claude API 파라미터/엔드포인트/가격 변경
- @anthropic-ai/claude-agent-sdk 현재 최신 버전 (현재 Jarvis 버전과 비교: `cat {{BOT_HOME}}/discord/package.json`)
- 신규 모델 출시 / deprecation
- Claude Code 신규 기능 (Jarvis에 즉시 활용 가능한 것)

### 1-B. 경쟁사 벤치마킹
검색 쿼리:
1. `openai assistants API update {{MONTH}} {{YEAR}}`
2. `cursor AI windsurf new features {{MONTH}} {{YEAR}}`
3. `AI personal assistant discord bot 2025 features`
4. `github copilot workspace agentic features`

수집:
- Jarvis에 적용 가능한 구체적 기능만 (일반 뉴스 불필요)
- Discord AI 봇 생태계 혁신 사례

### 1-C. 커뮤니티 / 오픈소스
검색 쿼리:
1. `site:reddit.com/r/ClaudeAI tips workflow {{MONTH}} {{YEAR}}`
2. `github trending MCP server {{MONTH}} {{YEAR}}`
3. `hacker news claude agent automation`
4. `claude system prompt optimization tips`

수집:
- 사용자 발견 유용한 패턴/트릭
- 신규 MCP 서버 (우리 미적용 것 위주)

### 1-D. MCP 생태계
검색 쿼리:
1. `model context protocol new servers {{YEAR}}`
2. `MCP server productivity github awesome`
3. `anthropic MCP spec update breaking change`

수집:
- 현재 Jarvis 미사용 유용한 MCP 서버
- 프로토콜 변경사항

### ⚠️ WebSearch 실패 폴백
- **429 Rate Limit** → 해당 쿼리 30초 후 1회 재시도 → 재실패 시 "수집 불가 (Rate Limit)"로 표기 후 다음 진행
- **검색 자체 불가** → `ls {{BOT_HOME}}/rag/teams/reports/recon-*.md | tail -3` 으로 최근 보고서에서 관련 내용 추출

---

## Phase 2: 분석 (Analyst) — Jarvis 현황 대조

Phase 1 결과를 갖고 현재 Jarvis 코드베이스와 대조합니다.

### 2-1. 버전 갭
```bash
cat {{BOT_HOME}}/discord/package.json | grep -E '"@anthropic|"discord|"claude'
```
→ Phase 1 수집 최신 버전과 비교. 버전 차이 있으면 Breaking change 여부 명시.

### 2-2. 최근 실패 연계
```bash
grep -i "failed\|error\|timeout\|SKIPPED" {{BOT_HOME}}/logs/cron.log | tail -30
```
→ 수집된 정보 중 현재 실패를 해결할 수 있는 것 → Quick Win 우선 배치.

### 2-3. 적용 가능성 분류
각 Phase 1 항목을:
- **🟢 즉시** — 코드 10줄 이내, 리스크 없음 → Quick Win
- **🟡 1주** — 구조 변경 필요, 테스트 필요 → Medium-term
- **🔴 장기** — 아키텍처 변경, 사이드이펙트 큼 → Long-term

---

## Phase 3: 설계 (Architect) — 보고서 작성

Phase 1+2 결과를 종합하여 **대표님이 바로 "이거 해줘" 지시할 수 있는 수준**으로 작성하세요.
- 코드 스니펫: 파일명 + 실제 코드 필수
- 비용 영향: Claude API 토큰 증감 여부 명시
- 소요시간: 분 단위 추정

### 출력 형식

```markdown
# 🚀 Jarvis 업그레이드 리포트 — {{DATE}}

## 📡 이번 주 AI 업계 핵심 변경사항
(실제 확인된 것만. URL 포함. 미확인은 명시)

| 항목 | 출처 | Jarvis 영향 |
|------|------|-----------|
| ... | URL | 높음/중간/낮음 |

---

## 🎯 Quick Win (즉시 적용 — 각 30분 이내)

### QW-1: [제목]
- **파일:** `{{BOT_HOME}}/경로/파일명`
- **현재 코드:**
  ```js
  // 현재 (라인 번호)
  ```
- **변경 후:**
  ```js
  // 변경
  ```
- **효과:** [구체적 수치 또는 동작 변화]
- **리스크:** 🟢 낮음 — [이유]
- **소요:** ~X분

---

## 📋 Medium-term (1주 이내)

### MT-1: [제목]
- **작업:** [단계별 체크리스트]
- **효과:** [수치]
- **리스크:** 🟡 중간 — [이유]
- **선행 조건:** [필요한 것]

---

## 🔮 Long-term (설계 필요)

### LT-1: [제목]
- **비전:** [한 줄]
- **필요 변경:** [아키텍처 레벨]
- **우선순위:** High / Medium / Low

---

## 🏆 경쟁사에서 훔쳐올 기능 TOP 3

1. **[기능명]** (출처: [제품명])
   - 내용: [설명]
   - Jarvis 적용: [구체적으로]
   - 난이도: ⭐~⭐⭐⭐⭐⭐

---

## ⚠️ 주의사항 / 리스크
- [항목]: [설명]

---

## 📊 수집 품질 리포트
- 성공 쿼리: X / 16
- Rate Limit: X건
- 미확인 항목: [나열]
- 다음 주 보완: [항목]
```

---

## 🔍 자체 QA (저장 전 필수 확인)

아래 기준 미달 시 해당 섹션 보강 후 저장하세요:
- [ ] Quick Win 최소 2개 이상 (코드 스니펫 포함)
- [ ] 보고서 전체 2000자 이상
- [ ] 추측이 아닌 실제 검색 기반 항목 50% 이상
- [ ] 수집 품질 리포트 포함

---

## 저장
```bash
# 저장 경로
REPORT="{{BOT_HOME}}/rag/teams/reports/recon-{{DATE}}.md"

# 저장 확인
ls -lh "$REPORT"
```
