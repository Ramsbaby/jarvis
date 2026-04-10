#!/usr/bin/env bash
set -euo pipefail

# apply-kpi-decisions.sh - kpi-decisions.jsonl에서 pending 항목 적용
# 기본값: dry-run (preview only). 실제 적용하려면 --apply 플래그 필요.
# Usage:
#   apply-kpi-decisions.sh          → 변경 예정 내용만 출력 (tasks.json 수정 안 함)
#   apply-kpi-decisions.sh --apply  → 실제로 tasks.json 수정 + Discord 알림

DRY_RUN=true
for arg in "$@"; do
    if [[ "$arg" == "--apply" ]]; then
        DRY_RUN=false
    fi
done

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MONITORING="${BOT_HOME}/config/monitoring.json"
DECISIONS_FILE="${BOT_HOME}/state/kpi-decisions.jsonl"

if [[ ! -f "$DECISIONS_FILE" ]]; then
    echo "No decisions file found: $DECISIONS_FILE"
    exit 0
fi

# pending 항목 수집
PENDING=$(grep '"status"' "$DECISIONS_FILE" 2>/dev/null | grep '"pending"') || PENDING=""

if [[ -z "$PENDING" ]]; then
    echo "No pending decisions to apply."
    exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] 아래 변경사항이 적용될 예정입니다. 실제 적용: --apply 플래그 사용"
else
    echo "Applying pending KPI decisions..."
fi
echo ""

# python3으로 tasks.json 업데이트 + decisions 파일 갱신
APPLIED_MSG=$(DRY_RUN="$DRY_RUN" python3 << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone

bot_home = os.environ.get("BOT_HOME", os.path.expanduser("~/.jarvis"))
dry_run = os.environ.get("DRY_RUN", "true") == "true"
tasks_path = os.path.join(bot_home, "config", "tasks.json")
decisions_path = os.path.join(bot_home, "state", "kpi-decisions.jsonl")

# tasks.json 로드
with open(tasks_path) as f:
    tasks_data = json.load(f)

# tasks 배열 -> dict (id 기반)
tasks_by_id = {}
for i, t in enumerate(tasks_data.get("tasks", [])):
    tasks_by_id[t["id"]] = i

# decisions 전체 로드
all_lines = []
with open(decisions_path) as f:
    for line in f:
        line = line.strip()
        if line:
            all_lines.append(json.loads(line))

applied = []
now_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

for dec in all_lines:
    if dec.get("status") != "pending":
        continue
    if dec.get("action") != "timeout_increase":
        continue

    task_id = dec["task"]
    proposed = dec["proposed_timeout"]

    idx = tasks_by_id.get(task_id)
    if idx is None:
        dec["status"] = "skipped"
        dec["applied_ts"] = now_ts
        dec["reason"] = f"task {task_id} not found in tasks.json"
        continue

    old_timeout = tasks_data["tasks"][idx].get("timeout", 120)
    if not dry_run:
        tasks_data["tasks"][idx]["timeout"] = proposed
        dec["status"] = "applied"
        dec["applied_ts"] = now_ts
        applied.append(f"  {task_id} timeout: {old_timeout}s -> {proposed}s [APPLIED]")
    else:
        applied.append(f"  {task_id} timeout: {old_timeout}s -> {proposed}s [PREVIEW]")

if not dry_run:
    # tasks.json 저장
    with open(tasks_path, "w") as f:
        json.dump(tasks_data, f, indent=2, ensure_ascii=False)
        f.write("\n")

    # decisions 파일 덮어쓰기 (상태 갱신)
    with open(decisions_path, "w") as f:
        for dec in all_lines:
            f.write(json.dumps(dec, ensure_ascii=False) + "\n")

prefix = "[DRY-RUN] " if dry_run else ""
if applied:
    msg = f"{prefix}KPI decisions preview:\n" + "\n".join(applied)
    if dry_run:
        msg += "\n\n실제 적용: bash ~/.jarvis/scripts/apply-kpi-decisions.sh --apply"
else:
    msg = "No applicable pending decisions found."

print(msg)
PYEOF
)

echo "$APPLIED_MSG"

# Discord 확인 알림
if echo "$APPLIED_MSG" | grep -q "timeout:"; then
    WEBHOOK=$(jq -r '.webhooks["jarvis"]' "$MONITORING" 2>/dev/null || echo "")
    if [[ -n "$WEBHOOK" && "$WEBHOOK" != "null" ]]; then
        PAYLOAD=$(jq -n --arg c "$APPLIED_MSG" '{"content":$c}')
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK" \
            -H "Content-Type: application/json" -d "$PAYLOAD")
        if [[ "$HTTP" != "204" ]]; then
            echo "WARNING: Discord send failed: HTTP $HTTP" >&2
        fi
    fi
fi
