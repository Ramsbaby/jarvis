#!/usr/bin/env bash
# cron-sync.sh — tasks.json ↔ launchd 자동 동기화
# Usage: cron-sync.sh [--dry-run]
# 역할: tasks.json의 스케줄 항목 중 launchd plist 없는 것을 자동 생성/등록

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
TASKS_FILE="$BOT_HOME/config/effective-tasks.json"
[[ -f "$TASKS_FILE" ]] || TASKS_FILE="$BOT_HOME/config/tasks.json"
LOG="$BOT_HOME/logs/cron-sync.log"
DRY_RUN="${1:-}"

# log()는 >> 리다이렉트(bot-preflight.sh)와 tee 이중 기록 방지: 파일만 append
log() { echo "[$(date '+%F %T')] cron-sync: $*" >> "$LOG"; echo "[$(date '+%F %T')] cron-sync: $*"; }

# --- 동시 실행 방지 락 ---
_LOCK_FILE="/tmp/jarvis-cron-sync.lock"
if [[ -f "$_LOCK_FILE" ]]; then
    _old_pid=$(cat "$_LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$_old_pid" ]] && kill -0 "$_old_pid" 2>/dev/null; then
        echo "[$(date '+%F %T')] cron-sync: 이미 실행 중 (PID $_old_pid) — skip" >> "$LOG"
        exit 0
    fi
    rm -f "$_LOCK_FILE"
fi
echo $$ > "$_LOCK_FILE"
trap 'rm -f "$_LOCK_FILE"' EXIT
notify() {
  local webhook; webhook=$(python3 -c "import json; d=json.load(open('$BOT_HOME/config/monitoring.json')); print(d.get('webhooks',{}).get('jarvis',''))" 2>/dev/null || echo "")
  if [[ -z "$webhook" ]]; then return; fi
  python3 -c "
import json, urllib.request
payload = json.dumps({'content': '$1'}).encode()
req = urllib.request.Request('$webhook', data=payload, headers={'Content-Type':'application/json'})
urllib.request.urlopen(req, timeout=5)
" 2>/dev/null || true
}

log "=== cron-sync 시작 ==="
CREATED=0
SKIPPED=0

# 🔒 B1 복구 (2026-04-22) — heredoc 인용 경화
# 기존 `<< PYEOF` (unquoted) → bash 가 heredoc 안의 백틱/$ 를 해석.
# 증상: Python 주석의 `0 * * * *` 백틱을 command substitution 으로 해석해 매 실행 "line 45: 0: command not found" 노이즈.
# 대응: `<< 'PYEOF'` (quoted) 로 치환 차단 + TASKS_FILE/DRY_RUN 은 env export 로 전달.
export TASKS_FILE
export DRY_RUN
python3 << 'PYEOF'
import json, os, subprocess, sys

BOT_HOME = os.environ.get('BOT_HOME', os.path.expanduser('~/jarvis/runtime'))
LAUNCH_AGENTS = os.path.expanduser('~/Library/LaunchAgents')
TASKS_FILE = os.environ['TASKS_FILE']
DRY_RUN = os.environ.get('DRY_RUN', '') == '--dry-run'

with open(TASKS_FILE) as f:
    raw = json.load(f)
tasks = raw.get('tasks', raw) if isinstance(raw, dict) else raw

def _expand_field(field, lo, hi):
    """cron 필드 → 정수 리스트 전개. 지원 패턴:
       '*' → None (any), '5' → [5], '1-5' → [1..5], '*/15' → [0,15,30,45],
       '22-23' → [22,23], '1,3,5' → [1,3,5]. 실패 시 ValueError.
    """
    if field == '*':
        return None
    if field.startswith('*/'):
        step = int(field[2:])
        return list(range(lo, hi + 1, step))
    if ',' in field:
        vals = []
        for part in field.split(','):
            vals.extend(_expand_field(part, lo, hi) or [])
        return sorted(set(vals))
    if '-' in field:
        a, b = field.split('-', 1)
        return list(range(int(a), int(b) + 1))
    if field.isdigit():
        return [int(field)]
    raise ValueError(f'지원하지 않는 필드 패턴: {field}')


def parse_schedule(cron):
    """cron 표현식 → launchd StartCalendarInterval 변환.
    2026-04-22 확장: 범위(a-b) / 리스트(a,b,c) / */N 복합 패턴 지원.
    반환 형태:
      - ('interval', seconds) : StartInterval
      - ('calendar', dict)    : 단일 StartCalendarInterval
      - ('calendar_list', [dict, ...]) : 다중 StartCalendarInterval (배열)
    """
    parts = cron.strip().split()
    if len(parts) != 5:
        return None
    minute, hour, dom, month, dow = parts

    # --- */N 단순 간격 (기존 동작 보존) ---
    if minute.startswith('*/') and hour == '*' and dom == '*' and month == '*' and dow == '*':
        return ('interval', int(minute[2:]) * 60)
    if minute == '*' and hour.startswith('*/') and dom == '*' and month == '*' and dow == '*':
        return ('interval', int(hour[2:]) * 3600)

    # --- 각 필드 전개 ---
    try:
        minutes = _expand_field(minute, 0, 59)
        hours = _expand_field(hour, 0, 23)
        doms = _expand_field(dom, 1, 31)
        months = _expand_field(month, 1, 12)
        dows = _expand_field(dow, 0, 6)
    except ValueError:
        return None

    # 빈 결과 방지
    def _iter_or_none(v):
        return v if v is not None else [None]

    entries = []
    for mi in _iter_or_none(minutes):
        for ho in _iter_or_none(hours):
            for dm in _iter_or_none(doms):
                for mo in _iter_or_none(months):
                    for dw in _iter_or_none(dows):
                        d = {}
                        if mi is not None: d['Minute'] = mi
                        if ho is not None: d['Hour'] = ho
                        if dm is not None: d['Day'] = dm
                        if mo is not None: d['Month'] = mo
                        if dw is not None: d['Weekday'] = dw
                        if d:
                            entries.append(d)

    if not entries:
        return None
    if len(entries) == 1:
        return ('calendar', entries[0])
    # 폭증 방어 — 500 초과 시 skip (`0 * * * *` 같은 패턴이 */N 으로 잡혔어야 함)
    if len(entries) > 500:
        return None
    return ('calendar_list', entries)

created = 0
skipped = 0
broken = []   # 설치돼 있으나 실행 경로가 실재하지 않는 plist (2026-07-25 추가)


def _broken_program(plist_path):
    """설치된 plist 의 ProgramArguments 가 없는 파일을 가리키면 그 경로를 돌려준다.

    배경(2026-07-25): 이 동기화기는 'plist 파일이 있으면 무조건 통과'였다.
    그래서 안의 실행 경로가 깨져도 영원히 고쳐지지 않았고, 실제로 plist 18개가
    존재하지 않는 경로를 가리킨 채 방치돼 모닝브리핑·뉴스·각종 감사가 조용히 죽어 있었다.
    파일 유무만이 아니라 '가리키는 대상'까지 확인하는 것이 이 함수의 목적이다.
    (발견만 하고 자동 재생성은 하지 않는다 — 손으로 조정한 plist 를 덮어쓸 수 있어서)
    """
    try:
        out = subprocess.run(['plutil', '-convert', 'json', '-o', '-', plist_path],
                             capture_output=True, timeout=10)
        if out.returncode != 0:
            return '(plist 파싱 불가 — 파일 손상 의심)'
        args = json.loads(out.stdout).get('ProgramArguments') or []
    except Exception:
        return None
    for a in args:
        if not isinstance(a, str) or not a.startswith('/'):
            continue
        if a in ('/bin/bash', '/bin/sh', '/bin/zsh', '/usr/bin/env'):
            continue
        if not os.path.exists(a):
            return a
    return None


for t in tasks:
    if not isinstance(t, dict):
        continue
    task_id = t.get('id', '')
    schedule = t.get('schedule', t.get('cron', ''))
    
    # enabled: false 태스크는 plist 생성 안 함 (Nexus SSoT 정책)
    if t.get('enabled') is False:
        continue

    # 스케줄 없거나 manual이면 skip
    if not schedule or schedule == '(manual)':
        continue
    
    # plist 레이블 결정
    label = f'com.jarvis.{task_id}'
    plist_path = os.path.join(LAUNCH_AGENTS, f'{label}.plist')
    
    # 이미 존재하면 skip — 단, 가리키는 실행 파일이 실재하는지는 확인한다
    if os.path.exists(plist_path):
        bad = _broken_program(plist_path)
        if bad:
            print(f'BROKEN (실행 경로 없음): {label} -> {bad}')
            broken.append((label, bad))
        skipped += 1
        continue
    
    # 스케줄 파싱
    parsed = parse_schedule(schedule)
    if parsed is None:
        print(f'SKIP (복잡한 스케줄): {task_id} ({schedule})')
        skipped += 1
        continue
    
    # script 결정 — .mjs/.js 는 node, 그 외는 bash
    # 🔒 2층 방어막 — output:discord|both|file+discord 태스크는 bot-cron.sh 경유 강제 (2026-04-22 P2 도입)
    # Nexus 디스패처(bot-cron.sh)를 거쳐야 output:discord 지시가 수행됨.
    # 직접 호출 패턴이 생성 시점에 애초에 불가능하게 차단.
    outputs = t.get('output', []) or []
    if not isinstance(outputs, list):
        outputs = [outputs]
    needs_dispatcher = any(
        isinstance(o, str) and (
            o == 'discord' or o == 'both' or ('discord' in o)
        ) for o in outputs
    )

    script_field = t.get('script', '')
    if needs_dispatcher:
        # output:discord 계열은 스크립트 필드 무관, 무조건 bot-cron.sh 경유
        prog_args = ['/bin/bash', f'{BOT_HOME}/bin/bot-cron.sh', task_id]
    elif script_field and script_field != '(none)':
        script_field = script_field.replace('~', os.path.expanduser('~'))
        if script_field.endswith('.mjs') or script_field.endswith('.js'):
            # node 로 실행 (launchd 가 shebang 못 읽으므로 명시)
            prog_args = ['/usr/bin/env', 'node', script_field]
        else:
            prog_args = ['/bin/bash', script_field]
    else:
        prog_args = ['/bin/bash', f'{BOT_HOME}/bin/bot-cron.sh', task_id]
    
    # 스케줄 블록 생성
    if parsed[0] == 'interval':
        schedule_block = f'''  <key>StartInterval</key>
  <integer>{parsed[1]}</integer>'''
    elif parsed[0] == 'calendar':
        cal = parsed[1]
        inner = ''
        for k, v in cal.items():
            inner += f'    <key>{k}</key>\n    <integer>{v}</integer>\n'
        schedule_block = f'''  <key>StartCalendarInterval</key>
  <dict>
{inner}  </dict>'''
    else:  # 'calendar_list' — 다중 시점 (2026-04-22 범위 패턴 지원)
        dicts = ''
        for cal in parsed[1]:
            inner = ''
            for k, v in cal.items():
                inner += f'      <key>{k}</key>\n      <integer>{v}</integer>\n'
            dicts += f'    <dict>\n{inner}    </dict>\n'
        schedule_block = f'''  <key>StartCalendarInterval</key>
  <array>
{dicts}  </array>'''
    
    args_xml = '\n'.join(f'    <string>{a}</string>' for a in prog_args)
    # 🔏 1층 방어막 — plist 생성 서명 강제 (2026-04-22 P1 도입)
    # launchagents-audit 가 이 서명 없는 plist 를 unsigned_plist 로 경보함.
    # 서명 포맷: "JARVIS_GENERATED_BY: cron-sync.sh v1.0 @ <kst_ts> source: tasks.json#<task_id>"
    import datetime as _dt
    sign_ts = _dt.datetime.now().astimezone().strftime('%Y-%m-%dT%H:%M:%S%z')
    signature = f'<!-- JARVIS_GENERATED_BY: cron-sync.sh v1.0 @ {sign_ts} source: tasks.json#{task_id} -->'
    plist_content = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
{signature}
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
{args_xml}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOT_HOME</key>
    <string>{BOT_HOME}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>{os.path.expanduser("~")}</string>
  </dict>
{schedule_block}
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>{BOT_HOME}/logs/{task_id}.log</string>
  <key>StandardErrorPath</key>
  <string>{BOT_HOME}/logs/{task_id}-err.log</string>
</dict>
</plist>'''
    
    if DRY_RUN:
        print(f'[DRY] 생성 예정: {label}.plist ({schedule})')
        created += 1
        continue
    
    with open(plist_path, 'w') as f:
        f.write(plist_content)
    
    # launchctl 등록
    ret = subprocess.run(['launchctl', 'load', plist_path], capture_output=True)
    if ret.returncode == 0:
        print(f'CREATED+LOADED: {label} ({schedule})')
        created += 1
    else:
        print(f'CREATED (load 실패): {label} — {ret.stderr.decode().strip()}')
        created += 1

print(f'완료: 신규={created} 스킵={skipped} 깨진경로={len(broken)}')
if broken:
    print('')
    print(f'🚨 실행 경로가 없는 plist {len(broken)}건 — 이 자동화들은 지금 조용히 실패하고 있습니다:')
    for lbl, bad in broken[:20]:
        print(f'   - {lbl} -> {bad}')
    if len(broken) > 20:
        print(f'   ... 외 {len(broken) - 20}건')
    print('   조치: plist 의 ProgramArguments 경로를 정본으로 교정 후 bootout+bootstrap 재적재')
PYEOF

log "=== cron-sync 종료 ==="