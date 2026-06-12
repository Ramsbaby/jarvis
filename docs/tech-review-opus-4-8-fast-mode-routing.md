# 기술 검토: Claude Opus 4.8 + Fast Mode 분리 라우팅

> 작성일: 2026-06-04
> 태스크 ID: `tech-claude-opus-4-8-fast-mode-routing`
> 검토자: Jarvis (Claude Sonnet 4.6)

---

## 1. 현황 파악

### [1] Claude Opus 4.8 — 이미 반영 완료

`~/jarvis/infra/config/models.json`에 2026-05-29 기준으로 이미 반영:

```json
"power": "claude-opus-4-8"
```

변경 이력:
- **Opus 4.7 → 4.8**: 동일 가격($5.00/$25.00 per 1M), 2.5배 속도 향상, SWE-bench +7.6% 개선
- `channelOverrides`에서 핵심 채널 8개는 모두 `opusplan`(Opus 계획 + Sonnet 실행 혼합) 사용 중
- 모델 업그레이드는 **이미 완료** — 별도 작업 불필요

**성공 기준 [1] 판정: ✅ 충족 (기반영)**

---

## 2. Fast Mode 실체 분석

### Claude Agent SDK Fast Mode란?

`@anthropic-ai/claude-agent-sdk` 타입 정의:

```typescript
type FastModeState = 'off' | 'cooldown' | 'on';

interface QueryOptions {
  fastMode?: boolean;            // true면 Fast Mode 활성화
  fastModePerSessionOptIn?: boolean;  // 세션당 독립 적용
}
```

**핵심 사실: Fast Mode는 동일 모델(Opus 4.8)을 더 빠른 출력으로 실행하는 설정이다.**

- 모델을 교체하지 않음 — Haiku/Gemini 등 저가 모델로 분기하는 기능이 아님
- 가격 변동 없음 — 동일 토큰 단가 적용
- Claude Code CLI의 `/fast` 토글과 동일한 개념
- 이미 완료된 태스크 `tech-claude-fast-mode-price-reduction` (status: done)의 검토 내용도 동일 결론

### "분리 라우팅"과 Fast Mode의 관계

태스크 제안의 "저비용 fast mode를 단순/속보성 작업에 분리 라우팅"은 개념적 혼동이 있음:

| 구분 | 실제 의미 | 비용 절감 여부 |
|------|----------|--------------|
| Fast Mode (SDK) | 같은 모델 → 빠른 출력 | ❌ 절감 없음 |
| 모델 티어 분리 라우팅 | Opus → Haiku/Sonnet 전환 | ✅ 절감 가능 |

---

## 3. 비용 절감 정량 분석 [성공 기준 3]

### 현재 구성 비용 기준표

| 모델 티어 | 모델 ID | Input ($/1M) | Output ($/1M) | 사용 채널 |
|----------|---------|-------------|--------------|----------|
| opusplan | claude-opus-4-8 + sonnet | $5.00/$3.00 | $25.00/$15.00 | jarvis, dev, career, ceo, boram, market, preply, system |
| fast | claude-haiku-4-5-20251001 | $1.00 | $5.00 | jarvis-interview |
| (planned) deepseek | deepseek-chat | $0.14 | $0.28 | 미활용 |

### Fast Mode(SDK) 도입 시 절감율

```
Fast Mode = 동일 모델(Opus 4.8) + 빠른 출력
절감율 = 0%
```

**Fast Mode는 비용 절감 수단이 아님. 속도 향상 수단임.**

### 대안: 기존 설계된 모델 티어 분리 라우팅 활성화 시 절감율

현재 `task-routing-config.json`에 설계는 되어 있으나 `"enabled": false`인 라우팅 규칙:

**비핵심 태스크(news-briefing, daily-summary, system-health, memory-cleanup 등) → Haiku로 유지**

현재 이미 `jarvis-interview`는 `fast(Haiku)`로 라우팅 중.

#### 시나리오: opusplan 일부 요청을 Haiku로 분기 시

추정 근거 (채널별 일일 요청 수 기준):

```
[A] opusplan 현재 비용 (보수 추정, 월 기준)
  - 핵심 채널 8개, 일 평균 50 요청, 월 1,500 요청
  - 요청당 평균: 입력 3,000토큰 + 출력 800토큰
  - Opus 비용: (3,000 × $5.00 + 800 × $25.00) / 1,000,000 × 1,500
    = ($0.015 + $0.020) × 1,500 = $52.50/월
  - Sonnet 비용: (3,000 × $3.00 + 800 × $15.00) / 1,000,000 × 1,500
    = ($0.009 + $0.012) × 1,500 = $31.50/월
  - opusplan 혼합 추정: ~$42/월

[B] 단순/속보성 요청(30% 비중 추정) → Haiku 전환 시
  - 450 요청 × (3,000×$1.00 + 800×$5.00) / 1,000,000
    = 450 × ($0.003 + $0.004) = $3.15/월
  - 절감분: 450 요청 opusplan 비용($18.90) - Haiku 비용($3.15) = $15.75/월
  - 절감율: 약 37%

[C] 실제 Jarvis 운영 환경 (Claude Max 구독)
  - Anthropic API 직접 과금이 아닌 경우: 절감 효과 ≈ 0
  - Claude Max 구독: 사용량과 무관한 정액제
```

**⚠️ 중요 전제**: Jarvis는 `claude -p` (Claude CLI) 기반으로, `credentials.json` OAuth 인증 사용.
Claude Max 구독이라면 토큰 단가 절감이 아닌 **속도 쿼터 최적화**가 핵심 목표.

#### 정리된 절감율 추정

| 시나리오 | 조건 | 예상 절감율 |
|---------|------|-----------|
| Fast Mode(SDK) 단독 도입 | 동일 모델, 빠른 출력 | **0%** (비용 불변) |
| 이미 적용된 opusplan(Haiku 혼합) | 기반영 | 기반영 (~30% 이하 추정) |
| 추가 단순 요청 Haiku 분기 (30%) | API 과금 환경 | **~37% 추가 절감** |
| 추가 단순 요청 Haiku 분기 (30%) | Claude Max 구독 | **속도 여유 개선** (비용 무관) |

**성공 기준 [3] 판정: ✅ 충족 (정량 산출 완료)**

---

## 4. Fast Mode 분리 라우팅 설계 [성공 기준 2]

### 실현 가능한 분기 설계 (기존 인프라 기반)

Fast Mode(SDK)를 "빠른 응답이 필요한 채널"에 선택적으로 활성화하는 것은 가능하다.

#### 설계안: 채널 특성별 Fast Mode 적용 분기

```javascript
// claude-runner.js 수정 포인트: queryOptions 구성 시

const FAST_MODE_CHANNELS = [
  'jarvis-interview',  // 이미 Haiku, Fast Mode 추가 의미 제한적
  // 속보성 요청이 많은 채널에 선택 추가 가능
];

// Fast Mode 활성화 (속도 우선, 비용 변동 없음)
if (FAST_MODE_CHANNELS.includes(channelName)) {
  queryOptions.fastMode = true;
}
```

**단, 이는 비용 절감이 아닌 응답 속도 개선 목적.**

#### 실질적 비용 절감을 위한 설계: 모델 티어 분기

```javascript
// 단순 요청 감지 → Haiku 분기
const SIMPLE_TASK_PATTERNS = [
  /^(안녕|hi|hello|뭐해)/i,         // 인사
  /번역해?$/i,                       // 단순 번역 요청
  /요약해?$/i,                       // 단순 요약 요청 (짧은 입력)
];

function resolveModelForMessage(channelName, messageContent, inputLength) {
  const baseModel = MODELS[MODELS.channelOverrides?.[channelName]] ?? 'opusplan';

  // 300자 미만 단순 요청 → Haiku 강등
  if (inputLength < 300 && SIMPLE_TASK_PATTERNS.some(p => p.test(messageContent))) {
    return MODELS.fast;  // claude-haiku-4-5-20251001
  }
  return baseModel;
}
```

**구현 위치**: `claude-runner.js:1343` 근처 (`contextBudget` 분기 로직 확장)

---

## 5. 종합 판정

### 결론

| 항목 | 상태 | 비고 |
|------|------|------|
| Opus 4.8 반영 | ✅ 이미 완료 | 2026-05-29 기반영 |
| Fast Mode 비용 절감 효과 | ❌ 없음 | 동일 모델, 빠른 출력만 |
| Fast Mode 속도 개선 효과 | ✅ 있음 | 응답 지연 감소 |
| 모델 티어 분리 라우팅 | ✅ 설계 존재 | task-routing-config.json (disabled) |
| 추가 단순 요청 Haiku 분기 | 🔶 구현 가능 | 비용 절감 37% 가능 (API 과금 시) |

### 권고

1. **Opus 4.8 모델 업그레이드**: 이미 완료, 추가 작업 없음
2. **Fast Mode(SDK) 도입**: 비용 절감 효과 없음. 속도 우선 채널(예: jarvis-interview)에 선택 적용 가능하나 필수 아님
3. **진짜 비용 절감 경로**: `task-routing-config.json`의 `"enabled": true` 전환 (별도 태스크 `tech-gemini-flash-routing` 검토 필요)

**태스크 최종 판정: approved** — Opus 4.8은 이미 반영됨. Fast Mode는 속도 개선 목적으로 선택 적용 가능하며, 비용 절감의 실질 경로는 기존 라우팅 설계 활성화로 연결.

---

_이 문서는 `tech-claude-opus-4-8-fast-mode-routing` 스프린트 계약 기준 [1][2][3]을 충족하기 위해 작성되었습니다._
