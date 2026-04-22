#!/usr/bin/env bash
# launchagents-watcher.sh — fswatch 기반 plist 실시간 감시 (3층 방어막)
#
# Why: launchagents-audit.sh 는 매시간 13분 주기 → 최대 60분 침묵 가능.
#      실시간 감시로 CREATE/MODIFY 이벤트 즉시 정책 검증.
#      2026-04-19~22 BYPASS 4일 침묵 사건(일일 복구 주기 한계) 재발 차단.
#
# Design:
#   - fswatch 가 ~/Library/LaunchAgents/ 변경 이벤트 스트리밍
#   - com.jarvis.* / ai.jarvis.* 파일만 필터
#   - 3초 debounce (연속 편집 합치기)
#   - 이벤트마다 정책 검증 → 위반 시 ledger 기록 + Discord 즉시 경보
#
# 검증 항목 (audit.sh 와 동일):
#   1. JARVIS_GENERATED_BY 서명 존재 여부 (1층)
#   2. output:discord 태스크의 bot-cron.sh 경유 여부 (2층)

set -euo pipefail

LA_DIR="${HOME}/Library/LaunchAgents"
LEDGER_DIR="${HOME}/jarvis/runtime/ledger"
LEDGER="${LEDGER_DIR}/launchagents-watcher.jsonl"
EFF_TASKS="${HOME}/jarvis/runtime/config/effective-tasks.json"
MONITORING="${HOME}/jarvis/runtime/config/monitoring.json"
DEBOUNCE_SEC=3

mkdir -p "$LEDGER_DIR"

# fswatch 존재 확인
if ! command -v fswatch >/dev/null 2>&1; then
  echo "[watcher] FATAL: fswatch 미설치 (brew install fswatch)" >&2
  exit 1
fi

# Discord webhook 로드 (선택 — 없으면 ledger 만 기록)
WEBHOOK=""
if [[ -f "$MONITORING" ]]; then
  WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // empty' "$MONITORING" 2>/dev/null || true)
fi

# 이벤트 debounce 는 fswatch -l 3.0 의 batch latency 로 처리 (macOS /bin/bash 3.2 호환).
# inspect_plist 는 idempotent (grep 기반) → 중복 호출 무해.

log_ledger() {
  local action="$1" entry="$2" task="$3" reason="$4"
  local ts
  ts=$(TZ=Asia/Seoul date +"%Y-%m-%dT%H:%M:%S%z")
  printf '{"ts":"%s","action":"%s","entry":"%s","task":"%s","reason":"%s"}\n' \
    "$ts" "$action" "$entry" "$task" "$reason" >> "$LEDGER"
}

notify_discord() {
  local msg="$1"
  [[ -z "$WEBHOOK" ]] && return 0
  local payload
  payload=$(jq -n --arg m "$msg" '{content: $m}')
  curl -sS -X POST "$WEBHOOK" -H "Content-Type: application/json" \
    -d "$payload" > /dev/null 2>&1 || true
}

inspect_plist() {
  local plist_path="$1"
  local entry; entry=$(basename "$plist_path")

  # .plist 만 검사 (disabled/bak/nexus_primary 제외)
  [[ "$entry" =~ \.plist$ ]] || return 0
  [[ "$entry" =~ ^(ai|com)\.jarvis\. ]] || return 0

  local label="${entry%.plist}"
  local task_id="${label#com.jarvis.}"
  task_id="${task_id#ai.jarvis.}"

  # 파일 없으면 삭제 이벤트 — 기록만
  if [[ ! -f "$plist_path" ]]; then
    log_ledger "removed" "$entry" "$task_id" "plist_removed_live"
    return 0
  fi

  # 1층 — 서명 검증
  if ! grep -q 'JARVIS_GENERATED_BY:' "$plist_path" 2>/dev/null; then
    log_ledger "unsigned_plist" "$entry" "$task_id" "plist_created_or_edited_without_signature"
    notify_discord "🔏 **[실시간] 서명 없는 plist**: \`$entry\` — cron-sync.sh 우회 의심"
  fi

  # 2층 — output:discord 태스크 bot-cron.sh 경유 여부
  if [[ -f "$EFF_TASKS" ]]; then
    local is_discord
    is_discord=$(jq -r --arg tid "$task_id" \
      '.tasks[]? | select(.id==$tid) | select((.output // []) | index("discord")) | .id' \
      "$EFF_TASKS" 2>/dev/null | head -1)
    if [[ -n "$is_discord" ]] && ! grep -q 'bot-cron\.sh' "$plist_path" 2>/dev/null; then
      log_ledger "program_args_violation" "$entry" "$task_id" "discord_task_bypasses_bot_cron_realtime"
      notify_discord "🚨 **[실시간] BYPASS 재발**: \`$entry\` — output:discord 태스크가 bot-cron.sh 우회"
    fi
  fi
}

echo "[watcher] 시작 — $LA_DIR 감시 중 (debounce=${DEBOUNCE_SEC}s)"

# fswatch: -0 null 구분자, -l 3.0 batch latency (fswatch 자체가 3초 debounce 수행)
# --event Created/Updated/Renamed/MovedTo 만 반응
# inspect_plist 는 idempotent 이므로 같은 파일 중복 호출되어도 무해.
fswatch -0 \
  -l 3.0 \
  --event Created \
  --event Updated \
  --event Renamed \
  --event MovedTo \
  "$LA_DIR" \
  | while IFS= read -r -d '' path; do
      case "$(basename "$path")" in
        com.jarvis.*.plist|ai.jarvis.*.plist)
          inspect_plist "$path"
          ;;
      esac
    done
