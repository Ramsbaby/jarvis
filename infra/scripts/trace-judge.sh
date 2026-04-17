#!/usr/bin/env bash
set -euo pipefail

# trace-judge.sh — LLM-as-Judge: 크론 태스크 결과 자동 품질 평가
# OpenJarvis TraceJudge 패턴 차용
#
# Usage:
#   trace-judge.sh evaluate <task-id>    — 최근 결과를 LLM이 평가 (0-1 점수)
#   trace-judge.sh report [days]         — 태스크별 평균 점수 리포트
#   trace-judge.sh low-score [threshold] — 저점수 태스크 목록 (기본 0.6)

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
DB="${BOT_HOME}/data/traces.db"
JUDGE_LOG="${BOT_HOME}/logs/judge.jsonl"

# judge 대상 태스크 (비용이 들므로 주요 태스크만)
JUDGE_TARGETS=(
    "morning-standup"
    "council-insight"
    "record-daily"
    "infra-daily"
    "weekly-report"
    "daily-summary"
)

# --- evaluate: 단일 태스크 최근 결과 평가 ---
cmd_evaluate() {
    local task_id="${1:?Usage: trace-judge.sh evaluate <task-id>}"
    local results_dir="${BOT_HOME}/results/${task_id}"

    # 최근 결과 파일 찾기
    local latest
    latest=$(ls -t "${results_dir}"/*.md 2>/dev/null | head -1 || echo "")
    if [[ -z "$latest" || ! -f "$latest" ]]; then
        echo "No results found for ${task_id}"
        return 1
    fi

    local result_content
    result_content=$(head -c 3000 "$latest")
    local result_date
    result_date=$(basename "$latest" .md)

    # LLM 평가 (llm-gateway 경유 — Pro 플랜 할당량 사용, API 크레딧 불필요)
    local judge_prompt
    judge_prompt="You are a quality evaluator for an automated AI task system.

Evaluate the following output from the task '${task_id}' (generated at ${result_date}).

## Evaluation Criteria:
1. **Completeness** (0-1): Does it cover all expected sections/items?
2. **Accuracy** (0-1): Is the information correct and up-to-date?
3. **Actionability** (0-1): Does it provide clear, actionable insights?
4. **Conciseness** (0-1): Is it appropriately concise without losing important details?

## Task Output:
${result_content}

## Required Response Format (EXACTLY this format, no extra text):
SCORE: <overall 0.0-1.0>
REASON: <one-line reason in Korean>
SUGGESTION: <one-line improvement suggestion in Korean>"

    local judge_result judge_tmp
    judge_tmp=$(mktemp)
    # model 미지정 시 sonnet 사용 (비용 효율), --max-turns 1로 단일 턴
    judge_result=$(claude -p "$judge_prompt" --max-turns 1 --model claude-sonnet-4-6 2>/dev/null) || {
        # Pro 플랜 폴백: llm-gateway 직접 호출
        source "${BOT_HOME}/lib/llm-gateway.sh"
        JARVIS_MAX_OUTPUT_TOKENS=500 llm_call \
            --prompt "$judge_prompt" \
            --timeout 30 \
            --allowed-tools "" \
            --output "$judge_tmp" \
            --work-dir "/tmp" \
            --mcp-config "${BOT_HOME}/config/empty-mcp.json" \
            2>/dev/null || {
                rm -f "$judge_tmp"
                echo "Judge call failed for ${task_id}"
                return 1
            }
        judge_result=$(jq -r '.result // empty' "$judge_tmp" 2>/dev/null || cat "$judge_tmp")
        rm -f "$judge_tmp"
    }

    # 점수 파싱
    local score reason suggestion
    score=$(echo "$judge_result" | grep -oP 'SCORE:\s*\K[0-9.]+' | head -1 || echo "0")
    reason=$(echo "$judge_result" | grep -oP 'REASON:\s*\K.*' | head -1 || echo "unknown")
    suggestion=$(echo "$judge_result" | grep -oP 'SUGGESTION:\s*\K.*' | head -1 || echo "none")

    # 점수 유효성 검증 (0-1 범위)
    if ! python3 -c "s=float('${score}'); assert 0<=s<=1" 2>/dev/null; then
        score="0.5"
        reason="Failed to parse score"
    fi

    # JSONL 로그
    printf '{"ts":"%s","task":"%s","score":%s,"reason":"%s","suggestion":"%s","result_file":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$task_id" "$score" \
        "${reason//\"/\'}" "${suggestion//\"/\'}" \
        "$(basename "$latest")" \
        >> "$JUDGE_LOG"

    # SQLite에도 저장 (traces DB의 별도 테이블)
    sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS judge_scores (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    task TEXT NOT NULL,
    score REAL NOT NULL,
    reason TEXT,
    suggestion TEXT
);
INSERT INTO judge_scores (ts, task, score, reason, suggestion)
VALUES ('$(date -u +%FT%TZ)', '${task_id}', ${score}, '${reason//\'/\'\'}', '${suggestion//\'/\'\'}');
SQL

    printf "%-20s  score=%.2f  %s\n" "$task_id" "$score" "$reason"
}

# --- evaluate-all: 대상 태스크 전체 평가 ---
cmd_evaluate_all() {
    echo "=== LLM-as-Judge: 태스크 품질 평가 ==="
    echo ""
    for task_id in "${JUDGE_TARGETS[@]}"; do
        cmd_evaluate "$task_id" 2>/dev/null || echo "  ${task_id}: SKIP (no results)"
    done
}

# --- report: 태스크별 평균 점수 ---
cmd_report() {
    local days="${1:-30}"
    sqlite3 -header -column "$DB" <<SQL
SELECT
    task,
    COUNT(*) AS evals,
    ROUND(AVG(score), 2) AS avg_score,
    ROUND(MIN(score), 2) AS min_score,
    ROUND(MAX(score), 2) AS max_score,
    MAX(ts) AS last_eval
FROM judge_scores
WHERE ts >= datetime('now', '-${days} days')
GROUP BY task
ORDER BY avg_score ASC;
SQL
}

# --- low-score: 저점수 태스크 목록 ---
cmd_low_score() {
    local threshold="${1:-0.6}"
    echo "=== 저점수 태스크 (< ${threshold}) ==="
    sqlite3 -header -column "$DB" <<SQL
SELECT task, score, reason, suggestion, ts
FROM judge_scores
WHERE score < ${threshold}
ORDER BY ts DESC
LIMIT 20;
SQL
}

# --- Main ---
mkdir -p "$(dirname "$JUDGE_LOG")"

case "${1:-help}" in
    evaluate)     cmd_evaluate "${2:-}" ;;
    evaluate-all) cmd_evaluate_all ;;
    report)       cmd_report "${2:-30}" ;;
    low-score)    cmd_low_score "${2:-0.6}" ;;
    help|*)
        echo "Usage: trace-judge.sh {evaluate <task-id>|evaluate-all|report [days]|low-score [threshold]}"
        ;;
esac