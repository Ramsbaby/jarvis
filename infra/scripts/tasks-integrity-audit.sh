#!/usr/bin/env bash
set -euo pipefail

# tasks-integrity-audit.sh — tasks.json + LaunchAgent 무결성 감사 (일 1회 권장)
# 하네스 엔지니어링 관점:
#   - Sensor: tasks.json enabled 태스크 script 존재 + LaunchAgent 상태 + 정책 정합
#   - Verification: PID+last_exit 조합 판정 (signal exit 128+ 은 false positive 방지)
#   - Correction: 자동 조치 없음 (리포트만). 판단은 cron-helpers _permanent_disable_task
#                 + 오너 수동 검토 (OPERATIONS.md Auto-Disable Recovery).
#   - 2026-09-04 (SELF-HEAL-PLAN 2d): tasks.json 자체의 sha256·개수·전일 대비 변경(id·필드)을
#     tasks-json-integrity.sh 로 재고 원장 "integrity" 에 남긴다. 개수 ±5·삭제 ≥5·파손은 🔴 경보,
#     해시만 바뀌면 🟡 통지. 매 실행이 ~/backup/jarvis-topology/tasks-json/ 에 백업(14일 회전).
# 원장: ${BOT_HOME}/ledger/tasks-integrity-audit.jsonl (append-only)

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
TASKS_FILE="${BOT_HOME}/config/tasks.json"
LEDGER_DIR="${BOT_HOME}/ledger"
LEDGER_FILE="${LEDGER_DIR}/tasks-integrity-audit.jsonl"

mkdir -p "$LEDGER_DIR"

log() { echo "[$(date '+%F %T')] [tasks-integrity-audit] $*"; }

if [[ ! -f "$TASKS_FILE" ]]; then
    log "ERROR: tasks.json not found: $TASKS_FILE"
    exit 1
fi

AUDIT_JSON=$(BOT_HOME="$BOT_HOME" python3 - "$TASKS_FILE" <<'PYEOF'
import json, os, sys, subprocess, re

path = sys.argv[1]
bot_home = os.environ.get('BOT_HOME', os.path.expanduser('~/.openclaw-data/runtime'))

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
com_plists = []  # com.jarvis.* = cron-sync.sh 가 tasks.json 에서 생성한 태스크 실행기 (정책 정합은 아래)
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

# ── 정책 정합 (tasks.json = 등록 SSoT, com.jarvis.<id> = cron-sync.sh 가 거기서 생성한 실행기) ──
# 2026-09-04 정정(SELF-HEAL-PLAN 2b): 이전 판정은 "com.jarvis.X + tasks.json enabled X = 이중 실행"
#   이었고 그래서 매일 99~101건을 '정책 위반'으로 보고했다. 그러나 tasks.json 을 스케줄링하는
#   별도 실행기(Nexus)는 존재하지 않는다 — cron-sync.sh(15 * * * *) 가 enabled 태스크마다
#   com.jarvis.<id>.plist 를 만들고 그 plist 가 bot-cron.sh <id> 를 부른다. 즉 그 조합은 정상이며,
#   지우면 태스크가 멈춘다(그리고 다음 cron-sync 가 다시 만든다). 진짜 이중 실행은
#   같은 태스크가 crontab 에도 걸려 있는 경우다(2026-09-04 실측 7건: validate-tasks 와 같은 기준).
tasks_enabled = {
    t['id'] for t in d.get('tasks', [])
    if t.get('id') and t.get('enabled', True) is not False
}
tasks_all = {t['id'] for t in d.get('tasks', []) if t.get('id')}
task_script_base = {}
for t in d.get('tasks', []):
    s = t.get('script') or ''
    if t.get('id') and s:
        task_script_base[t['id']] = os.path.basename(os.path.expanduser(os.path.expandvars(s)))

try:
    crontab_lines = [
        l for l in subprocess.check_output(['crontab', '-l'], text=True, timeout=5,
                                           stderr=subprocess.DEVNULL).splitlines()
        if l.strip() and not l.lstrip().startswith('#')
    ]
except Exception:
    crontab_lines = []

def crontab_hits(task_id):
    """같은 태스크를 crontab 이 따로 돌리는 줄 — bot-cron.sh <id> 호출 또는 같은 script 파일 실행."""
    base = task_script_base.get(task_id)
    hits = []
    for l in crontab_lines:
        if re.search(r'bot-cron\.sh\s+' + re.escape(task_id) + r'(\s|$)', l):
            hits.append(l)
        elif base and re.search(r'/' + re.escape(base) + r'(\s|$)', l):
            hits.append(l)
    return hits

policy_duplicate = []     # com.jarvis.X(로드) + crontab 에도 X → 진짜 이중 실행
policy_orphan_plist = []  # com.jarvis.Y + tasks.json 에 없음 → SSoT 미등록(추적 밖에서 돈다)
policy_ghost = []         # com.jarvis.Z plist 의 실행 파일이 실재하지 않음 (즉시 제거 가능)

for label in com_plists:
    task_id = label.replace('com.jarvis.', '')
    plist_path = os.path.join(plist_dir, label + '.plist')
    # plist 안의 실행 파일 경로 추출 (정적 XML 파싱). `zsh -c "... exec /path/bot-cron.sh id"` 처럼
    # 셸 래퍼로 감싼 plist 는 문자열 안의 경로 토큰을 뽑는다 — 이전엔 통째로 ghost 로 오판했다.
    try:
        xml = subprocess.check_output(
            ['plutil', '-convert', 'xml1', '-o', '-', plist_path],
            text=True, timeout=5)
        args = re.findall(r'<string>(.*?)</string>', xml)
        script = None
        for a in args:
            # 따옴표는 \x22(") \x27(') 로 쓴다 — 이 heredoc 은 $( ) 안에 있어서 macOS /bin/bash 3.2 가
            # 본문의 홑따옴표 하나를 문자열 시작으로 읽고 "unexpected EOF" 로 스크립트 전체를 거부한다
            # (2026-09-05 10:07 감사 크론 exit 2 — 9ec0ed6 에서 유입).
            for tok in re.findall(r'(?:~|/)[^\s\x22\x27<>;&|]+\.(?:sh|mjs|js|py)', a):
                script = os.path.expanduser(tok)
                break
            if script:
                break
    except Exception:
        script = None
    script_exists = bool(script) and os.path.exists(script)

    if not script_exists:
        policy_ghost.append({'label': label, 'script': script or '(unknown)'})
    elif task_id not in tasks_all:
        policy_orphan_plist.append(label)
    elif task_id in tasks_enabled:
        hits = crontab_hits(task_id)
        if hits:
            policy_duplicate.append({'label': label, 'crontab': hits[0][:160]})

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

# tasks.json 무결성 (2d) — 원장 기록 전에 돌려야 '직전 감사' 창이 맞다
INTEGRITY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tasks-json-integrity.sh"
INTEGRITY_JSON='{"level":"unknown","text":"⚪ tasks.json 무결성: 측정 실패 (tasks-json-integrity.sh)"}'
if [[ -x "$INTEGRITY_SCRIPT" ]]; then
    INTEGRITY_JSON=$(BOT_HOME="$BOT_HOME" "$INTEGRITY_SCRIPT" 2>/dev/null) || INTEGRITY_JSON='{"level":"unknown","text":"⚪ tasks.json 무결성: 측정 실패 (스크립트 오류)"}'
fi
INTEGRITY_LEVEL=$(echo "$INTEGRITY_JSON" | jq -r '.level // "unknown"')
INTEGRITY_TEXT=$(echo "$INTEGRITY_JSON" | jq -r '.text // ""')

# 원장 기록
TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS_UNIX=$(date +%s)
printf '{"ts":"%s","ts_unix":%d,"audit":%s,"integrity":%s}\n' "$TS_ISO" "$TS_UNIX" "$AUDIT_JSON" \
    "$(echo "$INTEGRITY_JSON" | jq -c 'del(.text)')" >> "$LEDGER_FILE"

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
    lines.append("\n**🔴 이중 실행 — com.jarvis plist 와 crontab 이 같은 태스크를 따로 돌림:** {}건".format(len(dup)))
    lines.append("  → 조치: crontab 줄 제거 (tasks.json → cron-sync → com.jarvis plist 가 정본 실행기)")
    for d_it in dup[:7]: lines.append("  • `{}` ← crontab: `{}`".format(d_it["label"], d_it["crontab"]))
if orphan:
    lines.append("\n**🟡 com.jarvis.* tasks.json 미등록 (추적 밖에서 도는 plist):** {}건".format(len(orphan)))
    lines.append("  → 조치: tasks.json 에 등재(같은 schedule·script) or 의도적이면 bootout")
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
MSG="${MSG}

${INTEGRITY_TEXT}"
[[ "$INTEGRITY_LEVEL" == "critical" ]] && HAS_ISSUE=yes

log "$MSG"

# 24h throttle — 동일 문제 알림 하루 1회 (2026-07-19 인프라 지혈: 94건 반복 도배 방지)
# ledger 기록(관측)은 위에서 매번 유지하고, Discord 발송만 제한한다.
THROTTLE_STATE="${HOME}/.openclaw-data/runtime/state/tasks-integrity-audit-last-alert.txt"
THROTTLE_OK=yes
if [[ -f "$THROTTLE_STATE" ]]; then
    LAST_ALERT=$(cat "$THROTTLE_STATE" 2>/dev/null || echo 0)
    [[ "$LAST_ALERT" =~ ^[0-9]+$ ]] || LAST_ALERT=0
    (( $(date +%s) - LAST_ALERT < 86400 )) && THROTTLE_OK=no
fi

if [[ "$HAS_ISSUE" == "yes" && "$THROTTLE_OK" == "yes" ]]; then
    date +%s > "$THROTTLE_STATE"
    # 2026-09-04: 직접 curl 대신 중앙 egress — JARVIS_NO_EXTERNAL=1 이면 파일 기록만 남는다 (1d)
    # shellcheck source=../lib/discord-route.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/discord-route.sh" 2>/dev/null || true
    if declare -f discord_route_raw >/dev/null 2>&1; then
        discord_route_raw "jarvis-system" "$MSG" || true
    fi
fi

echo "$MSG"