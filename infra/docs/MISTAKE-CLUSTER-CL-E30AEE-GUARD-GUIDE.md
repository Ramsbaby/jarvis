# 반복 실수 클러스터 cl-e30aee511af89e13 방어 가이드

**목적**: 로그 에러를 API 호출 실패로 오판하는 반복 실수 클러스터를 방어하기 위한 표준 판정 및 재실행 가드

**버전**: 1.0 (2026-07-13)

---

## 1. 문제 정의

### 반복 실수의 특징
- **로그 에러를 API 실패로 오판**: stderr에 "ERROR" 텍스트가 있으면 즉시 실패로 판정
- **불필요한 재시도 강행**: 판정 오류로 인한 무한 루프, 중복 실행
- **grep 검증 부족**: 실제 상태를 재확인하지 않고 선언
- **도구 로그와 실패 혼동**: 로그 출력 에러 ≠ 실행 실패

### 기존 동작의 문제
```bash
# ❌ 잘못된 판정 로직 (절대 금지)
if grep -q "ERROR" "$stderr_log"; then
    echo "failed"  # stderr 텍스트 기반 오판
    exit 1
fi
```

---

## 2. 해결책: Exit Code First 판정

### 핵심 원칙
1. **Exit code를 1순위 판정 기준으로 사용**
   - `exit code == 0` → SUCCESS (stderr 무시)
   - `exit code != 0` → FAILURE (stderr 내용 무관)
   - `stderr` → 로깅 및 모니터링 용도로만 사용

2. **성공/실패 판정 규칙**
   ```bash
   # ✅ 올바른 판정 로직
   command_result=$?
   if [[ $command_result -eq 0 ]]; then
       echo "success"  # exit code 0 = 성공
   else
       echo "failure"  # exit code != 0 = 실패
   fi
   ```

3. **stderr 다루기**
   - 판정 기준으로 사용 금지
   - 로그 파일로 기록하여 추적용으로만 사용
   - 모니터링 및 디버깅에만 활용

---

## 3. 구현된 래퍼 및 함수

### 3.1 Exit Code 판정 래퍼 (`exit-code-first-wrapper.sh`)
**위치**: `~/jarvis/infra/lib/exit-code-first-wrapper.sh` # ALLOW-DOTJARVIS

**사용 가능한 함수**:
```bash
source ~/jarvis/infra/lib/exit-code-first-wrapper.sh

# 1. 일반 exit code 판정
evaluate_command_result <exit_code> [<task_id>] [<stderr_log_path>]
# 반환값: 0 (성공) / 1 (실패)

# 2. 명령 실행 후 자동 판정
run_command_with_guard <task_id> <command> [args...]
# 반환값: 0 (성공) / 1 (실패)

# 3. 판정 결과 로깅
log_decision <task_id> <decision> <exit_code> [<stderr_snippet>] [<action>]
```

**예시**:
```bash
source ~/jarvis/infra/lib/exit-code-first-wrapper.sh

# 직접 exit code 전달
some_command
exit_code=$?
evaluate_command_result "$exit_code" "my-task" "$stderr_log"

# 또는 래퍼를 통해 직접 실행
run_command_with_guard "my-task" /path/to/command arg1 arg2
```

### 3.2 실행 판정 래퍼 (`execution-verdict-wrapper.sh`)
**위치**: `~/jarvis/infra/lib/execution-verdict-wrapper.sh` # ALLOW-DOTJARVIS

**사용 가능한 함수**:
```bash
source ~/jarvis/infra/lib/execution-verdict-wrapper.sh

# 1. 핵심 판정 함수 (exit code 기반)
determine_verdict <exit_code> <command_name> [<stderr_sample>]
# 반환값: 0 (성공) / 1 (실패)

# 2. 편의 함수
is_success <exit_code>      # exit code 0 이면 0 반환
is_failure <exit_code>      # exit code != 0 이면 0 반환

# 3. 에러 타입 분류 (참고용, 판정에 미사용)
get_error_type <exit_code>  # "timeout", "auth_failure", "circuit_open" 등

# 4. 감사 함수
audit_stderr_judgment_misuse <task_id> <stderr_file> <exit_code>
# stderr 패턴 오판 위험 검사
```

**예시**:
```bash
source ~/jarvis/infra/lib/execution-verdict-wrapper.sh

# 명령 실행
my_command arg1 arg2
exit_code=$?

# exit code 기반 판정
if determine_verdict "$exit_code" "my-task" "$(cat stderr.log)"; then
    echo "✓ Task succeeded"
else
    echo "✗ Task failed"
fi

# 또는 편의 함수 사용
if is_success "$exit_code"; then
    echo "Success"
else
    echo "Failure"
fi
```

### 3.3 재실행 가드 (`pre-execution-guard.sh`)
**위치**: `~/jarvis/infra/lib/pre-execution-guard.sh` # ALLOW-DOTJARVIS

**사용 가능한 함수**:
```bash
source ~/jarvis/infra/lib/pre-execution-guard.sh

# 1. 재실행 전 상태 확인 (핵심)
check_task_status <task_id> [allow_retry=false]
# 반환값: 0 (진행 가능) / 1 (진행 불가, 이미 완료됨 또는 진행중)

# 2. 작업 상태 조회
get_task_status <task_id>
# 반환값: "unknown", "running", "success", "failure", "timeout"

# 3. 작업 상태 기록
mark_task_running <task_id> <pid>
mark_task_success <task_id> [exit_code]
mark_task_failure <task_id> [exit_code]

# 4. 상태 파일 정리
clear_task_status <task_id>

# 5. 디버그
list_all_task_statuses
```

**예시 (재실행 방지)**:
```bash
source ~/jarvis/infra/lib/pre-execution-guard.sh

TASK_ID="my-data-sync"

# 재실행 전 현재 상태 확인
if ! check_task_status "$TASK_ID"; then
    echo "Task already completed or in progress. Skipping."
    exit 0
fi

# 진행 중 표시
mark_task_running "$TASK_ID" "$$"

# 작업 수행
result=$?

# 결과 기록
if [[ $result -eq 0 ]]; then
    mark_task_success "$TASK_ID" "$result"
else
    mark_task_failure "$TASK_ID" "$result"
fi
```

---

## 4. 통합 사용 패턴

### 패턴 1: 표준 크론 작업
```bash
#!/usr/bin/env bash
set -euo pipefail

source ~/jarvis/infra/lib/exit-code-first-wrapper.sh
source ~/jarvis/infra/lib/execution-verdict-wrapper.sh
source ~/jarvis/infra/lib/pre-execution-guard.sh

TASK_ID="my-cron-task"

# 1. 재실행 전 상태 확인 (이미 완료되었으면 스킵)
if ! check_task_status "$TASK_ID"; then
    exit 0  # 이미 완료됨
fi

# 2. 진행 중 표시
mark_task_running "$TASK_ID" "$$"

# 3. 작업 실행
stderr_log=$(mktemp)
run_command_with_guard "$TASK_ID" /path/to/my-command arg1 arg2 2>"$stderr_log" || exit_code=$?

# 4. Exit code 기반 판정
if determine_verdict "$exit_code" "$TASK_ID" "$(cat "$stderr_log")"; then
    mark_task_success "$TASK_ID" 0
    echo "✓ Task completed successfully"
else
    mark_task_failure "$TASK_ID" "$exit_code"
    echo "✗ Task failed with exit code $exit_code"
fi
```

### 패턴 2: ask-claude.sh 호출 (이미 구현됨)
```bash
#!/bin/bash
# ask-claude.sh는 다음 가드를 자동으로 로드합니다:
# - execution-verdict-wrapper.sh (line 133)
# - pre-execution-guard.sh (line 136)

# 호출자는 exit code로만 결과를 판정하면 됩니다
ask-claude.sh "my-task" "Write a Python script..." || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    echo "✓ Claude succeeded"
else
    echo "✗ Claude failed with code $exit_code"
fi
```

---

## 5. Exit Code 사전

| 코드 | 의미 | 판정 | 비고 |
|------|------|------|------|
| 0 | 성공 | ✓ SUCCESS | 모든 명령의 기본 성공 코드 |
| 1 | 일반 오류 | ✗ FAILURE | 일반적인 실패 |
| 2 | 인증 실패 / 예산 초과 | ✗ FAILURE | ask-claude.sh에서 사용 |
| 98 | 중복 요청 차단 | ⏭ SKIP | 차단됨 (실패 아님) |
| 99 | Circuit breaker open | ⏭ SKIP | 보호 모드 활성화 |
| 124 | 타임아웃 | ✗ FAILURE | gtimeout 또는 명시적 타임아웃 |
| 126-127 | 명령어 없음 | ✗ FAILURE | 비복구 가능 오류 |

---

## 6. 안티패턴 (절대 금지)

❌ **금지 사항**:
```bash
# 1. stderr 텍스트 기반 판정
if grep -q "error\|fail" "$stderr_log"; then
    exit 1  # 절대 금지!
fi

# 2. stderr 존재 여부로 판정
if [[ -s "$stderr_log" ]]; then
    exit 1  # 절대 금지!
fi

# 3. stderr 패턴으로 재시도 결정
if [[ "$stderr" =~ "connection refused" ]]; then
    # 재시도  # 절대 금지!
fi

# 4. 상태 확인 없이 재시도
for i in {1..5}; do
    my_command && break
    # 상태를 확인하지 않으므로 중복 실행 위험
done
```

✅ **올바른 방법**:
```bash
# 1. exit code만 사용
my_command
exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    echo "Success"
else
    echo "Failure"
fi

# 2. 재실행 전 상태 확인
if ! check_task_status "$TASK_ID"; then
    exit 0  # 이미 완료
fi

# 3. stderr는 로깅 용도로만
stderr_log=$(mktemp)
my_command 2>"$stderr_log"
# stderr는 모니터링/디버깅 용도로만 기록
cat "$stderr_log" >> /var/log/my-app.log
```

---

## 7. 모니터링 및 디버깅

### 작업 상태 조회
```bash
source ~/jarvis/infra/lib/pre-execution-guard.sh
list_all_task_statuses
```

### 판정 감사
```bash
source ~/jarvis/infra/lib/execution-verdict-wrapper.sh
print_verdict_rules  # 현재 판정 규칙 출력
```

### 로그 위치
- **exit code 판정 로그**: `~/jarvis/runtime/logs/exit-code-wrapper.log`
- **실행 판정 감사**: `~/jarvis/runtime/logs/execution-verdict-audit.log`
- **재실행 가드 로그**: `~/jarvis/runtime/logs/pre-execution-guard.log`

---

## 8. 마이그레이션 체크리스트

새로운 크론/태스크를 작성할 때:

- [ ] `exit-code-first-wrapper.sh` 소싱
- [ ] `execution-verdict-wrapper.sh` 소싱
- [ ] `pre-execution-guard.sh` 소싱
- [ ] `check_task_status` 호출 (재실행 전)
- [ ] `mark_task_running` 호출 (시작 시)
- [ ] Exit code 판정 (return 0/1만 사용)
- [ ] `mark_task_success` 또는 `mark_task_failure` 호출 (완료 시)
- [ ] stderr 로깅 (판정에 미사용)
- [ ] 테스트 (정상 완료 + 오류 케이스)

---

## 9. 참고자료

- **ask-claude.sh**: `~/jarvis/infra/bin/ask-claude.sh` (line 133-136에서 가드 로드)
- **구현 위치**: `~/jarvis/infra/lib/`
  - `exit-code-first-wrapper.sh`
  - `execution-verdict-wrapper.sh`
  - `pre-execution-guard.sh`
  - `status-guard.sh` (보조)
- **클러스터 ID**: cl-e30aee511af89e13 (로그 에러 오판)
- **작성일**: 2026-07-13
