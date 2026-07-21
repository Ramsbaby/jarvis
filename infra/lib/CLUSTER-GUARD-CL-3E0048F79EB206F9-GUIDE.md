# Cluster Guard: cl-3e0048f79eb206f9
## 명령 중복 처리 및 상태 혼란 방지 가드

**클러스터 ID:** `cl-3e0048f79eb206f9`  
**문제:** 동일 명령 중복 제출 시 상태 혼란, 부분 완료 상태에서 병렬 진행, 중복에 대해 각각 독립적 작업 보고  
**재발:** 최근 7일 14건  
**구현일:** 2026-07-16

---

## 아키텍처

### 핵심 컴포넌트

| 파일 | 역할 |
|------|------|
| `cluster-guard-cl-3e0048f79eb206f9.sh` | SQLite 기반 명령 상태 저장소 + 해시 기반 중복 감지 |
| `idempotency-middleware.sh` | ask-claude.sh와의 통합 미들웨어 (중복 감지 + 경고) |
| `ask-claude-safe.sh` | ask-claude.sh의 안전한 래퍼 (옵션: 기존 스크립트 대체) |

### 데이터 저장소

```
SQLite: ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db
테이블: task_state
  - command_hash (TEXT, UNIQUE) — SHA256(task_id + prompt)
  - command_text (TEXT) — 원본 명령 텍스트
  - status (TEXT) — pending|running|completed|failed
  - result (TEXT) — 실행 결과 (JSON/텍스트)
  - created_at (INTEGER) — 첫 생성 시간 (UNIX timestamp)
  - started_at (INTEGER) — 실행 시작 시간
  - completed_at (INTEGER) — 완료 시간
  - retries (INTEGER) — 재시도 횟수
```

### 상태 전이도

```
┌─────────┐
│  NEW    │ — 처음 실행되는 명령
└────┬────┘
     │
     ↓
┌─────────┐
│ RUNNING │ — 실행 중 (중복 감지 시 경고)
└────┬────┘
     │
  ┌──┴──┐
  ↓     ↓
┌──────┐ ┌────────┐
│ DONE │ │ FAILED │ — 중복 재실행 가능
└──────┘ └────────┘
```

---

## 사용 방법

### 1. 기본 사용: 래퍼 함수

```bash
#!/bin/bash
source ~/.jarvis/lib/idempotency-middleware.sh

# 예시: 명령 실행 전 중복 체크
task_id="my-task-001"
prompt="Please analyze this code..."

result=$(check_and_protect_duplicate "$task_id" "$prompt")
check_code=$?

case $check_code in
  0)
    echo "새로운 명령입니다. 실행을 진행합니다."
    # ask-claude.sh 실행
    ;;
  1)
    echo "진행중인 명령입니다. 기다려주세요."
    exit 1
    ;;
  2)
    echo "이미 완료된 명령입니다. 이전 결과를 재사용할 수 있습니다."
    ;;
esac
```

### 2. ask-claude-safe 사용 (권장)

```bash
#!/bin/bash
source ~/.jarvis/lib/ask-claude-safe.sh

# ask-claude.sh와 동일한 인터페이스, 자동 멱등성 체크
ask_claude_safe "my-task" "Do something" "Read,Edit"
```

### 3. Cron 작업에 통합

```bash
#!/bin/bash
# cron-task.sh

source ~/.jarvis/lib/ask-claude-safe.sh

ask_claude_safe \
  "daily-report" \
  "Generate today's report" \
  "Read,Bash" \
  "300" \
  "10000"
```

### 4. 직접 상태 조회

```bash
#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

# 단일 명령 상태 조회
get_command_status "command-hash-here"

# 모든 진행 중인 명령 조회
list_pending_commands

# 전체 상태 DB 덤프 (디버깅)
dump_state_db
```

---

## 실행 흐름

### 시나리오 1: 새로운 명령 (Normal Path)

```
User: ask-claude-safe "task-1" "analyze code"
  ↓
check_and_protect_duplicate()
  ↓ — 새로운 명령 감지
  ↓
record_command_start() — DB에 상태 기록 (status=running)
  ↓
ask-claude.sh 실행
  ↓
mark_command_completed() — DB 업데이트 (status=completed, result=...)
  ↓
return 0 (성공)
```

### 시나리오 2: 중복 명령 (Running)

```
User #1: ask-claude-safe "task-1" "analyze code" (실행 중)
User #2: ask-claude-safe "task-1" "analyze code" (동시 요청)
  ↓
check_and_protect_duplicate()
  ↓ — 진행중 명령 감지 (status=running)
  ↓
stderr에 경고 출력
⚠️  DUPLICATE COMMAND DETECTED
  ↓
return 1 (실패)
```

### 시나리오 3: 이전 완료 명령

```
User #1: ask-claude-safe "task-1" "analyze code" (완료됨)
User #2: ask-claude-safe "task-1" "analyze code" (재실행 요청)
  ↓
check_and_protect_duplicate()
  ↓ — 완료 명령 감지 (status=completed)
  ↓
stderr에 안내 메시지 출력
ℹ️  DUPLICATE COMMAND DETECTED (Completed)
  ↓
ask-claude.sh 재실행 (새로운 실행으로 기록됨)
  ↓
return 0 (진행)
```

---

## API 레퍼런스

### cluster-guard-cl-3e0048f79eb206f9.sh

```bash
# 중복 여부 확인 (DB 조회)
check_command_duplicate "command_text"
# 반환: 0=새 명령, 1=진행중, 2=완료됨, 3=실패

# 명령 시작 기록
record_command_start "command_hash" "command_text"

# 명령 완료 기록
record_command_result "command_hash" "result_json" "true"  # true=success, false=fail

# 상태 조회
get_command_status "command_hash"

# 진행 중인 명령 모두 조회
list_pending_commands

# 상태 초기화 (테스트)
clear_command_state "command_hash"

# DB 상태 덤프
dump_state_db
```

### idempotency-middleware.sh

```bash
# 중복 체크 + 보호 (권장)
check_and_protect_duplicate "task_id" "prompt" ["cluster_id"]

# 완료 기록
mark_command_completed "task_id" "prompt" ["result_text"]

# 실패 기록
mark_command_failed "task_id" "prompt" ["error_message"]

# 상태 조회
get_command_state "task_id" "prompt"
```

### ask-claude-safe.sh

```bash
# ask-claude.sh와 동일한 인터페이스 + 자동 멱등성 체크
ask_claude_safe "task_id" "prompt" [allowed_tools] [timeout] [max_budget]

# 상태 조회
ask_claude_status "task_id" "prompt"
```

---

## 모니터링 및 디버깅

### 로그 위치

```
일반 로그:      ~/.jarvis/runtime/state/idempotency-middleware.jsonl
DB 상태:        ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db
SQLite 보기:    sqlite3 ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db
```

### 상태 확인

```bash
#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

# 최근 10개 명령 상태 (테이블 형식)
dump_state_db

# 실시간 진행 중인 명령
list_pending_commands

# 특정 명령 상태
get_command_status "specific-hash"
```

### 초기화 (테스트 후)

```bash
#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

# 특정 명령 상태 초기화
clear_command_state "command_hash"

# 전체 DB 초기화 (주의!)
rm ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db
```

---

## 성공 기준 확인

### [1] ✅ 명령 해시와 실행 상태 저장 저장소
- **구현:** SQLite DB (`command-state-cl-3e0048f79eb206f9.db`)
- **테이블:** `task_state` (command_hash, command_text, status, result, timestamps, retries)
- **검증:**
  ```bash
  sqlite3 ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db ".schema task_state"
  ```

### [2] ✅ Idempotency 가드 함수
- **파일:** `cluster-guard-cl-3e0048f79eb206f9.sh`
- **핵심 함수:** `check_command_duplicate`, `record_command_start`, `record_command_result`
- **검증:**
  ```bash
  source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh
  check_command_duplicate "test command"
  ```

### [3] ✅ 중복 명령 감지 시 경고/결과 반환
- **파일:** `idempotency-middleware.sh`
- **기능:** 중복 감지 시 stderr에 경고 메시지 출력 + 상태별 반환값
- **검증:**
  ```bash
  source ~/.jarvis/lib/idempotency-middleware.sh
  check_and_protect_duplicate "task-test" "same prompt"
  check_and_protect_duplicate "task-test" "same prompt"  # 중복 경고 출력
  ```

### [4] ✅ ask-claude.sh 또는 스크립트에 가드 호출 추가
- **옵션 A (권장):** `ask-claude-safe.sh` 래퍼 사용 (기존 동작 파괴 없음)
  ```bash
  ask_claude_safe "task" "prompt"
  ```
- **옵션 B:** 기존 ask-claude.sh 내에 선택적 통합 (수동 활성화)

### [5] ✅ 클러스터 재발 방지 확인
- **테스트 시나리오:**
  1. 동일 명령 2회 연속 제출 → 중복 경고 + 상태 유지 (혼란 없음)
  2. 부분 완료 상태에서 병렬 진행 시도 → 실패 또는 재사용 (상태 혼란 없음)
  3. 중복 요청에 대한 독립적 작업 보고 방지 → 단일 해시로 통합 (보고 중복 없음)

---

## 기술 고려사항

### 왜 SQLite인가?

- **멱등성:** 중복 INSERT 방지 (UNIQUE constraint)
- **원자성:** 트랜잭션으로 상태 업데이트 보장
- **스케일:** 명령 해시 인덱스로 빠른 조회
- **확장성:** 향후 메트릭, 결과 저장 확대 용이
- **로컬:** 외부 의존성 없음

### SHA256 해시 충돌 위험

- **가능성:** 2^-128 (무시할 수 있는 수준)
- **안전성:** TASK_ID + PROMPT 조합으로 충돌 최소화

### DB 락 및 동시성

- SQLite는 단일 쓰기 커넥션만 허용 (write-lock)
- 읽기는 병렬 가능
- cron 작업 간 충돌 가능성 낮음 (순차 실행)
- 필요시 mutex 추가 가능

---

## 운영 가이드

### 일일 점검

```bash
#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

# 진행 중인 작업 확인
echo "=== Pending Commands ==="
list_pending_commands

# 최근 상태
echo "=== Recent States ==="
dump_state_db
```

### 정기 정리

```bash
#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

# 7일 이상 오래된 완료 기록 삭제 (선택사항)
sqlite3 ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db << 'EOF'
DELETE FROM task_state 
WHERE status = 'completed' 
  AND completed_at < (strftime('%s', 'now') - 7*86400);
EOF
```

### 장애 대응

**증상:** "명령이 진행 중이라고만 나옴"

```bash
# DB 확인
sqlite3 ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db \
  "SELECT * FROM task_state WHERE status = 'running';"

# 해당 해시의 상태를 강제 변경
sqlite3 ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db \
  "UPDATE task_state SET status = 'failed', completed_at = strftime('%s', 'now') WHERE command_hash = '...';"
```

---

## 향후 개선

- [ ] Redis 지원 (분산 환경)
- [ ] 결과 캐싱 (hit rate 추적)
- [ ] 타임아웃 자동 페일오버
- [ ] 결과 TTL (자동 정리)
- [ ] Prometheus 메트릭 노출
