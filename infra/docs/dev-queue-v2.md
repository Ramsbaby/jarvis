# dev-queue v2 — 자동 실행 + 박스 단위 사후 확인

> 작성: 2026-04-22 KST · 대표님 승인: "네 그렇게 해주세요" → 재검증 요청 "최대한 자동으로 돌아가게끔 원하는데 너무 복잡한 파이프라인은 원치 않아" → 간소화안 확정 ("넵 맞습니다.")
> 원칙: **승인 게이트 없음 · 박스(batch_id)는 UI 그룹핑 전용 · 기존 자동 실행 경로 보존**

---

## 1. 쉽게 설명 — 택배 송장 번호만 붙이기

지금: 택배 33개가 **낱개**로 도착 → 보드에서 개별 확인.
바꾼 뒤: 같은 곳에서 같은 시각에 보낸 건 **같은 송장 번호(batch_id)** 를 붙여서 보낸다. 처리는 **그대로 자동**으로 흐른다. 대표님은 사후에 송장 번호별로 **한 박스 단위로 펼쳐 보는 것**만 달라진다.

- 송장 번호(batch_id) = 누가(source) × 언제(배치 시각)
- 처리는 자동 (승인 대기 없음)
- 대표님 손이 가는 건 **예외 중단 버튼** 1개 (선택 사항)

---

## 2. 근본 문제 재확인

### 현재 끊긴 지점

| 단계 | 파일 | 현황 | 문제 |
|------|------|------|------|
| 입구 | `task-store.mjs ensure/enqueue` | 개별 건별 삽입 | 박스(batch_id) 없음 |
| 처리 | `jarvis-coder.sh` pick-and-lock | `queued`만 집음 | **문제없음 — 그대로 둔다** |
| 출구 | `/api/dev-tasks/` | `:id` 건별 엔드포인트만 | 박스 뷰 없음 |

### 핵심 오해 해소 (대표님의 불만 원인)

- `dev-queue`는 원래 **실행 큐**. 보드 UI가 이걸 "승인함"으로 잘못 노출 중이었음 → 승인 개념 자체가 설계 오해.
- 간소화 설계: **승인 게이트를 도입하지 않는다**. 자동 실행 유지. 보드는 박스별로 **사후 확인·예외 중단**만 한다.

---

## 3. 신규 스키마 (최소 변경)

### 컬럼 2개 추가만

```sql
ALTER TABLE tasks ADD COLUMN batch_id TEXT;   -- 예: "news-briefing-20260422-0700"
ALTER TABLE tasks ADD COLUMN source   TEXT;   -- 예: 'news-briefing' | 'auditor' | 'bot-cron' | 'manual'
CREATE INDEX IF NOT EXISTS idx_tasks_batch  ON tasks(batch_id);
CREATE INDEX IF NOT EXISTS idx_tasks_source ON tasks(source);
```

### 하지 않을 것 (일부러 뺌)

- ❌ `batches` 테이블 신설 — `GROUP BY batch_id`로 충분. SSoT 분산 위험.
- ❌ `awaiting_approval` 상태 신설 — 승인 게이트가 없으므로 불필요. 자동 실행 원칙 유지.
- ❌ `/api/dev-tasks/batches/*` 승인 API 4종 — 승인 행위 자체가 없어짐.

**`source`는 이미 `meta` JSON 안에 있음.** 별도 컬럼 승격은 인덱스 조회 속도와 `GROUP BY source` 성능을 위해서만. `meta.source`도 한동안 병기(쓰기 시 양쪽 기록) — 완전 이주 후 제거.

---

## 4. 상태 머신 — 변경 없음

```
pending → queued → running → done / failed / skipped
```

기존 FSM 그대로. `awaiting_approval` 추가 안 함. `jarvis-coder.sh`의 `pick-and-lock`도 수정 불필요.

---

## 5. 소스별 정책 — 단순 태깅만

| source | 동작 |
|--------|------|
| `news-briefing` | 자동 실행 (사후 확인용 박스 태깅) |
| `auditor` | 자동 실행 (debug-cron 중복 억제 규칙은 §7) |
| `bot-cron` | 자동 실행 (기존 dev-runner 제외 규칙 유지) |
| `manual` | 자동 실행 (수동 적재도 자동 흐름) |
| `recon` | 자동 실행 |

**대표님의 개입 지점은 단 하나**: 박스 카드의 "⛔ 박스 전체 중단" 버튼 (§6 선택 사항).

---

## 6. 보드 UI 변경

### 기본 변경 (필수)

- `/dev-tasks` 페이지를 **박스 카드 리스트**로 전환.
- 쿼리: `SELECT batch_id, source, COUNT(*), SUM(status='done'), ... GROUP BY batch_id`.
- 카드 한 장 = 한 박스 (예: "뉴스 브리핑 · 4/22 아침 · 5건").
- 펼치면 기존 개별 태스크 테이블 노출.

### 선택 추가 (대표님이 명시 요청 시만)

- 박스 카드 오른쪽에 `⛔ 박스 전체 중단` 버튼 1개.
- 클릭 → 박스 내 `queued` 상태만 `skipped`로 전이 (`running`은 건드리지 않음).
- 엔드포인트: `POST /api/dev-tasks/batches/:batch_id/abort` (쿠키 인증).

### 하지 않을 것

- 박스 승인 API 없음. 자동 실행이므로 승인할 게 없음.
- 기존 `/api/dev-tasks/:id` 엔드포인트 유지 (디버깅·예외용).

---

## 7. debug-cron-* 자동 압축 (부수 정리)

현재 `queued` 33건 중 **infra 23건**이 `debug-cron-*` 잡음. 근본 규칙:

1. `jarvis-auditor.sh`가 `debug-cron-X` 적재 **전** 실제 크론 상태 재확인. 이미 정상이면 skip.
2. 적재 시 `source='auditor'`, `batch_id='auditor-<YYYYMMDD-HH>'`.
3. 같은 crontask에 대해 최근 24h 내 `debug-cron-X`가 이미 있으면 **신규 건 생성 X**, 기존 태스크의 `retries++` 또는 `meta.last_seen_at` 갱신만.

---

## 8. 기존 queued 33건 처리안

| 소스 | 건수 | 조치 |
|------|-----:|------|
| `infra` (debug-cron-* 잡음) | 23 | **일괄 `skipped`** (1-line SQL) |
| `news-briefing` | 5 | 그대로 `queued` 유지 (자동 실행 흐름에 태움) |
| `bot-cron` | 5 | 그대로 `queued` 유지 (기존 경로) |

일회성 SQL:
```sql
UPDATE tasks
   SET status='skipped',
       meta=json_set(meta, '$.skipReason', 'one-time-infra-cleanup-20260422')
 WHERE status='queued'
   AND id LIKE 'debug-cron-%';
```

---

## 9. 구현 순서 (3단계로 압축)

> 입구 → UI → 호출처 순. 각 단계 후 기존 흐름이 깨지지 않음을 확인.

### 1단계 · DB 입구 (task-store.mjs)
- `getDb()`에 `ALTER TABLE` 마이그레이션 2줄 추가 (try/catch 멱등)
- `batch_id`, `source` 인덱스 추가
- `ensureCronTask(id, meta)`에서 `meta.batch_id`, `meta.source`를 컬럼에도 기록
- `enqueue` CLI에 `--batch-id` 플래그 추가. 기존 `--source`는 이미 존재 → 컬럼에도 기록
- `deserialize`가 `batch_id`를 surface
- **기존 호출부 무영향 검증** (플래그 미전달 시 NULL 저장 → 기존 동작 그대로)

### 2단계 · 보드 UI
- `/api/dev-tasks` 응답에 `batch_id`, `source` 포함
- `/dev-tasks` 페이지를 박스 카드 뷰로 전환 (GROUP BY batch_id)
- 박스 카드 클릭 → 기존 개별 테이블 펼쳐보기

### 3단계 · 호출처 일괄 수정
- `news-briefing`: `batch_id = "news-briefing-<YYYYMMDD-HHmm>"`
- `jarvis-auditor.sh`: `batch_id = "auditor-<YYYYMMDD-HH>"` + 24h dedupe
- `bot-cron`: `batch_id = "bot-cron-<YYYYMMDD>"` (기존 `source=bot-cron` 유지)
- `recon`: `batch_id = "recon-<YYYYMMDD-HHmm>"`

### 부수 · 기존 33건 정리
- 일회성 SQL 1회 (§8)

---

## 10. 롤백 플랜

- 스키마 변경은 **ADD COLUMN만** (기존 컬럼 수정 X) → 롤백 시 컬럼 무시하면 이전 코드 그대로 작동.
- 새 상태 도입 없음 → FSM 변경 없음.
- 각 단계 커밋 분리. 실패 시 단계별 revert 가능.
- 새 API 추가 없음 (선택 사항인 abort만 제외).

---

## 11. 완료 정의 (Definition of Done)

- [ ] 보드 `/dev-tasks` 열면 박스 카드 리스트가 기본 뷰
- [ ] `news-briefing` 인계 → 단일 박스로 등장 → 자동 실행 진행 상황 한눈에 파악 가능
- [ ] `auditor` debug-cron 자동 압축 → 24h 내 중복 0건
- [ ] 기존 33건 정리 완료 → queued에 실제 작업 대기만 남음
- [ ] 대표님이 보드 열어 **"뭐가 언제 들어왔고 지금 어디까지 처리됐나"** 를 박스 단위로 즉시 파악 가능
- [ ] 승인 행위 0회 — 전부 자동 흐름

---

## 12. 이전 설계안과의 차이 (왜 덜어냈나)

| 항목 | 원안 (6단계) | 간소화 (3단계) |
|------|-------------|----------------|
| 신규 DB 컬럼 | 3개 + `batches` 테이블 | 2개만 |
| 신규 상태 | `awaiting_approval` | 없음 |
| 신규 API | 4개 (approve/reject/partial/batches) | 0개 (선택: abort 1개) |
| 승인 단계 | 박스 단위 수동 승인 | 자동 실행 (사후 확인만) |
| 호출처 수정 | 4곳 전면 개편 | 4곳 batch_id 1줄 추가 |
| 구현 공수 | 4~6시간 | 1~2시간 |

**대표님 요청 "최대한 자동으로 돌아가게끔"에 맞춰 승인 게이트와 `batches` 테이블·새 상태를 모두 제거.** 박스 개념은 UI 그룹핑용 태그로만 살림.
