#!/usr/bin/env bash
# cron-master.sh — 크론 총괄책임자.
#
# 매일 아침 1회(06:03 KST) 호출되어 모든 감사 결과를 수집하여
# jarvis-system 채널에 "한 장짜리 종합 리포트"로 요약 출력한다.
#
# 2026-04-20 신설 배경:
#   기존 cron-monitoring-orchestrator.sh는 crontab에 등록돼 있었으나
#   파일 자체가 존재하지 않는 유령 상태였다. 개별 감사 9개가 각자 뛰고
#   일부(cron-auditor, launchagents-audit, token-ledger-audit,
#   tasks-prompt-path-audit)는 Discord 경보도 안 보내서 daily-usage-check
#   plist 우회 사건이 3일간 방치되었다. 본 스크립트는 그 공백을 구조적으로
#   채우는 총괄책임자다.
#
# 설계 원칙:
#   - 이미 돌고 있는 감사들을 재실행하지 않고 "로그에서 결과만 수집"한다
#     (멱등성 + 가벼움)
#   - 정상이면 한 줄로 "✅ 모두 정상", 문제가 있으면 상세 리포트
#   - bot-cron.sh가 stdout을 route-result.sh로 보내 Discord로 라우팅한다

set -euo pipefail

# 자체 로그 (Blocker #2 대응: plist StandardOutPath는 bot-cron.sh 우회 경로라 0B.
# 모든 로깅은 파일 기록 → cron-master 본인이 죽어도 사후 조사 가능)
# stdout은 Discord 라우팅을 위해 순수하게 유지 (dedup digest 계산 영향 최소화)
SELF_LOG="${HOME}/jarvis/runtime/logs/cron-master-self.log"
mkdir -p "$(dirname "$SELF_LOG")"
# 헤더는 self-log에만 기록 (stdout에 누출되면 Discord 전송 skip 시 빈 쓰레기 전송됨)
{
  echo ""
  echo "═══ cron-master 시작: $(date '+%Y-%m-%d %H:%M:%S %z') (PID=$$) ═══"
} >> "$SELF_LOG"

# self-log 전용 logger — stdout 오염 방지 (Test 5 dedup 회귀 해소, 2026-04-24).
# 이전 echo 사용 시 bare stdout 4줄 누출 → Discord digest 변동 → dedup 실패.
log() { echo "[$(date '+%H:%M:%S')] $*" >> "${SELF_LOG:-/dev/null}"; }

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_DIR="$BOT_HOME/logs"
LA_DIR="$HOME/Library/LaunchAgents"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
NOW_EPOCH=$(date +%s)
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d 2>/dev/null || echo "")
CUTOFF=$(date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
  || date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "1970-01-01 00:00:00")

# 감지 원장 (일 단위 시계열 — 주간 추세 분석 기반)
DAILY_LEDGER="$BOT_HOME/state/cron-master-daily.jsonl"
mkdir -p "$(dirname "$DAILY_LEDGER")"

# 어제 엔트리 조회
YESTERDAY_ENTRY=""
if [[ -n "$YESTERDAY" && -f "$DAILY_LEDGER" ]]; then
  YESTERDAY_ENTRY=$(grep "^{\"date\":\"$YESTERDAY\"" "$DAILY_LEDGER" 2>/dev/null | tail -1 || true)
fi

get_yesterday() {
  local key="$1"
  if [[ -z "$YESTERDAY_ENTRY" ]]; then echo ""; return; fi
  # "key":VAL 패턴 추출 → sed로 콜론 뒤 숫자만 분리
  # (주의: `fail_24h` 같은 키에 포함된 숫자가 grep에 매칭되지 않도록 sed 사용)
  echo "$YESTERDAY_ENTRY" | grep -oE "\"$key\":[0-9]+" | head -1 | sed 's/.*://'
}

# delta 포매터: 현재값 어제값 → 🔺/🔻/➖ 태그
format_delta() {
  local current="$1" yesterday="$2"
  if [[ -z "$yesterday" ]]; then
    echo "[첫 기록]"
    return
  fi
  local diff=$((current - yesterday))
  if [[ "$diff" -eq 0 ]]; then
    echo "➖ 어제 $yesterday (변화 없음)"
  elif [[ "$diff" -gt 0 ]]; then
    echo "🔺 어제 $yesterday → +$diff"
  else
    echo "🔻 어제 $yesterday → $diff"
  fi
}

ISSUES=()
add_issue() { ISSUES+=("$1"); }

# ── 1. 최근 24h cron.log FAILED/ERROR ────────────────────────────────────────
FAIL_COUNT=0
FAIL_SAMPLES=""
if [[ -f "$LOG_DIR/cron.log" ]]; then
  FAIL_LINES=$(grep -E 'FAILED|ERROR' "$LOG_DIR/cron.log" \
    | awk -v c="[$CUTOFF" '$0 >= c' \
    | grep -v 'not found in tasks.json' || true)
  if [[ -n "$FAIL_LINES" ]]; then
    FAIL_COUNT=$(echo "$FAIL_LINES" | wc -l | tr -d ' ')
    FAIL_SAMPLES=$(echo "$FAIL_LINES" \
      | grep -oE '\[[a-z][a-z0-9-]+\]' | sort -u | head -5 | tr '\n' ' ')
    add_issue "FAIL 실행 ${FAIL_COUNT}건 (${FAIL_SAMPLES})"
  fi
fi

# ── 2. LaunchAgent 언로드 탐지 (plist는 있는데 launchctl list에 없음) ────────
# launchctl list를 한 번만 호출해 snapshot으로 비교 (race condition 방지)
LOADED_SET=$(launchctl list 2>/dev/null | awk 'NR>1 {print $3}' | sort -u)
UNLOADED=()
for p in "$LA_DIR"/com.jarvis.*.plist "$LA_DIR"/ai.jarvis.*.plist; do
  [[ -f "$p" ]] || continue
  label=$(basename "$p" .plist)
  if ! echo "$LOADED_SET" | grep -qx "$label"; then
    UNLOADED+=("$label")
  fi
done
if [[ ${#UNLOADED[@]} -gt 0 ]]; then
  add_issue "LaunchAgent 언로드 ${#UNLOADED[@]}건 (${UNLOADED[*]})"
fi

# ── 3. output:discord BYPASS (cron-auditor 섹션 4 결과 파싱) ──────────────────
BYPASS_LIST=""
if [[ -x "$BOT_HOME/../infra/scripts/cron-auditor.sh" ]] \
   || [[ -x "$HOME/jarvis/infra/scripts/cron-auditor.sh" ]]; then
  AUDITOR_OUT=$(timeout 60 bash "$HOME/jarvis/infra/scripts/cron-auditor.sh" 2>/dev/null || true)
  BYPASS_LIST=$(echo "$AUDITOR_OUT" \
    | awk '/^## \[output:discord BYPASS/,/^## \[요약\]/' \
    | grep -E '  [a-z]' | awk '{print $1}' | tr '\n' ' ' || true)
  if [[ -n "$BYPASS_LIST" ]]; then
    bypass_count=$(echo "$BYPASS_LIST" | wc -w | tr -d ' ')
    add_issue "Discord 파이프 BYPASS ${bypass_count}건 (${BYPASS_LIST})"
  fi
fi

# ── 4. 유령 crontab 엔트리 탐지 (파일 없는 스크립트 호출) ────────────────────
PHANTOM_COUNT=0
while IFS= read -r script; do
  if [[ -n "$script" && ! -f "$script" ]]; then PHANTOM_COUNT=$((PHANTOM_COUNT+1)); fi
done < <(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' \
         | grep -oE '/[^[:space:]]+\.(sh|py|mjs|js)' | sort -u || true)
if [[ "$PHANTOM_COUNT" -gt 0 ]]; then
  add_issue "crontab 유령 스크립트 호출 ${PHANTOM_COUNT}개"
fi

# ── 4.5. L2 자동 복구 — bootstrap만 (2026-04-20) ──────────────────────────────
# 안전장치:
#   - 원장(ledger): 모든 복구 액션을 JSONL append-only 기록 (rollback 가능)
#   - Rate-limit: 동일 action+target 하루 3회 제한 (무한 루프 방지)
#   - bootout → bootstrap 2단계: stale reference로 인한 Input/output error 해결
#   - Dry-run: CRON_MASTER_DRY_RUN=1 이면 계획만 표시, 실제 실행 skip
#
# 스텁 배치 기능 제거 이유:
#   ~/jarvis/runtime/bin → ~/jarvis/infra/bin 심링크 체인으로 git 추적 디렉토리에
#   stub이 무단 침투하는 설계 결함 발견 (2026-04-20 초기 구현에서 19개 침범).
#   유령 스크립트는 감지만 하고 주인님이 수동으로 판단·처리한다.

REPAIR_LEDGER="$BOT_HOME/state/cron-master-ledger.jsonl"
mkdir -p "$(dirname "$REPAIR_LEDGER")"
REPAIRS=()
DRY_RUN="${CRON_MASTER_DRY_RUN:-0}"

repair_count_today() {
  local action="$1" target="$2" today count
  today=$(date +%Y-%m-%d)
  if [[ ! -f "$REPAIR_LEDGER" ]]; then echo 0; return; fi
  # grep -c 는 매치 0건일 때 stdout "0" + exit 1 → `|| true`로 exit만 삼키고 stdout "0" 유지
  # (`|| echo 0` 안티패턴: 이전엔 "0\n0" 출력되어 [[ ]] syntax error 유발)
  count=$(grep -cF "\"action\":\"$action\",\"target\":\"$target\",\"ts\":\"$today" "$REPAIR_LEDGER" 2>/dev/null || true)
  echo "${count:-0}"
}

log_repair() {
  local action="$1" target="$2" result="$3" classification="${4:-normal}"
  local today
  today=$(date +%Y-%m-%d)
  echo "{\"action\":\"$action\",\"target\":\"$target\",\"ts\":\"${today}T$(date '+%H:%M:%S%z')\",\"result\":\"$result\",\"dry_run\":${DRY_RUN},\"classification\":\"$classification\"}" >> "$REPAIR_LEDGER"
}

# Permanent failure classifier (2026-04-21)
# 최근 N일(default 3) 연속으로 동일 target의 bootstrap이 **모두 failed**인지 판정.
# 판정되면 "permanent" 분류 + auto-disable 후보로 승격.
# Iron Law 3: 자동 disable은 기본 OFF, JARVIS_CRON_AUTO_DISABLE=1 일 때만 실행.
AUTO_DISABLE="${JARVIS_CRON_AUTO_DISABLE:-0}"
PERMA_FAIL_DAYS="${JARVIS_CRON_PERMA_FAIL_DAYS:-3}"
PERMA_FAILS=()   # 영구 실패 판정 target 목록 (리포트용)
AUTO_DISABLED=() # 실제 disable된 target 목록 (리포트용)

classify_permanent_failure() {
  # $1 = target label
  # 최근 PERMA_FAIL_DAYS일 각각에 해당 target bootstrap 시도가 있었고,
  # **모두 failed(SUCCESS 하나도 없음)**이면 "permanent" 반환.
  # stdout: "permanent" | "transient" | "insufficient_data"
  local target="$1"
  if [[ ! -f "$REPAIR_LEDGER" ]]; then
    echo "insufficient_data"
    return
  fi

  local days_with_attempt=0 days_with_success=0 i day
  for ((i=0; i<PERMA_FAIL_DAYS; i++)); do
    day=$(date -v-${i}d +%Y-%m-%d 2>/dev/null || date -d "${i} days ago" +%Y-%m-%d 2>/dev/null || echo "")
    if [[ -z "$day" ]]; then continue; fi
    local day_attempts day_success
    day_attempts=$(grep -cF "\"action\":\"bootstrap\",\"target\":\"$target\",\"ts\":\"$day" "$REPAIR_LEDGER" 2>/dev/null || true)
    day_success=$(grep -F "\"action\":\"bootstrap\",\"target\":\"$target\",\"ts\":\"$day" "$REPAIR_LEDGER" 2>/dev/null \
                  | grep -cF "\"result\":\"success\"" || true)
    if [[ "${day_attempts:-0}" -gt 0 ]]; then
      days_with_attempt=$((days_with_attempt+1))
      if [[ "${day_success:-0}" -gt 0 ]]; then
        days_with_success=$((days_with_success+1))
      fi
    fi
  done

  # 기대 일수 미만으로 데이터 부족 → 섣불리 permanent 판정 금지
  if [[ "$days_with_attempt" -lt "$PERMA_FAIL_DAYS" ]]; then
    echo "insufficient_data"; return
  fi
  if [[ "$days_with_success" -eq 0 ]]; then
    echo "permanent"; return
  fi
  echo "transient"
}

# LaunchAgent 영구 disable (plist를 .permafail-disabled suffix로 rename + bootout)
# 파괴적 조치이므로 JARVIS_CRON_AUTO_DISABLE=1 일 때만 실행.
auto_disable_launchagent() {
  local lbl="$1" plist="$LA_DIR/$lbl.plist" ts suffix target_path
  ts=$(date +%Y%m%d-%H%M%S)
  suffix=".permafail-disabled-${ts}"
  target_path="${plist}${suffix}"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_repair "auto-disable" "$lbl" "[DRY-RUN] would rename to $(basename "$target_path")" "permanent"
    AUTO_DISABLED+=("[DRY-RUN] $lbl")
    return
  fi

  # 1. bootout (실패해도 계속)
  launchctl bootout "gui/$(id -u)/$lbl" 2>/dev/null || true
  # 2. rename (파괴적이지만 원복 가능: mv로 되돌리면 됨)
  if mv "$plist" "$target_path" 2>/dev/null; then
    log_repair "auto-disable" "$lbl" "renamed to $(basename "$target_path")" "permanent"
    AUTO_DISABLED+=("🛑 $lbl → $(basename "$target_path")")
  else
    log_repair "auto-disable" "$lbl" "rename failed" "permanent"
    AUTO_DISABLED+=("❌ $lbl (rename 실패)")
  fi
}

# bootout → bootstrap 2단계 복구 공통 함수 (2026-04-21 DRY 리팩터)
# UNLOADED 루프 + stale 감사 도구 루프가 함께 호출. Rate-limit + classifier 포함.
# $1 = LaunchAgent label (예: com.jarvis.daily-summary)
attempt_bootstrap() {
  local lbl="$1"
  local plist="$LA_DIR/$lbl.plist"
  local count verdict bootstrap_err safe_err load_status

  # [2026-04-24] 이미 정상 loaded + exit=0인 agent는 bootout/bootstrap 생략.
  # 불필요한 bootout이 "Bootstrap failed: 5: Input/output error"를 유발 (daily-summary 자정 3일 연속 실패).
  # action "bootstrap-skip"으로 분리: classify_permanent_failure의 "action:bootstrap" 집계 오염 방지.
  # R3: UNLOADED agent는 launchctl list에 없어 load_status 빈 문자열 → 가드 통과 → bootstrap 정상 시도.
  # R4 제거(2026-04-24 재검증): macOS launchctl print에 "last exit reason" 필드 부재 확인.
  # load_status(=last exit code)가 non-zero면 이미 가드 통과해 bootstrap 시도하므로 기본 crash 케이스는 포괄.
  # exit=0 + runs 급증 crash-loop은 별도 watchdog scope (본 가드 범위 외).
  load_status=$(launchctl list 2>/dev/null | awk -v lbl="$lbl" '$3==lbl {print $2; exit}')
  if [[ -n "$load_status" && "$load_status" == "0" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      REPAIRS+=("[DRY-RUN] SKIP bootstrap $lbl (이미 loaded, 최근 exit=0)")
    else
      REPAIRS+=("SKIP bootstrap $lbl (이미 loaded, 최근 exit=0)")
      log_repair "bootstrap-skip" "$lbl" "success" "healthy"
    fi
    return
  fi

  count=$(repair_count_today "bootstrap" "$lbl")
  if [[ "$count" -ge 3 ]]; then
    verdict=$(classify_permanent_failure "$lbl")
    if [[ "$verdict" == "permanent" ]]; then
      REPAIRS+=("🛑 영구 실패 분류: $lbl (${PERMA_FAIL_DAYS}일 연속 복구 실패, 오늘 ${count}/3회 SKIP)")
      PERMA_FAILS+=("$lbl")
      if [[ "$AUTO_DISABLE" == "1" ]]; then
        auto_disable_launchagent "$lbl"
      fi
    else
      REPAIRS+=("SKIP bootstrap $lbl (오늘 ${count}/3회)")
    fi
    return
  fi

  if [[ ! -f "$plist" ]]; then
    REPAIRS+=("SKIP bootstrap $lbl (plist 없음)")
    return
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    REPAIRS+=("[DRY-RUN] bootstrap $lbl")
    log_repair "bootstrap" "$lbl" "dry-run"
    return
  fi

  # stale reference 회피: bootout 먼저 (실패해도 무시), 그 후 bootstrap
  launchctl bootout "gui/$(id -u)/$lbl" 2>/dev/null || true
  if bootstrap_err=$(launchctl bootstrap "gui/$(id -u)" "$plist" 2>&1); then
    log_repair "bootstrap" "$lbl" "success"
    REPAIRS+=("✅ bootstrap $lbl")
  else
    safe_err=$(echo "$bootstrap_err" | tr -d '"' | tr '\n' ' ' | head -c 120)
    verdict=$(classify_permanent_failure "$lbl")
    log_repair "bootstrap" "$lbl" "failed: ${safe_err}" "$verdict"
    if [[ "$verdict" == "permanent" ]]; then
      REPAIRS+=("🛑 영구 실패 분류: $lbl (${PERMA_FAIL_DAYS}일 연속 복구 실패)")
      PERMA_FAILS+=("$lbl")
      if [[ "$AUTO_DISABLE" == "1" ]]; then
        auto_disable_launchagent "$lbl"
      fi
    else
      REPAIRS+=("❌ bootstrap 실패: $lbl → $safe_err")
    fi
  fi
}

# [4.5.1] LaunchAgent 언로드 → bootout → bootstrap (2단계로 견고화)
# GUARD: set -u(nounset) 활성 환경에서 빈 배열 "${UNLOADED[@]}" 접근 시 unbound variable
#        에러로 스크립트 전체가 죽는다. 2026-04-21 07:00/07:30 두 런 폭사 원인.
#        (b45d287 "set-e 안티패턴 일괄 제거" 커밋에서 누락된 케이스)
if (( ${#UNLOADED[@]} > 0 )); then
  for lbl in "${UNLOADED[@]}"; do
    attempt_bootstrap "$lbl"
  done
fi

# ── 4.5.5. Phase 3c-1: 주기 기대값 대조 (발동 누락 감지) ─────────────────────
# LaunchAgent의 StartCalendarInterval과 로그 mtime을 비교하여
# "돌아야 하는데 안 돈" 케이스를 감지. 오늘 wiki-lint weekly 오해에서 파생.
#
# 판정:
#   - Day 있음       → monthly (30일)
#   - Weekday 있음   → weekly  (7일)
#   - Hour 있음      → daily   (1일)
#   - 로그 mtime이 기대 주기 × 2 초과면 STALE

STALE_TRIGGERS=()
for plist in "$LA_DIR"/com.jarvis.*.plist "$LA_DIR"/ai.jarvis.*.plist; do
  [[ -f "$plist" ]] || continue
  label=$(basename "$plist" .plist)
  pl_json=$(plutil -convert json -o - "$plist" 2>/dev/null || true)
  if [[ -z "$pl_json" ]]; then continue; fi

  has_weekday=$(echo "$pl_json" | grep -c '"Weekday"' || true)
  has_day=$(echo "$pl_json" | grep -c '"Day"' || true)
  has_hour=$(echo "$pl_json" | grep -c '"Hour"' || true)

  expected_sec=0
  period_label=""
  if [[ "$has_day" -gt 0 ]]; then
    expected_sec=$((30 * 86400)); period_label="monthly"
  elif [[ "$has_weekday" -gt 0 ]]; then
    expected_sec=$((7 * 86400)); period_label="weekly"
  elif [[ "$has_hour" -gt 0 ]]; then
    expected_sec=86400; period_label="daily"
  else
    continue
  fi

  log_path=$(echo "$pl_json" | grep -oE '"StandardOutPath"[^"]*"[^"]+"' \
    | sed -E 's/.*"StandardOutPath"[^"]*"([^"]+)".*/\1/' | head -1)
  if [[ -z "$log_path" || ! -f "$log_path" ]]; then continue; fi

  log_mtime=$(stat -f %m "$log_path" 2>/dev/null || echo 0)
  age_sec=$((NOW_EPOCH - log_mtime))

  if [[ "$age_sec" -gt $((expected_sec * 2)) ]]; then
    age_days=$((age_sec / 86400))
    STALE_TRIGGERS+=("${label} (${period_label}, ${age_days}d 경과)")
  fi
done
if [[ ${#STALE_TRIGGERS[@]} -gt 0 ]]; then
  add_issue "주기 누락 LaunchAgent ${#STALE_TRIGGERS[@]}건"
fi

# ── 4.6. 기존 감사 9개 결과 흡수 (2026-04-20 Phase 3a) ───────────────────────
# 기존 감사 도구들의 로그에서 최근 활동 요약. 중복 알림 제거는 별도 단계에서.

AUDIT_LOGS=(
  "cron-auditor"
  "launchagents-audit"
  "tasks-integrity-audit"
  "token-ledger-audit"
  "schedule-coherence"
  "log-size-audit"
  "doc-sync-auditor"
  "code-auditor"
  "tasks-prompt-path-audit"
  "cost-cap-audit"
  "claude-md-audit"
)
AUDIT_SUMMARY=()
# 감사 도구가 stale일 때 bootout → bootstrap으로 강제 재등록 시도.
# plist가 존재하고, label이 com.jarvis.${name} 규칙을 따를 때만.
# 기존 attempt_bootstrap 함수 재사용 → rate-limit + classifier 가드 자동 적용.
# JARVIS_CRON_STALE_AUDIT_RECOVER=0 이면 비활성화.
STALE_AUDIT_RECOVER="${JARVIS_CRON_STALE_AUDIT_RECOVER:-1}"
for name in "${AUDIT_LOGS[@]}"; do
  logpath="$LOG_DIR/${name}.log"
  errpath="$LOG_DIR/${name}-err.log"
  if [[ ! -f "$logpath" && ! -f "$errpath" ]]; then continue; fi
  # stdout이 비어있어도 err.log가 최신이면 정상 실행 중 (Discord 라우팅 태스크)
  mtime=$(stat -f %m "$logpath" 2>/dev/null || echo 0)
  if [[ -f "$errpath" ]]; then
    err_mtime=$(stat -f %m "$errpath" 2>/dev/null || echo 0)
    if [[ "$err_mtime" -gt "$mtime" ]]; then mtime="$err_mtime"; fi
  fi
  age_h=$(( (NOW_EPOCH - mtime) / 3600 ))
  # 48h 이상 업데이트 없으면 stale
  if [[ "$age_h" -gt 48 ]]; then
    # [2026-04-23 재적용] tasks.json enabled=false 태스크는 stale 판정 제외
    # 주의: jq `// "true"`는 boolean false도 falsy로 취급 → has("enabled") + 명시 비교
    _tasks_json="${BOT_HOME:-$HOME/.jarvis}/config/tasks.json"
    _task_disabled=$(jq -r --arg id "$name" '
      .tasks[]? | select(.id == $id)
      | if has("enabled") and .enabled == false then "true" else "false" end
    ' "$_tasks_json" 2>/dev/null | head -1)
    if [[ "$_task_disabled" == "true" ]]; then
      log "SKIP stale(${name}): tasks.json enabled=false — 의도된 비활성, bootstrap 건너뜀"
      continue
    fi
    AUDIT_SUMMARY+=("${name}: stale (${age_h}h 업데이트 없음)")
    # L2 편입: 해당 LaunchAgent가 있으면 재등록 시도
    audit_lbl="com.jarvis.${name}"
    if [[ "$STALE_AUDIT_RECOVER" == "1" && -f "$LA_DIR/${audit_lbl}.plist" ]]; then
      attempt_bootstrap "$audit_lbl"
    fi
    continue
  fi
  # 최근 100줄에서 에러성 키워드 카운트
  err_count=$(tail -100 "$logpath" 2>/dev/null | grep -ciE 'error|fail|warn|issue' || true)
  if [[ "$err_count" -gt 0 ]]; then
    AUDIT_SUMMARY+=("${name}: ${err_count}건 의심 키워드")
  fi
done

# ── 4.6.5. Phase 3c-2: 미해결 감사 경고 추적 (wiki-lint 리포트 이슈 수) ──────
WIKI_META="${HOME}/jarvis/runtime/wiki/meta"
LATEST_LINT_REPORT=""
LATEST_LINT_ISSUES=0
if [[ -d "$WIKI_META" ]]; then
  LATEST_LINT_REPORT=$(ls -t "$WIKI_META"/lint-*.md 2>/dev/null | head -1)
  if [[ -n "$LATEST_LINT_REPORT" && -f "$LATEST_LINT_REPORT" ]]; then
    LATEST_LINT_ISSUES=$(grep -cE "^- \[" "$LATEST_LINT_REPORT" 2>/dev/null || true)
    LATEST_LINT_ISSUES=${LATEST_LINT_ISSUES:-0}
    if [[ "$LATEST_LINT_ISSUES" -gt 0 ]]; then
      lint_date=$(basename "$LATEST_LINT_REPORT" .md | sed 's/lint-//')
      add_issue "wiki-lint 미해결 ${LATEST_LINT_ISSUES}건 (${lint_date} 리포트)"
    fi
  fi
fi

# ── 4.6.7. Phase 3c-3: 위키 파이프라인 건강 (autoExtract 침묵 감지) ──────────
# 최근 7일간 [source:discord] 태그가 1건도 안 붙으면 autoExtract 침묵으로 판정.
# 오늘 조치 3에서 발견한 패턴의 자동 감지 장치.
DISCORD_INJECTIONS_7D=0
WIKI_ROOT="${HOME}/jarvis/runtime/wiki"
if [[ -d "$WIKI_ROOT" ]]; then
  for i in 0 1 2 3 4 5 6; do
    day=$(date -v-${i}d +%Y-%m-%d 2>/dev/null || date -d "$i days ago" +%Y-%m-%d 2>/dev/null || echo "")
    if [[ -z "$day" ]]; then continue; fi
    for f in "$WIKI_ROOT"/*/_facts.md; do
      [[ -f "$f" ]] || continue
      c=$(grep -cE "\[$day\].*source:discord" "$f" 2>/dev/null || true)
      DISCORD_INJECTIONS_7D=$((DISCORD_INJECTIONS_7D + ${c:-0}))
    done
  done
  if [[ "$DISCORD_INJECTIONS_7D" -eq 0 ]]; then
    add_issue "Discord autoExtract 7일간 0건 (코드 침묵 의심)"
  fi
fi

# ── 4.7. 오늘 감지 카운트를 원장에 append (하루 1회) ─────────────────────────
BYPASS_COUNT_NUM=$(echo "$BYPASS_LIST" | wc -w | tr -d ' ')
UNLOADED_COUNT=${#UNLOADED[@]}

if ! grep -q "^{\"date\":\"$TODAY\"" "$DAILY_LEDGER" 2>/dev/null; then
  echo "{\"date\":\"$TODAY\",\"fail_24h\":${FAIL_COUNT:-0},\"unloaded\":${UNLOADED_COUNT},\"bypass\":${BYPASS_COUNT_NUM},\"phantom\":${PHANTOM_COUNT:-0},\"stale_triggers\":${#STALE_TRIGGERS[@]},\"lint_open\":${LATEST_LINT_ISSUES:-0},\"discord_7d\":${DISCORD_INJECTIONS_7D:-0},\"repairs\":${#REPAIRS[@]},\"ts\":\"$(date '+%H:%M:%S%z')\"}" >> "$DAILY_LEDGER"
fi

# ── 4.8. 리포트 전송 정책 — 변화 없으면 stdout 비움 (2026-04-21) ─────────────
# 정책:
#   1) ISSUES 조합이 이전 실행과 동일 + PERMA_FAILS 없음 + AUTO_DISABLED 없음 →
#      Discord 전송 스킵 (stdout 비우고 조용히 종료).
#   2) 주간 정기 요약: 매주 월요일 09:00 ±30분에는 변화 여부 무관하게 강제 전송.
#   3) JARVIS_CRON_FORCE_REPORT=1 이면 항상 강제 전송 (디버깅용).
# allowEmptyResult=true 로 tasks.json 설정되어 있어 빈 출력 허용.

LAST_DIGEST_FILE="$BOT_HOME/state/cron-master-last-digest.txt"
mkdir -p "$(dirname "$LAST_DIGEST_FILE")"

# 현재 이슈 digest 계산 (정렬된 ISSUES + PERMA_FAILS 합쳐 hash)
current_digest=""
if (( ${#ISSUES[@]} > 0 )) || (( ${#PERMA_FAILS[@]} > 0 )); then
  current_digest=$(printf "%s\n" "${ISSUES[@]:-}" "${PERMA_FAILS[@]:-}" | sort | shasum -a 256 | awk '{print $1}')
else
  current_digest="no-issues"
fi
prev_digest=$(cat "$LAST_DIGEST_FILE" 2>/dev/null || echo "")

# 강제 전송 조건
FORCE_REPORT="${JARVIS_CRON_FORCE_REPORT:-0}"
weekly_slot=0  # 월요일 09:00 ±30분
dow=$(date +%u)      # 1=월요일
hour=$(date +%H)
minute=$(date +%M)
if [[ "$dow" == "1" && "$hour" == "09" && "$minute" -lt "30" ]]; then
  weekly_slot=1
fi

# PERMA_FAILS·AUTO_DISABLED 있으면 긴급 → 항상 전송
urgent=0
if (( ${#PERMA_FAILS[@]} > 0 )) || (( ${#AUTO_DISABLED[@]} > 0 )); then
  urgent=1
fi

# 변화 감지: digest 다름
changed=0
if [[ "$current_digest" != "$prev_digest" ]]; then
  changed=1
fi

# 출력 여부 결정
should_emit=0
if [[ "$FORCE_REPORT" == "1" ]]; then
  should_emit=1
elif [[ "$urgent" == "1" ]]; then
  should_emit=1
elif [[ "$weekly_slot" == "1" ]]; then
  should_emit=1
elif [[ "$changed" == "1" ]]; then
  should_emit=1
fi

# digest 저장 (다음 실행 비교용)
echo "$current_digest" > "$LAST_DIGEST_FILE"

if [[ "$should_emit" != "1" ]]; then
  # Discord 전송 skip. self-log에만 기록하고 조용히 종료.
  log "변화 없음 (digest=${current_digest:0:12}…). Discord 전송 skip."
  exit 0
fi

# ── 4.9. plist-bypass-autofix 통계 수집 (2026-04-22) ─────────────────────────
# plist-bypass-autofix.sh가 남긴 ledger를 파싱해 오늘의 감지→수정→검증 통계 수집.
# BYPASS 재발 방지 가드의 가시화 — 감지만 하고 끝나지 않도록 리포트에 건수 표기.
BYPASS_AUTOFIX_LEDGER="$BOT_HOME/state/plist-bypass-autofix.jsonl"
BYPASS_AUTOFIX_SUMMARY=""
BYPASS_AUTOFIX_TARGETS=()
if [[ -f "$BYPASS_AUTOFIX_LEDGER" ]]; then
  today_prefix=$(TZ=Asia/Seoul date +%Y-%m-%dT)  # KST 로컬 날짜 (ledger ts와 일치)
  # 오늘자 action 전수 집계 (tail -1 summary는 후속 0/0/0 실행에 가려지므로 폐기)
  today_entries=$(grep "\"ts\":\"${today_prefix}" "$BYPASS_AUTOFIX_LEDGER" 2>/dev/null || true)
  if [[ -n "$today_entries" ]]; then
    # grep -c는 매치 0일 때도 "0" 출력 + exit 1 → `|| echo 0`이 추가 "0" 출력 → "0\n0" → [[ syntax error.
    # 2>/dev/null + ${var:-0} 조합으로 단일 값 보장.
    _fix=$(echo "$today_entries" | grep -c '"action":"fixed"' 2>/dev/null || true)
    _fail=$(echo "$today_entries" | grep -c '"action":"failed"' 2>/dev/null || true)
    _fix=${_fix:-0}
    _fail=${_fail:-0}
    # skip은 summary에만 남음(line-level action 아님) — 오늘의 최대 skip값 채택
    _skip=$(echo "$today_entries" | grep '"action":"summary"' \
            | grep -oE '"skip":[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
    _skip=${_skip:-0}
    BYPASS_AUTOFIX_SUMMARY="fix=${_fix} skip=${_skip} fail=${_fail}"
    while IFS= read -r tgt; do
      [[ -n "$tgt" ]] && BYPASS_AUTOFIX_TARGETS+=("$tgt")
    done < <(echo "$today_entries" | grep '"action":"fixed"' | grep -oE '"task":"[^"]+"' | cut -d'"' -f4 || true)
    if [[ "${_fail}" -gt 0 ]]; then
      add_issue "plist-bypass-autofix 복구 실패 ${_fail}건 (검증: ${BYPASS_AUTOFIX_LEDGER})"
    fi
  fi
fi

# ── 5. 리포트 출력 (stdout → bot-cron.sh가 Discord로 라우팅) ─────────────────

echo "🔍 **크론 마스터 종합 리포트** — ${NOW} KST"
echo ""
if [[ ${#ISSUES[@]} -eq 0 ]]; then
  echo "✅ **상태: 정상** — 최근 24h 모든 크론·감사 이상 없음"
else
  echo "⚠️ **상태: 주의** — ${#ISSUES[@]}건 검출"
  echo ""
  for i in "${ISSUES[@]}"; do
    echo "  - ${i}"
  done
fi

echo ""
echo "---"
echo "📊 **상세 (어제 대비)**"
echo "  · FAIL 실행 (24h): ${FAIL_COUNT}  $(format_delta "${FAIL_COUNT:-0}" "$(get_yesterday fail_24h)")"
echo "  · LaunchAgent 언로드: ${UNLOADED_COUNT}  $(format_delta "$UNLOADED_COUNT" "$(get_yesterday unloaded)")"
echo "  · Discord BYPASS: ${BYPASS_COUNT_NUM}  $(format_delta "$BYPASS_COUNT_NUM" "$(get_yesterday bypass)")"
echo "  · crontab 유령 스크립트: ${PHANTOM_COUNT:-0}  $(format_delta "${PHANTOM_COUNT:-0}" "$(get_yesterday phantom)")"
echo "  · 주기 누락 LaunchAgent: ${#STALE_TRIGGERS[@]}  $(format_delta "${#STALE_TRIGGERS[@]}" "$(get_yesterday stale_triggers)")"
echo "  · wiki-lint 미해결: ${LATEST_LINT_ISSUES}  $(format_delta "${LATEST_LINT_ISSUES}" "$(get_yesterday lint_open)")"
echo "  · Discord 주입 7d: ${DISCORD_INJECTIONS_7D}  $(format_delta "${DISCORD_INJECTIONS_7D}" "$(get_yesterday discord_7d)")"
echo "  · 리포트 생성: ${NOW} KST"

if [[ ${#STALE_TRIGGERS[@]} -gt 0 ]]; then
  echo ""
  echo "🔄 **주기 누락 LaunchAgent (기대 주기 × 2 초과)**"
  for s in "${STALE_TRIGGERS[@]}"; do
    echo "  · $s"
  done
fi

if [[ ${#AUDIT_SUMMARY[@]} -gt 0 ]]; then
  echo ""
  echo "🔍 **기존 감사 도구 (최근 100줄 키워드)**"
  for a in "${AUDIT_SUMMARY[@]}"; do
    echo "  · $a"
  done
fi

if [[ ${#PERMA_FAILS[@]} -gt 0 ]]; then
  echo ""
  echo "🛑 **영구 실패 분류 (${PERMA_FAIL_DAYS}일 연속 복구 실패)** — ${#PERMA_FAILS[@]}건"
  for pf in "${PERMA_FAILS[@]}"; do
    echo "  · ${pf} — 수동 개입 필요 (plist 재검토, Input/output error 근본 원인 진단)"
  done
  if [[ "$AUTO_DISABLE" == "1" && ${#AUTO_DISABLED[@]} -gt 0 ]]; then
    echo ""
    echo "🔒 **auto-disable 실행** — ${#AUTO_DISABLED[@]}건"
    for ad in "${AUTO_DISABLED[@]}"; do
      echo "  · ${ad}"
    done
    echo "  💡 원복: mv <plist.permafail-disabled-*> <원래 이름> → launchctl bootstrap"
  else
    echo "  💡 자동 disable OFF (활성화: JARVIS_CRON_AUTO_DISABLE=1)"
  fi
fi

if [[ ${#REPAIRS[@]} -gt 0 ]]; then
  echo ""
  echo "🔧 **자동 복구 (L2)** — ${#REPAIRS[@]}건"
  for r in "${REPAIRS[@]}"; do
    echo "  · ${r}"
  done
  if [[ "$DRY_RUN" == "1" ]]; then echo "  ⚠️ DRY-RUN 모드: 실제 변경 없음"; fi
  echo ""
  echo "  📝 원장: ${REPAIR_LEDGER}"
  echo "  📈 감지 원장: ${DAILY_LEDGER}"
fi

if [[ -n "$BYPASS_AUTOFIX_SUMMARY" ]]; then
  echo ""
  echo "🛠 **plist BYPASS 자동 복구** — 오늘 ${BYPASS_AUTOFIX_SUMMARY}"
  if [[ ${#BYPASS_AUTOFIX_TARGETS[@]} -gt 0 ]]; then
    echo "  · 복구 대상: ${BYPASS_AUTOFIX_TARGETS[*]}"
  fi
  echo "  · 원장: ${BYPASS_AUTOFIX_LEDGER}"
fi
