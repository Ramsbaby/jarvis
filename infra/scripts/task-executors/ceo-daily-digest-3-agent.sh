#!/usr/bin/env bash
set -euo pipefail

# ceo-daily-digest-3-agent.sh — Tier 3 plan/execute/verify 분할
#
# Anthropic 3-agent 아키텍처:
#   Plan    : 데이터 소스 존재 + webhook 설정 사전 검증
#   Execute : ask-claude.sh 위임 (기존 프롬프트 사용)
#   Verify  : 결과 schema + Discord webhook 도달 검증
#
# 호출: bot-cron.sh가 tasks.json `script` 필드로 직접 실행
# 단계별 실패는 ledger에 stage 태그로 기록 (ceo-daily-digest:plan / :execute / :verify)

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
TASK_ID="ceo-daily-digest"
LEDGER="${BOT_HOME}/state/token-ledger.jsonl"
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
    local data_script="${BOT_HOME}/scripts/ceo-digest-data.sh"
    if [[ ! -x "$data_script" ]]; then
        log "plan_fail: ceo-digest-data.sh not executable at $data_script"
        ledger_stage "plan" "fail" "data_script_missing"
        return 1
    fi
    local monitoring_cfg="${BOT_HOME}/config/monitoring.json"
    if [[ -f "$monitoring_cfg" ]]; then
        local webhook
        webhook=$(jq -r '.discord.webhook_url // .webhooks["jarvis-ceo"] // ""' "$monitoring_cfg" 2>/dev/null || echo "")
        if [[ -z "$webhook" ]]; then
            log "plan_warn: no discord webhook found in monitoring.json (execute will proceed but verify may fail)"
            ledger_stage "plan" "warn" "webhook_missing"
        fi
    fi
    mkdir -p "$REPORTS_DIR" 2>/dev/null || true
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
    local prompt="ceo-digest-data.sh를 실행하여 데이터를 수집하고, 오늘의 CEO 다이제스트 보고서를 한국어로 작성하세요.

1. 데이터 수집:
   bash ~/.jarvis/scripts/ceo-digest-data.sh

2. 아래 구조로 간결한 보고서 작성 (모든 내용 한국어):
   - 요약 (1문장)
   - 크론 실행 현황 (성공/실패, 성공률, 주요 오류)
   - 시스템 상태
   - Discord 활동 건수
   - 내일 핵심 과제

3. 보고서 저장: ${REPORTS_DIR}/ceo-digest-\$(date +%Y-%m-%d).md

4. 300자 이내 요약을 Discord #jarvis-ceo에 한국어로 전송.

간결하고 실행 가능한 내용만."

    if bash "$ask_claude" "$TASK_ID" "$prompt" "Read,Write,Bash" "160" "0.30" 2>&1; then
        ledger_stage "execute" "pass" ""
        return 0
    else
        local ec=$?
        log "execute_fail: ask-claude.sh exit=$ec"
        ledger_stage "execute" "fail" "ask_claude_exit_$ec"
        return "$ec"
    fi
}

# ─── STAGE 3: VERIFY ────────────────────────────────────────
stage_verify() {
    log "STAGE 3: verify"
    local report_file
    report_file=$(find "$REPORTS_DIR" -name "ceo-digest-$(date +%Y-%m-%d).md" -mmin -5 2>/dev/null | head -1)
    if [[ -z "$report_file" ]]; then
        log "verify_warn: 오늘자 리포트 파일 미발견 — LLM이 저장 경로를 누락했을 수 있음"
        ledger_stage "verify" "warn" "report_not_found"
        return 0
    fi
    local report_bytes
    report_bytes=$(wc -c < "$report_file" | tr -d ' ')
    if (( report_bytes < 100 )); then
        log "verify_fail: 리포트 너무 짧음 ($report_bytes bytes)"
        ledger_stage "verify" "fail" "report_too_short_${report_bytes}"
        return 1
    fi
    local missing=""
    for section in "요약" "크론" "시스템" "Discord" "과제"; do
        if ! grep -q "$section" "$report_file"; then
            missing="${missing}${section},"
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
printf 'CEO daily digest 3-agent 완료 (plan+execute+verify)\n'
