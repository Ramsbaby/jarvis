#!/usr/bin/env bash
set -euo pipefail

# token-ledger-audit.sh — 주간 토큰 낭비 자동 감사
#
# Purpose:
#   Tier 0 원장(`~/jarvis/runtime/state/token-ledger.jsonl`) 위에서 주간 패턴 감사.
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
# Output: Markdown 리포트 ~/jarvis/runtime/results/token-ledger-audit/<YYYY-MM-DD>.md
# Alert:  유의미한 발견(dedup/budget/cb) 시 Discord jarvis-system 채널 알림

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
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

# F-2. 미관리 대용량 경로 — 역방향 retention (2026-07-27 등재)
# 배경: 기존 정리 크론은 "알려진 경로"만 돈다(화이트리스트). 그래서 새로 생긴 경로는
#       영원히 사각지대다. runtime/backups 3GB, runtime/rag 2.5GB가 그렇게 쌓였다.
# 방식: 정리 스크립트들이 실제로 언급하는 경로를 자동 수집하고,
#       거기 안 걸리는 100MB+ 디렉토리를 역으로 찾는다. 앞으로 생길 경로도 자동으로 잡힌다.
managed_paths=$(grep -rhoE 'runtime/[a-z][a-z0-9_-]*' \
    "${BOT_HOME}/scripts/"*cleanup* "${BOT_HOME}/scripts/"*retention* \
    "${BOT_HOME}/scripts/"*rotate* "${BOT_HOME}/scripts/"*prune* 2>/dev/null \
    | sort -u || true)
unmanaged_paths=""
while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    sz_mb=$(du -sm "$d" 2>/dev/null | cut -f1 || echo 0)
    (( ${sz_mb:-0} < 100 )) && continue
    rel="runtime/$(basename "$d")"
    if ! grep -qxF "$rel" <<< "$managed_paths"; then
        unmanaged_paths="${unmanaged_paths}- \`${rel}\` — ${sz_mb}MB (**어떤 정리 규칙에도 안 걸림**)"$'\n'
    fi
    # 제외 목록을 두지 않는 이유: 하드코딩한 목록은 반드시 낡는다(2026-07-27 Serena 규칙 사례).
    # 런타임 코드 디렉토리가 섞여 나올 수 있으니 사람이 보고 판단한다. 오탐은 해롭지 않다.
    # sort -u 필수: find가 같은 경로를 중복 반환하는 사례를 실측했다(state 5회, 전체 57 vs 고유 53).
done < <(find "$BOT_HOME" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -u)

# G-0. 센서 생존 검사 (2026-07-27 등재)
# 배경: cost_usd 필드명 오타로 3.5개월간 비용이 null이었는데 아무도 몰랐다.
#       response-ledger 2개월간 2행, PreCompact 훅 2개월 침묵도 같은 부류다.
#       공통 원인은 `?? null` / `|| 0` / `[ -z ] && exit 0` — 값이 안 와도 예외가 안 나서
#       "정상"으로 읽힌다. 실패가 아니라 침묵이다.
# 계약: 원장은 (a) 기대 주기 안에 갱신되고 (b) 핵심 숫자 필드가 전부 null/0이면 안 된다.
sensor_health=""
sensor_check() {
    local label="$1" file="$2" max_stale_h="$3" field="${4:-}"
    if [[ ! -f "$file" ]]; then
        sensor_health="${sensor_health}- ❌ **${label}**: 파일 없음 (\`${file##*/}\`)"$'\n'
        return
    fi
    local mtime now age_h
    mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo 0)
    now=$(date +%s)
    age_h=$(( (now - mtime) / 3600 ))
    if (( age_h > max_stale_h )); then
        sensor_health="${sensor_health}- ❌ **${label}**: ${age_h}시간째 기록 없음 (기대 ${max_stale_h}h 이내) — 생산자 중단 의심"$'\n'
        return
    fi
    if [[ -n "$field" ]]; then
        # 0이 아닌 실제 값만 센다. `"f":0` 이나 `"f":0.000` 은 죽은 센서로 취급.
        # 생산자 필터(5번째 인자): 한 원장에 여러 생산자가 쓰면 해당 생산자 행만 본다.
        # 2026-07-27 실측: response-ledger에는 discord-bot과 claude-code-cli 두 생산자가 쓰는데
        # 후자는 cost 필드를 아예 안 넣는다. 구분 없이 세면 봇이 멀쩡해도 고장으로 오판한다.
        local producer="${5:-}" sample
        if [[ -n "$producer" ]]; then
            sample=$(grep -F "\"source\":\"${producer}\"" "$file" 2>/dev/null | tail -50 || true)
            if [[ -z "$sample" ]]; then
                sensor_health="${sensor_health}- ⚠️ ${label}: 최근 기록에 \`${producer}\` 생산자 행이 없음 — 생산자 유휴 또는 중단"$'\n'
                return
            fi
        else
            sample=$(tail -50 "$file" 2>/dev/null || true)
        fi
        local live
        live=$(printf '%s' "$sample" | grep -cE "\"${field}\":(0\.0*[1-9]|[1-9])" || true)
        if (( live == 0 )); then
            sensor_health="${sensor_health}- ❌ **${label}**: 최근 50행의 \`${field}\`가 전부 null/0 — **필드명 오타 의심**"$'\n'
            return
        fi
        sensor_health="${sensor_health}- ✅ ${label}: 정상 (${age_h}h 전, ${field} 유효 ${live}/50)"$'\n'
        return
    fi
    sensor_health="${sensor_health}- ✅ ${label}: 정상 (${age_h}h 전 기록)"$'\n'
}

sensor_check "token-ledger"            "$LEDGER"                                    48  "cost_usd"
sensor_check "response-ledger (봇)"    "${BOT_HOME}/state/response-ledger.jsonl"    48  "cost_usd" "discord-bot"
sensor_check "automation-budget"       "${BOT_HOME}/ledger/automation-budget.jsonl" 168
sensor_check "bot-response-bus"        "${BOT_HOME}/ledger/bot-response-bus.jsonl"  48

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

### 🕳 미관리 대용량 경로 (역방향 retention)

> 정리 스크립트가 언급하지 않는 100MB+ 디렉토리입니다. 방치하면 무한히 자랍니다.
> 런타임 코드 디렉토리가 섞여 나올 수 있으니 **지우기 전에 내용을 확인**하십시오.

${unmanaged_paths:-_(전부 어떤 정리 규칙엔가 걸려 있음)_}

## 🩺 센서 생존 검사

> 원장이 "조용히 죽어 있는" 상태를 잡습니다. ❌가 있으면 그 수치는 **믿으면 안 됩니다.**

${sensor_health:-_(검사 대상 없음)_}

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
3회+ 연속실패 태스크의 root cause 파악 (\`~/jarvis/runtime/logs/claude-stderr-<task>*.log\` 참조).
"
fi

if [[ -z "$recs" ]]; then
    printf '현재 데이터로는 즉시 조치할 사항 없음. 다음 주 감사에서 재확인.\n'
else
    printf '%s\n' "$recs"
fi

cat <<'EOF'

## 📋 Tier 로드맵 진행 상황

- [x] **Tier 0**: 토큰 원장 (`~/jarvis/runtime/state/token-ledger.jsonl`)
- [ ] **Tier 1**: 글로벌 일일 캡
- [ ] **Tier 2**: 해시 dedup 범용화 (현재 github-monitor만)
- [ ] **Tier 3**: 영구 실패 auto-disable
- [ ] **Tier 4**: 80% 예산 경고 Discord alert

EOF

printf -- '---\n\n*다음 감사: %s*\n' "$(date -v+7d '+%Y-%m-%d' 2>/dev/null || date -d '+7 days' '+%Y-%m-%d' 2>/dev/null || echo '7일 후')"

} > "$REPORT_FILE"

log "report written: $REPORT_FILE"

# --- Tier 2: Gate candidates 자동 수집 ---
# dedup 후보를 gate-candidates.json 큐에 append (수동 리뷰 대기)
GATE_QUEUE="${BOT_HOME}/state/gate-candidates.json"
mkdir -p "$(dirname "$GATE_QUEUE")" 2>/dev/null || true
if [[ ! -f "$GATE_QUEUE" ]]; then
    echo '{"candidates":[],"last_audit_run":""}' > "$GATE_QUEUE"
fi

# 현재 감사 기준 dedup 후보 (result_hash 5회+, cache_hit 제외)
new_candidates=$(jq -s -c '
  map(select(.ts > (now - 7*86400 | strftime("%Y-%m-%dT%H:%M:%SZ")) and .result_hash != "" and .status != "cache_hit"))
  | group_by([.task, .result_hash])
  | map(select(length >= 5))
  | map({
      detected_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      task: .[0].task,
      result_hash: .[0].result_hash,
      repeat_count: length,
      model: .[0].model,
      status: "pending",
      notes: ""
    })
' "$LEDGER" 2>/dev/null || echo "[]")

# 기존 큐에 병합 — 이미 implemented/rejected인 것은 건들지 않음
if [[ -n "$new_candidates" && "$new_candidates" != "[]" ]]; then
    merged=$(jq -s --arg now "$(date -u +%FT%TZ)" '
      .[0] as $existing | .[1] as $new |
      $existing.candidates as $old |
      # 이미 implemented/rejected인 task+hash는 제외
      ($old | map(select(.status != "pending")) | map({key: (.task + "|" + .result_hash), value: .}) | from_entries) as $locked |
      # 신규 후보 중 locked되지 않은 것만
      ($new | map(select(($locked[(.task + "|" + .result_hash)] // null) == null))) as $fresh |
      # 이미 pending인 것은 repeat_count 업데이트
      ($old | map(select(.status == "pending"))) as $pending |
      ($pending | map(. as $p | $fresh | map(select(.task == $p.task and .result_hash == $p.result_hash)) | if length > 0 then ($p + {repeat_count: .[0].repeat_count, detected_at: .[0].detected_at}) else $p end)) as $updated_pending |
      # locked + updated_pending + 완전 신규 pending
      ($fresh | map(select(. as $f | $pending | map(select(.task == $f.task and .result_hash == $f.result_hash)) | length == 0))) as $brand_new |
      {
        candidates: (($locked | to_entries | map(.value)) + $updated_pending + $brand_new),
        last_audit_run: $now
      }
    ' "$GATE_QUEUE" <(echo "$new_candidates") 2>/dev/null || echo "")

    if [[ -n "$merged" ]]; then
        tmp_queue="${GATE_QUEUE}.tmp"
        echo "$merged" > "$tmp_queue" && mv "$tmp_queue" "$GATE_QUEUE"
        pending_count=$(jq -r '.candidates | map(select(.status == "pending")) | length' "$GATE_QUEUE" 2>/dev/null || echo 0)
        log "gate-candidates queue updated: ${pending_count} pending"
    else
        log "gate-candidates merge failed (jq error) — skipping"
    fi
fi

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