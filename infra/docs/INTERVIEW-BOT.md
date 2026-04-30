# INTERVIEW-BOT — 면접봇 기획 문서

> **SSoT**: 이 파일이 면접봇 시스템의 단일 기획 원본입니다.
> **압축본**: `~/jarvis/runtime/context/interview-bot-profile.md` (Jarvis 세션 자동 주입용)
> **최종 업데이트**: 2026-04-30 · 현재 버전: v4.66

---

## 1. 목적 (Why)

주인님의 백엔드 개발자 면접을 **자동화된 반복 훈련**으로 준비한다.

- 면접관이 자주 파는 약점 영역(STAR 취약점)을 데이터로 찾아 집중 노출
- 매 라운드 답변을 LLM 평가관이 채점 → 개선 궤적 추적
- 회사별 시나리오(삼성물산, SK 등) 전용 Q&A로 실전 대비

---

## 2. 시스템 구성 (Architecture)

```
┌─────────────────────────────────────────────────────────────────┐
│                     interview-ralph-runner.mjs                  │
│  (오케스트레이터: 라운드 관리, 질문 선택, 결과 집계, 학습 피드백)  │
└────────────────────────┬───────────────────────────────────────┘
                         │ mock Discord 메시지 생성 후 직접 함수 호출
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                   interview-fast-path.js                        │
│  (면접 엔진: user-profile 로드, 질문 수신, LLM 답변 생성,        │
│   STAR 컨텍스트 관리, RAG 주입, 서킷 브레이커, daily cap)        │
└────────────────────────┬───────────────────────────────────────┘
                         │ HTTP POST /meta-analyze
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                interview-verifier-server.mjs                    │
│  (독립 평가관: Claude Sonnet 4.6, port 7779,                    │
│   답변 채점 → overallScore 0~10 + verdict + insights)           │
└─────────────────────────────────────────────────────────────────┘

[외부 감사관 — 런타임과 독립]
interview-harness-audit.mjs   C1~C5 데이터 무결성 검사 (독립 실행)
```

### 핵심 설계 결정: "fast-path는 discord 없이도 동작한다"

ralph-runner가 mock Discord 메시지를 만들어 fast-path 함수를 직접 호출한다.
Discord를 거치지 않으므로 응답 속도가 빠르고, 실제 Discord 채널에는 영향 없다.
(fast-path가 Discord 객체 구조를 기대하므로 mock이 해당 형태를 맞춰 주입)

---

## 3. 데이터 파일 (State)

| 파일 | 위치 | 역할 |
|------|------|------|
| `ralph-insights.jsonl` | `runtime/state/` | 질문별 평가 결과 원장 (roundId·qid·star·overallScore·verdict·evalError) |
| `ralph-rounds.jsonl` | `runtime/state/` | 라운드별 요약 |
| `ralph-forbid-list.json` | `runtime/state/` | 출제 금지 질문 패턴 목록 (cap: 100) |
| `ralph-dynamic-questions.json` | `runtime/state/` | LLM 생성 동적 질문 캐시 (mtime + 약점 시그니처 일치 시 재사용) |
| `scenarios/samsung-cnt.json` | `runtime/state/` | 삼성물산 시나리오 (v9.2, Q&A 100문항, instantRisk 21개) |
| `openai-ledger.jsonl` | `runtime/state/` | 토큰 비용 원장 |
| `interview-fast-path-circuit.json` | `runtime/state/` | 서킷 브레이커 상태 (fails·openUntil) |

---

## 4. 핵심 설계 불변식 (Invariants)

### 4-1. 질문 ID 형식

- **v9.2 이후** (현재): `v92-Q001` ~ `v92-Q100`
- **v3.6 이전** (폐기): `samsung-Q001` 형식 — 절대 사용 금지
- `instantRiskQuestions` 배열과 `qnaQuestions[].id`는 반드시 같은 형식으로 일치해야 함
- **C1 감사**: harness-audit이 매 실행 시 교차 검증

### 4-2. isInstantRisk 참조 방식

```javascript
// ✅ 올바름 (v4.58+)
const aRisk = a.isInstantRisk === true ? 1 : 0;

// ❌ 금지 (v4.57 이전 — ID 불일치로 항상 false 반환)
const riskSet = new Set(scenario.instantRiskQuestions || []);
const aRisk = riskSet.has(a.id) ? 1 : 0;
```

### 4-3. EVAL_ERROR 격리

평가관(verifier)이 JSON parse 실패 시 `verdict: 'EVAL_ERROR'`를 반환한다.
`aggregateInsights()`는 EVAL_ERROR 항목을 자동 제외한다.
EVAL_ERROR를 `score: 0 정상 데이터`로 취급하면 약점 통계가 오염된다.

### 4-4. fast-path null 반환 = SKIP

fast-path가 `null`을 반환하는 경우: daily cap 도달 · 서킷 브레이커 open · placeholder 실패.
ralph-runner는 이를 SKIP으로 분류하며, 에러로 처리하지 않는다.

### 4-5. STAR-J* 제외 원칙

`STAR-J*` (Jarvis 개인 프로젝트)는 면접 대상 경험이 아니다.
동적 질문 생성 시 약점 가중치 산출에서 제외한다.

---

## 5. 학습 피드백 루프 (Data Flywheel)

```
라운드 실행
    │
    ├── 질문 선택: instantRisk 우선 → STAR 약점 가중치 → cross-round dedup 페널티
    │
    ├── 답변 생성: fast-path (user-profile SSoT + RAG 주입)
    │
    ├── 채점: verifier (Claude Sonnet 4.6) → insights.jsonl 기록
    │
    ├── forbid 업데이트: 2회 이상 낮은 점수 질문 → forbid-list (cap 100)
    │
    ├── 동적 질문 재생성: DYN > BASE 점수 역전 시 캐시 삭제 → LLM 재생성
    │
    └── RAG 주입: 우수 답변(threshold 이상) → LanceDB 누적
```

---

## 6. 주요 기능별 설계 의도

### 6-1. Hybrid Verifier (regex + LLM)

LLM 채점 전에 regex 사전 체크를 돌린다.
regex가 명백한 실패(예: 너무 짧은 답변, 금지 패턴 포함)를 잡으면 LLM 호출을 skip → 비용 절약.
LLM 결과는 항상 상위 판정이다.

### 6-2. 동적 질문 생성

`weakStars` (집계에서 score 낮은 STAR 번호)를 LLM에 전달해 약점 공략 질문을 생성한다.
캐시 조건: mtime이 같고 weakStars 시그니처가 동일하면 LLM 호출 skip.
**점수 역전 감지** (DYN avg > BASE avg by ≥ 0.3): 캐시 삭제 + Discord 알림.
→ 동적 질문이 오히려 더 쉬우면(약점 노출 실패) 자동으로 재생성을 강제한다.

### 6-3. 시나리오 모드 (삼성물산 등)

`INTERVIEW_ACTIVE_SCENARIO=samsung-cnt` 환경변수로 활성화.
시나리오 Q&A 100문항에서 instantRisk 우선 10문항 선택.
PDF 슬라이드 8/8 + 보충 PDF 2 = 10문항 (15분 cap 기준).
시나리오 활성 시 동적 질문은 사용하지 않는다 (v4.62).

### 6-4. 서킷 브레이커

fast-path 연속 실패 감지 → 자동 open → 쿨다운 → 재시도.
daily cap 도달 시 모든 질문이 SKIP 처리됨 (라운드가 60/60 SKIP이어도 에러 아님).

### 6-5. Cross-round Dedup

최근 3라운드에서 사용한 질문 ID를 추적해 동일 질문 재출제에 페널티를 부여한다.
페널티 적용 후에도 질문 풀이 부족하면 최근 사용 질문도 출제된다.

---

## 7. 버전 히스토리 (마일스톤)

| 버전 구간 | 주요 변경 |
|-----------|-----------|
| v4.0~v4.36 | 기본 시스템, STAR 프레임워크, 동적 질문, forbid 학습 |
| v4.38~v4.43 | STAR 약점 가중치, 직전 STAR 회피, 자기 PR 다양성 강제 |
| v4.47~v4.49 | 회사 시나리오 모드 신설 (samsung-cnt), PDF/이력서 출제 비율 |
| v4.50~v4.51 | styleGuide 캐시, silent fail 제거, answerGuide 직접 주입, RAG 1.5s timeout |
| v4.52~v4.53 | Race-safe write queue, hybrid verifier, 비용 추적 |
| v4.54~v4.56 | 스키마 가드 (L1), RAG warmup await, null 반환 SKIP 분류 |
| v4.57~v4.58 | EVAL_ERROR 격리, isInstantRisk boolean 직접 참조 (ID 불일치 수정) |
| v4.60 | forbid-list cap(100) unshift 우회 결함 수정 |
| v4.62 | 시나리오 모드에서 동적 질문 제거 (PDF 전용) |
| v4.66 | 현재 (동적 질문 역전 신호-액션 루프, harness-audit 신설) |

---

## 8. 주요 파라미터 (현재 값)

| 파라미터 | 현재 값 | 위치 |
|----------|---------|------|
| `FORBID_CAP` | 100 | ralph-runner L1429 |
| `CONCURRENCY` | 1 (기본) | 환경변수 `RALPH_CONCURRENCY` |
| Verifier 모델 | Claude Sonnet 4.6 | verifier-server |
| Verifier 포트 | 7779 | verifier-server / LaunchAgent |
| LaunchAgent | `ai.jarvis.interview-verifier` | `~/Library/LaunchAgents/` |
| 시나리오 ID 형식 | `v92-Q*` | v9.2+ |
| instantRisk 수 (samsung-cnt) | 21개 | scenarios/samsung-cnt.json |
| Cross-round lookback | 3라운드 | `scenarioQnaToQuestions` |
| 동적 질문 역전 임계값 | 0.3점 | `printTrendReport` |

---

## 9. 독립 감사관 (harness-audit)

`interview-harness-audit.mjs` — 파이프라인과 독립 실행. Karpathy 원칙 적용.

| 체크 | 설명 | 자동 수정 |
|------|------|-----------|
| C1 | instantRiskQuestions ↔ qnaQuestions ID 교차 검증 | `--fix` 가능 |
| C2 | insights.jsonl EVAL_ERROR 오염률 검사 | `--fix` 가능 |
| C3 | 동적 질문 점수 역전 감지 | 자동 캐시 삭제 |
| C4 | forbid list 중복·오염 검사 | — |
| C5 | rounds.jsonl 구조 무결성 | — |

```bash
# 정기 실행
node ~/jarvis/infra/scripts/interview-harness-audit.mjs --verbose

# 자동 수정 포함
node ~/jarvis/infra/scripts/interview-harness-audit.mjs --fix --notify
```

---

## 10. 파일 크기 현황 (2026-04-30 기준)

| 파일 | 줄 수 | gitignore 여부 |
|------|-------|---------------|
| `interview-fast-path.js` | 3,320줄 | ✅ (PII — STAR/수치) |
| `interview-ralph-runner.mjs` | 2,164줄 | ✅ (PII — 질문 풀) |
| `interview-verifier-server.mjs` | 660줄 | ✅ (PII — few-shot) |
| `interview-harness-audit.mjs` | 347줄 | ❌ (커밋 대상) |

> PII 파일들은 `.gitignore`에 의도적으로 포함. 변경 사항은 로컬에만 존재.

---

## 11. 알려진 이슈 / 주의사항

- **v9.2 마이그레이션**: 2026-04-28 시나리오 ID를 `samsung-Q*` → `v92-Q*`로 일괄 변경. 이전 ID 형식 코드 참조 시 항상 false/miss 발생.
- **fast-path 파일 크기**: 3,320줄로 1,500줄 상한 초과 상태. 향후 모듈 분리 필요.
- **verifier 프롬프트 캐시**: Claude Prompt Cache 활용 중. 시스템 프롬프트 변경 시 캐시 미스 발생 → 비용 일시 증가 정상.
- **ralph 재가동 권한**: 주인님 명시 승인 없이 ralph를 시작하지 않는다 (Iron Law 3).
