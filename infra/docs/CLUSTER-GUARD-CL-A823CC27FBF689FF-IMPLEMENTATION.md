# 오답승격 클러스터 방지 가드 구현 (cl-a823cc27fbf689ff)

**상태**: ✅ 구현 완료  
**작성 일자**: 2026-07-19  
**버전**: 1.0  

---

## 개요

클러스터 **cl-a823cc27fbf689ff**의 반복 실수 패턴:
- 태스크 완료 마킹만 수행, 결과 미기재 (최근 7일 재발 10건)
- 구조적 방어 가드 추가로 근본 원인 해결

## 구현 내용

### [1] Task FSM 검증 로직 추가

**파일**: `~/jarvis/runtime/lib/task-store.mjs`  
**변경**: `transition()` 함수에 `RESULT_REQUIRED` 검증 추가

```javascript
// toStatus === 'done' 시: result 필드 필수
if (toStatus === 'done') {
  const providedResult = extra.result ?? null;
  const existingResult = task.meta?.result ?? null;
  const finalResult = providedResult !== null ? providedResult : existingResult;

  if (!finalResult || (typeof finalResult === 'string' && !finalResult.trim())) {
    const err = new Error(`[RESULT_REQUIRED] task '${id}' 완료 거부: ...`);
    err.code = 'RESULT_REQUIRED';
    throw err;
  }
}
```

**역호환성**: 
- `task.meta.result` 이미 존재 → 사용 (구 완료 태스크 미영향)
- `extra.result` 제공됨 → 우선 사용 (신규 워크플로우)

### [2] 완료 워크플로우 스크립트

**파일**: `~/jarvis/infra/scripts/task-completion-workflow.sh`  
**사용**: `task-completion-workflow.sh <TASK_ID> <RESULT_CONTENT> [TRIGGERED_BY]`

**3단계 순차 실행**:

#### Step 1: 검증 (Validation)
- result 필드 존재 여부 확인
- 빈 문자열, null, undefined 모두 거부
- **실패 시**: exit 100 → `running → queued` (재시도)

#### Step 2: 업로드 (Upload)
- 결과 아카이브: `${BOT_HOME}/results/task-outcomes/YYYY-MM-DD-<TASK_ID>.json`
- RAG 피드백: `${BOT_HOME}/rag/task-outcomes-YYYY-MM.md` 에 append
- **실패 시**: exit 101 → `running → queued` (재시도)

#### Step 3: 레지스트리 갱신 (Registry Update)
- `task-store.mjs transition <TASK_ID> done <TRIGGERED_BY> '{"result":"..."}'` 호출
- FSM: `running → done` + 완료 이력 기록
- 완료 원장: `${BOT_HOME}/ledger/task-completion.jsonl` 추가
- **실패 시**: exit 102 → `running → failed` (최대 재시도 초과)

**종료 코드**:
- `0`: 성공
- `100`: 검증 실패 (result 필드 필수)
- `101`: 업로드 실패
- `102`: 레지스트리 갱신 실패

### [3] 통합 테스트

**파일**: `~/jarvis/infra/scripts/test-completion-guard.sh`  
**테스트 케이스**: 8/8 통과 ✅

| # | 테스트 | 결과 |
|---|--------|------|
| 1 | transition 함수가 빈 result 거부 | ✅ |
| 2 | transition 함수가 유효한 result 허용 | ✅ |
| 3 | 역호환성: meta.result 사용 | ✅ |
| 4 | 워크플로우 스크립트 존재성 | ✅ |
| 5 | 워크플로우 스크립트: 빈 result 거부 (exit 100) | ✅ |
| 6 | discord_route 함수 존재 | ✅ |
| 7 | 결과 아카이브 디렉토리 생성 | ✅ |
| 8 | RAG 피드백 디렉토리 생성 | ✅ |

실행:
```bash
bash ~/jarvis/infra/scripts/test-completion-guard.sh
```

### [4] 완료 알림

**discord_route 사용**:
```bash
source ~/jarvis/infra/lib/discord-route.sh
discord_route info "오답승격 가드 구현 완료 cl-a823cc27fbf689ff" \
    "클러스터=cl-a823cc27fbf689ff,결과=3단계 검증-업로드-갱신 워크플로우 완성"
```

성공 결과:
```
✅ Discord visual sent [stats]
```

---

## 성공 기준 (Sprint Contract) 달성 현황

- [x] **[1]** Jarvis Task FSM(ADR-011)에 결과 필드 검증 로직 추가
  - `transition()` 함수에 `RESULT_REQUIRED` 에러 구현
  
- [x] **[2]** 태스크 완료 워크플로우 스크립트 구현
  - 검증→업로드→레지스트리 갱신 3단계 순차 실행
  - 각 단계 실패 시 중단 및 상태 롤백 (`running → queued` or `failed`)

- [x] **[3]** 기존 태스크 완료 방식 역호환성 유지
  - result 필드 존재 시 기존 플로우 정상 작동
  - 신규 가드 로직 투명하게 적용 (meta.result 사용)

- [x] **[4]** discord_route 함수 정상 작동
  - 완료 알림 성공 (jarvis-info 채널 자동 라우팅)

- ⏳ **[5]** 동일 클러스터 재발 0건 (7일 연속 신규 사건 없음)
  - 시간 경과 후 검증 예정

---

## 사용 방법

### 태스크 완료 시

기존 방식:
```bash
node task-store.mjs transition <TASK_ID> done "bot-cron"
```

신규 방식 (결과 필드 포함):
```bash
# 방법 1: 워크플로우 스크립트 사용 (권장)
~/jarvis/infra/scripts/task-completion-workflow.sh \
    "$TASK_ID" "작업 완료 결과: ..." "bot-cron/complete"

# 방법 2: transition 직접 호출
node task-store.mjs transition "$TASK_ID" done "bot-cron" \
    '{"result":"작업 완료 결과: ..."}'
```

### 오류 처리

빈 result 거부:
```bash
$ ~/jarvis/infra/scripts/task-completion-workflow.sh "task-id" "" "test"
[04:24:13] [ERROR] [task-id] RESULT_REQUIRED — 결과 필드가 비어있거나 공blanc입니다.
$ echo $?
100  # 재시도 신호
```

### 모니터링

완료 이력 조회:
```bash
tail -f ~/jarvis/runtime/ledger/task-completion.jsonl
```

결과 아카이브 확인:
```bash
ls -la ~/jarvis/runtime/results/task-outcomes/
```

RAG 피드백 확인:
```bash
cat ~/jarvis/runtime/rag/task-outcomes-2026-07.md
```

---

## 내부 설계

### FSM 상태 전이 규칙 (기존 + 신규 검증)

| 전이 경로 | 조건 | 결과 |
|----------|------|------|
| `running → done` | result 필드 존재 ✅ | 전이 성공, 완료 이력 기록 |
| `running → done` | result 필드 비어있음 ❌ | `RESULT_REQUIRED` 에러, 전이 거부 |
| `running → queued` | 재시도 필요 | retries++ (기존 로직 유지) |
| `running → failed` | 최대 재시도 초과 | Circuit Breaker 고려 |

### 워크플로우 exit code 매핑

```
exit 0   → done 전이 + 업로드 + 레지스트리 갱신 모두 성공
exit 100 → 검증 실패 (빈 result) — 재시도 인자로 running → queued
exit 101 → 업로드 실패 (권한/파일 오류) — 재시도 인자로 running → queued  
exit 102 → 레지스트리 갱신 실패 (DB 접근 오류) — 최대 재시도 초과로 running → failed
기타      → 예기치 않은 오류
```

### 역호환성 구현

```javascript
// task-store.mjs transition() 내부
const providedResult = extra.result ?? null;        // 신규: 호출자가 제공
const existingResult = task.meta?.result ?? null;   // 기존: DB에 이미 있음
const finalResult = providedResult !== null ? providedResult : existingResult;

// 우선순위: extra.result > meta.result
// → 신규 워크플로우와 기존 태스크가 공존 가능
```

---

## 향후 개선 사항

1. **자동 통합**: bot-cron.sh / retry-wrapper.sh에 워크플로우 자동 호출 추가
2. **메트릭**: 완료 이력에서 성공률/평균 시간 추출
3. **대시보드**: 클러스터별 재발률 추이 시각화
4. **피드백 루프**: 검증 실패 사유를 다음 시도의 프롬프트에 주입

---

## 참고

- **ADR-011**: Task FSM + SQLite 아키텍처 설명
- **fsm-guide.md**: FSM 운영 가이드 및 문제 해결
- **discord-route.sh**: Discord 채널 라우팅 함수
