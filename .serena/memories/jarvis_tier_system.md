# Jarvis — Tier 0~5 토큰 낭비 방어 시스템

2026-04-14 세션에서 구축. 모든 파일 경로는 `~/jarvis/` 기준.

## 전체 구조

```
Tier 0 (FOUNDATION)
  ↓ token-ledger.jsonl + 주간 자동 감사
  ↓
├── Tier 1: Evaluator (LLM 결과 6-check 게이트)
├── Tier 2: Gate Factory (해시 캐시 + 후보 큐)
├── Tier 3: 3-agent 선별 (council-insight / monthly-review / ceo-daily-digest)
├── Tier 4: Consumer 게이트 (consensus-parser, insight-recorder)
└── Tier 5: KPI Auto-tune 제안 엔진 (제안만, 자동 수정 금지)
```

## Tier 0 — 토큰 원장
- **파일**: `~/.jarvis/state/token-ledger.jsonl` (append-only JSONL)
- **Writer**: `infra/bin/ask-claude.sh:253` (success 직후)
- **필드**: ts, task, model, status, input, output, cost_usd, duration_ms, result_bytes, result_hash, max_budget_usd
- **조회**: `infra/scripts/token-ledger-query.sh` (today/top/dedup/budget/task/stats)
- **주간 감사**: `infra/scripts/token-ledger-audit.sh` (매주 일요일 08:30 KST)

## Tier 1 — 독립 평가자
- **파일**: `infra/lib/evaluator.sh`
- **호출**: `ask-claude.sh:201` (RESULT 추출 직후)
- **검사 6종**:
  1. empty/near-empty (<2 words → fail, <5 → warn)
  2. identical to prompt (sha256 일치 → fail)
  3. LLM refusal (한/영 정규식 → fail)
  4. truncated markers (`{`, `[`, `,`로 끝남 → warn)
  5. schema miss (태스크별 키워드 → warn)
  6. repeated loop (같은 줄 10회+ → fail)
- **태스크 schema 14개** 등록: `_schema_for()` case 문 (bash 3.2 호환)
- **단독 실행**: `evaluator.sh <task-id> <result> [prompt]`

## Tier 2 — Gate Factory
- **문서**: `infra/scripts/gate-factory/README.md` (3-step 패턴 명세)
- **레퍼런스**: `infra/scripts/github-monitor-gate.sh`
- **후보 큐**: `~/.jarvis/state/gate-candidates.json`
- **자동 수집**: `token-ledger-audit.sh` 가 dedup 후보(5회+ 동일 hash)를 큐에 append. status: pending/implemented/rejected.

## Tier 3 — 3-agent (plan/execute/verify)
- **위치**: `infra/scripts/task-executors/`
- **3개 태스크**:
  - `ceo-daily-digest-3-agent.sh` — webhook 사전 검증 + 리포트 schema
  - `council-insight-3-agent.sh` — context-bus 신선도 + 4-section 검증
  - `monthly-review-3-agent.sh` — 월 1일 가드 + 30d ledger 사전 집계 + 5-section
- **호출**: `tasks.json`의 `script` 필드. `bot-cron.sh:380`이 ask-claude.sh 대신 래퍼를 직접 실행.
- **단계별 ledger 기록**: `<task>:plan / <task>:execute / <task>:verify` 태그

## Tier 4 — Consumer 게이트
1. **`jarvis-board/lib/consensus-parser.ts`** — placeholder title 거부, MIN_TITLE/DETAIL 길이, INVALID_PATTERNS regex
2. **`infra/lib/insight-recorder.sh`** — confidence level (0/1/2). confidence < 2는 vault 기록 skip + `logs/insight-skipped.log`에 로깅.

## Tier 5 — KPI Auto-tune 제안
- **파일**: `infra/scripts/tune-task-params.sh`
- **스케줄**: 매주 일요일 08:35 KST (token-ledger-audit 직후)
- **5개 분석**: timeout 위험 / 예산 압박 / 재시도율 40%+ / thin output / evaluator warn 누적
- **출력**: `~/.jarvis/results/tune-suggestions/<date>.md` + Discord alert
- **🚨 자동 수정 금지** — 제안만. 오너가 월간 리뷰로 반영.

## 설계 원칙
- 모든 Tier는 Tier 0 원장 위에 구축
- 자동 수정은 명시적으로 금지 (Meta Agent는 "premature" 판정)
- 1회용 스크립트 금지, 재사용 가능한 패턴만
- 검증이 병목: warn은 통과시키되 추세 관측, fail만 차단

## 관련 commits
- `81f3fea` (jarvis): Tier 1-5 전면 구축
- `f47a87a` (jarvis-board): Tier 4 consensus-parser 게이트
- `385d39c` (jarvis): Tier 0 토큰 원장
- `eaf9ec7` (jarvis): 주간 자동 감사
