#!/usr/bin/env bash
set -euo pipefail

# kpi-anomaly-detector.sh - KPI 이상 감지 + 자동 조치 제안
# 매주 월요일 08:35 실행 (crontab)
# 측정 -> 이상 감지 -> 행동 제안 -> 재측정 루프의 핵심

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
MONITORING="${BOT_HOME}/config/monitoring.json"
DECISIONS_FILE="${BOT_HOME}/state/kpi-decisions.jsonl"
RESULTS_DIR="${BOT_HOME}/results/kpi-weekly"

mkdir -p "$(dirname "$DECISIONS_FILE")"
mkdir -p "$RESULTS_DIR"

TODAY=$(date '+%Y-%m-%d')
export TS
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Step 1: measure-kpi.sh --json 실행 ---
KPI_JSON=$(bash "${BOT_HOME}/scripts/measure-kpi.sh" --json --days 7)

if [[ -z "$KPI_JSON" ]]; then
    echo "ERROR: measure-kpi.sh --json returned empty output" >&2
    exit 1
fi

# 결과 파일 저장
echo "$KPI_JSON" | python3 -m json.tool > "${RESULTS_DIR}/${TODAY}.json"

# --- Step 2: 팀별 이상 감지 ---
# KPI_JSON을 환경변수로 전달 (heredoc stdin 충돌 회피)
export KPI_JSON
export BOT_HOME

ANALYSIS=$(python3 << 'PYEOF'
import json, os

bot_home = os.environ["BOT_HOME"]
kpi = json.loads(os.environ["KPI_JSON"])

tasks_path = os.path.join(bot_home, "config", "tasks.json")
with open(tasks_path) as f:
    tasks_data = json.load(f)

# tasks.json은 배열 구조 -> dict로 변환
tasks_by_id = {}
for t in tasks_data.get("tasks", []):
    tasks_by_id[t["id"]] = t

# 팀 -> task_id 매핑
team_tasks = {
    "council": ["council-insight", "weekly-kpi"],
    "trend":   ["news-briefing"],
    "career":  ["career-weekly"],
    "academy": ["academy-support"],
    "record":  ["record-daily", "memory-cleanup"],
    "infra":   ["infra-daily", "system-health", "security-scan", "rag-health", "disk-alert"],
    "brand":   ["brand-weekly", "weekly-report"],
}

team_labels = {
    "council": "감사팀 (Council)",
    "trend":   "정보팀 (Trend)",
    "career":  "성장팀 (Career)",
    "academy": "학습팀 (Academy)",
    "record":  "기록팀 (Record)",
    "infra":   "인프라팀 (Infra)",
    "brand":   "브랜드팀 (Brand)",
}

CRITICAL_THRESHOLD = 70
WARNING_THRESHOLD = 85

alerts = []
decisions = []
ts = os.environ.get("TS", kpi["date"] + "T00:00:00Z")

for team_key, team_data in kpi.get("teams", {}).items():
    rate = team_data["rate"]
    total = team_data["total"]
    success = team_data["success"]

    if total == 0:
        continue

    if rate < CRITICAL_THRESHOLD:
        level = "CRITICAL"
        icon = "\U0001f534"
    elif rate < WARNING_THRESHOLD:
        level = "WARNING"
        icon = "\U0001f7e1"
    else:
        continue

    label = team_labels.get(team_key, team_key)
    alerts.append({
        "team": team_key,
        "label": label,
        "level": level,
        "icon": icon,
        "rate": rate,
        "success": success,
        "total": total,
    })

    task_ids = team_tasks.get(team_key, [])
    for tid in task_ids:
        task_cfg = tasks_by_id.get(tid)
        if task_cfg is None:
            continue
        current_timeout = task_cfg.get("timeout", 120)
        proposed_timeout = int(current_timeout * 1.5)
        if current_timeout >= 600:
            continue
        decisions.append({
            "ts": ts,
            "team": team_key,
            "rate": rate,
            "threshold": WARNING_THRESHOLD,
            "action": "timeout_increase",
            "task": tid,
            "current_timeout": current_timeout,
            "proposed_timeout": proposed_timeout,
            "status": "pending",
        })

output = {
    "has_issues": len(alerts) > 0,
    "alerts": alerts,
    "decisions": decisions,
    "kpi": kpi,
}
print(json.dumps(output, ensure_ascii=False))
PYEOF
)

HAS_ISSUES=$(echo "$ANALYSIS" | python3 -c "import json,sys; print(json.load(sys.stdin)['has_issues'])")

# --- Step 3: decisions 기록 ---
DECISION_COUNT=$(echo "$ANALYSIS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['decisions']:
    print(json.dumps(d, ensure_ascii=False))
" | tee -a "$DECISIONS_FILE" | wc -l | tr -d ' ')

# --- Step 4: Discord 알림 ---
if [[ "$HAS_ISSUES" == "True" ]]; then
    export ANALYSIS
    DISCORD_MSG=$(python3 << 'PYEOF'
import json, os
data = json.loads(os.environ["ANALYSIS"])
lines = []
lines.append("KPI Weekly Report -- " + data["kpi"]["date"])
lines.append("")
for a in data["alerts"]:
    lines.append(f"{a['icon']} {a['label']}: {a['rate']}% ({a['success']}/{a['total']})")
lines.append("")
if data["decisions"]:
    lines.append("Auto-action suggestions:")
    for d in data["decisions"]:
        lines.append(f"  {d['task']} timeout: {d['current_timeout']}s -> {d['proposed_timeout']}s (+50%)")
    lines.append("")
    lines.append("To approve: bash ~/jarvis/runtime/scripts/apply-kpi-decisions.sh")
overall = data["kpi"]["overall"]
lines.append(f"Overall: {overall['rate']}% ({overall['success']}/{overall['total']})")
print("\n".join(lines))
PYEOF
)

    WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"]' "$MONITORING" 2>/dev/null || echo "")
    if [[ -n "$WEBHOOK" && "$WEBHOOK" != "null" ]]; then
        PAYLOAD=$(jq -n --arg c "$DISCORD_MSG" '{"content":$c}')
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK" \
            -H "Content-Type: application/json" -d "$PAYLOAD")
        if [[ "$HTTP" != "204" ]]; then
            echo "WARNING: Discord send failed: HTTP $HTTP" >&2
        fi
    fi

    echo "$DISCORD_MSG"
    echo ""
    echo "Decisions written: ${DECISION_COUNT}"

    # --- Step 5: CRITICAL 수준이면 자동 적용 / WARNING은 L3 승인 요청 ---
    CRITICAL_COUNT=$(echo "$ANALYSIS" | python3 -c "
import json,sys
data=json.load(sys.stdin)
print(sum(1 for a in data['alerts'] if a['level']=='CRITICAL'))
")

    if (( DECISION_COUNT > 0 )); then
        if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
            # CRITICAL: 자동 적용 (L3 승인 불필요)
            echo "CRITICAL 이슈 ${CRITICAL_COUNT}개 감지 — timeout 자동 적용 시작"
            bash "${BOT_HOME}/scripts/apply-kpi-decisions.sh" --apply && \
                echo "apply-kpi-decisions 자동 적용 완료" || \
                echo "WARNING: apply-kpi-decisions 실패" >&2
        else
            # WARNING: L3 승인 요청만 생성
            L3_DIR="$BOT_HOME/state/l3-requests"
            mkdir -p "$L3_DIR"
            cat > "$L3_DIR/kpi-$(date +%s).json" << REQEOF
{
  "label": "KPI Auto-Tuning (${DECISION_COUNT} tasks)",
  "description": "KPI anomaly detected. Apply timeout increases for underperforming tasks?\n${DISCORD_MSG}",
  "script": "apply-kpi-decisions.sh",
  "args": ["--apply"]
}
REQEOF
            echo "L3 승인 요청 생성 (WARNING 수준 — 자동 적용 보류)"
        fi
    fi
else
    echo "All teams OK. No anomalies detected."
    echo "Results saved: ${RESULTS_DIR}/${TODAY}.json"
fi