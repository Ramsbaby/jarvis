#!/usr/bin/env bash
# requirement-extractor.sh - Extract structured requirements from user prompts
# 클러스터 cl-28e5202af0584c23 방어: 요청사항 추출 및 체계적 검증
#
# Usage:
#   source requirement-extractor.sh
#   extract_requirements "$PROMPT"
#   # Output: JSON with extracted requirements
#
# Output format (JSON):
#   {
#     "formats": ["pdf", "html"],
#     "sections": ["요약본", "숙제"],
#     "bilingual": true,
#     "structure": ["제목", "본문"],
#     "additional_keywords": ["교사용", "정답지"],
#     "timestamp": "2026-07-07T...",
#     "source_hash": "abc123"
#   }

set -u

# Helper: Normalize and count occurrences of keywords
_extract_keyword_matches() {
    local pattern="$1"
    local text="$2"
    echo "$text" | grep -io "$pattern" 2>/dev/null | wc -l
}

# Helper: Check if text contains specific Korean patterns
_has_korean_pattern() {
    local pattern="$1"
    local text="$2"
    if echo "$text" | grep -q "$pattern"; then
        echo "true"
    else
        echo "false"
    fi
}

# Main extraction function
extract_requirements() {
    local prompt="${1:-}"
    local task_id="${2:-unknown}"

    if [[ -z "$prompt" ]]; then
        echo '{"error":"empty_prompt","message":"Prompt is required for requirement extraction"}'
        return 1
    fi

    # Normalize prompt for case-insensitive matching
    local prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

    # [1] Format extraction (형식 감지)
    declare -a formats=()
    [[ "$prompt_lower" =~ pdf ]] && formats+=("pdf")
    [[ "$prompt_lower" =~ html ]] && formats+=("html")
    [[ "$prompt_lower" =~ json ]] && formats+=("json")
    [[ "$prompt_lower" =~ (markdown|\.md) ]] && formats+=("markdown")
    [[ "$prompt_lower" =~ (xlsx?|excel) ]] && formats+=("excel")
    [[ "$prompt_lower" =~ csv ]] && formats+=("csv")
    [[ "$prompt_lower" =~ (docx?) ]] && formats+=("docx")
    [[ "$prompt_lower" =~ (txt|text) ]] && formats+=("txt")

    # [2] Section extraction (섹션 감지)
    declare -a sections=()
    [[ "$prompt_lower" =~ (요약|summary|요약본|요약부) ]] && sections+=("요약본")
    [[ "$prompt_lower" =~ (숙제|homework|과제|assignment) ]] && sections+=("숙제")
    [[ "$prompt_lower" =~ (정답|answer|해답|해설) ]] && sections+=("정답지")
    [[ "$prompt_lower" =~ (목차|table\.of\.contents|toc) ]] && sections+=("목차")
    [[ "$prompt_lower" =~ (수업|lesson|교재|material) ]] && sections+=("수업교재")
    [[ "$prompt_lower" =~ (소개|introduction|개요) ]] && sections+=("소개")
    [[ "$prompt_lower" =~ (예제|example|샘플|sample) ]] && sections+=("예제")
    [[ "$prompt_lower" =~ (참고|reference|출처) ]] && sections+=("참고자료")
    [[ "$prompt_lower" =~ (부록|appendix) ]] && sections+=("부록")
    [[ "$prompt_lower" =~ (결론|conclusion) ]] && sections+=("결론")

    # [3] Bilingual requirement (병기 여부 감지)
    local bilingual=false
    if echo "$prompt" | grep -iq "한글.*영어\|영어.*한글\|korean.*english\|english.*korean\|dual.*language\|bilingual\|병기\|이중언어"; then
        bilingual=true
    fi

    # [4] Language requirements
    declare -a languages=()
    [[ "$prompt" =~ [가-힣] ]] && languages+=("korean")
    [[ "$prompt_lower" =~ [a-z] ]] && languages+=("english")
    [[ "$prompt_lower" =~ (français|fr[_-]|french) ]] && languages+=("french")
    [[ "$prompt_lower" =~ (español|es[_-]|spanish) ]] && languages+=("spanish")

    # [5] Additional keywords (특수 요구사항)
    declare -a additional_keywords=()
    [[ "$prompt_lower" =~ (교사용|teacher) ]] && additional_keywords+=("교사용")
    [[ "$prompt_lower" =~ (학생용|student) ]] && additional_keywords+=("학생용")
    [[ "$prompt_lower" =~ (전체|all) ]] && additional_keywords+=("전체적용")
    [[ "$prompt_lower" =~ (부분|partial) ]] && additional_keywords+=("부분적용")
    [[ "$prompt_lower" =~ (선별|selective) ]] && additional_keywords+=("선별적용")
    [[ "$prompt_lower" =~ (색상|color) ]] && additional_keywords+=("색상지정")
    [[ "$prompt_lower" =~ (스타일|style) ]] && additional_keywords+=("스타일지정")
    [[ "$prompt_lower" =~ (레이아웃|layout) ]] && additional_keywords+=("레이아웃지정")

    # [6] Structure requirements (구조 감지)
    declare -a structure=()
    [[ "$prompt_lower" =~ (제목|title|heading) ]] && structure+=("제목")
    [[ "$prompt_lower" =~ (본문|body|content) ]] && structure+=("본문")
    [[ "$prompt_lower" =~ (각주|footnote|footnotes) ]] && structure+=("각주")
    [[ "$prompt_lower" =~ (링크|url|hyperlink) ]] && structure+=("하이퍼링크")
    [[ "$prompt_lower" =~ (이미지|image|그림|picture) ]] && structure+=("이미지")
    [[ "$prompt_lower" =~ (표|table) ]] && structure+=("표")
    [[ "$prompt_lower" =~ (리스트|list|목록) ]] && structure+=("목록")

    # [7] Completeness markers (완료도 감지)
    local completeness="unknown"
    if echo "$prompt" | grep -iq "전체\|all\|complete\|완전"; then
        completeness="full"
    elif echo "$prompt" | grep -iq "부분\|partial\|part\|일부"; then
        completeness="partial"
    fi

    # [8] Generate requirement hash for later validation
    local req_text="${formats[@]},${sections[@]},${languages[@]},${additional_keywords[@]},${structure[@]}"
    local req_hash=$(echo "$req_text" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "")

    # Build JSON output
    printf '{
  "task_id": "%s",
  "formats": [%s],
  "sections": [%s],
  "languages": [%s],
  "bilingual": %s,
  "additional_keywords": [%s],
  "structure": [%s],
  "completeness": "%s",
  "timestamp": "%s",
  "requirement_hash": "%s",
  "prompt_length": %d
}' \
        "$task_id" \
        "$(printf '"%s",' "${formats[@]}" | sed 's/,$//')" \
        "$(printf '"%s",' "${sections[@]}" | sed 's/,$//')" \
        "$(printf '"%s",' "${languages[@]}" | sed 's/,$//')" \
        "$bilingual" \
        "$(printf '"%s",' "${additional_keywords[@]}" | sed 's/,$//')" \
        "$(printf '"%s",' "${structure[@]}" | sed 's/,$//')" \
        "$completeness" \
        "$(date -u +%FT%TZ)" \
        "$req_hash" \
        "${#prompt}"
}

# Export for use in other scripts
export -f extract_requirements
