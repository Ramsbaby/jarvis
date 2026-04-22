#!/usr/bin/env bash
# legacy-plist-audit.sh — tasks.json에 없는 legacy LaunchAgent plist 탐지
#
# 목적: 2026-04-16 카카오 토큰 갱신 크론 영구 소실 사고(tasks.json에 없던 legacy plist가
# 일괄 정리 때 제거됨) 재발 방지. 정기 감사로 tasks.json 미편입 legacy plist를 찾아
# dev-queue 또는 Discord 경보로 "편입 필요" 신호 발송.
#
# 실행: bash legacy-plist-audit.sh [--notify-discord]
# 크론: tasks.json에 legacy-plist-audit 엔트리 추가 (주 1회 권장)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
TASKS_FILE="$BOT_HOME/config/effective-tasks.json"
[[ -f "$TASKS_FILE" ]] || TASKS_FILE="$BOT_HOME/config/tasks.json"
LOG="$BOT_HOME/logs/legacy-plist-audit.log"
NOTIFY_DISCORD="${1:-}"

log() {
    echo "[$(date '+%F %T')] legacy-plist-audit: $*" >> "$LOG"
    echo "[$(date '+%F %T')] legacy-plist-audit: $*"
}

mkdir -p "$(dirname "$LOG")"

log "=== legacy plist 감사 시작 ==="

# tasks.json의 id 목록 추출 (env 경유로 heredoc 안전화)
export TASKS_FILE
TASKS_IDS=$(python3 << 'PYEOF'
import json, os, sys
with open(os.environ['TASKS_FILE']) as f:
    d = json.load(f)
tasks = d.get('tasks', d) if isinstance(d, dict) else d
ids = [t.get('id', '') for t in tasks if isinstance(t, dict) and t.get('id')]
print('\n'.join(ids))
PYEOF
)

# com.jarvis.* plist 순회 + tasks.json 대조
LEGACY_COUNT=0
LEGACY_LIST=""

for plist in "$LAUNCH_AGENTS"/com.jarvis.*.plist; do
    [[ -f "$plist" ]] || continue
    fname=$(basename "$plist")
    label="${fname%.plist}"
    # com.jarvis.foo-bar → foo-bar 추출
    task_id="${label#com.jarvis.}"

    # .disabled/.bak 등 부가 접미사 skip
    if [[ "$task_id" == *.disabled || "$task_id" == *.bak* || "$task_id" == *.removed* ]]; then
        continue
    fi

    # tasks.json에 id 있는지 확인
    if ! echo "$TASKS_IDS" | grep -qFx "$task_id"; then
        LEGACY_COUNT=$((LEGACY_COUNT + 1))
        LEGACY_LIST+="  - $task_id (plist: $fname)"$'\n'
    fi
done

if (( LEGACY_COUNT == 0 )); then
    log "✅ legacy plist 없음 — tasks.json SSoT 정합성 OK"
    exit 0
fi

log "⚠️  legacy plist ${LEGACY_COUNT}건 발견 (tasks.json 미편입):"
printf '%s' "$LEGACY_LIST" | tee -a "$LOG"

# Discord 알림 (옵션)
if [[ "$NOTIFY_DISCORD" == "--notify-discord" ]]; then
    webhook=$(python3 -c "import json; d=json.load(open('$BOT_HOME/config/monitoring.json')); print(d.get('webhooks',{}).get('jarvis-system','') or d.get('webhooks',{}).get('jarvis',''))" 2>/dev/null || echo "")
    if [[ -n "$webhook" ]]; then
        msg="🚨 **legacy plist ${LEGACY_COUNT}건 탐지** — tasks.json SSoT 미편입\n\`\`\`\n${LEGACY_LIST}\`\`\`\n**조치**: tasks.json에 엔트리 추가 후 cron-sync 실행. 방치 시 다음 일괄 정리에서 영구 소실 위험."
        python3 << PYEOF
import json, urllib.request, os
webhook = "$webhook"
msg = """$msg"""
payload = json.dumps({'content': msg}).encode()
req = urllib.request.Request(webhook, data=payload, headers={'Content-Type':'application/json'})
try:
    urllib.request.urlopen(req, timeout=5)
    print("Discord 알림 전송")
except Exception as e:
    print(f"Discord 알림 실패: {e}")
PYEOF
    else
        log "⚠️  webhook 설정 없음 — Discord 알림 스킵"
    fi
fi

log "=== legacy plist 감사 종료 (legacy=${LEGACY_COUNT}건) ==="
exit 0
