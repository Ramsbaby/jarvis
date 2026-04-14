#!/usr/bin/env bash
set -euo pipefail

# token-ledger-audit.sh — 주간 토큰 낭비 자동 감사
#
# Purpose:
#   Tier 0 원장(`~/.jarvis/state/token-ledger.jsonl`) 위에서 주간 패턴 감사.
#   사람이 수동으로 했던 "토큰 낭비 검사"를 매주 일요일 자동 실행.
#
# Schedule: 매주 일요일 08:30 KST (tasks.json: 30 8 * * 0)
#
# Checks:
#   A. 일별 총 지출 추이 (7d)
#   B. 비용 Top 10 (dedup 후보 자동 감지)
#   C. 같은 result_hash 5회+ 반복 (dedup 후보)
#   D. maxBudget 80%+ 초과 실행 (예산 압박)
#   E. 캐시 게이트 효율 (cache_hit 비율)
#   F. 파일시스템 낭비 (logs/state/rag 크기, stderr 14d+)
#   G. 서킷브레이커 3회+ 연속실패
#   H. 자동 권장사항 (dedup 확장, Tier 1~4 활성화 시점, 프롬프트 다이어트)
#
# Output: Markdown 리포트 ~/.jarvis/results/token-ledger-audit/<YYYY-MM-DD>.md
# Alert:  유의미한 발견(dedup/budget/cb) 시 Discord jarvis-system 채널 알림

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LEDGER="${BOT_HOME}/state/token-ledger.jsonl"
REPORT_DIR="${BOT_HOME}/results/token-ledger-audit"
REPORT_FILE="${REPORT_DIR}/$(date +%F).md"

mkdir -p "$REPORT_DIR"

log() { printf '[%s] [token-ledger-audit] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# --- Preflight ---
if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq 필요"
    exit 2
fi

if [[ ! -f "$LEDGER" || ! -s "$LEDGER" ]]; then
    log "ledger 비어있음 — 데이터 수집 대기"
    {
        printf '# 토큰 원장 주간 감사 — %s\n\n' "$(date '+%Y-%m-%d %H:%M KST')"
        printf '## 수집 대기 중\n\n'
        printf '원장(`%s`)이 비어 있습니다.\n\n' "$LEDGER"
        printf 'ask-claude.sh 실행이 1건이라도 발생한 후 다시 시도하세요.\n'
    } > "$REPORT_FILE"
    printf 'ledger empty — waiting for data. report: %s\n' "$REPORT_FILE"
    exit 0
fi

ENTRIES=$(wc -l < "$LEDGER" | tr -d ' ')
EARLIEST=$(jq -r -s 'map(.ts) | min // ""' "$LEDGER" 2>/dev/null)
LATEST=$(jq -r -s 'map(.ts) | max // ""' "$LEDGER" 2>/dev/null)

DAYS_COVERED="?"
if [[ -n "$EARLIEST" ]] && command -v python3 >/dev/null 2>&1; then
    DAYS_COVERED=$(python3 -c "
import datetime, sys
try:
    earliest = datetime.datetime.fromisoformat('$EARLIEST'.replace('Z','+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    print(max(1, (now - earliest).days))
except Exception:
    print('?')
" 2>/dev/null || echo "?")
fi

# --- Aggregations (7d window) ---

# A. 일별 총 지출
daily_totals=$(jq -s -r '
  map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ"))))
  | group_by(.ts[0:10])
  | map({date: .[0].ts[0:10], cost: ((map(.cost_usd // 0) | add) * 10000 | round / 10000), runs: length})
  | sort_by(.date)
  | .[]
  | "| \(.date) | \(.runs) | $\(.cost) |"
' "$LEDGER" 2>/dev/null || echo "")

week_total=$(jq -s -r '
  (map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ")))) | map(.cost_usd // 0) | add // 0)
  | . * 100 | round / 100
' "$LEDGER" 2>/dev/null || echo "0")

# B. 비용 Top 10
top_cost=$(jq -s -r '
  map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ"))))
  | group_by(.task)
  | map({
      task: .[0].task,
      runs: length,
      cost: ((map(.cost_usd // 0) | add) * 10000 | round / 10000),
      cache_hits: (map(select(.status == "cache_hit")) | length),
      unique_hashes: ([.[].result_hash] | unique | length)
    })
  | sort_by(-.cost)
  | .[0:10]
  | .[]
  | "| \(.task) | \(.runs) | $\(.cost) | \(.cache_hits) | \(.unique_hashes)/\(.runs) |"
' "$LEDGER" 2>/dev/null || echo "")

# C. Dedup 후보 (같은 해시 5회+)
dedup_candidates=$(jq -s -r '
  map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ")) and .result_hash != "" and .status != "cache_hit"))
  | group_by([.task, .result_hash])
  | map(select(length >= 5))
  | map({task: .[0].task, hash: .[0].result_hash, count: length, model: .[0].model})
  | sort_by(-.count)
  | .[]
  | "| \(.task) | \(.hash) | \(.count) | \(.model) |"
' "$LEDGER" 2>/dev/null || echo "")

# D. 예산 압박
budget_pressure=$(jq -s -r '
  map(select((.max_budget_usd // 0) > 0 and (.cost_usd // 0) > 0 and ((.cost_usd / .max_budget_usd) > 0.8)))
  | group_by(.task)
  | map({
      task: .[0].task,
      max_budget: .[0].max_budget_usd,
      runs_over_80pct: length,
      highest_pct: (map((.cost_usd / .max_budget_usd) * 100) | max | floor)
    })
  | sort_by(-.highest_pct)
  | .[]
  | "| \(.task) | $\(.max_budget) | \(.highest_pct)% | \(.runs_over_80pct) |"
' "$LEDGER" 2>/dev/null || echo "")

# E. 캐시 효율
cache_effectiveness=$(jq -s -r '
  map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ"))))
  | group_by(.task)
  | map(select([.[].status] | any(. == "cache_hit")))
  | map({
      task: .[0].task,
      total: length,
      hits: (map(select(.status == "cache_hit")) | length),
      misses: (map(select(.status != "cache_hit")) | length)
    })
  | map(. + {hit_rate: ((.hits / .total * 100) | floor)})
  | sort_by(-.hit_rate)
  | .[]
  | "| \(.task) | \(.total) | \(.hits) | \(.misses) | \(.hit_rate)% |"
' "$LEDGER" 2>/dev/null || echo "")

# F. 파일시스템
logs_size=$(du -sh "${BOT_HOME}/logs" 2>/dev/null | cut -f1 || echo "?")
state_size=$(du -sh "${BOT_HOME}/state" 2>/dev/null | cut -f1 || echo "?")
rag_size=$(du -sh "${BOT_HOME}/rag" 2>/dev/null | cut -f1 || echo "?")
stderr_count=$(find "${BOT_HOME}/logs" -maxdepth 1 -name "claude-stderr-*.log" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
stale_stderr=$(find "${BOT_HOME}/logs" -maxdepth 1 -name "claude-stderr-*.log" -mtime +14 2>/dev/null | wc -l | tr -d ' ' || echo 0)

# G. 서킷브레이커
cb_high_fails=""
if [[ -d "${BOT_HOME}/state/circuit-breaker" ]]; then
    while IFS= read -r f; do
        fails=$(jq -r '.consecutive_fails // 0' "$f" 2>/dev/null || echo 0)
        if [[ "$fails" -ge 3 ]]; then
            task=$(basename "$f" .json)
            cb_high_fails="${cb_high_fails}- ${task} (${fails}회)"$'\n'
        fi
    done < <(find "${BOT_HOME}/state/circuit-breaker" -maxdepth 1 -name "*.json" 2>/dev/null)
fi

# --- Generate report ---
{
cat <<EOF
# 토큰 원장 주간 감사 — $(date '+%Y-%m-%d %H:%M KST')

> 자동 생성: \`token-ledger-audit.sh\` · 데이터 기간: 최근 7일

## 📊 원장 커버리지

- **총 엔트리**: ${ENTRIES}건
- **최초 기록**: ${EARLIEST:-N/A}
- **최종 기록**: ${LATEST:-N/A}
- **데이터 기간**: 약 ${DAYS_COVERED}일
- **7일 총 지출**: \$${week_total}

EOF

if [[ "$DAYS_COVERED" != "?" ]] && [[ "$DAYS_COVERED" -lt 3 ]]; then
    cat <<'EOF'
## ⚠️ 데이터 부족

3일 미만의 데이터만 있습니다. 아래 권장사항은 신뢰도가 낮으며, 다음 주 감사에서 재확인 필요.

EOF
fi

cat <<EOF
## 💰 일별 총 지출 (7d)

| 날짜 | 실행 수 | 비용 |
|------|---:|---:|
${daily_totals:-_(데이터 없음)_}

## 🔥 비용 Top 10 (7d)

| 태스크 | 실행 | 비용 | 캐시히트 | 유니크결과 |
|---|---:|---:|---:|---:|
${top_cost:-_(데이터 없음)_}

**해석**:
- \`유니크결과/실행\`이 낮으면 **dedup 후보** — 해시 캐시 gate 적용 가능
- \`캐시히트=0\`이면 해시 gate 없음

## 🔁 Dedup 후보 (같은 해시 5회+ 반복)

| 태스크 | 해시 | 반복 | 모델 |
|---|---|---:|---|
${dedup_candidates:-_(해당 없음)_}

**액션**: \`github-monitor-gate.sh\` 패턴 적용 권장.

## 💸 예산 압박 (단일 실행 cost > 80% maxBudget)

| 태스크 | maxBudget | 최고% | 80%+ 실행수 |
|---|---:|---:|---:|
${budget_pressure:-_(해당 없음)_}

**액션**: 80% 반복 초과 시 프롬프트 다이어트 또는 maxBudget 상향 검토.

## ✅ 캐시 효율 (cache_hit 기록 있는 태스크)

| 태스크 | 총실행 | 히트 | 미스 | 히트율 |
|---|---:|---:|---:|---:|
${cache_effectiveness:-_(cache gate 적용 태스크 없음)_}

## 🗂 파일 시스템

- **logs/**: ${logs_size} (stderr 파일 ${stderr_count}개, 14일+ 오래된 것 ${stale_stderr}개)
- **state/**: ${state_size}
- **rag/**: ${rag_size}

## 🚨 서킷브레이커 (연속실패 3회+)

$(if [[ -n "$cb_high_fails" ]]; then printf '%s' "$cb_high_fails"; else printf '_(해당 없음)_\n'; fi)

## 🎯 자동 권장사항

EOF

# Auto-recommendations
recs=""
if [[ -n "$dedup_candidates" ]]; then
    dc=$(printf '%s\n' "$dedup_candidates" | grep -c '^|' || echo 0)
    recs="${recs}
### 해시 캐시 gate 확장
${dc}개 태스크가 dedup 후보. \`infra/scripts/github-monitor-gate.sh\`를 참고해 각 태스크용 gate 스크립트 작성.
"
fi

if [[ -n "$budget_pressure" ]]; then
    bp=$(printf '%s\n' "$budget_pressure" | grep -c '^|' || echo 0)
    recs="${recs}
### 프롬프트 다이어트 또는 예산 조정
${bp}개 태스크가 maxBudget 80%+ 반복 소비. \`contextFile\`/프롬프트 용량 점검.
"
fi

if [[ -n "$week_total" ]] && awk -v w="$week_total" 'BEGIN{exit !(w+0 > 5)}'; then
    daily_avg=$(awk -v w="$week_total" 'BEGIN{printf "%.2f", w/7}')
    recs="${recs}
### Tier 1 (글로벌 일일 캡) 활성화 시점
주간 지출 \$${week_total} (일평균 \$${daily_avg}). 글로벌 캡 도입 검토 단계.
"
fi

if [[ "$stale_stderr" -gt 100 ]]; then
    recs="${recs}
### stderr 로그 자동 rotation
14일+ 오래된 stderr 로그 ${stale_stderr}개. 주간 cron에 \`find -mtime +14 -delete\` 등록 권장.
"
fi

if [[ -n "$cb_high_fails" ]]; then
    recs="${recs}
### 서킷브레이커 해소
3회+ 연속실패 태스크의 root cause 파악 (\`~/.jarvis/logs/claude-stderr-<task>*.log\` 참조).
"
fi

if [[ -z "$recs" ]]; then
    printf '현재 데이터로는 즉시 조치할 사항 없음. 다음 주 감사에서 재확인.\n'
else
    printf '%s\n' "$recs"
fi

cat <<'EOF'

## 📋 Tier 로드맵 진행 상황

- [x] **Tier 0**: 토큰 원장 (`~/.jarvis/state/token-ledger.jsonl`)
- [ ] **Tier 1**: 글로벌 일일 캡
- [ ] **Tier 2**: 해시 dedup 범용화 (현재 github-monitor만)
- [ ] **Tier 3**: 영구 실패 auto-disable
- [ ] **Tier 4**: 80% 예산 경고 Discord alert

EOF

printf -- '---\n\n*다음 감사: %s*\n' "$(date -v+7d '+%Y-%m-%d' 2>/dev/null || date -d '+7 days' '+%Y-%m-%d' 2>/dev/null || echo '7일 후')"

} > "$REPORT_FILE"

log "report written: $REPORT_FILE"

# --- Discord alert on significant findings ---
significant=false
if [[ -n "$dedup_candidates" ]] || [[ -n "$budget_pressure" ]] || [[ -n "$cb_high_fails" ]]; then
    significant=true
fi

if $significant; then
    log "significant findings → Discord alert"
    summary_parts=""
    if [[ -n "$dedup_candidates" ]]; then
        dc=$(printf '%s\n' "$dedup_candidates" | grep -c '^|' || echo 0)
        summary_parts="${summary_parts}• Dedup 후보 ${dc}개\n"
    fi
    if [[ -n "$budget_pressure" ]]; then
        bp=$(printf '%s\n' "$budget_pressure" | grep -c '^|' || echo 0)
        summary_parts="${summary_parts}• 예산 80%+ ${bp}개\n"
    fi
    if [[ -n "$cb_high_fails" ]]; then
        summary_parts="${summary_parts}• CB 연속실패 있음\n"
    fi

    ALERT_SCRIPT="${BOT_HOME}/scripts/alert.sh"
    if [[ -x "$ALERT_SCRIPT" ]]; then
        alert_body="주간 \$${week_total}"$'\n'"${summary_parts}리포트: ${REPORT_FILE}"
        # alert.sh signature: alert.sh <level> <title> <message> [fields_json]
        "$ALERT_SCRIPT" "warning" "토큰 원장 주간 감사" "$alert_body" 2>/dev/null || log "alert.sh 실패 (무시)"
    else
        log "alert.sh 없음 — Discord 알림 skip"
    fi
fi

# Print summary (bot-cron.sh가 RESULT로 캡처)
printf 'Weekly token ledger audit: $%s spent in 7d, %d entries analyzed. Report: %s\n' \
    "${week_total:-0}" "$ENTRIES" "$REPORT_FILE"
