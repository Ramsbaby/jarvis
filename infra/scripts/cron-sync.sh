#!/usr/bin/env bash
# cron-sync.sh — tasks.json ↔ launchd 자동 동기화
# Usage: cron-sync.sh [--dry-run]
# 역할: tasks.json의 스케줄 항목 중 launchd plist 없는 것을 자동 생성/등록

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
TASKS_FILE="$BOT_HOME/config/effective-tasks.json"
[[ -f "$TASKS_FILE" ]] || TASKS_FILE="$BOT_HOME/config/tasks.json"
LOG="$BOT_HOME/logs/cron-sync.log"
DRY_RUN="${1:-}"

log() { echo "[$(date '+%F %T')] cron-sync: $*" | tee -a "$LOG"; }
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

python3 << PYEOF
import json, os, subprocess, sys

BOT_HOME = os.environ.get('BOT_HOME', os.path.expanduser('~/.jarvis'))
LAUNCH_AGENTS = os.path.expanduser('~/Library/LaunchAgents')
TASKS_FILE = '$TASKS_FILE'
DRY_RUN = '$DRY_RUN' == '--dry-run'

with open(TASKS_FILE) as f:
    raw = json.load(f)
tasks = raw.get('tasks', raw) if isinstance(raw, dict) else raw

def parse_schedule(cron):
    """cron 표현식 → launchd StartCalendarInterval 변환 (단순 패턴만 지원)"""
    parts = cron.strip().split()
    if len(parts) != 5:
        return None
    minute, hour, dom, month, dow = parts
    
    # */N 패턴 (반복 간격) → StartInterval
    if minute.startswith('*/') and hour == '*' and dom == '*' and month == '*' and dow == '*':
        interval = int(minute[2:]) * 60
        return ('interval', interval)
    if minute == '*' and hour.startswith('*/') and dom == '*' and month == '*' and dow == '*':
        interval = int(hour[2:]) * 3600
        return ('interval', interval)
    if minute == '*' and hour == '*' and dom == '*' and month == '*' and dow == '*' and minute.startswith('*/'):
        pass

    # 고정 시간 패턴 → StartCalendarInterval
    result = {}
    if minute.isdigit(): result['Minute'] = int(minute)
    if hour.isdigit(): result['Hour'] = int(hour)
    if dom.isdigit(): result['Day'] = int(dom)
    if month.isdigit(): result['Month'] = int(month)
    
    # 요일 (1-5 같은 범위는 단순화 생략)
    if dow.isdigit(): result['Weekday'] = int(dow)
    
    if not result:
        return None
    return ('calendar', result)

created = 0
skipped = 0

for t in tasks:
    if not isinstance(t, dict):
        continue
    task_id = t.get('id', '')
    schedule = t.get('schedule', t.get('cron', ''))
    
    # 스케줄 없거나 manual이면 skip
    if not schedule or schedule == '(manual)':
        continue
    
    # plist 레이블 결정
    label = f'com.jarvis.{task_id}'
    plist_path = os.path.join(LAUNCH_AGENTS, f'{label}.plist')
    
    # 이미 존재하면 skip
    if os.path.exists(plist_path):
        skipped += 1
        continue
    
    # 스케줄 파싱
    parsed = parse_schedule(schedule)
    if parsed is None:
        print(f'SKIP (복잡한 스케줄): {task_id} ({schedule})')
        skipped += 1
        continue
    
    # script 결정
    script_field = t.get('script', '')
    if script_field and script_field != '(none)':
        script_field = script_field.replace('~', os.path.expanduser('~'))
        prog_args = ['/bin/bash', script_field]
    else:
        prog_args = ['/bin/bash', f'{BOT_HOME}/bin/bot-cron.sh', task_id]
    
    # 스케줄 블록 생성
    if parsed[0] == 'interval':
        schedule_block = f'''  <key>StartInterval</key>
  <integer>{parsed[1]}</integer>'''
    else:
        cal = parsed[1]
        inner = ''
        for k, v in cal.items():
            inner += f'    <key>{k}</key>\n    <integer>{v}</integer>\n'
        schedule_block = f'''  <key>StartCalendarInterval</key>
  <dict>
{inner}  </dict>'''
    
    args_xml = '\n'.join(f'    <string>{a}</string>' for a in prog_args)
    plist_content = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
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

print(f'완료: 신규={created} 스킵={skipped}')
PYEOF

log "=== cron-sync 종료 ==="
