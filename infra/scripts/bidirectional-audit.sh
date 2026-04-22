#!/usr/bin/env bash
# bidirectional-audit.sh — tasks.json ↔ LaunchAgents plist 양방향 감사 (2026-04-22 P4 도입)
#
# Why: launchagents-audit 는 plist 변화만 봄 (단방향).
#      tasks.json 엔트리와 실제 plist 를 교차 대조해 세 가지 상태 감지:
#        (1) orphan plist — plist 有 + tasks.json 無 → 삭제 후보
#        (2) missing plist — tasks.json 有 + plist 無 + enabled:true + schedule ≠ manual
#        (3) spec mismatch — plist ProgramArguments 가 2층 템플릿 위반
#
# Usage: weekly cron (일요일 07:30 KST)
# 산출물: ~/jarvis/runtime/ledger/bidirectional-audit.jsonl
#         stdout: Discord 리포트 텍스트 (bot-cron.sh 가 라우팅)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LA_DIR="${HOME}/Library/LaunchAgents"
EFF_TASKS="${BOT_HOME}/config/effective-tasks.json"
[[ -f "$EFF_TASKS" ]] || EFF_TASKS="${BOT_HOME}/config/tasks.json"
LEDGER_DIR="${BOT_HOME}/ledger"
LEDGER="${LEDGER_DIR}/bidirectional-audit.jsonl"
TS_ISO=$(TZ=Asia/Seoul date +"%Y-%m-%dT%H:%M:%S%z")
TODAY=$(TZ=Asia/Seoul date +"%Y-%m-%d")

mkdir -p "$LEDGER_DIR"

if [[ ! -f "$EFF_TASKS" ]]; then
  echo "❌ bidirectional-audit: tasks 파일 없음 ($EFF_TASKS)"
  exit 1
fi

# --- 1. tasks.json 엔트리 목록 (enabled + schedule ≠ manual) ---
# output: "task_id\tschedule\thas_discord"
TASKS_TSV=$(jq -r '
  (.tasks // [])[]
  | select(.enabled != false)
  | select((.schedule // .cron // "") != "" and (.schedule // .cron // "") != "(manual)")
  | [.id, (.schedule // .cron), (((.output // []) | index("discord")) != null | tostring)]
  | @tsv
' "$EFF_TASKS" 2>/dev/null || echo "")

# --- 2. 실제 plist 목록 (com.jarvis.*.plist / ai.jarvis.*.plist) ---
ACTIVE_PLISTS=$(ls -1 "$LA_DIR" 2>/dev/null \
  | grep -E '^(ai|com)\.jarvis\..*\.plist$' \
  | sed -E 's/^(ai|com)\.jarvis\.//; s/\.plist$//' \
  | sort -u)

# --- 3. 태스크 id 세트 ---
TASK_IDS=$(echo "$TASKS_TSV" | awk -F'\t' 'NF>0 {print $1}' | sort -u)

# ====================================================================
# (1) ORPHAN — plist 有 + tasks.json 無
# ====================================================================
ORPHAN_LIST=()
while IFS= read -r plist_id; do
  [[ -z "$plist_id" ]] && continue
  # 예외: 장기 데몬 (tasks.json 등록 안 되는 정책)
  case "$plist_id" in
    discord-bot|launchagents-watcher|cloudflared-*|bot-watchdog)
      continue
      ;;
  esac
  if ! echo "$TASK_IDS" | grep -qx "$plist_id"; then
    ORPHAN_LIST+=("$plist_id")
    printf '{"ts":"%s","action":"orphan_plist","task":"%s","reason":"plist_exists_but_no_tasks_json_entry"}\n' \
      "$TS_ISO" "$plist_id" >> "$LEDGER"
  fi
done <<< "$ACTIVE_PLISTS"

# ====================================================================
# (2) MISSING — tasks.json 有 + plist 無
# ====================================================================
MISSING_LIST=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | awk -F'\t' '{print $1}')
  # com.jarvis.* 또는 ai.jarvis.* 어느 쪽이든 있으면 OK
  if ! echo "$ACTIVE_PLISTS" | grep -qx "$task_id"; then
    MISSING_LIST+=("$task_id")
    printf '{"ts":"%s","action":"missing_plist","task":"%s","reason":"tasks_json_entry_but_no_plist"}\n' \
      "$TS_ISO" "$task_id" >> "$LEDGER"
  fi
done <<< "$TASKS_TSV"

# ====================================================================
# (3) SPEC MISMATCH — output:discord 인데 plist 가 bot-cron.sh 미경유
# ====================================================================
MISMATCH_LIST=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | awk -F'\t' '{print $1}')
  has_discord=$(echo "$line" | awk -F'\t' '{print $3}')
  [[ "$has_discord" != "true" ]] && continue

  # plist 경로 후보
  for prefix in com ai; do
    plist_path="$LA_DIR/${prefix}.jarvis.${task_id}.plist"
    if [[ -f "$plist_path" ]]; then
      if ! grep -q 'bot-cron\.sh' "$plist_path" 2>/dev/null; then
        MISMATCH_LIST+=("$task_id")
        printf '{"ts":"%s","action":"spec_mismatch","task":"%s","plist":"%s","reason":"discord_task_bypasses_bot_cron_template"}\n' \
          "$TS_ISO" "$task_id" "$(basename "$plist_path")" >> "$LEDGER"
      fi
      break
    fi
  done
done <<< "$TASKS_TSV"

# ====================================================================
# 리포트 출력 (stdout → bot-cron.sh 가 Discord 라우팅)
# ====================================================================
TOTAL_ISSUES=$((${#ORPHAN_LIST[@]} + ${#MISSING_LIST[@]} + ${#MISMATCH_LIST[@]}))

printf '{"ts":"%s","action":"summary","orphan":%d,"missing":%d,"mismatch":%d,"total":%d}\n' \
  "$TS_ISO" "${#ORPHAN_LIST[@]}" "${#MISSING_LIST[@]}" "${#MISMATCH_LIST[@]}" "$TOTAL_ISSUES" >> "$LEDGER"

echo "🔍 **양방향 감사 — tasks.json ↔ plist** ($TODAY KST)"
echo ""

if [[ "$TOTAL_ISSUES" -eq 0 ]]; then
  echo "✅ 이슈 없음. tasks.json ($(echo "$TASK_IDS" | wc -l | tr -d ' ')개) 과 plist ($(echo "$ACTIVE_PLISTS" | wc -l | tr -d ' ')개) 정합성 유지 중."
  exit 0
fi

echo "⚠️ 총 ${TOTAL_ISSUES}건 불일치 감지"
echo ""

if [[ ${#ORPHAN_LIST[@]} -gt 0 ]]; then
  echo "### 🏚️ 고아 plist (${#ORPHAN_LIST[@]}건) — tasks.json 엔트리 없이 돌고 있음"
  for t in "${ORPHAN_LIST[@]}"; do
    echo "- \`$t\` — tasks.json 등록 or plist 삭제 판단 필요"
  done
  echo ""
fi

if [[ ${#MISSING_LIST[@]} -gt 0 ]]; then
  echo "### 🚫 누락 plist (${#MISSING_LIST[@]}건) — tasks.json 있으나 launchd 미등록"
  for t in "${MISSING_LIST[@]}"; do
    echo "- \`$t\` — \`cron-sync.sh\` 재실행 권장"
  done
  echo ""
fi

if [[ ${#MISMATCH_LIST[@]} -gt 0 ]]; then
  echo "### 🚨 템플릿 위반 (${#MISMATCH_LIST[@]}건) — output:discord 인데 bot-cron.sh 우회"
  for t in "${MISMATCH_LIST[@]}"; do
    echo "- \`$t\` — plist-bypass-autofix 다음 실행에서 자동 복구 예상"
  done
  echo ""
fi

echo "-# ledger: \`~/jarvis/runtime/ledger/bidirectional-audit.jsonl\`"
exit 0
