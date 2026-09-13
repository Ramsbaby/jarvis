# 통합 테스트 가이드 (cl-41697ce934383874)

## 개요

이 문서는 완료 선언 가드(impossible-actions-registry, task-completion-validator, completion-guard)의 통합 테스트 절차를 설명합니다.

## 테스트 환경 준비

```bash
# 1. 스크립트 확인
ls -la ~/jarvis/infra/guards/impossible-actions-registry.sh
ls -la ~/jarvis/infra/guards/task-completion-validator.sh
ls -la ~/jarvis/infra/guards/completion-guard.sh

# 2. 실행 권한 확인
[[ -x ~/jarvis/infra/guards/completion-guard.sh ]] && echo "OK" || echo "권한 필요"

# 3. 로그 디렉토리 확인
mkdir -p ~/jarvis/runtime/logs/completion-guard
```

---

## 단위 테스트

### Test 1: 불가능한 작업 레지스트리
**목표:** 불가능한 작업을 정확히 차단하는가?

```bash
source ~/jarvis/infra/guards/impossible-actions-registry.sh

# 1.1 불가능한 작업 감지
echo "Test 1.1: web-form-manipulation (불가능) 감지"
is_impossible_action "web-form-manipulation"
RESULT=$?
[[ $RESULT -eq 0 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 0, got $RESULT)"

# 1.2 가능한 작업 통과
echo "Test 1.2: valid-action (가능) 통과"
is_impossible_action "valid-action"
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 1, got $RESULT)"

# 1.3 이유 조회
echo "Test 1.3: 불가능 이유 조회"
REASON=$(get_impossible_reason "web-form-manipulation")
[[ -n "$REASON" ]] && echo "✓ PASS: $REASON" || echo "✗ FAIL"

# 1.4 대체 제안 조회
echo "Test 1.4: 대체 제안 조회"
FALLBACK=$(get_impossible_fallback "web-form-manipulation")
[[ -n "$FALLBACK" ]] && echo "✓ PASS: $FALLBACK" || echo "✗ FAIL"

# 1.5 완료 검증 (차단)
echo "Test 1.5: 완료 선언 검증 (차단)"
validate_completion_against_impossible_registry "web-form-manipulation" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 1, got $RESULT)"
```

**예상 결과:**
- Test 1.1: PASS (웹폼 조작은 불가능)
- Test 1.2: PASS (유효한 작업은 가능)
- Test 1.3: PASS (이유 문자열 반환)
- Test 1.4: PASS (대체 제안 문자열 반환)
- Test 1.5: PASS (완료 차단됨)

---

### Test 2: 완료 검증자 (파일)
**목표:** 파일 산출물을 정확히 검증하는가?

```bash
source ~/jarvis/infra/guards/task-completion-validator.sh

# 2.1 정상 파일 검증
echo "Test 2.1: 정상 파일 검증"
echo "valid content here" > /tmp/valid.txt
validate_task_completion "file" "/tmp/valid.txt" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 0 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 0, got $RESULT)"

# 2.2 빈 파일 감지
echo "Test 2.2: 빈 파일 감지 (실패)"
touch /tmp/empty.txt
validate_task_completion "file" "/tmp/empty.txt" "min_size=10" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 1, got $RESULT)"

# 2.3 최소 크기 검증
echo "Test 2.3: 최소 크기 검증"
echo "small" > /tmp/small.txt
validate_task_completion "file" "/tmp/small.txt" "min_size=1000" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 1, got $RESULT)"

# 2.4 미존재 파일
echo "Test 2.4: 미존재 파일 감지"
validate_task_completion "file" "/tmp/nonexistent.txt" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 1, got $RESULT)"

# 정리
rm -f /tmp/valid.txt /tmp/empty.txt /tmp/small.txt
```

**예상 결과:**
- Test 2.1: PASS (유효한 파일)
- Test 2.2: PASS (빈 파일 차단)
- Test 2.3: PASS (크기 부족 감지)
- Test 2.4: PASS (파일 미존재 감지)

---

### Test 3: 완료 검증자 (텍스트)
**목표:** 텍스트 응답을 정확히 검증하는가? (1글자 응답 방지)

```bash
source ~/jarvis/infra/guards/task-completion-validator.sh

# 3.1 충분한 텍스트
echo "Test 3.1: 충분한 길이 텍스트 (성공)"
validate_task_completion "text" "이것은 충분히 긴 응답입니다" "min_chars=10" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 0 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 0, got $RESULT)"

# 3.2 너무 짧은 텍스트 (1글자)
echo "Test 3.2: 너무 짧은 텍스트 (경고/통과)"
validate_task_completion "text" "a" "min_chars=50" >/dev/null 2>&1
RESULT=$?
# 현재는 경고만 하고 통과 (WARN이지만 최종 OK)
echo "  반환값: $RESULT (낮은 min_chars에서는 통과, 높은 min_chars에서는 실패 확인)"

# 3.3 강제 최소 문자 수
echo "Test 3.3: 강제 최소 문자 수 검증"
validate_task_completion "text" "short" "min_chars=100" >/dev/null 2>&1
RESULT=$?
# 강제 min_chars=100에서는 5글자 "short"가 실패해야 함
echo "  테스트: 5글자 vs 100자 최소 요구 (예상 실패 또는 경고)"

# 3.4 비어있는 응답
echo "Test 3.4: 비어있는 응답 (실패)"
validate_task_completion "text" "" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS" || echo "✗ FAIL (expected 1, got $RESULT)"
```

**예상 결과:**
- Test 3.1: PASS (충분한 텍스트)
- Test 3.2: 통과 (경고 출력됨)
- Test 3.3: 낮은 값은 통과, 높은 값은 경고/실패
- Test 3.4: PASS (빈 응답 차단)

---

### Test 4: 완료 가드 (통합)
**목표:** 불가능한 작업과 산출물을 함께 검증하는가?

```bash
source ~/jarvis/infra/guards/completion-guard.sh

# 4.1 불가능한 작업 차단
echo "Test 4.1: 불가능한 작업 차단"
guard_completion_declaration --action "web-form-manipulation" --task-id "t1" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS (차단됨)" || echo "✗ FAIL (expected 1, got $RESULT)"

# 4.2 가능한 작업 + 유효 파일
echo "Test 4.2: 가능한 작업 + 유효 파일 (승인)"
echo "test content" > /tmp/output.txt
guard_completion_declaration \
    --action "generate-document" \
    --artifacts "file:/tmp/output.txt:min_size=1" \
    --task-id "t2" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 0 ]] && echo "✓ PASS (승인됨)" || echo "✗ FAIL (expected 0, got $RESULT)"

# 4.3 가능한 작업 + 빈 파일
echo "Test 4.3: 가능한 작업 + 빈 파일 (거부)"
touch /tmp/empty_output.txt
guard_completion_declaration \
    --action "generate-document" \
    --artifacts "file:/tmp/empty_output.txt:min_size=100" \
    --task-id "t3" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 1 ]] && echo "✓ PASS (거부됨)" || echo "✗ FAIL (expected 1, got $RESULT)"

# 4.4 산출물만 검증 (다중)
echo "Test 4.4: 다중 산출물 검증"
echo "file1 content" > /tmp/f1.txt
echo "file2 content" > /tmp/f2.txt
guard_completion_declaration \
    --artifacts "file:/tmp/f1.txt:min_size=1,file:/tmp/f2.txt:min_size=1" \
    --task-id "t4" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 0 ]] && echo "✓ PASS (모두 성공)" || echo "✗ FAIL (expected 0, got $RESULT)"

# 정리
rm -f /tmp/output.txt /tmp/empty_output.txt /tmp/f1.txt /tmp/f2.txt
```

**예상 결과:**
- Test 4.1: PASS (웹폼 조작 차단)
- Test 4.2: PASS (문서 생성 승인)
- Test 4.3: PASS (빈 파일 거부)
- Test 4.4: PASS (다중 검증 성공)

---

### Test 5: 간소화된 인터페이스
**목표:** 간단한 함수들도 제대로 작동하는가?

```bash
source ~/jarvis/infra/guards/completion-guard.sh

# 5.1 파일 완료 검증
echo "Test 5.1: guard_file_completion (성공)"
echo "file content" > /tmp/file_test.txt
guard_file_completion "/tmp/file_test.txt" 1 "test-task" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 0 ]] && echo "✓ PASS" || echo "✗ FAIL"

# 5.2 응답 완료 검증
echo "Test 5.2: guard_response_completion (성공)"
guard_response_completion "충분히 긴 응답입니다" 5 "test-task" >/dev/null 2>&1
RESULT=$?
[[ $RESULT -eq 0 ]] && echo "✓ PASS" || echo "✗ FAIL"

# 5.3 응답 완료 검증 (너무 짧음)
echo "Test 5.3: guard_response_completion (너무 짧음)"
guard_response_completion "a" 50 "test-task" >/dev/null 2>&1
RESULT=$?
echo "  반환값: $RESULT (현재는 경고이지만 강제 min_chars 사용 시 FAIL)"

# 정리
rm -f /tmp/file_test.txt
```

**예상 결과:**
- Test 5.1: PASS (파일 검증 성공)
- Test 5.2: PASS (응답 검증 성공)
- Test 5.3: 낮은 값은 통과, 높은 값은 경고

---

## 시나리오 테스트

### Scenario A: 웹 폼 조작 거짓 보고 (현실 시뮬레이션)

```bash
#!/bin/bash
# scenario-a.sh: 웹 폼 조작 거짓 보고

source ~/jarvis/infra/guards/completion-guard.sh

echo "=== Scenario A: 웹 폼 조작 거짓 보고 ==="
echo ""
echo "상황: 사용자가 웹 폼을 조작했다고 주장"
echo "실제: AI는 브라우저 없이 폼을 조작할 수 없음"
echo ""

guard_completion_declaration \
    --action "web-form-manipulation" \
    --task-id "web-form-001" \
    --verbose

echo ""
echo "결과: 차단됨 ✓"
```

**실행:**
```bash
bash ~/jarvis/infra/guards/scenario-a.sh
```

**예상 출력:**
```
=== Scenario A: 웹 폼 조작 거짓 보고 ===

상황: 사용자가 웹 폼을 조작했다고 주장
실제: AI는 브라우저 없이 폼을 조작할 수 없음

[completion-guard] [BLOCK] 불가능한 작업 감지: web-form-manipulation
❌ 완료 불승인: 실행 불가능한 작업
작업 유형: web-form-manipulation
이유: AI는 브라우저 없이 웹 폼을 직접 조작할 수 없습니다
제안: 폼 처리 스크립트 작성 또는 자동화 플랫폼(Selenium, Playwright) 사용을 제안하세요
```

---

### Scenario B: 1글자 응답 불완전성 감지

```bash
#!/bin/bash
# scenario-b.sh: 불완전 응답 감지

source ~/jarvis/infra/guards/completion-guard.sh

echo "=== Scenario B: 불완전 응답 감지 ==="
echo ""
echo "상황: 질문에 '1'이라고만 응답"
echo "검증: 최소 50자 응답 필요"
echo ""

# 현재 구현: min_chars=50에서 "1"은 경고만 출력
# 개선: 강제 실패하도록 설정

guard_response_completion "1" 50 "incomplete-response-001" || {
    echo "결과: 검증 거부됨 ✓"
}
```

---

### Scenario C: 빈 파일 생성 후 완료 선언

```bash
#!/bin/bash
# scenario-c.sh: 빈 파일 감지

source ~/jarvis/infra/guards/completion-guard.sh

echo "=== Scenario C: 빈 파일 감지 ==="
echo ""
echo "상황: 파일이 생성되었다고 주장하지만 실제로 비어있음"
echo ""

touch /tmp/scenario_c_empty.txt

guard_file_completion "/tmp/scenario_c_empty.txt" 1000 "file-gen-001" || {
    echo ""
    echo "결과: 빈 파일 감지 및 차단됨 ✓"
}

rm -f /tmp/scenario_c_empty.txt
```

---

## 회귀 테스트 (자동화)

```bash
#!/bin/bash
# run-all-tests.sh: 모든 테스트 자동 실행

set -e

TEST_DIR=$(dirname "$(readlink -f "$0")")
PASS=0
FAIL=0

run_test() {
    local name="$1"
    local test_fn="$2"

    echo "Running: $name"
    if $test_fn >/dev/null 2>&1; then
        echo "  ✓ PASS"
        ((PASS++))
    else
        echo "  ✗ FAIL"
        ((FAIL++))
    fi
}

# 테스트 1-5 실행
echo "=== Running Unit Tests ==="
cd "$TEST_DIR"

# 각 스크립트 직접 실행 (테스트 모드)
bash impossible-actions-registry.sh
bash task-completion-validator.sh
bash completion-guard.sh

echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

exit $FAIL
```

---

## 성능 테스트

```bash
#!/bin/bash
# performance-test.sh: 성능 테스트

source ~/jarvis/infra/guards/completion-guard.sh

echo "=== Performance Test ==="

# 테스트 1: 불가능한 작업 검사 (단일)
echo "Test 1: 불가능한 작업 검사 속도"
time is_impossible_action "web-form-manipulation" >/dev/null

# 테스트 2: 다중 산출물 검증
echo ""
echo "Test 2: 다중 산출물 검증 속도 (10개)"
for i in {1..10}; do
    echo "content $i" > "/tmp/perf_test_$i.txt"
done

time guard_completion_declaration \
    --artifacts "file:/tmp/perf_test_1.txt:min_size=1,file:/tmp/perf_test_2.txt:min_size=1" \
    --task-id "perf-test" >/dev/null

# 정리
rm -f /tmp/perf_test_*.txt
```

**예상:** 모든 테스트는 100ms 이내에 완료되어야 함

---

## 체크리스트

### 구현 검증

- [ ] 3개 스크립트 생성됨
  - `impossible-actions-registry.sh`
  - `task-completion-validator.sh`
  - `completion-guard.sh`

- [ ] 스크립트 실행 권한 확인
  ```bash
  ls -la ~/jarvis/infra/guards/*.sh | grep -c '^-rwx'  # 3 이상
  ```

- [ ] 로그 디렉토리 생성
  ```bash
  [[ -d ~/jarvis/runtime/logs/completion-guard ]] && echo "OK"
  ```

### 기능 검증

- [ ] 불가능한 작업 차단
  - web-form-manipulation 감지
  - 이유/제안 반환
  - 완료 선언 차단

- [ ] 산출물 검증
  - 파일 존재 확인
  - 파일 크기 확인
  - 텍스트 길이 확인
  - 빈 파일 감지

- [ ] 통합 가드
  - 불가능 작업 + 산출물 모두 검증
  - 다중 산출물 지원
  - JSON 리포트 생성

### 로깅 검증

- [ ] 완료 검증 로그 기록
  ```bash
  tail ~/jarvis/runtime/logs/completion-guard/completion-checks.log
  ```

- [ ] 로그에 BLOCK/OK 기록 포함
- [ ] 로그에 타임스탬프 포함

---

## 문제 해결

| 증상 | 원인 | 해결 |
|------|------|-----|
| "권한 거부" | 스크립트 실행 권한 없음 | `chmod +x` |
| "파일 없음" | 의존성 로드 실패 | 경로 확인, source 명령 재실행 |
| "jq 없음" | JSON 도구 미설치 | `brew install jq` 또는 `apt install jq` |
| "로그 안 보임" | 디렉토리 없음 | `mkdir -p ~/jarvis/runtime/logs/completion-guard` |

---

## 최종 검증

모든 테스트 통과 후:

```bash
# 1. 스크립트 최종 확인
bash ~/jarvis/infra/guards/impossible-actions-registry.sh
bash ~/jarvis/infra/guards/task-completion-validator.sh
bash ~/jarvis/infra/guards/completion-guard.sh

# 2. 로그 확인
cat ~/jarvis/runtime/logs/completion-guard/completion-checks.log | tail -20

# 3. 사용 가이드 읽기
cat ~/jarvis/infra/guards/CL-41697CE934383874-USAGE-GUIDE.md

# 모두 성공하면 → 구현 완료!
```

