#!/usr/bin/env bash
set -euo pipefail

# tune-task-params.sh — Tier 5 KPI → Auto-tune 제안 엔진
#
# Purpose:
#   token-ledger의 7일 데이터를 분석하여 각 태스크의 파라미터 조정 제안을 생성.
#   **제안만 생성** — tasks.json을 직접 수정하지 않음. 오너가 리뷰하고 수동 반영.
#
# Safety:
#   - tasks.json 절대 수정 금지 (growth-lead 팀장 권고: Meta Agent 자동 수정은 premature)
#   - 제안 리포트만 ~/jarvis/runtime/results/tune-suggestions/<date>.md 에 생성
#   - 유의미한 제안 시 Discord 알림
#
# Schedule: token-ledger-audit.sh 직후 실행 (매주 일요일 08:35 KST)
#
# Checks:
#   A. 타임아웃 율 > 20% → timeout +30% 제안
#   B. cost_usd > 80% × maxBudget → 프롬프트 다이어트 or 예산 상향 제안
#   C. 재시도 율 > 40% → retry.max +1 또는 retry-wrapper 점검 제안
#   D. 결과 size < 100 bytes → "thin output" 반복 플래그
#   E. evaluator warn 10회+ → 태스크별 warn 누적 추세 알림

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER="${BOT_HOME}/state/token-ledger.jsonl"
TASKS_JSON="${BOT_HOME}/config/tasks.json"
REPORT_DIR="${BOT_HOME}/results/tune-suggestions"
REPORT_FILE="${REPORT_DIR}/$(date +%F).md"

mkdir -p "$REPORT_DIR"

log() { printf '[%s] [tune-task-params] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq 필요"
    exit 2
fi

if [[ ! -f "$LEDGER" || ! -s "$LEDGER" ]]; then
    log "ledger 비어있음 — 수집 대기"
    {
        printf '# Tune Suggestions — %s\n\n' "$(date '+%Y-%m-%d %H:%M KST')"
        printf '원장 데이터 부족 — 최소 7일 수집 후 다시 시도.\n'
    } > "$REPORT_FILE"
    printf 'tune-task-params skipped (empty ledger)\n'
    exit 0
fi

ENTRIES=$(wc -l < "$LEDGER" | tr -d ' ')
EARLIEST=$(jq -r -s 'map(.ts) | min // ""' "$LEDGER" 2>/dev/null)

# 3일 미만이면 샘플 부족 경고
DAYS_COVERED="?"
if [[ -n "$EARLIEST" ]] && command -v python3 >/dev/null 2>&1; then
    DAYS_COVERED=$(python3 -c "
import datetime
try:
    e = datetime.datetime.fromisoformat('$EARLIEST'.replace('Z','+00:00'))
    n = datetime.datetime.now(datetime.timezone.utc)
    print(max(1, (n - e).days))
except Exception:
    print('?')
" 2>/dev/null || echo "?")
fi

# ─── A. 타임아웃 의심 태스크 (duration_ms가 timeout에 근접) ───
# tasks.json의 timeout 필드는 초. duration_ms/1000이 timeout * 0.8 이상이면 "at-risk"
timeout_at_risk=""
if [[ -f "$TASKS_JSON" ]]; then
    timeout_at_risk=$(jq -r -s --slurpfile tasks_wrap <(jq '{tasks: .tasks}' "$TASKS_JSON") '
      map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ"))))
      | group_by(.task)
      | map({
          task: .[0].task,
          runs: length,
          avg_duration_ms: ((map(.duration_ms // 0) | add) / length | floor),
          max_duration_ms: (map(.duration_ms // 0) | max)
        })
      | .[] as $t
      | $tasks_wrap[0].tasks[] as $def
      | select($def.id == $t.task and ($def.timeout // 0) > 0)
      | select(($t.max_duration_ms / 1000) > (($def.timeout // 0) * 0.8))
      | "| \($t.task) | \($def.timeout)s | \((($t.max_duration_ms / 1000) | floor))s | \(($t.max_duration_ms * 100 / ($def.timeout * 1000)) | floor)% | \($t.runs) |"
    ' "$LEDGER" 2>/dev/null || echo "")
fi

# ─── B. 예산 압박 (cost_usd > 80% × max_budget_usd) ───
budget_pressure=$(jq -s -r '
  map(select((.max_budget_usd // 0) > 0 and (.cost_usd // 0) > 0 and ((.cost_usd / .max_budget_usd) > 0.8)))
  | group_by(.task)
  | map({
      task: .[0].task,
      max_budget: .[0].max_budget_usd,
      highest_pct: (map((.cost_usd / .max_budget_usd) * 100) | max | floor),
      runs_over_80: length
    })
  | sort_by(-.highest_pct)
  | .[]
  | "| \(.task) | $\(.max_budget) | \(.highest_pct)% | \(.runs_over_80) |"
' "$LEDGER" 2>/dev/null || echo "")

# ─── C. 재시도 율 추정 (evaluator fail + error status) ───
retry_signals=$(jq -s -r '
  map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ"))))
  | group_by(.task)
  | map({
      task: .[0].task,
      total: length,
      fails: (map(select(.status == "fail" or .status == "error")) | length)
    })
  | map(. + {fail_pct: (if .total > 0 then (.fails * 100 / .total | floor) else 0 end)})
  | map(select(.fail_pct > 40))
  | sort_by(-.fail_pct)
  | .[]
  | "| \(.task) | \(.total) | \(.fails) | \(.fail_pct)% |"
' "$LEDGER" 2>/dev/null || echo "")

# ─── D. 결과 사이즈 작음 (result_bytes < 100) ───
thin_outputs=$(jq -s -r '
  map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ")) and .result_bytes > 0))
  | group_by(.task)
  | map({
      task: .[0].task,
      total: length,
      thin: (map(select(.result_bytes < 100)) | length)
    })
  | map(. + {thin_pct: (if .total > 0 then (.thin * 100 / .total | floor) else 0 end)})
  | map(select(.thin_pct > 50 and .total >= 3))
  | sort_by(-.thin_pct)
  | .[]
  | "| \(.task) | \(.total) | \(.thin) | \(.thin_pct)% |"
' "$LEDGER" 2>/dev/null || echo "")

# ─── E. Evaluator warn 누적 ───
evaluator_warns=$(jq -s -r '
  map(select(.task | contains(":verify") or contains(":plan") or contains(":execute")) | select(.status == "warn"))
  | group_by(.task)
  | map({task: .[0].task, warns: length, last_reason: .[-1].reason})
  | sort_by(-.warns)
  | .[]
  | "| \(.task) | \(.warns) | \(.last_reason) |"
' "$LEDGER" 2>/dev/null || echo "")

# ─── 리포트 생성 ───
{
cat <<EOF
# Tune Task Params — $(date '+%Y-%m-%d %H:%M KST')

> 자동 생성: \`tune-task-params.sh\` · 데이터 기간: 최근 7일 · 엔트리: ${ENTRIES}건 (약 ${DAYS_COVERED}일)
>
> **이 리포트는 제안만 생성합니다.** tasks.json을 자동 수정하지 않으며, 오너가 리뷰 후 수동 반영하세요.

EOF

if [[ "$DAYS_COVERED" != "?" ]] && [[ "$DAYS_COVERED" -lt 3 ]]; then
    cat <<'EOF'
## ⚠️ 데이터 부족 (3일 미만)

신뢰 가능한 패턴 분석을 위해 최소 1주일 원장 축적이 필요합니다. 아래 제안은 참고용.

EOF
fi

cat <<EOF
## ⏱️ 타임아웃 위험 (max duration이 timeout의 80% 초과)

| 태스크 | 현재 timeout | 최대 duration | 위험도 | 실행수 |
|---|---:|---:|---:|---:|
${timeout_at_risk:-_(해당 없음)_}

**제안**: 위험도 > 90% 태스크는 tasks.json \`timeout\` 필드를 현재값의 **1.3배**로 상향 검토.

## 💸 예산 압박 (단일 실행 cost > 80% maxBudget)

| 태스크 | maxBudget | 최고% | 80%+ 실행수 |
|---|---:|---:|---:|
${budget_pressure:-_(해당 없음)_}

**제안**: 선택지 3개 중 하나
1. **프롬프트 다이어트** — \`contextFile\` 또는 inline prompt 길이 축소
2. **모델 다운그레이드** — sonnet → haiku (단, 품질 저하 주의)
3. **maxBudget 상향** — 정말 필요한 컨텍스트면 캡 상향

## 🔁 재시도 율 높음 (>40%)

| 태스크 | 총실행 | 실패 | 실패율 |
|---|---:|---:|---:|
${retry_signals:-_(해당 없음)_}

**제안**: Root cause 조사 우선. evaluator reason 필드를 점검하고
\`claude-stderr-<task>-<date>.log\`에서 실패 원인 확인.

## 📏 Thin output 반복 (result_bytes < 100, >50%)

| 태스크 | 총실행 | Thin 횟수 | Thin 비율 |
|---|---:|---:|---:|
${thin_outputs:-_(해당 없음)_}

**제안**: 프롬프트가 너무 짧은 결과를 요청하거나, LLM이 줄여서 답하는 패턴.
필요 시 프롬프트에 "최소 N단어" 같은 하한 명시.

## 🟡 3-agent Verify 경고 누적

| 태스크 | 경고횟수 | 마지막 사유 |
|---|---:|---|
${evaluator_warns:-_(해당 없음)_}

**제안**: verify 경고가 반복되면 3-agent 스크립트의 schema/section 체크 리스트를 태스크 실제 출력에 맞춰 조정.

## 🎯 자동 추천 요약

EOF

# Auto recommendations
recs=""
if [[ -n "$timeout_at_risk" ]]; then
    cnt=$(printf '%s\n' "$timeout_at_risk" | grep -c '^|' || echo 0)
    recs="${recs}- ⏱️ **${cnt}개 태스크** timeout 조정 권장\n"
fi
if [[ -n "$budget_pressure" ]]; then
    cnt=$(printf '%s\n' "$budget_pressure" | grep -c '^|' || echo 0)
    recs="${recs}- 💸 **${cnt}개 태스크** 예산/프롬프트 점검 권장\n"
fi
if [[ -n "$retry_signals" ]]; then
    cnt=$(printf '%s\n' "$retry_signals" | grep -c '^|' || echo 0)
    recs="${recs}- 🔁 **${cnt}개 태스크** 재시도율 40%+ — root cause 필요\n"
fi
if [[ -n "$thin_outputs" ]]; then
    cnt=$(printf '%s\n' "$thin_outputs" | grep -c '^|' || echo 0)
    recs="${recs}- 📏 **${cnt}개 태스크** thin output 반복\n"
fi

if [[ -z "$recs" ]]; then
    printf '금주 제안 없음 — 모든 태스크가 정상 범위.\n'
else
    printf '%s\n' "$recs"
fi

printf '\n---\n\n*다음 감사: %s*\n' "$(date -v+7d '+%Y-%m-%d' 2>/dev/null || date -d '+7 days' '+%Y-%m-%d' 2>/dev/null || echo '7일 후')"

} > "$REPORT_FILE"

log "suggestions written: $REPORT_FILE"

# ─── Discord alert (유의미한 제안이 있을 때만) ───
significant=false
if [[ -n "$timeout_at_risk" ]] || [[ -n "$budget_pressure" ]] || [[ -n "$retry_signals" ]]; then
    significant=true
fi

if $significant; then
    log "significant tuning suggestions → Discord alert"
    ALERT_SCRIPT="${BOT_HOME}/scripts/alert.sh"
    if [[ -x "$ALERT_SCRIPT" ]]; then
        summary="주간 튜닝 제안"
        if [[ -n "$timeout_at_risk" ]]; then summary="${summary} · timeout"; fi
        if [[ -n "$budget_pressure" ]]; then summary="${summary} · budget"; fi
        if [[ -n "$retry_signals" ]]; then summary="${summary} · retry"; fi
        "$ALERT_SCRIPT" "info" "태스크 파라미터 튜닝 제안" "${summary}. 리포트: ${REPORT_FILE}" 2>/dev/null || log "alert.sh 실패"
    fi
fi

printf 'Tune suggestions generated. %d entries analyzed. Report: %s\n' "$ENTRIES" "$REPORT_FILE"