# 오답승격 가드 cl-41697ce934383874 통합 테스트

## 개요

클러스터 cl-41697ce934383874 (불완전 응답 / 거짓 완료 보고) 가드의 기능 검증

**테스트 대상:**
- `impossible-tasks-registry.json` — 불가능한 작업 유형 레지스트리
- `response-completion-validator.sh` — 응답 완전성 검증
- `artifact-validation-gate.sh` — 산출물 자동 검증
- `cluster-guard-cl-41697ce934383874.sh` — 통합 가드

---

## Test Case 1: 불가능한 작업 감지 — 웹 폼 조작

**시나리오:** 응답이 웹 폼 조작 완료를 주장

```bash
source ~/.jarvis/infra/lib/cluster-guard-cl-41697ce934383874.sh
guard_init

response="사용자 폼에 데이터를 입력하고 submit 버튼을 클릭했습니다."
guard_detect_impossible_task "$response"
```

**예상 결과:** `BLOCKED: 불가능한 작업 감지 — AI는 실제 웹 폼을 조작할 수 없음`

**검증:**
```bash
if ! guard_detect_impossible_task "$response"; then
    echo "✓ Test 1 PASSED: 불가능한 작업 올바르게 감지"
else
    echo "✗ Test 1 FAILED: 불가능한 작업 미감지"
    exit 1
fi
```

---

## Test Case 2: 불가능한 작업 감지 — 사용자 입력 받기

**시나리오:** 응답이 사용자 입력 수신을 주장

```bash
response="사용자로부터 메시지를 입력받았습니다: hello"
guard_detect_impossible_task "$response"
```

**예상 결과:** `BLOCKED: 불가능한 작업 감지 — 실시간 사용자 입력을 받을 수 없음`

---

## Test Case 3: 응답 완전성 검증 — 정상 응답

**시나리오:** 완전한 응답

```bash
response="이 작업의 목표는 사용자 경험을 개선하는 것입니다. 따라서 우리는 다음을 구현했습니다:
1. 새로운 UI 컴포넌트
2. 성능 최적화
3. 접근성 개선

이제 테스트 단계로 넘어갑니다."

validate_response_completion "$response" ""
```

**예상 결과:** 성공 (exit code 0)

---

## Test Case 4: 응답 완전성 검증 — 중단된 응답

**시나리오:** 응답이 갑자기 중단됨

```bash
response="작업을 완료했습니다. 결과는 다"  # 마지막 단어 "다"로 끝남

validate_response_completion "$response" ""
```

**예상 결과:** 실패 (exit code 1), 경고: `응답 중단 의심`

---

## Test Case 5: 산출물 검증 — 파일 존재

**시나리오:** 완료 선언 후 실제 파일 존재 여부 검증

```bash
# 테스트 파일 생성
echo "test content" > /tmp/test_output.txt

validate_artifact "file" "/tmp/test_output.txt"
```

**예상 결과:** 성공 (exit code 0)
```
OK: 파일 산출물 검증 성공 (/tmp/test_output.txt, 13 bytes)
```

---

## Test Case 6: 산출물 검증 — 파일 미존재

**시나리오:** 파일이 생성되지 않았음을 감지

```bash
validate_artifact "file" "/tmp/nonexistent_file.txt"
```

**예상 결과:** 실패 (exit code 1)
```
FAIL: 파일 미존재 — /tmp/nonexistent_file.txt
```

---

## Test Case 7: 산출물 검증 — 파일 비어있음

**시나리오:** 파일은 있지만 비어있음

```bash
touch /tmp/empty_file.txt
validate_artifact "file" "/tmp/empty_file.txt"
```

**예상 결과:** 실패 (exit code 1)
```
FAIL: 파일 비어있음 — /tmp/empty_file.txt (0 bytes)
```

---

## Test Case 8: 완료 선언과 현실 대조 — 거짓 완료

**시나리오:** 완료했다고 주장하지만 파일이 없음

```bash
response="작업을 완료했습니다. 파일이 생성되었습니다."
guard_verify_completion "task-001" "$response" "/tmp/missing_file.txt"
```

**예상 결과:** 실패 (exit code 1)
```
거짓 완료 보고 감지: 파일 미생성
```

---

## Test Case 9: 통합 검증 — 정상 완료

**시나리오:** 실제 파일이 생성되고 완료 선언

```bash
echo "실제 작업 결과" > /tmp/valid_output.txt
response="작업을 완료했습니다. 결과는 /tmp/valid_output.txt에 저장되었습니다."
guard_verify_completion "task-002" "$response" "/tmp/valid_output.txt"
```

**예상 결과:** 성공 (exit code 0)
```
결과: PASSED
```

---

## Test Case 10: HTML 기능 일관성 검증

**시나리오:** 설명은 추가했으나 인터랙티브 기능 없음

```bash
cat > /tmp/test.html << 'EOF'
<!DOCTYPE html>
<html>
<body>
<div class="description">설명</div>
<!-- 인터랙티브 기능 없음 -->
</body>
</html>
EOF

response="설명을 추가했고 인터랙티브 기능도 완성했습니다."
guard_verify_completion "task-003" "$response" "" "/tmp/test.html"
```

**예상 결과:** 경고 또는 실패
```
WARN: 설명은 추가했으나 인터랙티브 기능 미확인
```

---

## 실행 방법

### 전체 테스트 스크립트

```bash
#!/bin/bash
# test-cluster-guard-cl-41697ce934383874.sh

set -e

echo "=== 오답승격 가드 cl-41697ce934383874 통합 테스트 ==="
echo ""

# 의존성 로드
source ~/.jarvis/infra/lib/cluster-guard-cl-41697ce934383874.sh
guard_init

TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0

test_case() {
    local name="$1"
    local command="$2"
    local expect_pass="${3:-1}"  # 1 = expect success, 0 = expect failure

    TEST_COUNT=$((TEST_COUNT + 1))
    echo "Test $TEST_COUNT: $name"

    if eval "$command" > /dev/null 2>&1; then
        local exit_code=0
    else
        local exit_code=1
    fi

    if [ "$exit_code" -eq "$expect_pass" ]; then
        echo "  ✓ PASSED"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    else
        echo "  ✗ FAILED (exit=$exit_code, expected=$expect_pass)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

    echo ""
}

# Test 1: 불가능한 작업 감지
test_case \
    "불가능한 작업 감지 — 웹 폼 조작" \
    'guard_detect_impossible_task "사용자 폼에 데이터를 입력하고 submit 버튼을 클릭했습니다."' \
    1

# Test 2: 정상 응답 검증
test_case \
    "응답 완전성 검증 — 정상 응답" \
    'validate_response_completion "이것은 완전한 응답입니다. 작업이 성공했습니다."' \
    0

# Test 3: 파일 존재 검증
echo "test" > /tmp/guard_test_file.txt
test_case \
    "산출물 검증 — 파일 존재" \
    'validate_artifact "file" "/tmp/guard_test_file.txt"' \
    0

# Test 4: 파일 미존재 검증
test_case \
    "산출물 검증 — 파일 미존재" \
    'validate_artifact "file" "/tmp/nonexistent_guard_test.txt"' \
    1

# Test 5: 거짓 완료 감지
test_case \
    "완료 선언과 현실 대조 — 거짓 완료" \
    'guard_verify_completion "task-test-001" "작업을 완료했습니다." "/tmp/missing_file_test.txt"' \
    1

# 최종 결과
echo "=== 최종 결과 ==="
echo "총 테스트: $TEST_COUNT"
echo "성공: $PASSED_COUNT"
echo "실패: $FAILED_COUNT"

if [ "$FAILED_COUNT" -eq 0 ]; then
    echo "✓ 모든 테스트 통과"
    exit 0
else
    echo "✗ $FAILED_COUNT개 테스트 실패"
    exit 1
fi
```

### 개별 테스트 실행

```bash
# Test Case 1 실행
source ~/.jarvis/infra/lib/cluster-guard-cl-41697ce934383874.sh
guard_init

# 불가능한 작업 감지
guard_detect_impossible_task "사용자로부터 입력을 받았습니다."

# 응답 완전성 검증
validate_response_completion "정상적인 응답입니다." ""

# 산출물 검증
echo "test" > /tmp/test.txt
validate_artifact "file" "/tmp/test.txt"
```

---

## 예상 동작

### 시나리오 A: 불완전 응답 (1글자만 출력)
**입력:**
```
response="작업을 완료했습니다. 결과는 다"
```

**가드 동작:**
1. 응답 완전성 검증 → 중단 감지 (FAIL)
2. 로그: "응답 중단 의심 — 마지막 문자: '다'"
3. 결과: BLOCKED ❌

---

### 시나리오 B: 거짓 완료 보고 (웹 폼 조작 주장)
**입력:**
```
response="사용자 계정에서 비밀번호를 변경했습니다."
```

**가드 동작:**
1. 불가능한 작업 감지 → 매칭 (FAIL)
2. 로그: "BLOCKED: 불가능한 작업 감지 — 사용자 계정/권한 변경은 실행 불가능"
3. 결과: BLOCKED ❌

---

### 시나리오 C: 정상 완료
**입력:**
```
response="작업을 완료했습니다."
output_file="/tmp/output.txt"  # 실제 생성됨
```

**가드 동작:**
1. 불가능한 작업 감지 → 패스 (OK)
2. 응답 완전성 검증 → 패스 (OK)
3. 파일 존재 검증 → 패스 (OK)
4. 결과: PASSED ✅

---

## 다음 단계

1. **파이프라인 통합:**
   - `ask-claude.sh` 에 가드 호출 추가
   - 완료 선언 전에 자동 검증

2. **모니터링:**
   - 가드 로그 수집 및 분석
   - 거짓 완료 보고 추적

3. **확장:**
   - 추가 불가능한 작업 유형 등록
   - PDF 렌더링, HTML 검증 등 심화

---

## 연락처

문제가 있으면:
1. 로그 확인: `~/.jarvis/state/cluster-guard-cl-41697ce934383874/`
2. 레지스트리 확인: `~/.jarvis/infra/lib/impossible-tasks-registry.json`
3. 가드 상태 확인: `~/.jarvis/infra/lib/cluster-guard-cl-41697ce934383874.sh status`
