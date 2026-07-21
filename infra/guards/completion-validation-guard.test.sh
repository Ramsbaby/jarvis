#!/usr/bin/env bash
# completion-validation-guard.test.sh — 완료 검증 가드 테스트 스위트
#
# 성공 기준:
#   [1] PDF 페이지 수 검증: 유효한 PDF와 손상된 PDF 구분
#   [2] 응답 본문 파싱: HTTP 상태코드만 아닌 응답 본체 검증
#   [3] 중복 감지: 파일 해시로 중복 판단
#   [4] exit code 0 = 검증 통과, exit code 1 = 검증 실패

set -uo pipefail

GUARD_SCRIPT="${GUARD_SCRIPT:-${HOME}/.jarvis/infra/guards/completion-validation-guard.sh}"
TEST_DIR="/tmp/completion-guard-tests"
TOTAL_TESTS=0
PASSED_TESTS=0

# ── 테스트 헬퍼 ────────────────────────────────────────────────────────────────
_test_case() {
    local name="$1"
    local expected_exit="$2"  # 0=pass, 1=fail
    shift 2

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "Test $TOTAL_TESTS: $name" >&2

    if "$@" >/dev/null 2>&1; then
        if [[ "$expected_exit" -eq 0 ]]; then
            echo "  ✓ PASS" >&2
            PASSED_TESTS=$((PASSED_TESTS + 1))
            return 0
        else
            echo "  ✗ FAIL (expected exit 1, got 0)" >&2
            return 1
        fi
    else
        if [[ "$expected_exit" -ne 0 ]]; then
            echo "  ✓ PASS" >&2
            PASSED_TESTS=$((PASSED_TESTS + 1))
            return 0
        else
            echo "  ✗ FAIL (expected exit 0, got 1)" >&2
            return 1
        fi
    fi
}

# ── 설정 ────────────────────────────────────────────────────────────────────────
mkdir -p "$TEST_DIR"
# 테스트 환경 깨끗하게 초기화
rm -rf "$TEST_DIR"/*
cd "$TEST_DIR"

echo "=== Completion Validation Guard Test Suite ===" >&2
echo "Guard script: $GUARD_SCRIPT" >&2
echo "Test directory: $TEST_DIR" >&2
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [1] PDF 검증 테스트
# ══════════════════════════════════════════════════════════════════════════════

echo "--- [1] PDF Page Count Validation Tests ---" >&2

# 유효한 PDF 생성
cat > valid.pdf << 'PDF'
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>
endobj
4 0 obj
<< /Length 50 >>
stream
BT
/F1 12 Tf
100 700 Td
(Page 1) Tj
ET
endstream
endobj
5 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R >>
endobj
6 0 obj
<< /Length 50 >>
stream
BT
/F1 12 Tf
100 700 Td
(Page 2) Tj
ET
endstream
endobj
xref
0 7
0000000000 65535 f
0000000009 00000 n
0000000058 00000 n
0000000117 00000 n
0000000206 00000 n
0000000304 00000 n
0000000393 00000 n
trailer
<< /Size 7 /Root 1 0 R >>
startxref
491
%%EOF
PDF

_test_case "validate-pdf: valid PDF with 2 pages" 0 \
    "$GUARD_SCRIPT" validate-pdf valid.pdf

_test_case "validate-pdf: valid PDF with min_pages=1" 0 \
    "$GUARD_SCRIPT" validate-pdf valid.pdf 1

_test_case "validate-pdf: valid PDF with min_pages=2" 0 \
    "$GUARD_SCRIPT" validate-pdf valid.pdf 2

_test_case "validate-pdf: valid PDF with min_pages=3 (should fail)" 1 \
    "$GUARD_SCRIPT" validate-pdf valid.pdf 3

# 손상된 PDF 생성
echo "This is not a PDF" > corrupted.pdf

_test_case "validate-pdf: corrupted PDF (not PDF signature)" 1 \
    "$GUARD_SCRIPT" validate-pdf corrupted.pdf

_test_case "validate-pdf: non-existent file" 1 \
    "$GUARD_SCRIPT" validate-pdf /tmp/nonexistent_$RANDOM.pdf

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [2] 파일 업로드 응답 검증 테스트
# ══════════════════════════════════════════════════════════════════════════════

echo "--- [2] Upload Response Validation Tests ---" >&2

# 성공 응답
RESPONSE_SUCCESS='HTTP/1.1 200 OK
Content-Type: application/json

{"success": true, "file_size": 1024}'

_test_case "validate-upload: valid 200 response with success field" 0 \
    "$GUARD_SCRIPT" validate-upload --response "$RESPONSE_SUCCESS"

# 실패 응답 (400)
RESPONSE_400='HTTP/1.1 400 Bad Request
Content-Type: application/json

{"error": "invalid_file"}'

_test_case "validate-upload: 400 Bad Request response" 1 \
    "$GUARD_SCRIPT" validate-upload --response "$RESPONSE_400"

# 빈 응답
RESPONSE_EMPTY=""

_test_case "validate-upload: empty response" 1 \
    "$GUARD_SCRIPT" validate-upload --response "$RESPONSE_EMPTY"

# 상태코드 없는 본문만
RESPONSE_BODY_ONLY='{"success": true, "file_size": 2048}'

_test_case "validate-upload: response body only (no HTTP status)" 0 \
    "$GUARD_SCRIPT" validate-upload --response "$RESPONSE_BODY_ONLY"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [3] 중복 파일 감지 테스트
# ══════════════════════════════════════════════════════════════════════════════

echo "--- [3] Duplicate File Detection Tests ---" >&2

# 테스트 파일 생성 (고유한 해시 DB 디렉토리 사용)
HASH_DB_TEST_DIR="/tmp/completion-guard-hashdb-test-$RANDOM"
echo "Test content 1" > file1.txt
echo "Test content 2" > file2.txt
cp file1.txt file1_copy.txt

_test_case "check-duplicate: first check of file1 (should pass)" 0 \
    "$GUARD_SCRIPT" check-duplicate --file file1.txt --hash-db "$HASH_DB_TEST_DIR"

_test_case "check-duplicate: identical content (should detect duplicate)" 1 \
    "$GUARD_SCRIPT" check-duplicate --file file1_copy.txt --hash-db "$HASH_DB_TEST_DIR"

_test_case "check-duplicate: different file (should pass)" 0 \
    "$GUARD_SCRIPT" check-duplicate --file file2.txt --hash-db "$HASH_DB_TEST_DIR"

_test_case "check-duplicate: non-existent file" 1 \
    "$GUARD_SCRIPT" check-duplicate --file /tmp/nonexistent_$RANDOM.txt

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [4] 종합 검증 테스트
# ══════════════════════════════════════════════════════════════════════════════

echo "--- [4] Comprehensive Validation Tests ---" >&2

HASH_DB_COMP_TEST="/tmp/completion-guard-hashdb-comp-$RANDOM"

_test_case "validate-completion: all checks pass" 0 \
    "$GUARD_SCRIPT" validate-completion --pdf valid.pdf --response "$RESPONSE_SUCCESS" --file file1.txt

_test_case "validate-completion: PDF fails but others pass" 1 \
    "$GUARD_SCRIPT" validate-completion --pdf corrupted.pdf --response "$RESPONSE_SUCCESS" --file file1.txt

_test_case "validate-completion: response fails but others pass" 1 \
    "$GUARD_SCRIPT" validate-completion --pdf valid.pdf --response "$RESPONSE_400" --file file1.txt

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# 최종 결과
# ══════════════════════════════════════════════════════════════════════════════

echo "=== Test Summary ===" >&2
echo "Total: $TOTAL_TESTS, Passed: $PASSED_TESTS, Failed: $((TOTAL_TESTS - PASSED_TESTS))" >&2

if [[ $PASSED_TESTS -eq $TOTAL_TESTS ]]; then
    echo "✓ All tests PASSED" >&2
    exit 0
else
    echo "✗ Some tests FAILED" >&2
    exit 1
fi
