# ADR-011-task-priority-criteria — 태스크 우선순위 분류 기준과 WIP 제어 확장 경로

**상태:** accepted
**날짜:** 2026-03-21
**결정자:** Owner (인프라팀 검토)
**관련:** ADR-011 (Task FSM + SQLite), `lib/task-fsm.mjs`

---

## 우선순위 분류 기준 (urgent / normal / low)

태스크 FSM(`lib/task-store.mjs`)에서 `priority` 필드는 정수값이나, 실운용에서는 세 등급으로 묶어 판단한다. **urgent(2+)**: 당일 처리가 기본이며 현재 실행 중인 태스크를 무관하게 새 슬롯을 확보해야 한다. 장애 대응, 외부 데드라인이 임박한 업무, `council-insight`가 `CRITICAL` 태그를 붙인 항목이 해당된다. **normal(1)**: 오늘 안에 완료하면 좋지만 다음 실행 윈도우(22:55 크론)까지 밀려도 서비스 영향이 없는 작업으로, 대부분의 보드 디스패치 태스크가 여기에 속한다. **low(0)**: 백그라운드 최적화, 문서 작성, 코드 정리처럼 안 해도 당장 문제없는 작업이다. WIP 슬롯이 꽉 차면 low는 silently deferred되어도 무방하다.

---

## 향후 자동 스로틀 도입 트리거 조건

현재 `dev-runner.sh`는 단일 sequential 실행(한 번에 하나)이다. 병렬 처리 또는 스로틀 메커니즘 도입은 아래 조건 중 하나 이상이 확인될 때 검토한다.

| 트리거 | 측정 방법 | 임계값 |
|--------|-----------|--------|
| 큐 적체 지속 | `task_transitions`에서 `queued` 체류 시간 | 3일 연속 avg > 24h |
| urgent 지연 | urgent 태스크의 `queued → running` 소요 시간 | > 2시간 |
| 일일 처리 용량 초과 | 하루 `done` 전환 건수 vs 신규 투입 건수 | 신규 > 처리 × 1.5, 3일 이상 |
| 태스크 cost 급증 | `task_transitions.triggered_by` 기록 기반 평균 실행 시간 | avg > 5분/건 |

스로틀 도입 시 우선순위 순서는 **urgent → normal → low**, WIP 한도는 초기값 2로 설정 후 모니터링하여 조정한다. `lib/task-fsm.mjs`의 `pickNextTask()` 함수가 우선순위 정렬을 이미 처리하므로 실행 엔진만 병렬화하면 된다.

---

## 현행 WIP 제어 구조

```
dev-runner.sh (크론 22:55)
  └─ task-store.mjs CLI → tasks.db 조회 (status=queued, priority DESC)
       └─ 태스크 1개 순차 실행
            └─ 완료 시 done | 실패 시 failed (retries 소진 시 skipped)
```

병렬 WIP 제어 확장 시 예상 구조:

```
dev-runner.sh
  └─ pickNextTask() × N (WIP=2)
       ├─ 태스크 A (background &)
       └─ 태스크 B (background &)
  └─ wait; 결과 집계 → task-store.mjs transition
```

`BEGIN/COMMIT` 기반 원자적 전이(`lib/task-store.mjs`)는 병렬 실행 환경에서도 그대로 사용 가능하다.

---

## 관련 파일

- `lib/task-fsm.mjs` — FSM 순수 함수 (`pickNextTask`, `canTransition`, `applyTransition`)
- `lib/task-store.mjs` — SQLite 저장소 + CLI
- `bin/dev-runner.sh` — 태스크 실행 엔진 (WIP 확장 대상)
- `bin/dev-task-poller.sh` — 보드 디스패치 → 큐 투입
