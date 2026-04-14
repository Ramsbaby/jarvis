#!/usr/bin/env bash
# evaluator.sh — Tier 1 독립 평가자 레이어
#
# Purpose:
#   ask-claude.sh가 LLM 호출 결과를 "성공"으로 판정하기 전에 품질/무결성 게이트 통과 여부를 평가.
#   Anthropic 3-agent 아키텍처의 "evaluation" 역할을 최소 비용으로 구현.
#
# Design:
#   - Pure bash/regex/jq — LLM 호출 없음, 토큰 0원
#   - 3가지 판정: pass / warn / fail
#   - fail은 재시도 트리거 (exit 2), warn은 ledger 기록 후 통과
#   - 태스크별 semantic schema는 _schema_for() case로 확장 (bash 3.2 호환)
#
# Usage: evaluate_result "$TASK_ID" "$RESULT" "$PROMPT"
#   환경변수:
#     EVALUATOR_VERDICT  — 함수 호출 후 "pass"|"warn"|"fail"
#     EVALUATOR_REASON   — 판정 사유 (short string)
#
# Called from: ask-claude.sh line ~199 (RESULT 추출 직후, 결과 저장 직전)

# --- 태스크별 최소 컨텐츠 schema (bash 3.2 호환: case 문) ---
_schema_for() {
    case "$1" in
        github-monitor)       echo "GitHub" ;;
        system-health)        echo "디스크|메모리|CPU|Discord" ;;
        market-alert)         echo "TQQQ|SOXL|NVDA|\\\$|%" ;;
        tqqq-monitor)         echo "TQQQ|시세|SOXL" ;;
        news-briefing)        echo "뉴스|news|AI|기술" ;;
        morning-standup)      echo "오늘|일정|태스크" ;;
        daily-summary)        echo "오늘|완료|실행" ;;
        ceo-daily-digest)     echo "CEO|오늘|요약" ;;
        council-insight)      echo "점검|경영|인사이트" ;;
        monthly-review)       echo "월간|회고|개선" ;;
        infra-daily)          echo "시스템|디스크|서버" ;;
        rag-health)           echo "RAG|인덱스|벡터" ;;
        security-scan)        echo "보안|scan|취약" ;;
        memory-cleanup)       echo "메모리|정리|clean" ;;
        *)                    echo "" ;;
    esac
}

evaluate_result() {
    local task_id="$1"
    local result="$2"
    local prompt="$3"

    EVALUATOR_VERDICT="pass"
    EVALUATOR_REASON=""

    # --- Check 1: empty / near-empty ---
    local result_words
    result_words=$(printf '%s' "$result" | wc -w | tr -d ' ')

    if [[ -z "$result" ]] || (( result_words < 2 )); then
        EVALUATOR_VERDICT="fail"
        EVALUATOR_REASON="empty_result (${result_words} words)"
        return 0
    fi

    if (( result_words < 5 )); then
        EVALUATOR_VERDICT="warn"
        EVALUATOR_REASON="thin_result (${result_words}W)"
    fi

    # --- Check 2: identical to prompt (LLM echoed input) ---
    local result_hash prompt_hash
    result_hash=$(printf '%s' "$result" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "")
    prompt_hash=$(printf '%s' "$prompt" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "")
    if [[ -n "$result_hash" && "$result_hash" == "$prompt_hash" ]]; then
        EVALUATOR_VERDICT="fail"
        EVALUATOR_REASON="identical_to_prompt"
        return 0
    fi

    # --- Check 3: LLM refusal / hallucination markers ---
    if printf '%s' "$result" | grep -qiE '죄송합니다.*(정보가 충분하지|답변드리기 어렵|도움을 드릴 수 없)'; then
        EVALUATOR_VERDICT="fail"
        EVALUATOR_REASON="llm_refusal_ko"
        return 0
    fi
    if printf '%s' "$result" | grep -qiE "^(i can'?t|i cannot|i'?m sorry|unable to|sorry, but)"; then
        EVALUATOR_VERDICT="fail"
        EVALUATOR_REASON="llm_refusal_en"
        return 0
    fi

    # --- Check 4: truncated markers ---
    local last_char
    last_char=$(printf '%s' "$result" | tail -c 1)
    if [[ "$last_char" == "{" || "$last_char" == "[" || "$last_char" == "," ]]; then
        if [[ "$EVALUATOR_VERDICT" == "pass" ]]; then
            EVALUATOR_VERDICT="warn"
            EVALUATOR_REASON="possibly_truncated"
        fi
    fi

    # --- Check 5: 태스크별 semantic schema ---
    local schema
    schema=$(_schema_for "$task_id")
    if [[ -n "$schema" ]]; then
        if ! printf '%s' "$result" | grep -qiE "$schema"; then
            if [[ "$EVALUATOR_VERDICT" == "pass" ]]; then
                EVALUATOR_VERDICT="warn"
                EVALUATOR_REASON="schema_miss"
            fi
        fi
    fi

    # --- Check 6: repeated phrase spam (LLM 루프 감지) ---
    local max_dup
    max_dup=$(printf '%s\n' "$result" | awk 'NF>0' | sort | uniq -c | sort -rn | head -1 | awk '{print $1}' 2>/dev/null || echo 0)
    if [[ -n "$max_dup" ]] && (( max_dup >= 10 )); then
        EVALUATOR_VERDICT="fail"
        EVALUATOR_REASON="repeated_line_x${max_dup}"
        return 0
    fi

    return 0
}

# 단독 실행 테스트 (source 되지 않았을 때)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <task_id> <result> [prompt]" >&2
        exit 2
    fi

    task_id="$1"
    if [[ "$2" == "-" ]]; then
        result=$(cat)
    else
        result="$2"
    fi
    prompt="${3:-}"

    evaluate_result "$task_id" "$result" "$prompt"
    printf 'verdict=%s reason=%s\n' "$EVALUATOR_VERDICT" "$EVALUATOR_REASON"

    case "$EVALUATOR_VERDICT" in
        pass) exit 0 ;;
        warn) exit 1 ;;
        fail) exit 2 ;;
    esac
fi
