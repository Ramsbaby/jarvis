#!/usr/bin/env bash
set -euo pipefail

# qa-materials.sh — 교재 QA 검사 스크립트
# 목적: Preply 교재의 필수 요소(단어 탭, 한영병기, 정답 노출)를 자동 검사
#
# 사용:
#   qa-materials.sh <파일>              # 파일 검사, PASS/FAIL 판정
#   qa-materials.sh <파일1> <파일2>    # 여러 파일 검사
#   qa-materials.sh --batch <디렉토리> # 디렉토리 내 모든 파일 검사
#
# 종료 코드:
#   0 = 모든 검사 통과 (PASS)
#   1 = 최소 1개 이상 검사 실패 (FAIL)

err() { echo "❌ $*" >&2; exit 1; }
warn() { echo "⚠️  $*" >&2; }
info() { echo "ℹ️  $*"; }
pass() { echo "✅ $*"; }

# 파일이 PDF인지 확인
is_pdf() { [[ "$1" =~ \.(pdf|PDF)$ ]]; }

# 파일이 HTML인지 확인
is_html() { [[ "$1" =~ \.(html|htm|HTML|HTM)$ ]]; }

# ============================================================================
# 검사 함수들
# ============================================================================

# [검사 1] 정답 노출 여부 — 파일명이 정답/답안 패턴인지 확인
check_answer_exposure() {
  local file="$1"
  local basename
  basename=$(basename "$file" | tr '[:upper:]' '[:lower:]')

  # 정답지/답안지 키워드 확인
  if [[ "$basename" =~ (정답|답안|answerkey|answer.key|answer_key|solution|답지|정답지) ]]; then
    return 1  # FAIL
  fi

  return 0  # PASS
}

# [검사 2] 단어 탭 존재 여부 — HTML에서 word-card 요소 확인
check_vocab_section_html() {
  local file="$1"

  # word-card 클래스 또는 word 관련 구조 확인
  if grep -q 'class="word-' "$file" || grep -q 'class=".*word' "$file"; then
    # 최소 3개 이상의 word-card 존재 확인 (의미 있는 단어 탭)
    local count
    count=$(grep -o 'class="word-' "$file" | wc -l)
    if [ "$count" -ge 3 ]; then
      return 0  # PASS
    fi
  fi

  return 1  # FAIL — 단어 탭 없음 또는 너무 적음
}

# [검사 3] 한영병기 적용률 — HTML에서 word-en 요소의 실제 콘텐츠 확인
check_bilingual_coverage_html() {
  local file="$1"

  # word-en 태그 찾기
  local en_count
  en_count=$(grep -o '<div class="word-en">[^<]*</div>' "$file" | wc -l)

  if [ "$en_count" -eq 0 ]; then
    return 1  # FAIL
  fi

  # word-en에 실제 콘텐츠가 있는지 확인 (empty tag 제외)
  local en_with_content
  en_with_content=$(grep '<div class="word-en">[^<]*</div>' "$file" | \
    grep -v '<div class="word-en"></div>' | \
    grep -v '<div class="word-en">[[:space:]]*</div>' | wc -l)

  if [ "$en_with_content" -eq 0 ]; then
    return 1  # FAIL — 영문 번역 없음
  fi

  # 한글 단어(word-kr) 개수와 비교
  local kr_count
  kr_count=$(grep -o '<div class="word-kr">[^<]*</div>' "$file" | wc -l)

  if [ "$kr_count" -eq 0 ]; then
    return 1  # FAIL — 한글 단어 없음
  fi

  # 적용률: 영문 콘텐츠 / 한글 단어 * 100
  # 80% 이상이면 PASS
  if [ "$kr_count" -gt 0 ]; then
    local ratio
    ratio=$((en_with_content * 100 / kr_count))
    if [ "$ratio" -ge 80 ]; then
      return 0  # PASS
    fi
  fi

  return 1  # FAIL — 적용률 부족
}

# [검사 4] PDF 검사 (기본 유효성)
check_pdf_basic() {
  local file="$1"

  # PDF 파일 유효성 확인
  if ! file "$file" | grep -q "PDF document"; then
    return 1  # FAIL
  fi

  # pdftotext로 텍스트 추출 가능한지 확인
  if ! command -v pdftotext &>/dev/null; then
    warn "pdftotext 명령 없음, PDF 상세 검사 건너뜀"
    return 0  # 경고만 하고 PASS (도구 없음)
  fi

  # 텍스트 추출 시도
  if ! pdftotext "$file" /dev/null 2>/dev/null; then
    return 1  # FAIL
  fi

  return 0  # PASS
}

# [검사 5] HTML 구조 기본 검사
check_html_structure() {
  local file="$1"

  # HTML 시작 태그 확인
  if ! grep -q '<html' "$file" && ! grep -q '<HTML' "$file"; then
    return 1  # FAIL
  fi

  # head/body 중 하나라도 있는지 확인
  if ! grep -q -E '<head|<body|<HEAD|<BODY' "$file"; then
    return 1  # FAIL
  fi

  return 0  # PASS
}

# ============================================================================
# 파일별 검사 실행
# ============================================================================

run_checks() {
  local file="$1"
  local filename
  filename=$(basename "$file")

  # 파일 존재 확인
  if [ ! -f "$file" ]; then
    warn "파일 없음: $file"
    return 1
  fi

  echo ""
  echo "📋 검사: $filename"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local all_pass=0
  local checks_run=0

  # [검사 1] 정답 노출 여부
  checks_run=$((checks_run + 1))
  if check_answer_exposure "$file"; then
    pass "정답 노출: OK (정답지로 분류되지 않음)"
  else
    warn "정답 노출: FAIL (정답지/답안지 파일로 보임)"
    all_pass=1
  fi

  # 파일 타입별 검사
  if is_html "$file"; then
    # [검사 2] 단어 탭 존재
    checks_run=$((checks_run + 1))
    if check_vocab_section_html "$file"; then
      pass "단어 탭: OK (word-card 요소 3개 이상)"
    else
      warn "단어 탭: FAIL (word-card 요소 부족 또는 없음)"
      all_pass=1
    fi

    # [검사 3] 한영병기 적용률
    checks_run=$((checks_run + 1))
    if check_bilingual_coverage_html "$file"; then
      pass "한영병기: OK (80% 이상 적용)"
    else
      warn "한영병기: FAIL (적용률 부족)"
      all_pass=1
    fi

    # [검사 4] HTML 구조
    checks_run=$((checks_run + 1))
    if check_html_structure "$file"; then
      pass "HTML 구조: OK"
    else
      warn "HTML 구조: FAIL (유효한 HTML 구조 없음)"
      all_pass=1
    fi

  elif is_pdf "$file"; then
    # [검사 2] PDF 유효성
    checks_run=$((checks_run + 1))
    if check_pdf_basic "$file"; then
      pass "PDF 유효성: OK"
    else
      warn "PDF 유효성: FAIL (손상되었거나 읽을 수 없음)"
      all_pass=1
    fi
  else
    warn "지원하지 않는 파일 타입: $file (HTML, PDF만 지원)"
    all_pass=1
  fi

  echo ""
  if [ $all_pass -eq 0 ]; then
    echo "🎯 최종 판정: PASS ✅"
    return 0
  else
    echo "🎯 최종 판정: FAIL ❌"
    return 1
  fi
}

# ============================================================================
# 배치 처리
# ============================================================================

run_batch() {
  local dir="$1"
  local pass_count=0
  local fail_count=0
  local total=0

  if [ ! -d "$dir" ]; then
    err "디렉토리 없음: $dir"
  fi

  echo "📂 배치 검사 시작: $dir"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # HTML과 PDF 파일 찾기
  while IFS= read -r -d '' file; do
    total=$((total + 1))
    if run_checks "$file"; then
      pass_count=$((pass_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.html' -o -iname '*.pdf' \) -print0)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📊 배치 결과:"
  echo "  총 파일: $total"
  echo "  ✅ 통과: $pass_count"
  echo "  ❌ 실패: $fail_count"

  if [ $fail_count -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

# ============================================================================
# 메인
# ============================================================================

main() {
  if [ $# -eq 0 ]; then
    err "사용: $0 <파일> [파일2...] 또는 $0 --batch <디렉토리>"
  fi

  if [ "$1" = "--batch" ]; then
    if [ $# -lt 2 ]; then
      err "--batch 옵션 사용 시 디렉토리 필요"
    fi
    run_batch "$2"
    exit $?
  fi

  # 개별 파일 검사
  local all_pass=0
  for file in "$@"; do
    if ! run_checks "$file"; then
      all_pass=1
    fi
  done

  exit $all_pass
}

main "$@"
