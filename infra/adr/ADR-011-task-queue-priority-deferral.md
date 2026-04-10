# ADR-011-task-queue-priority-deferral — 우선순위 필드 동결 결정 및 재논의 트리거

**상태:** accepted
**날짜:** 2026-03-21
**결정자:** Owner (인프라팀 검토)
**관련:** ADR-011 (Task FSM + SQLite), ADR-011-task-priority-criteria.md

---

## 동결 사유

`lib/task-store.mjs`의 `priority` 필드는 정수형으로 저장되나, 현행 `dev-runner.sh`는 **단일 순차 실행** 구조다. 이 구조에서 우선순위 기반 스로틀(병렬 WIP 제어)을 도입하면 얻는 이득보다 부작용이 크다.

| 항목 | 근거 |
|------|------|
| **SQLite 잠금 경쟁** | 병렬 실행 시 WAL 모드에서도 write 경쟁 발생 가능. 현재 codebase는 단일 writer 가정 |
| **디버깅 복잡도** | 순차 실행에서는 `cron.log`가 태스크별 선형 흐름으로 읽힘. 병렬화 시 인터리빙으로 원인 추적 난이도 급상승 |
| **실측 데이터 부재** | WIP 슬롯 2개가 충분한지 3개가 필요한지 판단 근거 없음. ADR-011-task-priority-criteria.md 트리거 조건 3가지 중 하나도 아직 미달 |
| **urgent 태스크 희소성** | 2026-03-21 기준, `urgent(priority=2+)` 로 등록된 태스크가 `0`건. 스로틀의 최우선 수혜 대상이 없는 상태 |

---

## 필드 미예약 근거

`priority` 컬럼은 이미 `task_transitions` 테이블에 기록되어 있고 `pickNextTask()` 정렬에 반영된다. **추가 스키마 변경은 없다.** 새 필드를 미리 만들지 않은 이유:

1. **YAGNI**: 사용되지 않는 컬럼은 나중에 실제 요구사항이 나왔을 때 더 정확하게 설계 가능
2. **마이그레이션 부담**: SQLite `ALTER TABLE ADD COLUMN` 은 가능하지만, `NOT NULL` + 기본값 설계를 잘못 잡으면 기존 데이터 일관성이 깨짐
3. **현행 구조 충분**: `urgent/normal/low` 3단계는 현재 case 문으로 `_jitter` 조정에서 이미 간접 표현됨

---

## 재논의 트리거 조건

아래 조건 중 **하나 이상**이 측정될 때 이 ADR을 재오픈한다.
`measure-kpi.sh` 또는 `task_transitions` 쿼리로 측정 가능.

| 트리거 | 측정 방법 | 임계값 |
|--------|-----------|--------|
| 큐 적체 지속 | `queued` 상태 평균 체류 시간 | 3일 연속 > 24h |
| urgent 지연 발생 | `queued → running` 소요 시간 (urgent 태스크 기준) | > 2h, 1건 이상 |
| 처리 용량 역전 | 일일 `done` 건수 vs 신규 투입 건수 | 신규 > 처리 × 1.5, 3일 연속 |
| urgent 태스크 등장 | `priority >= 2` 태스크가 큐에 쌓임 | 주간 3건 이상 |

---

## 재논의 시 참고 구현

병렬화 시 `pickNextTask()` 함수 (`lib/task-fsm.mjs`)는 그대로 사용 가능하다.
`dev-runner.sh`의 실행 루프만 아래 구조로 전환하면 된다.

```bash
# WIP=2 예시 (재논의 채택 시)
for slot in 1 2; do
  _next=$(${NODE_SQLITE} "${FSM_STORE}" pick-next 2>/dev/null) || break
  [[ -z "$_next" ]] && break
  bash "$BOT_HOME/bin/jarvis-cron.sh" "$_next" &
done
wait
```

초기 WIP 한도는 **2**로 시작하고, urgent 태스크 처리 속도를 보며 조정한다.

---

## 관련 파일

- `lib/task-fsm.mjs` — FSM 순수 함수 (`pickNextTask`, `canTransition`)
- `lib/task-store.mjs` — SQLite 저장소 + CLI
- `bin/dev-runner.sh` — 현행 순차 실행 엔진
- `bin/jarvis-cron.sh` — 태스크별 실행 진입점
- `ADR-011-task-priority-criteria.md` — 우선순위 분류 기준 상세
