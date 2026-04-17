#!/usr/bin/env bash
set -euo pipefail

# monthly-review-3-agent.sh — Tier 3 plan/execute/verify 분할
#
# Plan    : 월초 여부 확인 + rag-index.log 접근 + token-ledger 30일 데이터 사전 집계
# Execute : ask-claude.sh 위임 (Opus 기반 복합 분석)
# Verify  : 5개 섹션(성공률/비용/안정성/Top3/개선목표) + 파일 저장 확인

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TASK_ID="monthly-review"
LEDGER="${BOT_HOME}/state/token-ledger.jsonl"
RAG_INDEX_LOG="${BOT_HOME}/logs/rag-index.log"
REPORTS_DIR="${BOT_HOME}/rag/teams/reports"

log() { printf '[%s] [%s:3agent] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TASK_ID" "$*" >&2; }

ledger_stage() {
    local stage="$1" status="$2" reason="${3:-}"
    if ! command -v jq >/dev/null 2>&1; then return 0; fi
    jq -cn --arg ts "$(date -u +%FT%TZ)" \
           --arg task "${TASK_ID}:${stage}" \
           --arg model "gate" \
           --arg status "$status" \
           --arg reason "$reason" \
           --arg result_hash "" \
           --argjson input 0 \
           --argjson output 0 \
           --argjson cost_usd 0 \
           --argjson duration_ms 0 \
           --argjson result_bytes 0 \
           --argjson max_budget_usd 0 \
           '{ts:$ts, task:$task, model:$model, status:$status, reason:$reason, input:$input, output:$output, cost_usd:$cost_usd, duration_ms:$duration_ms, result_bytes:$result_bytes, result_hash:$result_hash, max_budget_usd:$max_budget_usd}' \
        >> "$LEDGER" 2>/dev/null || true
}

# ─── STAGE 1: PLAN ──────────────────────────────────────────
stage_plan() {
    log "STAGE 1: plan"
    mkdir -p "$REPORTS_DIR" 2>/dev/null || true

    # 월초(1일) 또는 FORCE=1 환경변수일 때만 진행
    local dom
    dom=$(date +%-d)
    if [[ "$dom" != "1" && "${FORCE:-0}" != "1" ]]; then
        log "plan_skip: not 1st of month (today=${dom}). Set FORCE=1 to override."
        ledger_stage "plan" "skip" "not_month_start"
        printf 'monthly-review skipped (not 1st of month)\n'
        exit 0
    fi

    # 30일간 ledger 사전 집계 (LLM에게 힌트로 전달)
    if [[ -f "$LEDGER" ]] && command -v jq >/dev/null 2>&1; then
        local stats
        stats=$(jq -s -r '
          map(select(.ts > (now - 30*86400 | strftime("%Y-%m-%dT%H:%M:%SZ"))))
          | {
              total_runs: length,
              total_cost: (map(.cost_usd // 0) | add),
              unique_tasks: ([.[].task] | unique | length),
              fail_count: (map(select(.status == "fail" or .status == "error")) | length)
            }
          | "ledger_30d runs=\(.total_runs) cost=$\(.total_cost) unique=\(.unique_tasks) fails=\(.fail_count)"
        ' "$LEDGER" 2>/dev/null || echo "ledger_read_failed")
        log "plan_info: $stats"
    fi

    ledger_stage "plan" "pass" ""
    return 0
}

# ─── STAGE 2: EXECUTE ───────────────────────────────────────
stage_execute() {
    log "STAGE 2: execute (ask-claude.sh 위임)"
    local ask_claude="${BOT_HOME}/bin/ask-claude.sh"
    if [[ ! -x "$ask_claude" ]]; then
        ask_claude="${HOME}/jarvis/infra/bin/ask-claude.sh"
    fi
    local report_path="${REPORTS_DIR}/monthly-review-$(date +%Y-%m).md"
    local prompt="ultrathink

지난 달 Jarvis 운영 회고:
1) 크론 태스크 성공률 목표(90%) vs 달성
2) OpenAI API 비용 현황 (~/jarvis/runtime/logs/rag-index.log 기반 임베딩 건수 추정 + ~/jarvis/runtime/state/token-ledger.jsonl 집계)
3) 시스템 안정성 (watchdog 로그 크래시 횟수)
4) 가장 많이 실행된 태스크 Top 3
5) 다음 달 개선 목표 3가지

한국어로 간결하게. 위 5개 번호 섹션 모두 포함 필수 (verify 단계가 체크).

분석 완료 후 결과를 ${report_path} 에 마크다운으로 저장해줘."

    if bash "$ask_claude" "$TASK_ID" "$prompt" "Bash,Read,Write" "270" "1.00" 2>&1; then
        ledger_stage "execute" "pass" ""
        return 0
    else
        local ec=$?
        log "execute_fail: exit=$ec"
        ledger_stage "execute" "fail" "ask_claude_exit_$ec"
        return "$ec"
    fi
}

# ─── STAGE 3: VERIFY ────────────────────────────────────────
stage_verify() {
    log "STAGE 3: verify"
    local report_file="${REPORTS_DIR}/monthly-review-$(date +%Y-%m).md"
    if [[ ! -f "$report_file" ]]; then
        log "verify_fail: 리포트 파일 없음 — ${report_file}"
        ledger_stage "verify" "fail" "report_missing"
        return 1
    fi
    local report_bytes
    report_bytes=$(wc -c < "$report_file" | tr -d ' ')
    if (( report_bytes < 300 )); then
        log "verify_fail: 리포트 너무 짧음 ($report_bytes bytes)"
        ledger_stage "verify" "fail" "report_too_short"
        return 1
    fi
    local missing=""
    for keyword in "성공률" "비용" "안정성" "Top" "개선"; do
        if ! grep -qi "$keyword" "$report_file"; then
            missing="${missing}${keyword},"
        fi
    done
    if [[ -n "$missing" ]]; then
        log "verify_warn: 섹션 누락 — ${missing}"
        ledger_stage "verify" "warn" "missing_sections:${missing}"
    else
        ledger_stage "verify" "pass" ""
    fi
    return 0
}

# ─── MAIN ───────────────────────────────────────────────────
if ! stage_plan; then
    printf 'PLAN_FAIL\n'
    exit 1
fi
stage_execute || exit $?
stage_verify || exit $?
printf 'Monthly review 3-agent 완료 (plan+execute+verify)\n'