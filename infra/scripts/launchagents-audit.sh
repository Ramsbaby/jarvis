#!/usr/bin/env bash
# launchagents-audit.sh — LaunchAgents 디렉토리 변경 감지 + ledger 자동 기록
#
# Why: 정합화 작업 후 "누가/언제 .plist를 .disabled로 옮겼는지" 추적 불가했음.
#      매시간 디렉토리 스냅샷 → 변경 감지 시 ledger append + Discord 알림.
#
# Usage: tasks.json에 등록 (schedule: "13 * * * *", 매시간 13분)
# 산출물: ~/.jarvis/ledger/launchagents-audit.jsonl
#
# 추적 대상 변화:
#   - 신규 .plist (정책 가드 트리거)
#   - .plist → .plist.disabled rename (누군가 disable)
#   - .plist 삭제
#   - .plist.disabled → .plist 부활 (롤백)

set -euo pipefail

LA_DIR="${HOME}/Library/LaunchAgents"
LEDGER_DIR="${HOME}/.jarvis/ledger"
LEDGER="${LEDGER_DIR}/launchagents-audit.jsonl"
SNAPSHOT_DIR="${HOME}/.jarvis/state/launchagents-snapshots"
LATEST="${SNAPSHOT_DIR}/latest.txt"

mkdir -p "$LEDGER_DIR" "$SNAPSHOT_DIR"

TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 현재 스냅샷 — 한 줄당 "label\textension"
NOW=$(mktemp /tmp/la-snap-now-XXXXXX.txt)
trap 'rm -f "$NOW"' EXIT

ls -1 "$LA_DIR" 2>/dev/null \
  | grep -E '^(ai|com)\.jarvis\.' \
  | sort > "$NOW"

# 이전 스냅샷 없으면 첫 실행 — 생성만 하고 종료
if [[ ! -f "$LATEST" ]]; then
  cp "$NOW" "$LATEST"
  printf '{"ts":"%s","action":"baseline","total":%d,"note":"first_snapshot"}\n' \
    "$TS_ISO" "$(wc -l < "$NOW" | tr -d ' ')" >> "$LEDGER"
  echo "[la-audit] baseline created: $(wc -l < "$NOW" | tr -d ' ') entries"
  exit 0
fi

# diff 계산
ADDED=$(comm -23 "$NOW" "$LATEST")        # NOW에만 — 신규
REMOVED=$(comm -13 "$NOW" "$LATEST")      # LATEST에만 — 삭제

CHANGES=0
DISCORD_LINES=()

if [[ -n "$ADDED" ]]; then
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    CHANGES=$((CHANGES+1))
    # 분류: .plist 신규 = 정책 가드 트리거 / .disabled 신규 = 누군가 disable
    if [[ "$entry" == *.plist ]]; then
      kind="new_plist"
      if [[ "$entry" == com.jarvis.* ]]; then
        DISCORD_LINES+=("🟡 신규 com.jarvis plist: \`$entry\` (정책 검토 필요)")
      fi
    elif [[ "$entry" == *.plist.disabled ]]; then
      kind="newly_disabled"
    elif [[ "$entry" == *.plist.nexus_primary ]]; then
      kind="nexus_primary_added"
    else
      kind="other_added"
    fi
    printf '{"ts":"%s","action":"added","entry":"%s","kind":"%s"}\n' \
      "$TS_ISO" "$entry" "$kind" >> "$LEDGER"
  done <<< "$ADDED"
fi

if [[ -n "$REMOVED" ]]; then
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    CHANGES=$((CHANGES+1))
    if [[ "$entry" == *.plist ]]; then
      # 같은 base가 .plist.disabled로 추가됐으면 rename (disable). 아니면 삭제.
      base="${entry%.plist}"
      if echo "$ADDED" | grep -qx "${base}.plist.disabled"; then
        kind="plist_disabled_via_rename"
      else
        kind="plist_deleted"
        DISCORD_LINES+=("🔴 plist 삭제됨: \`$entry\` (의도된 작업?)")
      fi
    else
      kind="other_removed"
    fi
    printf '{"ts":"%s","action":"removed","entry":"%s","kind":"%s"}\n' \
      "$TS_ISO" "$entry" "$kind" >> "$LEDGER"
  done <<< "$REMOVED"
fi

# 스냅샷 갱신
cp "$NOW" "$LATEST"
ARCHIVE="${SNAPSHOT_DIR}/$(date +%Y%m%d_%H%M%S).txt"
cp "$NOW" "$ARCHIVE"

# 30일 이상 스냅샷 정리
find "$SNAPSHOT_DIR" -name "*.txt" -mtime +30 -not -name "latest.txt" -delete 2>/dev/null || true

echo "[la-audit] changes: $CHANGES (total entries: $(wc -l < "$NOW" | tr -d ' '))"

# Discord 알림 (변경 있을 때만)
if [[ ${#DISCORD_LINES[@]} -gt 0 ]]; then
  WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // empty' "${HOME}/.jarvis/config/monitoring.json" 2>/dev/null || true)
  if [[ -n "${WEBHOOK:-}" ]]; then
    MSG="📡 **LaunchAgents 변경 감지**\n$(printf '%s\n' "${DISCORD_LINES[@]}")\n\n총 변경: ${CHANGES}건 / ledger: \`~/.jarvis/ledger/launchagents-audit.jsonl\`"
    PAYLOAD=$(jq -n --arg m "$MSG" '{content: $m}')
    curl -sS -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "$PAYLOAD" > /dev/null 2>&1 || true
  fi
fi
