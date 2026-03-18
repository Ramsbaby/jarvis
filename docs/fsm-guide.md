# Jarvis Task FSM 운영 가이드

> 최종 업데이트: 2026-03-18 (A/B/C 신규 기능 반영)
> 대상: bot-cron.sh + task-store.mjs + tasks.db + stale-task-watcher.sh + auto-diagnose.sh

---

## 1. FSM이란?

Jarvis의 모든 cron 태스크는 SQLite(`state/tasks.db`)에 상태를 기록하며, 정해진 전이 규칙(Finite State Machine)에 따라서만 상태가 바뀐다. 이를 통해 중복 실행 방지, Circuit Breaker 격리, stale 감지, 이벤트 버스 연동이 가능하다. 태스크를 직접 실행하는 것은 `bot-cron.sh`이고, 상태 읽기/쓰기는 `lib/task-store.mjs`가 담당한다.

---

## 2. 상태 다이어그램 (ASCII)

```
            [pending]
           /         \
        queued ←←←←←← skipped (CB 쿨다운 해제 또는 수동)
          |               ↑
          ↓               | CB_OPEN 감지
       [running] ──────→ skipped
          |    \
          ↓     ↘ (재시도: running→queued, retries++)
        [done]  [failed] ──→ queued (수동 복구)
                            (terminal: 연속 3회 시 CB OPEN)
```

**허용 전이 테이블** (`lib/task-fsm.mjs`):

| from     | to (허용)                          |
|----------|------------------------------------|
| pending  | queued, skipped                    |
| queued   | running, skipped, pending          |
| running  | done, failed, queued (재시도)      |
| failed   | queued (수동 복구만)               |
| done     | (terminal — 전이 불가)             |
| skipped  | pending, queued (수동 복구/CB 해제)|

> `done`은 terminal이나, `bot-cron.sh`의 `ensureCronTask()`가 다음 cron 실행 시 `queued`로 리셋한다.

---

## 3. 일상 운영 명령어

### 현재 상태 확인

```bash
# 전체 태스크 상태 요약
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs fsm-summary

# 전체 목록 (JSON)
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs list | \
  python3 -c "import json,sys; [print(t['id'], t['status'], t.get('retries',0)) for t in json.load(sys.stdin)]"

# 특정 태스크 상세
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs get council-insight

# running 상태인 태스크 (stuck 의심)
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs list | \
  python3 -c "import json,sys; [print(t['id']) for t in json.load(sys.stdin) if t['status']=='running']"

# CB OPEN (skipped, reason=cb_open) 태스크
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs list | \
  python3 -c "
import json,sys
for t in json.load(sys.stdin):
    if t['status']=='skipped' and t.get('meta',{}).get('reason')=='cb_open':
        print(t['id'], 'CB OPEN, fails='+str(t.get('meta',{}).get('consecutiveFails','?')))
"
```

### 수동 상태 전이

```bash
# 문법: node task-store.mjs transition <id> <to_status> [triggeredBy] [extraJSON]

# failed → queued (수동 복구)
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition council-insight queued manual

# skipped → queued (CB 수동 해제)
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition github-monitor queued manual-cb-reset

# running → failed (stuck 태스크 강제 종료)
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition some-task failed ops '{"lastError":"manual kill"}'
```

### Circuit Breaker 초기화

CB는 두 곳에 상태가 있다: tasks.db(FSM skipped) + `state/circuit-breaker/<id>.json`(파일).
**둘 다 초기화해야 완전 복구**된다.

```bash
TASK_ID="github-monitor"

# 1. CB 파일 삭제
rm -f ~/.jarvis/state/circuit-breaker/${TASK_ID}.json

# 2. FSM skipped → queued
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition "$TASK_ID" queued manual-cb-reset

# 3. 확인
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs cb-status "$TASK_ID"
```

### 특정 태스크 강제 재실행

```bash
# 1. 상태를 queued로 리셋
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition council-insight queued manual-rerun

# 2. bot-cron.sh 직접 실행 (ensureCronTask가 재시작 처리)
/bin/bash ~/.jarvis/bin/bot-cron.sh council-insight
```

---

## 4. 문제 해결 (트러블슈팅)

### 태스크가 stuck running 상태일 때

**증상**: `list` 결과에서 status=running인 태스크가 오래 지속됨
**원인**: 프로세스가 비정상 종료(OOM, 머신 재부팅)되어 trap이 발동 못한 경우
**자동 처리**: stale-task-watcher.sh가 30분마다 실행 → `timeout × 2` 초 초과 시 자동 `failed` 전이
**수동 처리**:

```bash
# lock 디렉토리 확인 및 강제 제거
ls ~/.jarvis/state/active-tasks/
rmdir ~/.jarvis/state/active-tasks/<TASK_ID>.lock 2>/dev/null || true

# FSM running → failed 강제 전이
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition <TASK_ID> failed manual-stuck-recovery '{"lastError":"manual: stuck running"}'
```

### Circuit Breaker로 차단된 태스크 복구

**증상**: cron.log에 `SKIPPED [CB_OPEN]` 반복, FSM status=skipped
**원인**: 연속 3회 이상 failed
**확인**:

```bash
cat ~/.jarvis/state/circuit-breaker/<TASK_ID>.json
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs cb-status <TASK_ID>
```

**복구 절차**:
1. 실패 원인 파악 (cron.log, retry.jsonl)
2. 원인 수정 후 CB 초기화 (위 3절 참고)
3. `bot-cron.sh <TASK_ID>` 수동 실행으로 검증

#### [A] CB 쿨다운 만료 자동 복구 (신규 — 2026-03-18)

**stale-task-watcher.sh**가 30분마다 실행되면서 CB 쿨다운 만료도 자동 처리한다.

동작 흐름:
1. `state/circuit-breaker/` 디렉토리 내 모든 CB 파일 순회
2. `openAt + cooldown(초)` < 현재 시각 이면 쿨다운 만료 판정
3. CB 파일 삭제 → FSM `skipped → queued` 자동 전이
4. Discord `#jarvis` 채널에 복구 알림 전송
5. 다음 cron 실행 시 `bot-cron.sh`가 정상 처리

```bash
# stale-watcher가 자동 복구한 내역 확인
grep "CB cooldown expired" ~/.jarvis/logs/stale-task-watcher.log

# 쿨다운 만료까지 남은 시간 계산 (수동)
python3 -c "
import json, time
with open('/Users/ramsbaby/.jarvis/state/circuit-breaker/<TASK_ID>.json') as f:
    cb = json.load(f)
expires = cb['openAt']/1000 + cb.get('cooldown', 3600)
remaining = expires - time.time()
print(f'남은 쿨다운: {remaining:.0f}초 ({remaining/60:.1f}분)')
"
```

> 자동 복구를 원하지 않으면 CB 파일의 `cooldown` 값을 크게 늘리거나, 수동 복구(3절 참고)를 사용한다.

### tasks.db 무결성 깨진 경우

```bash
# WAL 체크포인트 강제 실행
node -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('/Users/ramsbaby/.jarvis/state/tasks.db');
db.exec('PRAGMA integrity_check');
db.exec('PRAGMA wal_checkpoint(FULL)');
console.log('OK');
" --experimental-sqlite --no-warnings

# 최악의 경우: DB 삭제 후 재생성 (다음 cron 실행 시 자동 재등록)
# cp ~/.jarvis/state/tasks.db ~/.jarvis/state/tasks.db.bak.$(date +%s)
# rm ~/.jarvis/state/tasks.db
```

### 전이 이력 조회 (특정 태스크)

```bash
node -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('/Users/ramsbaby/.jarvis/state/tasks.db');
db.prepare('SELECT * FROM task_transitions WHERE task_id=? ORDER BY created_at DESC LIMIT 20')
  .all('council-insight')
  .forEach(r => console.log(new Date(r.created_at).toISOString().slice(0,19), r.from_status+'→'+r.to_status, r.triggered_by||''));
" --experimental-sqlite --no-warnings
```

---

## 5. 태스크별 FSM 설정 권장 사항

tasks.json의 주요 FSM 관련 필드 권장값:

| 태스크 유형               | timeout | retry.max | circuitBreakerCooldown |
|---------------------------|---------|-----------|------------------------|
| LLM 분석 (council-insight 등) | 240-360s | 2       | 3600 (기본)            |
| 스크립트 전용 (disk-alert, gen-system-overview, skill-eval) | 10-600s | 0-1 | 3600 |
| LLM 문서 감사 (doc-sync-auditor) | 300s  | 1         | 3600                   |
| board-meeting (긴 분석)        | 600-660s | 1        | 3600                   |
| agent-batch-commit (스크립트)  | 60s      | 0        | 1800                   |
| event-trigger 핸들러           | 120-180s | 1-2      | 3600                   |
| 빠른 점검 (rate-limit-check)   | 15-30s  | 2         | 1800                   |
| recon-weekly (장시간)          | 900s    | 1         | 7200                   |

**주의사항**:
- `timeout`이 없으면 stale-watcher가 300s 폴백 사용 (실제 실행 시간과 불일치 가능)
- `retry.max`는 `retry-wrapper.sh`의 Claude 재시도 횟수 (8번째 인수로 전달됨)
- `retry.max`와 FSM의 `retries` 카운터는 별개: retry.max는 단일 cron 실행 내 재시도, retries는 ensureCronTask 리셋 횟수
- `script` 필드는 반드시 절대경로(`~/.jarvis/...`) 사용 — 상대경로는 cron CWD 의존으로 ENOENT 발생

---

## 6. depends 필드 사용법

### [C] 현재 동작 방식 (신규 강제 — 2026-03-18)

`tasks.json`의 `depends` 필드는 **`bot-cron.sh`에서 실제 강제**된다.
최근 25시간 내에 의존 태스크가 `done` 상태가 아니면 해당 태스크는 **DEFERRED(지연)**되고 `queued` 상태를 유지한다.

> ⚠️ 이전(구현 전)에는 `bot-cron.sh`가 depends를 무시했다. 2026-03-18 이후 강제 적용.

**적용 대상**: `schedule` 타입 태스크 (event_trigger 태스크는 제외 — 이벤트 발생 즉시 실행 필요)

**동작 흐름**:
1. `bot-cron.sh` 실행 → `task-store.mjs check-deps <TASK_ID>` 호출
2. 의존 태스크 중 최근 25h 내 done이 없으면 → `DEFERRED: depends not met` 로그
3. FSM 상태는 `queued` 유지 (running 전이 없음)
4. 다음 cron 주기에 재시도

```bash
# depends 충족 여부 확인
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs check-deps morning-standup

# 의존 태스크들 상태 직접 확인
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs list | python3 -c "
import json,sys
tasks = json.load(sys.stdin)
deps = ['council-insight', 'infra-daily']
for t in tasks:
    if t['id'] in deps:
        print(t['id'], t['status'], t.get('meta',{}).get('completedAt','?'))
"
```

### 의존성 태스크가 자주 실패하는 경우

depends에 걸린 태스크가 실패하면 다운스트림 태스크도 25h 동안 DEFERRED 된다.
예: council-insight 실패 → morning-standup, daily-summary, ceo-daily-digest DEFERRED

대응:
1. council-insight 원인 파악 및 수정
2. `bot-cron.sh council-insight` 수동 실행 → done 확인
3. 다운스트림 태스크 다음 cron 주기 대기 또는 수동 실행

### depends 강제 비활성화 (긴급 시)

```bash
# tasks.json에서 해당 태스크의 depends 필드 임시 제거 또는 []로 비움
# 또는 의존 태스크를 수동으로 done 전이 (실제 실행 없이)
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition council-insight done manual-skip '{"note":"manual done for deps"}'
```

---

## 7. 모니터링

### health.json FSM 섹션 해석

```bash
cat ~/.jarvis/state/health.json | python3 -c "
import json,sys
h=json.load(sys.stdin)
f=h.get('fsm',{})
print('총 태스크:', f.get('total'))
print('done:', f.get('done'))
print('failed:', f.get('failed'))
print('running:', f.get('running'))
print('queued:', f.get('queued'))
print('skipped:', f.get('skipped'))
print('CB OPEN:', f.get('cb_open'))
"
```

**비정상 신호**:
- `running` > 2: stuck 태스크 의심 → stale-watcher 로그 확인
- `cb_open` > 0: Circuit Breaker 격리 태스크 존재 → Discord 알림 확인
- `failed` > 3: 복수 태스크 동시 실패 → API 불가 상태 또는 환경 문제

### Discord 알림 종류별 대응

| 알림 메시지 | 의미 | 대응 |
|-------------|------|------|
| `Circuit Breaker: 연속 N회 실패` | CB OPEN 진입 | CB 파일 확인, 원인 수정, 수동 복구 |
| `CB cooldown expired: <id> → queued` | CB 쿨다운 만료 자동 복구 (A) | 다음 cron 실행 정상 여부 확인 |
| `stale-task-watcher: N개 stale 감지` | 프로세스 비정상 종료 | active-tasks lock 확인, DB 전이 확인 |
| `Task DROPPED: semaphore full` | 동시 실행 슬롯 포화 | `ps aux \| grep claude` 확인, 완료 대기 |
| `task.failed 이벤트 발행` | 이벤트 버스 기록 | auto-diagnose.sh 출력 확인 |
| `DEFERRED: depends not met` | 의존 태스크 미완료로 실행 지연 (C) | 의존 태스크 상태 확인, 필요 시 수동 실행 |

### 주요 로그 파일

| 파일 | 내용 |
|------|------|
| `logs/cron.log` | 모든 태스크 시작/종료/실패 기록 |
| `logs/retry.jsonl` | retry-wrapper 재시도 이력 (JSON Lines) |
| `logs/stale-task-watcher.log` | stale 감지 및 전이 기록 |
| `state/tasks.db` | FSM 상태 + 전이 이력 (SQLite) |
| `state/circuit-breaker/` | CB 파일 (태스크별 JSON) |
| `state/health.json` | 30분마다 갱신되는 전체 상태 스냅샷 |

---

## 8. 알려진 제한사항 및 구현 이력

### 현재 활성 제한사항

1. **retry.max vs FSM retries 카운터 분리**: tasks.json의 `retry.max`는 단일 cron 실행 내 retry-wrapper.sh 재시도 횟수다. FSM의 `retries` 카운터는 `ensureCronTask()` 리셋 횟수로 별개 개념.

2. **done은 terminal이지만 cron이 리셋**: `done` 상태에서 다음 cron 실행 시 `ensureCronTask()`가 자동으로 `queued`로 리셋한다. done 전이 후 `task_transitions` 기록을 통한 성공 이력은 보존된다.

3. **CB 파일 + FSM 이원화**: Circuit Breaker 상태는 `state/circuit-breaker/<id>.json`(파일)과 FSM DB(`skipped` 상태) 두 곳에 존재한다. 완전 복구 시 **둘 다** 초기화 필요 (3절 참고).

4. **event_trigger 중 bot-cron.sh 미경유 태스크**: `auto-diagnose.sh`는 직접 FSM 기록을 하도록 수정됨(B). 그러나 `github-pr-handler.sh` 등 기타 event_trigger 핸들러가 bot-cron.sh를 거치지 않는 경우 FSM 기록이 누락될 수 있다.

---

### 구현 이력 (2026-03-18 A/B/C)

| 구현 | 내용 | 관련 파일 |
|------|------|-----------|
| **A** CB 쿨다운 자동 복구 | stale-watcher.sh가 쿨다운 만료 시 skipped→queued 자동 전이 + CB 파일 삭제 | `scripts/stale-task-watcher.sh` |
| **B** event_trigger FSM 기록 | auto-diagnose.sh가 진입/완료/실패 시점에 직접 task-store.mjs 호출 | `scripts/auto-diagnose.sh` |
| **C** depends 실제 강제 | bot-cron.sh가 schedule 태스크 실행 전 checkDeps() 호출, 미충족 시 DEFERRED | `bin/bot-cron.sh`, `lib/task-store.mjs` |

> **이전 제한사항(해소됨)**:
> - ~~depends 미강제 (cron 경로)~~ → C 구현으로 해소
> - ~~event_trigger FSM 기록 누락~~ → B 구현으로 auto-diagnose.sh 해소
> - ~~CB 쿨다운 수동 복구만 가능~~ → A 구현으로 자동화
