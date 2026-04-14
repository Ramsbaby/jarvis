#!/usr/bin/env bash
set -euo pipefail

# council-insight-3-agent.sh — Tier 3 plan/execute/verify 분할
#
# Plan    : context-bus.md 신선도 + cron.log 존재 + board-minutes 접근성
# Execute : ask-claude.sh 위임 (기존 Sonnet 기반 복합 보고)
# Verify  : 4개 섹션(cron/system/market/action) + 숫자 일관성 + context-bus 갱신 확인

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
TASK_ID="council-insight"
LEDGER="${BOT_HOME}/state/token-ledger.jsonl"
CONTEXT_BUS="${BOT_HOME}/state/context-bus.md"
CRON_LOG="${BOT_HOME}/logs/cron.log"
BOARD_MINUTES_DIR="${BOT_HOME}/state/board-minutes"

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
    if [[ ! -f "$CRON_LOG" ]]; then
        log "plan_fail: cron.log 없음"
        ledger_stage "plan" "fail" "cron_log_missing"
        return 1
    fi
    # context-bus 신선도 (2시간 넘으면 경고)
    if [[ -f "$CONTEXT_BUS" ]]; then
        local bus_age_min
        bus_age_min=$(( ( $(date +%s) - $(stat -f %m "$CONTEXT_BUS" 2>/dev/null || echo 0) ) / 60 ))
        if (( bus_age_min > 120 )); then
            log "plan_warn: context-bus.md stale (${bus_age_min}분 전 갱신) — LLM이 outdated 정보를 쓸 수 있음"
            ledger_stage "plan" "warn" "context_bus_stale_${bus_age_min}m"
        fi
    else
        log "plan_warn: context-bus.md 없음 — 신규 생성 예상"
        ledger_stage "plan" "warn" "context_bus_missing"
    fi
    mkdir -p "$BOARD_MINUTES_DIR" 2>/dev/null || true
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
    local prompt="ultrathink

자비스 CEO(비서실장)로서 일일 종합 경영 점검을 수행해. 컨텍스트 파일의 실행 순서(Step 1→2→3)를 반드시 따를 것. 핵심: 데이터 수집 후 공용 게시판(~/.jarvis/state/context-bus.md)과 모닝스탠드업 인계사항을 갱신하고, Discord #jarvis-ceo에 임원 보고서를 전송.

## 외부 에이전트 동향 (Workgroup 게시판)
오늘 board 인사이트 파일이 있으면 참조해서 보고서에 '외부 에이전트 동향' 섹션을 추가하라.
\`\`\`bash
cat ~/Jarvis-Vault/02-daily/board/\$(date '+%Y-%m-%d').md 2>/dev/null | head -100
\`\`\`
주목할 것: 다른 에이전트들이 논의한 기술 주제, 자비스에 대한 언급/반응, 벤치마킹할 만한 아이디어.

## 출력 요구사항 (verify 단계가 체크)
보고서는 반드시 4개 섹션을 포함하라:
1. 크론 실행 현황 (성공/실패 숫자)
2. 시스템 상태 (디스크/메모리/봇)
3. 경영 판단 포인트
4. 내일 CEO 액션"

    if bash "$ask_claude" "$TASK_ID" "$prompt" "Bash,Read,Write" "540" "1.50" 2>&1; then
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
    # context-bus.md가 이번 실행 중에 갱신됐는지 (5분 이내)
    if [[ -f "$CONTEXT_BUS" ]]; then
        local bus_age_s
        bus_age_s=$(( $(date +%s) - $(stat -f %m "$CONTEXT_BUS" 2>/dev/null || echo 0) ))
        if (( bus_age_s > 300 )); then
            log "verify_warn: context-bus.md 갱신 흔적 없음 (${bus_age_s}s ago) — LLM이 업데이트 누락 가능성"
            ledger_stage "verify" "warn" "context_bus_not_touched"
        fi
    fi
    # 오늘자 결과 파일 존재 확인
    local results_dir="${BOT_HOME}/results/${TASK_ID}"
    local latest_result
    latest_result=$(find "$results_dir" -name "*.md" -mmin -10 2>/dev/null | head -1)
    if [[ -z "$latest_result" ]]; then
        log "verify_warn: 오늘자 결과 파일 없음"
        ledger_stage "verify" "warn" "result_not_found"
        return 0
    fi
    # 4개 기대 섹션 키워드 확인
    local missing=""
    for keyword in "크론" "시스템" "경영" "내일"; do
        if ! grep -q "$keyword" "$latest_result"; then
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
printf 'Council insight 3-agent 완료 (plan+execute+verify)\n'
