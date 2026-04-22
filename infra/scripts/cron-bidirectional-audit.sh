#!/usr/bin/env bash
# cron-bidirectional-audit.sh — tasks.json ↔ plist 양방향 교차 감사 (4층 방어막)
#
# Why: 기존 감사는 tasks.json → plist 방향만 봄(정방향).
#      역방향(plist → tasks.json)이 감사 사각지대였음.
#      tasks.json 없이 돌고 있는 "고아 plist", plist 없이 등록만 된 "누락 plist" 를 찾는다.
#
# 검출 카테고리 3종:
#   1. orphan_plist — ~/Library/LaunchAgents 에는 있는데 tasks.json 엔 없음
#                     → cron-sync.sh 체계 밖 수동 생성 or 과거 잔존 plist
#   2. missing_plist — tasks.json enabled:true 인데 plist 없음
#                      → cron-sync.sh 가 생성 실패했거나 수동 삭제된 상태
#   3. spec_mismatch — plist 의 ProgramArguments 가 cron-sync.sh 생성 패턴과 다름
#                      (서명 있는데 bot-cron.sh 경유 안 함 같은 모순)
#
# 제외 대상 (의도된 예외):
#   - ai.jarvis.* 패턴의 daemon plist (watchdog, discord-bot, board 등 tasks.json SSoT 밖)
#   - .plist.disabled / .bak / .removed-* 백업 파일
#
# Usage: cron-bidirectional-audit.sh [--json]
#   --json  ledger 형식 JSONL 만 출력 (크론 호출용)
# 산출물: ~/jarvis/runtime/ledger/cron-bidirectional-audit.jsonl

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LA_DIR="${HOME}/Library/LaunchAgents"
TASKS_FILE="${BOT_HOME}/config/effective-tasks.json"
[[ -f "$TASKS_FILE" ]] || TASKS_FILE="${BOT_HOME}/config/tasks.json"
LEDGER_DIR="${BOT_HOME}/ledger"
LEDGER="${LEDGER_DIR}/cron-bidirectional-audit.jsonl"
MONITORING="${BOT_HOME}/config/monitoring.json"

JSON_ONLY=0
[[ "${1:-}" == "--json" ]] && JSON_ONLY=1

mkdir -p "$LEDGER_DIR"
TS_ISO=$(TZ=Asia/Seoul date +"%Y-%m-%dT%H:%M:%S%z")

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "[bidir-audit] FATAL: tasks.json 없음 — $TASKS_FILE" >&2
  exit 1
fi

# ---- 1. tasks.json 측 인덱스 (enabled 태스크만) ----
TASKS_TMP=$(mktemp /tmp/bidir-tasks-XXXXXX.txt)
trap 'rm -f "$TASKS_TMP" "$PLIST_TMP" 2>/dev/null' EXIT

jq -r '.tasks[]? | select(.enabled != false) | select((.schedule // "") != "" and (.schedule // "") != "(manual)") | .id' \
  "$TASKS_FILE" 2>/dev/null | sort -u > "$TASKS_TMP"

TASKS_COUNT=$(wc -l < "$TASKS_TMP" | tr -d ' ')

# ---- 2. plist 측 인덱스 (com.jarvis.* 만, ai.jarvis.* 는 daemon 으로 제외) ----
PLIST_TMP=$(mktemp /tmp/bidir-plist-XXXXXX.txt)
ls -1 "$LA_DIR" 2>/dev/null \
  | grep -E '^com\.jarvis\..*\.plist$' \
  | sed 's/^com\.jarvis\.//' \
  | sed 's/\.plist$//' \
  | sort -u > "$PLIST_TMP"

PLIST_COUNT=$(wc -l < "$PLIST_TMP" | tr -d ' ')

# ---- 3. 교차 비교 ----
ORPHAN_PLISTS=$(comm -23 "$PLIST_TMP" "$TASKS_TMP")
MISSING_PLISTS=$(comm -13 "$PLIST_TMP" "$TASKS_TMP")

ORPHAN_COUNT=$(echo -n "$ORPHAN_PLISTS" | grep -c . || true)
MISSING_COUNT=$(echo -n "$MISSING_PLISTS" | grep -c . || true)

# ---- 4. spec_mismatch 검사 (서명 있는데 bot-cron 우회 등 구조 모순) ----
SPEC_MISMATCH_TASKS=()
while IFS= read -r tid; do
  [[ -z "$tid" ]] && continue
  plist="$LA_DIR/com.jarvis.${tid}.plist"
  [[ -f "$plist" ]] || continue

  # output:["discord"] 태스크인데 bot-cron.sh 없으면 spec mismatch
  is_discord=$(jq -r --arg t "$tid" \
    '.tasks[]? | select(.id==$t) | select((.output // []) | index("discord")) | .id' \
    "$TASKS_FILE" 2>/dev/null | head -1)
  if [[ -n "$is_discord" ]] && ! grep -q 'bot-cron\.sh' "$plist" 2>/dev/null; then
    SPEC_MISMATCH_TASKS+=("$tid:discord_no_bot_cron")
    continue
  fi

  # 서명 있는데 ProgramArguments 가 `/bin/bash` 시작 아니면 의심
  if grep -q 'JARVIS_GENERATED_BY:' "$plist"; then
    first_arg=$(awk '/<key>ProgramArguments<\/key>/{found=1; next} found && /<string>/{gsub(/.*<string>|<\/string>.*/,""); print; exit}' "$plist" 2>/dev/null)
    if [[ -n "$first_arg" ]] && [[ "$first_arg" != "/bin/bash" ]] && [[ "$first_arg" != "/usr/bin/env" ]]; then
      SPEC_MISMATCH_TASKS+=("$tid:nonstandard_interpreter($first_arg)")
    fi
  fi
done < "$TASKS_TMP"

SPEC_COUNT=${#SPEC_MISMATCH_TASKS[@]}

# ---- 5. ledger 기록 ----
printf '{"ts":"%s","action":"summary","tasks":%d,"plists":%d,"orphan":%d,"missing":%d,"spec_mismatch":%d}\n' \
  "$TS_ISO" "$TASKS_COUNT" "$PLIST_COUNT" "$ORPHAN_COUNT" "$MISSING_COUNT" "$SPEC_COUNT" >> "$LEDGER"

if [[ -n "$ORPHAN_PLISTS" ]]; then
  while IFS= read -r tid; do
    [[ -z "$tid" ]] && continue
    printf '{"ts":"%s","action":"orphan_plist","task":"%s","reason":"plist_exists_but_not_in_tasks_json"}\n' \
      "$TS_ISO" "$tid" >> "$LEDGER"
  done <<< "$ORPHAN_PLISTS"
fi

if [[ -n "$MISSING_PLISTS" ]]; then
  while IFS= read -r tid; do
    [[ -z "$tid" ]] && continue
    printf '{"ts":"%s","action":"missing_plist","task":"%s","reason":"enabled_in_tasks_json_but_no_plist"}\n' \
      "$TS_ISO" "$tid" >> "$LEDGER"
  done <<< "$MISSING_PLISTS"
fi

for entry in "${SPEC_MISMATCH_TASKS[@]}"; do
  tid="${entry%%:*}"
  reason="${entry#*:}"
  printf '{"ts":"%s","action":"spec_mismatch","task":"%s","reason":"%s"}\n' \
    "$TS_ISO" "$tid" "$reason" >> "$LEDGER"
done

# ---- 6. 사람용 리포트 (--json 아닐 때만) ----
if [[ "$JSON_ONLY" -eq 0 ]]; then
  echo "🔍 cron-bidirectional-audit · $TS_ISO"
  echo ""
  echo "📊 요약: tasks=$TASKS_COUNT · plists=$PLIST_COUNT · orphan=$ORPHAN_COUNT · missing=$MISSING_COUNT · spec_mismatch=$SPEC_COUNT"
  echo ""

  if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
    echo "⚠️ 고아 plist ($ORPHAN_COUNT건) — tasks.json 에 없는데 돌고 있음:"
    echo "$ORPHAN_PLISTS" | sed 's/^/  - /'
    echo ""
  fi

  if [[ "$MISSING_COUNT" -gt 0 ]]; then
    echo "⚠️ 누락 plist ($MISSING_COUNT건) — tasks.json enabled 인데 plist 없음 (cron-sync 재실행 필요):"
    echo "$MISSING_PLISTS" | sed 's/^/  - /'
    echo ""
  fi

  if [[ "$SPEC_COUNT" -gt 0 ]]; then
    echo "🚨 구조 모순 ($SPEC_COUNT건):"
    for entry in "${SPEC_MISMATCH_TASKS[@]}"; do
      echo "  - $entry"
    done
    echo ""
  fi

  if [[ "$ORPHAN_COUNT" -eq 0 && "$MISSING_COUNT" -eq 0 && "$SPEC_COUNT" -eq 0 ]]; then
    echo "✅ 양방향 정합성 완전 일치 — 장부/실물 차이 0건"
  fi
fi

# ---- 7. Discord 경보 (이슈 있을 때만) ----
if [[ "$ORPHAN_COUNT" -gt 0 || "$MISSING_COUNT" -gt 0 || "$SPEC_COUNT" -gt 0 ]]; then
  WEBHOOK=""
  [[ -f "$MONITORING" ]] && WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // empty' "$MONITORING" 2>/dev/null || true)
  if [[ -n "$WEBHOOK" ]]; then
    MSG="🔍 **양방향 감사 결과** — orphan=$ORPHAN_COUNT · missing=$MISSING_COUNT · spec_mismatch=$SPEC_COUNT"
    if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
      MSG="$MSG\n**고아 plist**: $(echo "$ORPHAN_PLISTS" | tr '\n' ',' | sed 's/,$//')"
    fi
    if [[ "$MISSING_COUNT" -gt 0 ]]; then
      MSG="$MSG\n**누락 plist**: $(echo "$MISSING_PLISTS" | tr '\n' ',' | sed 's/,$//')"
    fi
    PAYLOAD=$(jq -n --arg m "$MSG" '{content: $m}')
    curl -sS -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "$PAYLOAD" > /dev/null 2>&1 || true
  fi
fi

# exit code: 이슈 있으면 1 (크론에서 alert 트리거 가능)
if [[ "$ORPHAN_COUNT" -gt 0 || "$MISSING_COUNT" -gt 0 || "$SPEC_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
