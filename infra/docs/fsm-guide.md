# Jarvis Task FSM 운영 가이드

> 최종 업데이트: 2026-03-31 (9절 추가: transition/ensureCronTask/checkDeps API 레퍼런스)
> 대상: bot-cron.sh + task-store.mjs + tasks.db + stale-task-watcher.sh + auto-diagnose.sh + dashboard/server.mjs

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
        [done]  [failed] ──→ queued / pending / done (수동 복구 또는 재시도 성공)
                            (terminal: 연속 3회 시 CB OPEN)
```

**허용 전이 테이블** (`lib/task-fsm.mjs`):

| from     | to (허용)                          |
|----------|------------------------------------|
| pending  | queued, skipped                    |
| queued   | running, skipped, pending          |
| running  | done, failed, queued (재시도)      |
| failed   | queued, pending, done (수동 복구 또는 재시도 성공) |
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

# 그룹 태스크 집계 (부모-자식 진행률)
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs list-with-aggregation | \
  python3 -c "
import json,sys
tasks = json.load(sys.stdin)
for t in tasks:
    if t.get('total_children',0) > 0:
        progress = (t.get('completed_children',0) / t.get('total_children',1)) * 100
        print(f\"{t['id']}: {t['completed_children']}/{t['total_children']} done ({progress:.0f}%)\")
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

### 대량 ABORTED (exit 127) — crontab PATH 문제

**증상**: 여러 태스크가 동시에 `ABORTED (unexpected exit: 127)`으로 종료, cron.log에
`bot-cron.sh: line XXX: <명령어>: command not found` 출력
**원인**: crontab의 기본 PATH(`/usr/bin:/bin`)에 해당 명령어가 없음. `set -euo pipefail`로
인해 `$()` 안에서 명령 실패 시 즉시 스크립트 종료.
**수정 원칙**: `bot-cron.sh`에서 외부 명령 추가 시 반드시 `command -v`로 존재 확인 후 fallback.
macOS 기본 탑재 보장: `shasum`, `python3`, `awk`, `jq` (`/opt/homebrew/bin` 포함 시).
`md5`, `md5sum`은 환경에 따라 없을 수 있음 → `shasum`으로 대체.

**2026-03-22 수정 사례**: `bot-cron.sh` 191~193번 라인의 프롬프트 변경 감지 로직에서
`md5` 호출 → crontab 환경 exit 127 → 전체 태스크 ABORTED. `shasum`으로 교체 완료.

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

### enabled: false로 태스크 영구 비활성화

`bot-cron.sh`는 두 가지 스킵 필드를 지원한다:

- `"disabled": true` — 레거시 필드. `SKIPPED (disabled)` 로그 후 exit 0.
- `"enabled": false` — 신규 필드 (2026-04-01 추가). `SKIPPED (enabled: false)` 로그 후 exit 0.

두 방식 모두 FSM 전이 없이 조용히 종료된다 (Circuit Breaker 카운트 소모 없음).

```bash
# tasks.json에서 비활성화
# "enabled": false  →  bot-cron.sh가 SKIPPED (enabled: false)로 건너뜀

# 직접 crontab 등록 스크립트(board-topic-proposer 등)는 스크립트 내부에서
# tasks.json을 읽어 enabled 필드를 확인해야 한다 (bot-cron.sh 경유하지 않음)
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
with open('~/.jarvis/state/circuit-breaker/<TASK_ID>.json') as f:
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
const db=new DatabaseSync('~/.jarvis/state/tasks.db');
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
const db=new DatabaseSync('~/.jarvis/state/tasks.db');
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
| board-topic-proposer (LLM 제안) | 120s   | 1         | 1800                   |
| recon-weekly (장시간)          | 900s    | 1         | 7200                   |

**주의사항**:
- `timeout`이 없으면 stale-watcher가 300s 폴백 사용 (실제 실행 시간과 불일치 가능)
- `retry.max`는 `retry-wrapper.sh`의 Claude 재시도 횟수 (8번째 인수로 전달됨)
- `retry.max`와 FSM의 `retries` 카운터는 별개: retry.max는 단일 cron 실행 내 재시도, retries는 ensureCronTask 리셋 횟수
- `retry-wrapper.sh` 실행 로그: 시작 시 Board API에서 태스크 제목을 fetch → "⚙️ 작업 시작 — {제목}" 로그 전송. heartbeat(30초)에 경과 시간 포함 ("⏳ 진행 중 (Ns 경과)")
- **DEV_TASK_ID 환경변수**: retry-wrapper.sh가 ask-claude.sh를 호출할 때 `DEV_TASK_ID=$TASK_ID`를 전달. 이 변수가 설정되면 llm-gateway.sh가 `stream-json` 모드로 전환하여 도구 호출 이벤트를 `stream-to-board.sh`로 실시간 전송 (3초 스로틀)
- **dev-task-daemon.sh**: tmux 상주 데몬이 10초 간격으로 Board에서 승인 태스크를 가져와 즉시 실행 (concurrency=1). 기존 cron 폴러(*/5)는 fallback으로 유지. 멈춘 태스크(running >10분)는 자동 재큐잉
- `script` 필드는 반드시 절대경로(`~/.jarvis/...`) 사용 — 상대경로는 cron CWD 의존으로 ENOENT 발생
- `skipDuringRagRebuild: true` — `~/.jarvis/state/rag-rebuilding.json` 존재 시 태스크 실행 보류 (RAG 재인덱싱 중 Claude 에이전트가 DB를 파괴하는 사고 방지). `system-health`에 적용됨.

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
참고: board-monitor/agent/catchup은 LaunchAgent 직접 실행 방식이라 FSM 의존성 체계 외부에 있음

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
| `세마포어 포화: <id> → retry 소모 없이 재큐잉` | 슬롯 포화 — retry 카운트 보존 (exit 100) | 다음 cron 실행 시 자동 재시도, `ps aux \| grep claude` 확인 |
| `task.failed 이벤트 발행` | 이벤트 버스 기록 | auto-diagnose.sh 출력 확인 |
| `DEFERRED: depends not met` | 의존 태스크 미완료로 실행 지연 (C) | 의존 태스크 상태 확인, 필요 시 수동 실행 |
| `🔴 AUTH_ERROR: <id> 실패. Claude 토큰 만료.` | **CB 3회 대기 없이 즉시** ntfy urgent 발송 | `claude login` 또는 `/account refresh` 실행 |

### 주요 로그 파일

| 파일 | 내용 |
|------|------|
| `logs/cron.log` | 모든 태스크 시작/종료/실패 기록 |
| `logs/retry.jsonl` | retry-wrapper 재시도 이력 (JSON Lines) |
| `logs/stale-task-watcher.log` | stale 감지 및 전이 기록 |
| `state/tasks.db` | FSM 상태 + 전이 이력 (SQLite) |
| `state/circuit-breaker/` | CB 파일 (태스크별 JSON) |
| `state/health.json` | 30분마다 갱신되는 전체 상태 스냅샷 |
| Board `execution_log` | retry-wrapper.sh 실행 중 30초마다 PATCH /api/dev-tasks/{id} 로 스트리밍 (BOARD_URL + AGENT_API_KEY + TASK_ID 설정 시) |

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
| **D** dev-runner 분리 | `getReadyTasks()`에서 `source: 'bot-cron'` 태스크 제외. jarvis-coder(구 dev-runner)는 board-task/improvement/cron-fix 등 개발 태스크만 처리. bot-cron 태스크는 bot-cron.sh 단독 관리 | `lib/task-store.mjs` |
| **F** pick → pick-and-lock | `pick` 커맨드는 ID 반환만 했으나, 병렬 실행 시 race condition 발생. `pick-and-lock`은 `BEGIN IMMEDIATE` 트랜잭션으로 pick+queued→running 전이를 원자적으로 처리. `bin/jarvis-coder.sh`(구 dev-runner.sh)가 단독 사용 | `lib/task-store.mjs`, `bin/jarvis-coder.sh` |
| **G** AUTH_ERROR 즉시 ntfy | CB 3회 대기 없이 첫 번째 AUTH_ERROR 감지 시 즉시 ntfy urgent 발송 (30분 쿨다운). `is_error:true` + `duration_api_ms:0` 패턴으로 진짜 인증 실패 구별. 2026-03-23 사고(7.5h 묵살) 재발방지 | `bin/bot-cron.sh` |
| **G** jarvis-coder 리브랜딩 | `dev-runner.sh` → `bin/jarvis-coder.sh` 명칭 변경. Discord 알람·로그 파일명·크론 항목 일괄 갱신. `dev-runner.sh`는 하위 호환 심볼릭 링크로 유지. `bot-cron.sh`에 `jarvis-coder\|dev-runner` 케이스 추가 | `bin/jarvis-coder.sh`, `bin/bot-cron.sh` |
| **H** Board 실시간 로그 스트리밍 | `retry-wrapper.sh`에 배경 heartbeat 루프 추가. `BOARD_URL` + `AGENT_API_KEY` + `TASK_ID` 세 환경변수가 모두 설정된 경우에만 활성화. 실행 시작 즉시 태스크 제목 포함 "⚙️ 작업 시작 — [제목]" 항목 전송 (Board API로 title 조회), 이후 30초마다 경과 시간 포함 항목을 `PATCH /api/dev-tasks/{TASK_ID}` (`log_entry` 필드)로 전송. `stream-to-board.sh` 완료 시 스로틀 우회하여 "✅ 완료" 전송. EXIT trap에서 자동 종료 — 메인 실행을 절대 블록하지 않음 | `bin/retry-wrapper.sh`, `lib/stream-to-board.sh` |
| **I** failed → pending/done 전이 허용 | jarvis-coder가 Board API에 `failed` 상태를 PATCH할 때 HTTP 400 반환 문제 수정. Board API(`agentAllowed`)에 `'failed'` 추가, `validTransitions['in-progress']`에 `'failed'` 추가, `failed: ['pending']` 전이 추가. task-fsm.mjs도 `failed: ['queued', 'pending', 'done']`으로 확장하여 재시도 성공 시 `done` 직접 전이 가능 | `app/api/dev-tasks/[id]/route.ts` (Railway), `lib/task-fsm.mjs` |
| **K** stale-watcher 기본값 300s→900s | tasks.json에 없는 동적 태스크(dispatch-*, synth-* 등)의 timeout 조회 순서: ① tasks.json ② tasks.db `meta.timeout` ③ 기본값 900s. 기존 300s 기본값은 stale 임계 10분 → 실제 실행 시간(15-30분) 보다 짧아 정상 실행 중인 태스크를 오탐으로 failed 전이시킴. stale 임계 = timeout × 2 이므로 900s → 30분. Board API `failed → done` 전이도 허용 추가 (stale-watcher 오탐 후 실제 완료 복구 가능) | `scripts/stale-task-watcher.sh`, `dashboard/app/api/dev-tasks/[id]/route.ts` |
| **L** 실패 알림 채널 jarvis-system 전환 | `bot-cron.sh`의 태스크 실패/FSM 요약 Discord 알림이 `webhooks["jarvis"]` → `webhooks["jarvis-system"]` 우선으로 전환. `jarvis-system` 웹훅이 없으면 `jarvis`로 fallback하여 하위호환 유지. 시스템 운영 알림을 범용 채널이 아닌 전용 채널로 분리 | `bin/bot-cron.sh` |
| **M** tasks.json retry.max 전달 | `bot-cron.sh`가 `tasks.json`의 `retry.max`(또는 `maxRetries`) 값을 읽어 `retry-wrapper.sh`에 8번째 인수(`MAX_RETRIES`)로 전달. 미설정 시 기본값 3. 태스크별 재시도 횟수를 `config/tasks.json`에서 선언적으로 제어 가능 | `bin/bot-cron.sh`, `bin/retry-wrapper.sh` |
| **N** stale-watcher 단일 인스턴스 보장 | cron + LaunchAgent 이중 등록 시 동일 태스크를 2회 failed 처리하는 경쟁 조건 수정. `/tmp/jarvis-stale-watcher.pid` PID 파일 기반 가드 추가: 기존 PID가 살아있으면 즉시 exit 0, EXIT trap으로 PID 파일 자동 정리 | `scripts/stale-task-watcher.sh` |
| **O** ceo-daily-digest 스케줄 22:00→23:15 | council-insight(23:05)보다 먼저 실행되어 구조적으로 항상 DEFERRED되던 문제 수정. 23:15로 변경하여 council-insight 완료 후 실행 보장 | `config/tasks.json` |
| **P** github-monitor timeout 180s→720s | claude -p 실행 시 LLM API 응답 대기로 실제 소요 시간이 10-25분임에도 timeout=180s(stale임계=6분)로 설정되어 항상 stale-watcher 오탐. timeout=720s(stale임계=24분)로 수정 | `config/tasks.json` |
| **R** SQLite WAL 튜닝 | `task-store.mjs`의 DB 초기화에 3개 PRAGMA 추가: ① `busy_timeout=10000` (5→10초, 동시 쓰기 시 대기 여유 증가) ② `wal_autocheckpoint=1000` (1000페이지마다 WAL 자병합, 무한 WAL 성장 방지) ③ `PRAGMA optimize` (연결 시마다 쿼리 플래너 통계 갱신, 인덱스 활용 최적화) | `lib/task-store.mjs` |
| **S** 부모-자식 태스크 집계 (aggregation API) | ① tasks 테이블에 `parent_id TEXT` 컬럼 추가 (마이그레이션 자동). ② `addTask()`, `ensureCronTask()`에 parent_id 파라미터 지원. ③ `deserialize()`에 parent_id 필드 추가. ④ `list-with-aggregation` CLI 명령 신규: 각 태스크에 `total_children`, `completed_children` 필드 자동 계산 (parent_id 그룹별 자식 수 + done 상태 자식 수). ⑤ Dashboard `/api/tasks` 엔드포인트를 `list-with-aggregation`으로 변경하여 API 응답에 진행률 필드 포함. 프론트엔드에서 그룹 태스크의 진행률 바 렌더링 가능 | `lib/task-store.mjs`, `dashboard/server.mjs` |

> **이전 제한사항(해소됨)**:
> - ~~depends 미강제 (cron 경로)~~ → C 구현으로 해소
> - ~~event_trigger FSM 기록 누락~~ → B 구현으로 auto-diagnose.sh 해소
> - ~~CB 쿨다운 수동 복구만 가능~~ → A 구현으로 자동화
> - ~~dev-runner가 bot-cron 태스크 실행 (오작동)~~ → D 구현으로 해소

---

## 9. task-store.mjs 핵심 API 레퍼런스

`lib/task-store.mjs`의 세 핵심 함수 동작 사양. 코드 변경 시 이 절을 함께 갱신할 것.

### `transition(id, toStatus, opts?)`

**역할**: 단일 태스크의 FSM 상태를 원자적으로 전이시키고 이력을 기록한다.

```javascript
// 시그니처
transition(id: string, toStatus: string, opts?: {
  triggeredBy?: string,  // 기본값: 'system'
  extra?: object         // 기본값: {}
}): Task
```

**동작 흐름**:
1. `canTransition(currentStatus, toStatus)` 검증 — 허용되지 않은 전이면 throw
2. `BEGIN IMMEDIATE` 트랜잭션 진입
3. `tasks` 테이블 상태 업데이트:
   - `running → queued` 전이 시: `retries++` 증가
   - `toStatus === 'done'` 시: `completedAt = NOW()`
4. `task_transitions` 테이블에 이력 행 삽입 `{task_id, from_status, to_status, triggered_by, extra_json, created_at}`
5. `COMMIT`
6. `toStatus === 'done'` 시: RAG 피드백 파일 `~/.jarvis/rag/task-outcomes-YYYY-MM.md`에 결과 append
7. 업데이트된 태스크 객체 반환

**CLI 사용**:
```bash
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  transition <id> <toStatus> [triggeredBy] [extraJSON]
```

---

### `ensureCronTask(id, meta?)`

**역할**: cron 태스크를 DB에 보장한다. 없으면 생성, 실패/완료 상태면 재시작, 이미 queued/running이면 그대로.

```javascript
// 시그니처
ensureCronTask(id: string, meta?: object): { id: string, status: string, isNew: boolean }
```

**동작 흐름**:
1. `id`로 tasks DB 조회
2. **태스크 없음** → `queued` 상태로 신규 insert. `isNew: true` 반환
3. **`failed` 또는 `done`** → `BEGIN IMMEDIATE` 트랜잭션으로 `queued` 전이 + `task_transitions` 기록. `isNew: false`
4. **`queued`, `running`, `skipped`** → 아무것도 하지 않음. 현재 상태 그대로 반환
5. `parent_id`가 meta에 있으면 컬럼에 저장 (S 구현)

**주의**: `done`은 FSM에서 terminal 상태지만, 이 함수가 매 cron 실행마다 `queued`로 리셋하여 반복 실행을 구현한다. 단, `task_transitions` 이력은 보존된다.

---

### `checkDeps(taskId, windowHours?)`

**역할**: 태스크의 `depends` 조건이 충족되었는지 확인한다.

```javascript
// 시그니처
checkDeps(taskId: string, windowHours?: number /* 기본값: 25 */): { ok: boolean, missing: string[] }
```

**동작 흐름**:
1. `~/.jarvis/state/effective-tasks.json` 읽기 (없으면 `config/tasks.json` fallback)
2. `taskId`에 해당하는 태스크 항목의 `depends` 배열 추출
3. `depends`가 없거나 빈 배열 → `{ ok: true, missing: [] }` 즉시 반환
4. 각 의존 태스크 ID에 대해: tasks DB에서 `status = 'done'` AND `completedAt >= NOW() - windowHours*3600*1000` 인 행 존재 여부 확인
5. 미충족 의존 태스크 → `missing[]` 배열에 추가
6. `{ ok: missing.length === 0, missing }` 반환

**bot-cron.sh 연동**: `schedule` 타입 태스크 실행 전 반드시 호출. `ok: false`이면 태스크를 DEFERRED하고 `queued` 상태 유지. `event_trigger` 타입은 호출 안 함.

**CLI 사용**:
```bash
node --experimental-sqlite --no-warnings ~/.jarvis/lib/task-store.mjs \
  check-deps <taskId>
```

---

## 10. 개발 대기(Backlog) 관리

개발 대기 항목(Feature backlog)은 이사회 승인 후 구현 일정 대기 중인 작업들이다. `config/dev-backlog.json`에서 중앙화하여 관리한다.

### 백로그 조회

```bash
# 현재 백로그 목록 확인
cat ~/.jarvis/config/dev-backlog.json | jq '.backlog[] | {id, title, status, phase}'

# 특정 작업 상세
cat ~/.jarvis/config/dev-backlog.json | jq '.backlog[] | select(.id=="dashboard-archive")'

# 차단 중인 작업 확인
cat ~/.jarvis/config/dev-backlog.json | jq '.blocked_by'
```

### 백로그 항목 구조

각 백로그 항목은:
- `id`: 고유 식별자 (예: `dashboard-progress-bar`)
- `title`: 작업 제목
- `priority`: urgent / high / medium / low
- `phase`: `post-aggregation-api` / `polish-sprint` / 기타
- `status`: `backlog` (기본값) / `in-progress` / `completed`
- `dependencies`: 선행 작업 ID 배열
- `acceptance_criteria`: 완료 기준 (배열)

### 백로그 업데이트 워크플로우

1. **상태 변경** (작업 착수 시):
   ```bash
   jq '.backlog[] |= if .id=="dashboard-archive" then .status="in-progress" else . end' \
     ~/.jarvis/config/dev-backlog.json > /tmp/dev-backlog.tmp && \
     mv /tmp/dev-backlog.tmp ~/.jarvis/config/dev-backlog.json
   ```

2. **완료 표시**:
   ```bash
   jq '.backlog[] |= if .id=="dashboard-archive" then .status="completed" | .completed_at=now|tostring else . end' \
     ~/.jarvis/config/dev-backlog.json > /tmp/dev-backlog.tmp && \
     mv /tmp/dev-backlog.tmp ~/.jarvis/config/dev-backlog.json
   ```

3. **새 항목 추가** — `jq`로 `.backlog += [새_항목]` 후 파일 저장

### 참고: ADR-012와의 관계

- ADR-012 (2026-03-31): 대시보드 UI/UX 개선 범위 및 배포 전략 결정
- **후순위 항목 (이 백로그에 등록)**:
  - `dashboard-progress-bar`: aggregation API 완성 후
  - `dashboard-archive`: polish sprint
  - `dashboard-empty-state`: polish sprint
- **선행 필수 작업**:
  - `dashboard-null-handling`: sysMetrics null 처리 (진행 중)
  - `dashboard-aggregation-api`: 백엔드 집계 API (진행 중)
