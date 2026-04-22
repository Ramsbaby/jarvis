#!/usr/bin/env bash
# orphan-plist-classifier.sh — bidirectional-audit 가 찾아낸 orphan plist 를
# long-running daemon / 주기 실행 / 기타 3 종으로 자동 분류.
#
# Why: "plist 有 + tasks.json 無" 상태는 삭제 후보일 수도, 보존 대상(daemon)일 수도 있다.
#      KeepAlive=true / RunAtLoad=true / Schedule 키 존재 여부로 안전하게 분류.
#
# Usage: orphan-plist-classifier.sh
# 출력: Discord 리포트 텍스트 (stdout)
# 산출물: ~/jarvis/runtime/ledger/orphan-plist-classifier.jsonl

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LA_DIR="${HOME}/Library/LaunchAgents"
EFF_TASKS="${BOT_HOME}/config/effective-tasks.json"
[[ -f "$EFF_TASKS" ]] || EFF_TASKS="${BOT_HOME}/config/tasks.json"
LEDGER_DIR="${BOT_HOME}/ledger"
LEDGER="${LEDGER_DIR}/orphan-plist-classifier.jsonl"
TS_ISO=$(TZ=Asia/Seoul date +"%Y-%m-%dT%H:%M:%S%z")

mkdir -p "$LEDGER_DIR"

# --- tasks.json id set ---
TASK_IDS=$(jq -r '(.tasks // [])[] | .id' "$EFF_TASKS" 2>/dev/null | sort -u)

# --- plist 수집 (com.jarvis.*) ---
DAEMON=()
SCHEDULED=()
OTHER=()

for plist in "$LA_DIR"/com.jarvis.*.plist; do
  [[ -f "$plist" ]] || continue
  base=$(basename "$plist" .plist)
  task_id="${base#com.jarvis.}"

  # tasks.json 에 있으면 orphan 이 아님 — skip
  if echo "$TASK_IDS" | grep -qx "$task_id"; then
    continue
  fi

  # KeepAlive / RunAtLoad / StartInterval / StartCalendarInterval 파싱
  keep_alive="false"
  run_at_load="false"
  has_schedule="false"

  if grep -A1 '<key>KeepAlive</key>' "$plist" 2>/dev/null | grep -q '<true/>'; then
    keep_alive="true"
  fi
  if grep -A1 '<key>RunAtLoad</key>' "$plist" 2>/dev/null | grep -q '<true/>'; then
    run_at_load="true"
  fi
  if grep -qE '<key>(StartInterval|StartCalendarInterval)</key>' "$plist" 2>/dev/null; then
    has_schedule="true"
  fi

  if [[ "$keep_alive" == "true" ]]; then
    DAEMON+=("$task_id")
  elif [[ "$has_schedule" == "true" ]]; then
    SCHEDULED+=("$task_id")
  else
    OTHER+=("$task_id")
  fi

  printf '{"ts":"%s","task":"%s","keep_alive":%s,"run_at_load":%s,"has_schedule":%s}\n' \
    "$TS_ISO" "$task_id" "$keep_alive" "$run_at_load" "$has_schedule" >> "$LEDGER"
done

# --- 리포트 출력 ---
TOTAL=$((${#DAEMON[@]} + ${#SCHEDULED[@]} + ${#OTHER[@]}))

echo "## 🗂 orphan plist 분류 결과 ($TOTAL건)"
echo ""

if [[ ${#DAEMON[@]} -gt 0 ]]; then
  echo "### 🟢 보존 권장 — long-running daemon (${#DAEMON[@]}건, KeepAlive=true)"
  for t in "${DAEMON[@]}"; do echo "- \`$t\`"; done
  echo ""
fi

if [[ ${#SCHEDULED[@]} -gt 0 ]]; then
  echo "### 🟡 조치 필요 — tasks.json 등록 or plist 삭제 (${#SCHEDULED[@]}건, 주기 실행)"
  for t in "${SCHEDULED[@]}"; do echo "- \`$t\`"; done
  echo ""
fi

if [[ ${#OTHER[@]} -gt 0 ]]; then
  echo "### ⚫ 수동 검토 — 스케줄/KeepAlive 모두 없음 (${#OTHER[@]}건)"
  for t in "${OTHER[@]}"; do echo "- \`$t\`"; done
  echo ""
fi

echo "-# ledger: \`~/jarvis/runtime/ledger/orphan-plist-classifier.jsonl\` · ts: $TS_ISO"
