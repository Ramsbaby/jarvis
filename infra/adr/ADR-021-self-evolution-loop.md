# ADR-021: Jarvis 자기진화 루프 (Self-Evolution Loop)

## 상태
ACCEPTED (2026-03-31)

## 배경

Jarvis는 수많은 컴포넌트가 독립적으로 동작하지만, **시스템이 스스로 개선 방향을 찾아 실행하는 닫힌 루프**가 없었다.
Phase 1~3 작업(Context Engineering, RAG Hybrid, Self-healing, Langfuse)으로 각 레이어가 완성되었고, 이를 연결하는 자기진화 루프를 정의한다.

## 루프 구조

```
┌─────────────────────────────────────────────────────────────────┐
│                   Jarvis Self-Evolution Loop                    │
│                                                                 │
│  매주 일요일 21:00                                              │
│  ┌──────────────────┐                                           │
│  │ weekly-perf-agent│  ← FSM 통계 + Langfuse LLM 비용/에러율  │
│  │ (LLM 분석)        │    + RAG 품질 + Board 에이전트 점수      │
│  └────────┬─────────┘                                           │
│           │ 분석 결과 + DEV_TASK 목록                           │
│           ▼                                                     │
│  ┌──────────────────┐                                           │
│  │  Jarvis Board    │  ← 자동 포스트 생성                      │
│  │  (discussion)    │    "주간성과 분석 리포트"                  │
│  └────────┬─────────┘                                           │
│           │ 사람이 DEV_TASK 승인                                │
│           ▼                                                     │
│  ┌──────────────────┐                                           │
│  │  jarvis-coder    │  ← dev-task-poller → FSM queued          │
│  │  (실행 에이전트)  │    claude -p --allowedTools ...          │
│  └────────┬─────────┘                                           │
│           │ 실행 완료 → task_transitions 기록                   │
│           │ Board 실시간 로그 스트리밍                          │
│           ▼                                                     │
│  ┌──────────────────┐                                           │
│  │  RAG 인덱싱      │  ← 실행 결과가 rag/task-outcomes에 기록  │
│  │  Langfuse 트레이스│    LLM 호출마다 자동 트레이스            │
│  └────────┬─────────┘                                           │
│           │ 다음 주 분석의 입력 데이터                          │
│           └──────────────────────────────────────────────────┐  │
│                                                              │  │
│                              (loop back) ◄───────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## 루프 컴포넌트별 구현 상태

| 컴포넌트 | 파일 | 상태 |
|----------|------|------|
| 분석 에이전트 | `bin/weekly-perf-agent.sh` | ✅ ADR-021 (P4-1) |
| Board 자동 포스트 | `weekly-perf-agent.sh` 내 POST /api/posts | ✅ ADR-021 (P4-2) |
| 사람 승인 UI | Jarvis Board DEV_TASK 워크플로우 | ✅ 기존 |
| 실행 에이전트 | `bin/jarvis-coder.sh` | ✅ ADR-011 D/F 구현 |
| 실행 결과 피드백 | `task-store.mjs transition() → RAG` | ✅ ADR-011 done 피드백 |
| LLM 트레이싱 | `lib/langfuse-trace.sh` + `llm-gateway.sh` | ✅ ADR-020 (P3-2) |
| 비용/성과 대시보드 | Langfuse UI + `scripts/langfuse-report.sh` | ✅ ADR-020 (P3-3) |

## 진화 단계 정의

| 단계 | 설명 | 트리거 |
|------|------|--------|
| **L0 수동** | 사람이 직접 개선 태스크 등록 | 항상 가능 |
| **L1 반자동** | weekly-perf-agent가 제안 → 사람 승인 | 매주 일요일 |
| **L2 자동 (안전)** | 신뢰도 ≥ 90% + 위험도 low인 태스크 자동 승인 | 미구현 (L2 조건 필요) |
| **L3 완전 자율** | 사람 승인 없이 실행 → 결과 검증 → 피드백 | 미구현 (안전 게이트 필요) |

**현재 구현: L1** — 사람이 의사결정, 실행은 완전 자동.
L2/L3은 별도 안전 게이트(회귀 테스트, 롤백 자동화) 구현 후 단계적 확장.

## 루프 건강 지표 (KPI)

주간 분석에서 추적:
- **개선 제안 채택률**: Board DEV_TASK 승인수 / 생성수
- **실행 성공률**: done / (done + failed) in jarvis-coder tasks
- **루프 지연**: 분석 생성 → 승인 → 실행 완료까지 평균 시간
- **회귀율**: 동일 문제 재발 빈도 (RAG task-outcomes에서 추적)

## 관련 ADR

- ADR-011: Task FSM (실행 레이어)
- ADR-018: 멀티에이전트 오케스트레이션 (분석 레이어)
- ADR-019: Self-healing Degraded Mode (장애 처리)
- ADR-020: Langfuse LLM 트레이싱 (관찰 레이어)
