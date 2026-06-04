# ADR-022 — Adaptive Model 비용 재산정 및 라우팅 룰 업데이트

**상태**: accepted
**날짜**: 2026-05-25
**담당**: tech-adaptive-model-cost-rebalance 스프린트

---

## 배경

프론티어 LLM 토큰 단가는 연간 10~100배 하락 추세다. 기존 adaptive-model.js는
power/opusplan 채널의 normal 쿼리에 대해 sonnet 다운그레이드를 금지하는 하드코딩
가드를 포함하고 있었다. 이로 인해 일상 대화·짧은 답변 요청에도 Opus급 모델이
호출되어 불필요한 비용이 발생했다.

---

## 결정

### 1. 토큰 단가 (2026-05-25 공시가 기준)

출처: https://platform.claude.com/docs/en/about-claude/pricing

| 티어 | 모델 | 입력 ($/1M tok) | 출력 ($/1M tok) |
|------|------|----------------|----------------|
| fast | claude-haiku-4-5-20251001 | $1.00 | $5.00 |
| sonnet | claude-sonnet-4-6 | $3.00 | $15.00 |
| power / opusplan / opus47 | claude-opus-4-7 | $5.00 | $25.00 |

models.json 및 adaptive-model.js의 `TIER_PRICING` 상수가 위 단가와 일치하도록 동기화됨.

### 2. 라우팅 룰 변경

**이전 로직:**
```
power/opusplan 채널 + normal 입력 → 채널 티어 무조건 유지 (sonnet 다운 금지 가드)
```

**새 로직 (2026-05-25 이후):**
```
deep   → 채널 티어 유지 (품질 보장)
trivial → fast (비용 절감)
normal  → sonnet으로 합리적 다운 (비용 최적화)
```

**분류 기준:**
- `deep`: 코드블록 포함 OR 리뷰·설계·아키텍처·비교·트레이드오프·분석·디버그·최적화·성능·장애·버그·면접·이력서 등 키워드
- `trivial`: 20자 미만 + yes/no·숫자·상태 요약 패턴 또는 10자 미만 초단문
- `normal`: 그 외 모든 쿼리

**Opus 4.7 전용 라우팅 (2026-05-24 추가):**
- taskType `rag-debug` | `complex-code` 에 한정하여 tier=`opus47` 강제 지정
- 채널 티어·프롬프트 분류와 무관하게 우선 적용

### 3. 예상 비용 절감률

normal 쿼리 기준 (예상 출력 512 tokens):

| 모델 | 출력 비용/응답 | 비율 |
|------|--------------|------|
| Opus 4.7 (이전) | 512 × $25/MTok = $0.0000128 | 100% |
| Sonnet 4.6 (이후) | 512 × $15/MTok = $0.0000077 | 60% |

**→ normal 쿼리당 약 40% 비용 절감**

일상 대화 비율이 전체 쿼리의 50~70%로 가정 시, 전체 API 비용 **20~28% 절감** 예상.

---

## 근거

- Sonnet 4.6은 일상 대화·요약·단순 답변에서 Opus 4.7 대비 품질 차이 미미
- deep 분류(코드·아키텍처·면접)는 채널 티어를 유지하여 품질 저하 없음
- 2026-05-21 회귀 사례: jarvis-career(opusplan) 감정 메시지 → sonnet 강제 다운 → 품질 급락 경험을 반영하여 감정·일반 발화는 normal로 분류, sonnet 다운을 정책적으로 수용

---

## 검증

테스트 파일: `infra/discord/test/adaptive-model.test.js`

실행 결과 (2026-05-25):
```
19 passed, 0 failed
```

검증 케이스:
- fast/sonnet/power/opusplan × trivial/normal/deep 12조합
- 감정 발화 normal → sonnet 다운 회귀 테스트
- deep 쿼리 채널 티어 유지 품질 보장 테스트
- TIER_PRICING 단가 구조 유효성
- ADAPTIVE_MODEL_ENABLED=0 비활성 동작

---

## 영향 범위

- `infra/discord/lib/adaptive-model.js` — 라우팅 로직 변경
- `infra/config/models.json` — 단가 동기화
- `runtime/config/models.json` — 단가 동기화 (infra/config와 동일 내용)

---

## 결과

Sprint Contract 기준 충족 여부:

| 기준 | 결과 |
|------|------|
| [1] adaptive-model.js 문법 오류 없이 파싱 | ✓ `node --check` SYNTAX OK |
| [2] models.json 단가 2025~2026 공시가 기준 업데이트 | ✓ Haiku $1/$5, Sonnet $3/$15, Opus $5/$25 |
| [3] opusplan 고정 가드 대신 비용-품질 임계값 조건으로 변경 | ✓ normal→sonnet 다운, deep→채널 티어 유지 |
| [4] 단위 테스트 exit 0 통과 | ✓ 19 passed, 0 failed |
| [5] 재산정 근거 문서 작성 | ✓ 본 ADR-022 |
