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
# tee로 화면과 파일 양쪽 기록 → cron-master 본인이 죽어도 사후 조사 가능)
SELF_LOG="${HOME}/.jarvis/logs/cron-master-self.log"
mkdir -p "$(dirname "$SELF_LOG")"
exec > >(tee -a "$SELF_LOG") 2>&1
echo ""
echo "═══ cron-master 시작: $(date '+%Y-%m-%d %H:%M:%S %z') (PID=$$) ═══"

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
  [[ -z "$YESTERDAY_ENTRY" ]] && { echo ""; return; }
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
  [[ -n "$script" && ! -f "$script" ]] && PHANTOM_COUNT=$((PHANTOM_COUNT+1))
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
#   ~/.jarvis/bin → ~/jarvis/infra/bin 심링크 체인으로 git 추적 디렉토리에
#   stub이 무단 침투하는 설계 결함 발견 (2026-04-20 초기 구현에서 19개 침범).
#   유령 스크립트는 감지만 하고 주인님이 수동으로 판단·처리한다.

REPAIR_LEDGER="$BOT_HOME/state/cron-master-ledger.jsonl"
mkdir -p "$(dirname "$REPAIR_LEDGER")"
REPAIRS=()
DRY_RUN="${CRON_MASTER_DRY_RUN:-0}"

repair_count_today() {
  local action="$1" target="$2" today count
  today=$(date +%Y-%m-%d)
  [[ ! -f "$REPAIR_LEDGER" ]] && { echo 0; return; }
  # grep -c 는 매치 0건일 때 stdout "0" + exit 1 → `|| true`로 exit만 삼키고 stdout "0" 유지
  # (`|| echo 0` 안티패턴: 이전엔 "0\n0" 출력되어 [[ ]] syntax error 유발)
  count=$(grep -cF "\"action\":\"$action\",\"target\":\"$target\",\"ts\":\"$today" "$REPAIR_LEDGER" 2>/dev/null || true)
  echo "${count:-0}"
}

log_repair() {
  local action="$1" target="$2" result="$3"
  local today
  today=$(date +%Y-%m-%d)
  echo "{\"action\":\"$action\",\"target\":\"$target\",\"ts\":\"${today}T$(date '+%H:%M:%S%z')\",\"result\":\"$result\",\"dry_run\":${DRY_RUN}}" >> "$REPAIR_LEDGER"
}

# [4.5.1] LaunchAgent 언로드 → bootout → bootstrap (2단계로 견고화)
for lbl in "${UNLOADED[@]}"; do
  count=$(repair_count_today "bootstrap" "$lbl")
  if [[ "$count" -ge 3 ]]; then
    REPAIRS+=("SKIP bootstrap $lbl (오늘 ${count}/3회)")
    continue
  fi
  plist="$LA_DIR/$lbl.plist"
  if [[ ! -f "$plist" ]]; then
    REPAIRS+=("SKIP bootstrap $lbl (plist 없음)")
    continue
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    REPAIRS+=("[DRY-RUN] bootstrap $lbl")
    log_repair "bootstrap" "$lbl" "dry-run"
    continue
  fi
  # stale reference 회피: bootout 먼저 (실패해도 무시), 그 후 bootstrap
  launchctl bootout "gui/$(id -u)/$lbl" 2>/dev/null || true
  if bootstrap_err=$(launchctl bootstrap "gui/$(id -u)" "$plist" 2>&1); then
    log_repair "bootstrap" "$lbl" "success"
    REPAIRS+=("✅ bootstrap $lbl")
  else
    # 에러 메시지에서 따옴표 제거해 JSON 안전성 확보
    safe_err=$(echo "$bootstrap_err" | tr -d '"' | tr '\n' ' ' | head -c 120)
    log_repair "bootstrap" "$lbl" "failed: ${safe_err}"
    REPAIRS+=("❌ bootstrap 실패: $lbl → $safe_err")
  fi
done

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
  [[ -z "$pl_json" ]] && continue

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
  [[ -z "$log_path" || ! -f "$log_path" ]] && continue

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
)
AUDIT_SUMMARY=()
for name in "${AUDIT_LOGS[@]}"; do
  logpath="$LOG_DIR/${name}.log"
  [[ ! -f "$logpath" ]] && continue
  mtime=$(stat -f %m "$logpath" 2>/dev/null || echo 0)
  age_h=$(( (NOW_EPOCH - mtime) / 3600 ))
  # 48h 이상 업데이트 없으면 stale
  if [[ "$age_h" -gt 48 ]]; then
    AUDIT_SUMMARY+=("${name}: stale (${age_h}h 업데이트 없음)")
    continue
  fi
  # 최근 100줄에서 에러성 키워드 카운트
  err_count=$(tail -100 "$logpath" 2>/dev/null | grep -ciE 'error|fail|warn|issue' || true)
  if [[ "$err_count" -gt 0 ]]; then
    AUDIT_SUMMARY+=("${name}: ${err_count}건 의심 키워드")
  fi
done

# ── 4.6.5. Phase 3c-2: 미해결 감사 경고 추적 (wiki-lint 리포트 이슈 수) ──────
WIKI_META="${HOME}/.jarvis/wiki/meta"
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
WIKI_ROOT="${HOME}/.jarvis/wiki"
if [[ -d "$WIKI_ROOT" ]]; then
  for i in 0 1 2 3 4 5 6; do
    day=$(date -v-${i}d +%Y-%m-%d 2>/dev/null || date -d "$i days ago" +%Y-%m-%d 2>/dev/null || echo "")
    [[ -z "$day" ]] && continue
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

if [[ ${#REPAIRS[@]} -gt 0 ]]; then
  echo ""
  echo "🔧 **자동 복구 (L2)** — ${#REPAIRS[@]}건"
  for r in "${REPAIRS[@]}"; do
    echo "  · ${r}"
  done
  [[ "$DRY_RUN" == "1" ]] && echo "  ⚠️ DRY-RUN 모드: 실제 변경 없음"
  echo ""
  echo "  📝 원장: ${REPAIR_LEDGER}"
  echo "  📈 감지 원장: ${DAILY_LEDGER}"
fi
