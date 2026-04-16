#!/usr/bin/env bash
set -euo pipefail

# tasks-integrity-audit.sh — tasks.json 무결성 주간 감사
# - enabled 태스크의 script 경로 존재 검증
# - LaunchAgent plist 로드 상태 검증 (ai.jarvis.* 패턴)
# - 결과를 Discord jarvis-system 채널 + append-only 원장에 기록
# Why: jarvis-cron.sh가 개별 실행 시 auto-disable 하지만, "오너가 전체 현황을 주간 단위로
#      볼 수 있는 안전망"이 별도로 필요. 스크립트 유령화/plist drift를 조기 포착.

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
TASKS_FILE="${BOT_HOME}/config/tasks.json"
LEDGER_DIR="${BOT_HOME}/ledger"
LEDGER_FILE="${LEDGER_DIR}/tasks-integrity-audit.jsonl"
CONFIG_FILE="${BOT_HOME}/config/monitoring.json"

mkdir -p "$LEDGER_DIR"

log() { echo "[$(date '+%F %T')] [tasks-integrity-audit] $*"; }

if [[ ! -f "$TASKS_FILE" ]]; then
    log "ERROR: tasks.json not found: $TASKS_FILE"
    exit 1
fi

# 감사 실행 (Python으로 구조적 검증)
AUDIT_JSON=$(BOT_HOME="$BOT_HOME" python3 - "$TASKS_FILE" <<'PYEOF'
import json, os, sys, subprocess

path = sys.argv[1]
bot_home = os.environ.get('BOT_HOME', os.path.expanduser('~/.jarvis'))

with open(path) as f:
    d = json.load(f)

missing_scripts = []
auto_disabled_still_bad = []
total_enabled = 0

for t in d.get('tasks', []):
    tid = t.get('id', '?')
    script = t.get('script', '')
    disabled = t.get('disabled', False) or (t.get('enabled', True) is False)
    auto_dis = t.get('_auto_disabled', False)

    if not script:
        continue

    expanded = os.path.expanduser(os.path.expandvars(script))
    exists = os.path.exists(expanded)

    if not disabled:
        total_enabled += 1
        if not exists:
            missing_scripts.append({'id': tid, 'script': script, 'resolved': expanded})

    # auto-disabled 태스크도 "언젠가 복원" 대상이므로 상태 보고
    if auto_dis and not exists:
        auto_disabled_still_bad.append({'id': tid, 'script': script})

# LaunchAgent 로드 상태 (ai.jarvis.* 만)
plist_dir = os.path.expanduser('~/Library/LaunchAgents')
expected = []
if os.path.isdir(plist_dir):
    for n in os.listdir(plist_dir):
        if n.startswith('ai.jarvis.') and n.endswith('.plist'):
            expected.append(n.replace('.plist', ''))

loaded = set()
try:
    out = subprocess.check_output(['launchctl', 'list'], text=True, timeout=10)
    for line in out.splitlines():
        parts = line.split('\t')
        if len(parts) >= 3 and parts[2].startswith('ai.jarvis.'):
            loaded.add(parts[2])
except Exception:
    pass

# 스크립트 실체 없는 plist는 "레거시"로 분류
plist_unloaded = []
for label in expected:
    if label in loaded:
        continue
    # 레거시 여부: label에서 스크립트 파일명 매핑 못하므로, 일단 전부 보고
    plist_unloaded.append(label)

report = {
    'enabled_total': total_enabled,
    'missing_scripts': missing_scripts,
    'auto_disabled_still_bad': auto_disabled_still_bad,
    'plist_unloaded': plist_unloaded,
    'plist_expected_total': len(expected),
    'plist_loaded_total': len([l for l in expected if l in loaded]),
}
print(json.dumps(report, ensure_ascii=False))
PYEOF
)

# 원장 기록
TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS_UNIX=$(date +%s)
printf '{"ts":"%s","ts_unix":%d,"audit":%s}\n' "$TS_ISO" "$TS_UNIX" "$AUDIT_JSON" >> "$LEDGER_FILE"

# 리포트 요약 + Discord 알림 (문제 있을 때만)
SUMMARY=$(echo "$AUDIT_JSON" | python3 -c '
import json, sys
a = json.load(sys.stdin)
miss = a["missing_scripts"]
plist = a["plist_unloaded"]
still_bad = a["auto_disabled_still_bad"]

lines = []
lines.append("📋 **tasks-integrity-audit**")
lines.append("enabled 태스크 {}건 / 누락 스크립트 {}건".format(a["enabled_total"], len(miss)))
lines.append("LaunchAgent {}/{} 로드됨".format(a["plist_loaded_total"], a["plist_expected_total"]))
if miss:
    lines.append("\n**🔴 누락 스크립트 (즉시 auto-disable 대상):**")
    for m in miss[:10]:
        lines.append("  • `{}` → `{}`".format(m["id"], m["script"]))
if still_bad:
    lines.append("\n⚪ 이전에 auto-disable된 채 미복원: {}건".format(len(still_bad)))
if plist:
    more = "..." if len(plist) > 5 else ""
    lines.append("\n⚠️ LaunchAgent 미로드: {}건 — {}{}".format(len(plist), ", ".join(plist[:5]), more))

print("\n".join(lines))
print("---HAS_ISSUE---" if (miss or plist) else "---OK---")
')

HAS_ISSUE=$(echo "$SUMMARY" | grep -q "HAS_ISSUE" && echo yes || echo no)
MSG=$(echo "$SUMMARY" | sed '/^---/d')

log "$MSG"

if [[ "$HAS_ISSUE" == "yes" ]]; then
    WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"] // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "${WEBHOOK:-}" ]]; then
        PAYLOAD=$(jq -n --arg m "$MSG" '{content: $m}')
        curl -sS -X POST "$WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" > /dev/null 2>&1 || true
    fi
fi

echo "$MSG"
