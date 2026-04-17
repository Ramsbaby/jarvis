#!/usr/bin/env bash
set -euo pipefail

# tasks-integrity-audit.sh — tasks.json + LaunchAgent 무결성 감사 (일 1회 권장)
# 하네스 엔지니어링 관점:
#   - Sensor: tasks.json enabled 태스크 script 존재 + LaunchAgent 상태 + 정책 정합
#   - Verification: PID+last_exit 조합 판정 (signal exit 128+ 은 false positive 방지)
#   - Correction: 자동 조치 없음 (리포트만). 판단은 cron-helpers _permanent_disable_task
#                 + 오너 수동 검토 (OPERATIONS.md Auto-Disable Recovery).
# 원장: ${BOT_HOME}/ledger/tasks-integrity-audit.jsonl (append-only)

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
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

AUDIT_JSON=$(BOT_HOME="$BOT_HOME" python3 - "$TASKS_FILE" <<'PYEOF'
import json, os, sys, subprocess, re

path = sys.argv[1]
bot_home = os.environ.get('BOT_HOME', os.path.expanduser('~/jarvis/runtime'))

with open(path) as f:
    d = json.load(f)

# ── tasks.json sensor ─────────────────────────────────────────────────────
missing_scripts = []
auto_disabled_pending_review = []  # 이전에 auto-disable 된 채 아직 복원 안 됨
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
    if auto_dis and not exists:
        auto_disabled_pending_review.append({'id': tid, 'script': script})

# ── LaunchAgent sensor ────────────────────────────────────────────────────
plist_dir = os.path.expanduser('~/Library/LaunchAgents')
ai_plists = []   # ai.jarvis.*  = 코어 데몬
com_plists = []  # com.jarvis.* = 과거 SSoT 위반, 정리 대상
if os.path.isdir(plist_dir):
    for n in os.listdir(plist_dir):
        if not n.endswith('.plist'):
            continue
        label = n[:-6]  # strip .plist
        if label.startswith('ai.jarvis.'):
            ai_plists.append(label)
        elif label.startswith('com.jarvis.'):
            com_plists.append(label)

# launchctl list → (pid_str, last_exit) 매핑
status_map = {}
try:
    out = subprocess.check_output(['launchctl', 'list'], text=True, timeout=10)
    for line in out.splitlines():
        parts = line.split('\t')
        if len(parts) >= 3:
            pid_str, status_str, label = parts[0], parts[1], parts[2]
            try: s = int(status_str)
            except: s = 0
            status_map[label] = (pid_str, s)
except Exception:
    pass

def pid_running(pid_str):
    """launchctl list 의 PID 컬럼이 유효 정수인가 (현재 실행 중인가)."""
    return pid_str not in ('-', '') and pid_str.isdigit() and int(pid_str) > 0

def is_signal_exit(code):
    """128~255는 signal 종료 (SIGTERM=143 등). KeepAlive=true + kickstart 는 합법."""
    return 128 <= code <= 255

# ai.jarvis.* 판정: PID 있으면 정상, 없으면 last_exit 판정 (signal exit 제외)
ai_loaded = [l for l in ai_plists if l in status_map]
ai_unloaded = [l for l in ai_plists if l not in status_map]
ai_failing = []
for l in ai_loaded:
    pid_str, status = status_map[l]
    if pid_running(pid_str):
        continue  # 현재 실행 중 → 정상
    if status > 0 and not is_signal_exit(status):
        ai_failing.append({'label': l, 'last_exit': status, 'pid': pid_str})

# ── 정책 정합 (CLAUDE.md: SSoT = Nexus tasks.json, LaunchAgent는 코어 데몬만) ──
nexus_enabled = {
    t['id'] for t in d.get('tasks', [])
    if t.get('id') and t.get('enabled', True) is not False
}
nexus_all = {t['id'] for t in d.get('tasks', []) if t.get('id')}

policy_duplicate = []   # com.jarvis.X + tasks.json 에 enabled X → 이중 실행
policy_orphan_plist = []  # com.jarvis.Y + tasks.json 에 없음 → Nexus 미등록
policy_ghost = []       # com.jarvis.Z plist 의 참조 스크립트가 없음 (즉시 제거 가능)

for label in com_plists:
    task_id = label.replace('com.jarvis.', '')
    plist_path = os.path.join(plist_dir, label + '.plist')
    # plist 안의 script 경로 추출 (정적 XML 파싱)
    try:
        xml = subprocess.check_output(
            ['plutil', '-convert', 'xml1', '-o', '-', plist_path],
            text=True, timeout=5)
        args = re.findall(r'<string>(.*?)</string>', xml)
        script = next((a for a in args if ('.sh' in a or '.mjs' in a or '.js' in a) and '/' in a), None)
    except Exception:
        script = None
    script_exists = bool(script) and os.path.exists(script)

    if not script_exists:
        policy_ghost.append({'label': label, 'script': script or '(unknown)'})
    elif task_id in nexus_enabled:
        policy_duplicate.append(label)
    elif task_id not in nexus_all:
        policy_orphan_plist.append(label)

# ── 최종 리포트 ───────────────────────────────────────────────────────────
report = {
    'enabled_total': total_enabled,
    'missing_scripts': missing_scripts,
    'auto_disabled_pending_review': auto_disabled_pending_review,
    'ai_plist_total': len(ai_plists),
    'ai_plist_loaded': len(ai_loaded),
    'ai_plist_unloaded': ai_unloaded,
    'ai_plist_failing': ai_failing,
    'com_plist_total': len(com_plists),
    'policy_duplicate': policy_duplicate,
    'policy_orphan_plist': policy_orphan_plist,
    'policy_ghost': policy_ghost,
}
print(json.dumps(report, ensure_ascii=False))
PYEOF
)

# 원장 기록
TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS_UNIX=$(date +%s)
printf '{"ts":"%s","ts_unix":%d,"audit":%s}\n' "$TS_ISO" "$TS_UNIX" "$AUDIT_JSON" >> "$LEDGER_FILE"

# 사람이 읽을 요약 + Discord 알림 (문제 있을 때만)
SUMMARY=$(echo "$AUDIT_JSON" | python3 -c '
import json, sys
a = json.load(sys.stdin)
miss = a["missing_scripts"]
ai_un = a["ai_plist_unloaded"]
ai_fail = a["ai_plist_failing"]
pending = a["auto_disabled_pending_review"]
dup = a["policy_duplicate"]
orphan = a["policy_orphan_plist"]
ghost = a["policy_ghost"]

lines = []
lines.append("📋 **tasks-integrity-audit**")
lines.append("enabled 태스크 {}건 / 누락 스크립트 {}건".format(a["enabled_total"], len(miss)))
lines.append("ai.jarvis.* LaunchAgent {}/{} 로드 / 실패 {}건".format(a["ai_plist_loaded"], a["ai_plist_total"], len(ai_fail)))
lines.append("com.jarvis.* 정책 정합: 활성 {}건 / 중복 {}건 / orphan {}건 / ghost {}건".format(a["com_plist_total"], len(dup), len(orphan), len(ghost)))

if miss:
    lines.append("\n**🔴 누락 스크립트 (auto-disable 대상):**")
    for m in miss[:10]: lines.append("  • `{}` → `{}`".format(m["id"], m["script"]))
if ai_fail:
    lines.append("\n**🔴 LaunchAgent 실행 실패 (PID 없음 + last_exit>0, signal exit 제외):**")
    for f in ai_fail[:10]: lines.append("  • `{}` (exit={}, pid={})".format(f["label"], f["last_exit"], f["pid"]))
if ghost:
    lines.append("\n**🔴 com.jarvis.* ghost plist (참조 스크립트 없음):** {}건".format(len(ghost)))
    lines.append("  → 조치: `launchctl bootout` + plist 백업 후 삭제 (안전)")
    for g in ghost[:5]: lines.append("  • `{}`".format(g["label"]))
if dup:
    lines.append("\n**🔴 정책 위반 — 이중 실행 (com.jarvis + Nexus 모두 enabled):** {}건".format(len(dup)))
    lines.append("  → 조치: com.jarvis plist 제거 (Nexus tasks.json SSoT)")
    for d_lbl in dup[:5]: lines.append("  • `{}`".format(d_lbl))
if orphan:
    lines.append("\n**🟡 com.jarvis.* Nexus 미등록 (단발 plist):** {}건".format(len(orphan)))
    lines.append("  → 조치: tasks.json 이관 or 의도적이면 유지 판단")
    for o_lbl in orphan[:5]: lines.append("  • `{}`".format(o_lbl))
if pending:
    lines.append("\n⚪ auto-disable 후 복원 대기: {}건 (원인 해결 시 OPERATIONS.md 복구 절차 참조)".format(len(pending)))
if ai_un:
    more = "..." if len(ai_un) > 5 else ""
    lines.append("\n⚠️ ai.jarvis.* 미로드: {}건 — {}{}".format(len(ai_un), ", ".join(ai_un[:5]), more))

print("\n".join(lines))
print("---HAS_ISSUE---" if (miss or ai_fail or ghost or dup or ai_un or orphan) else "---OK---")
')

HAS_ISSUE=$(echo "$SUMMARY" | grep -q "HAS_ISSUE" && echo yes || echo no)
MSG=$(echo "$SUMMARY" | sed '/^---/d')

log "$MSG"

if [[ "$HAS_ISSUE" == "yes" ]]; then
    WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"] // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "${WEBHOOK:-}" ]]; then
        PAYLOAD=$(jq -n --arg m "$MSG" '{content: $m, allowed_mentions: {parse: []}}')
        curl -sS -X POST "$WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" >/dev/null 2>&1 || true
    fi
fi

echo "$MSG"