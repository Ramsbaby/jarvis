# Mistaken Judgment Guard Guide
## 반복 실수 클러스터 cl-e30aee511af89e13 방어 체계

**문제**: 로그 에러를 API 호출 실패로 오판하는 반복 실수
- 7일 내 재발 14건
- stderr에 "ERROR" 텍스트가 있으면 작업 실패로 오판
- 그로 인해 불필요한 재시도, 재실행 강행

**해결책**: 표준 판정 래퍼 + 전실행 가드

---

## 1. 표준 판정 래퍼 스크립트 (execution-verdict-wrapper.sh)

### 위치
`${BOT_HOME}/lib/execution-verdict-wrapper.sh` (또는 `${BOT_HOME}/lib/execution-verdict-wrapper.sh`)

### 핵심 원칙
```
exit code = 성공/실패의 유일한 판정 기준
stderr = 로깅/모니터링 참고 정보일 뿐, 판정 근거 아님
```

### 함수 목록

#### `determine_verdict <exit_code> <command_name> [<stderr_sample>]`
- **역할**: exit code 기반 성공/실패 판정
- **반환값**: 0 (성공) 또는 1 (실패)
- **예시**:
  ```bash
  source ${BOT_HOME}/lib/execution-verdict-wrapper.sh
  my_command
  RESULT=$?
  if determine_verdict $RESULT "my_command" "$stderr_output"; then
      echo "작업 성공"
  else
      echo "작업 실패"
  fi
  ```

#### `is_success <exit_code>`
- **역할**: exit code가 0인지 확인
- **반환값**: 0 (성공) 또는 1 (실패)
- **예시**:
  ```bash
  command_to_run
  EC=$?
  is_success $EC && echo "OK" || echo "FAIL"
  ```

#### `is_failure <exit_code>`
- **역할**: exit code가 0이 아닌지 확인
- **반환값**: 0 (실패함) 또는 1 (실패 안 함)

#### `get_error_type <exit_code>`
- **역할**: 실패의 분류 (참고용, 판정용 아님)
- **반환값**: "timeout", "auth_failure", "command_not_found", "unknown" 등
- **용도**: 로깅, 모니터링, 에러 분류
- **예시**:
  ```bash
  command_to_run
  EC=$?
  if is_failure $EC; then
      error_type=$(get_error_type $EC)
      log "Failed with type: $error_type"  # 로깅만, 판정 기준 아님
  fi
  ```

#### `audit_stderr_judgment_misuse <task_id> <stderr_file> <exit_code>`
- **역할**: stderr 기반 오판 감지 (감사용)
- **반환값**: 0 (리스크 없음) 또는 1 (리스크 있음)
- **용도**: 기존 코드에서 stderr 로그를 판정 기준으로 사용했는지 감시
- **예시**:
  ```bash
  audit_stderr_judgment_misuse "my-task" "/path/to/stderr.log" $exit_code
  if [[ $? -ne 0 ]]; then
      echo "경고: stderr를 판정 기준으로 사용했을 가능성"
  fi
  ```

#### `print_verdict_rules`
- **역할**: 판정 규칙 출력 (디버깅용)
- **사용법**:
  ```bash
  print_verdict_rules
  ```

### Exit Code 의미

| Exit Code | 의미 | 판정 |
|-----------|------|------|
| 0 | 성공 (명시적으로 실패한 것 아님) | **성공** |
| 1 | 일반 오류 | **실패** |
| 2 | 인증 실패 또는 예산 초과 | **실패** (재시도 불가) |
| 98 | 중복 요청 (차단됨) | 블록됨 (판정 대상 아님) |
| 99 | Circuit breaker open (차단됨) | 블록됨 (판정 대상 아님) |
| 124 | 타임아웃 (gtimeout) | **실패** (타임아웃) |
| 126-127 | 명령어 없음 | **실패** (재시도 불가) |

### 절대 금지 사항

```bash
❌ BAD: grep "ERROR" stderr.log && echo "Failed"
❌ BAD: if [[ "$stderr" =~ "failed" ]]; then retry...; fi
❌ BAD: "로그에 error 텍스트가 있으므로 재실행" → 오판 유발

✅ GOOD: exit_code=$?; if [[ $exit_code -eq 0 ]]; then success...; fi
✅ GOOD: is_success $exit_code && echo "OK" || echo "FAIL"
✅ GOOD: stderr는 로깅 목적으로만 사용
```

---

## 2. 전실행 가드 (pre-execution-guard.sh)

### 위치
`${BOT_HOME}/lib/pre-execution-guard.sh`

### 핵심 원칙
```
재실행 전에 현재 상태를 먼저 확인하여 불필요한 중복 실행 방지
```

### 함수 목록

#### `check_task_status <task_id> [<allow_retry>]`
- **역할**: 작업 재실행 가능 여부 확인
- **반환값**: 0 (진행 가능) 또는 1 (진행 불가)
- **파라미터**:
  - `task_id`: 작업 ID
  - `allow_retry`: "true"면 실패 상태도 재시도 허용, 기본값 "false"
- **로직**:
  - 상태 = "success" → 반환 1 (이미 완료, 진행 불가)
  - 상태 = "running" → 반환 1 (진행중, 중복 실행 방지)
  - 상태 = "failure/timeout" → allow_retry="true"면 반환 0, 아니면 1
  - 상태 = "unknown" → 반환 0 (신규 작업, 진행 가능)
- **예시**:
  ```bash
  source ${BOT_HOME}/lib/pre-execution-guard.sh
  
  # 이미 완료되었으면 중단
  if ! check_task_status "my-task"; then
      echo "이미 완료된 작업입니다"
      exit 0
  fi
  
  # 또는 재시도 허용
  if ! check_task_status "my-task" "true"; then
      echo "재시도 불가"
      exit 1
  fi
  ```

#### `get_task_status <task_id>`
- **역할**: 작업 현재 상태 조회
- **반환값**: "unknown", "running", "success", "failure", "timeout"
- **예시**:
  ```bash
  status=$(get_task_status "my-task")
  echo "Current status: $status"
  ```

#### `is_task_already_complete <task_id>`
- **역할**: 작업이 이미 성공했는지 확인
- **반환값**: 0 (성공함) 또는 1 (미완료)

#### `is_task_in_progress <task_id>`
- **역할**: 작업이 현재 진행 중인지 확인
- **반환값**: 0 (진행중) 또는 1 (진행중 아님)
- **특징**: PID가 살아있는지 확인, 죽은 프로세스면 자동 정리

#### `mark_task_success <task_id> [<exit_code>]`
- **역할**: 작업 완료 상태 기록
- **예시**:
  ```bash
  # ... 작업 수행 ...
  mark_task_success "my-task" 0
  ```

#### `mark_task_failure <task_id> [<exit_code>]`
- **역할**: 작업 실패 상태 기록
- **예시**:
  ```bash
  # ... 작업 수행 ...
  mark_task_failure "my-task" 1
  ```

#### `mark_task_running <task_id> <pid>`
- **역할**: 작업 진행 중 상태 기록
- **예시**:
  ```bash
  mark_task_running "my-task" $$
  ```

#### `clear_task_status <task_id>`
- **역할**: 작업 상태 파일 정리
- **용도**: 상태 초기화 (테스트용)

#### `list_all_task_statuses`
- **역할**: 모든 작업의 상태 조회 (디버깅용)
- **예시**:
  ```bash
  list_all_task_statuses
  ```

### 상태 파일 위치

상태 파일: `${BOT_HOME}/state/task-status/{task_id}.json`

예시:
```json
{
  "task_id": "my-task",
  "status": "success",
  "timestamp": "2026-07-13T04:15:23Z",
  "exit_code": 0
}
```

---

## 3. 통합 사용 예시

### 전체 워크플로우

```bash
#!/usr/bin/env bash
source ${BOT_HOME}/lib/execution-verdict-wrapper.sh
source ${BOT_HOME}/lib/pre-execution-guard.sh

TASK_ID="my-important-task"

# 1. 재실행 전 상태 확인
if ! check_task_status "$TASK_ID"; then
    echo "이미 완료되었거나 진행 중입니다"
    exit 0
fi

# 2. 작업 시작 표시
mark_task_running "$TASK_ID" $$

# 3. 실제 작업 수행
my_command_here
EXIT_CODE=$?

# 4. Exit code 기반 판정 (stderr 무시)
if is_success $EXIT_CODE; then
    # 성공
    mark_task_success "$TASK_ID" 0
    echo "작업 완료"
else
    # 실패
    mark_task_failure "$TASK_ID" $EXIT_CODE
    error_type=$(get_error_type $EXIT_CODE)
    echo "작업 실패: $error_type (exit code $EXIT_CODE)"
    exit $EXIT_CODE
fi
```

---

## 4. 기존 코드 마이그레이션

### Before (❌ 오판 패턴)

```bash
my_command > /tmp/output.txt 2> /tmp/error.log

# 오판: stderr에 "ERROR" 텍스트가 있으면 실패?
if grep -q "ERROR\|error\|failed" /tmp/error.log; then
    echo "Failed based on stderr pattern" >&2
    retry_command  # 불필요한 재시도!
    exit 1
fi
```

### After (✅ 정정된 패턴)

```bash
source ${BOT_HOME}/lib/execution-verdict-wrapper.sh
source ${BOT_HOME}/lib/pre-execution-guard.sh

my_command > /tmp/output.txt 2> /tmp/error.log
EXIT_CODE=$?

# 정정: exit code만 판정 기준
if ! is_success $EXIT_CODE; then
    error_type=$(get_error_type $EXIT_CODE)
    # stderr는 로깅만 (판정 아님)
    echo "Failed: $error_type (exit $EXIT_CODE)" >&2
    exit $EXIT_CODE
fi
```

---

## 5. 테스트

### 단위 테스트

```bash
source ${BOT_HOME}/lib/execution-verdict-wrapper.sh
source ${BOT_HOME}/lib/pre-execution-guard.sh

# Test 1: exit 0 → 성공
is_success 0 && echo "✓ Test 1 passed" || echo "✗ Test 1 failed"

# Test 2: exit 1 → 실패
is_failure 1 && echo "✓ Test 2 passed" || echo "✗ Test 2 failed"

# Test 3: 상태 기록 및 조회
mark_task_success "test-task" 0
status=$(get_task_status "test-task")
[[ "$status" == "success" ]] && echo "✓ Test 3 passed" || echo "✗ Test 3 failed"

# Test 4: 중복 실행 방지
! check_task_status "test-task" && echo "✓ Test 4 passed" || echo "✗ Test 4 failed"

# 정리
clear_task_status "test-task"
```

---

## 6. 모니터링

### 감사 로그

- **위치**: `${BOT_HOME}/logs/execution-verdict-audit.log`
- **내용**: 모든 판정 결과 (성공, 실패, 시간)

### 전실행 가드 로그

- **위치**: `${BOT_HOME}/logs/pre-execution-guard.log`
- **내용**: 상태 확인, 중복 실행 방지 기록

### 로그 조회

```bash
# 최근 판정 결과
tail -20 ${BOT_HOME}/logs/execution-verdict-audit.log

# 가드 활동
tail -20 ${BOT_HOME}/logs/pre-execution-guard.log

# 특정 작업 추적
grep "my-task" ${BOT_HOME}/logs/pre-execution-guard.log
```

---

## 7. FAQ

### Q1: stderr 로그에 "ERROR"가 있는데, exit code는 0이라면?

**A**: 성공입니다. stderr의 "ERROR"는 무시합니다.

판정:
- exit code = 0 → **성공** ✅
- stderr 내용 → 로깅만, 판정 기준 아님

**예시**:
```bash
#!/bin/bash
echo "ERROR: something logged" >&2
echo "But process completed successfully"
exit 0

# is_success 0 → 성공
# stderr의 "ERROR" → 무시됨
```

### Q2: 작업이 이미 완료됐는데, 다시 실행해야 한다면?

**A**: `check_task_status`의 두 번째 인자를 "true"로 설정하거나, `clear_task_status`로 상태 초기화.

```bash
# 방법 1: allow_retry 사용
check_task_status "my-task" "true"  # 성공했어도 재실행 가능

# 방법 2: 상태 초기화
clear_task_status "my-task"
# 그 다음 다시 실행
```

### Q3: 어떤 exit code를 반환해야 할까?

**A**: 
- 성공 → `exit 0`
- 일반 실패 → `exit 1`
- 인증 실패/예산 초과 → `exit 2` (자동 재시도 제외)
- 타임아웃 → `exit 124` (자동 재시도 제외)

다른 코드도 가능하지만, 이 4가지가 표준입니다.

### Q4: 기존 스크립트에서 이 가드를 어떻게 통합할까?

**A**: 
1. 스크립트 시작: `source ${BOT_HOME}/lib/execution-verdict-wrapper.sh`
2. 스크립트 시작: `source ${BOT_HOME}/lib/pre-execution-guard.sh`
3. 작업 전: `check_task_status $TASK_ID`
4. 작업 시작: `mark_task_running $TASK_ID $$`
5. 작업 후: `determine_verdict $? "command-name" "$stderr"`

---

## 8. 참고 문서

- **Cluster ID**: cl-e30aee511af89e13 (최근 7일 재발 14건)
- **문제 패턴**: 로그 에러를 API 호출 실패로 오판
- **해결 원칙**: exit code 1순위, stderr는 참고용

