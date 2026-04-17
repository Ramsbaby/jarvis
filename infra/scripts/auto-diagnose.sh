#!/usr/bin/env bash
set -euo pipefail
# auto-diagnose.sh — 크론 실패 감지 후 요약 출력
# 실패 없으면 아무 출력 없이 종료 → Discord 전송 안 됨

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
CRON_LOG="$BOT_HOME/logs/cron.log"

# FSM 기록: 실행 추적 (stdout 억제 — Discord 출력 오염 방지)
node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" ensure "auto-diagnose" "auto-diagnose" "auto-diagnose" >/dev/null 2>&1 || true
node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" transition "auto-diagnose" "running" "auto-diagnose" >/dev/null 2>&1 || true
_fsm_done=false
_fsm_cleanup() {
    if [[ "$_fsm_done" == "false" ]]; then
        node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" transition "auto-diagnose" "failed" "auto-diagnose" >/dev/null 2>&1 || true
    fi
}
trap '_fsm_cleanup' ERR EXIT

# 최근 1시간 내 FAILED/ABORTED 확인
FAILURES=$(grep -E "FAILED|ABORTED" "$CRON_LOG" 2>/dev/null \
  | awk -v cutoff="$(date -v-1H '+%F %H:%M' 2>/dev/null || date -d '-1 hour' '+%F %H:%M' 2>/dev/null)" \
    '$0 >= "[" cutoff' \
  | tail -10)

# 실패 없으면 조용히 종료
if [[ -z "$FAILURES" ]]; then
    _fsm_done=true
    trap - ERR EXIT
    node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" transition "auto-diagnose" "done" "auto-diagnose" >/dev/null 2>&1 || true
    exit 0
fi

# tasks.json 설명 로드 (태스크별 description 조회용)
TASKS_JSON="$BOT_HOME/config/tasks.json"

get_task_desc() {
  local tid="$1"
  python3 -c "
import json, sys
try:
    tasks = json.load(open('$TASKS_JSON'))
    ts = tasks.get('tasks', tasks) if isinstance(tasks, dict) else tasks
    for t in ts:
        if isinstance(t, dict) and t.get('id') == sys.argv[1]:
            print(t.get('description', ''))
            sys.exit(0)
except Exception:
    pass
" "$tid" 2>/dev/null || true
}

# 실패 태스크 중복 제거 후 포맷 출력 (python3 위임 — bash 버전 무관)
KST_TIME=$(TZ=Asia/Seoul date '+%H:%M' 2>/dev/null || date '+%H:%M')

python3 - "$FAILURES" "$TASKS_JSON" "$KST_TIME" << 'PYEOF'
import sys, json, re

raw_failures = sys.argv[1]
tasks_json_path = sys.argv[2]
kst_time = sys.argv[3]

# tasks.json에서 id→description 맵 로드
desc_map = {}
try:
    data = json.load(open(tasks_json_path))
    task_list = data.get('tasks', data) if isinstance(data, dict) else data
    for t in task_list:
        if isinstance(t, dict) and t.get('id'):
            desc_map[t['id']] = t.get('description', '')
except Exception:
    pass

# 라인 파싱 + 태스크별 중복 제거
seen = set()
entries = []
for line in raw_failures.strip().splitlines():
    ids = re.findall(r'\[([a-zA-Z0-9_-]+)\]', line)
    tid = ids[-1] if ids else ''
    if not tid or tid in seen:
        continue
    seen.add(tid)
    reason_m = re.search(r'(FAILED[^\]]*|ABORTED[^\]]*)', line)
    reason = reason_m.group(1).strip() if reason_m else 'FAILED'
    entries.append((tid, reason))

print(f"🔴 크론 태스크 실패 — {len(entries)}건 ({kst_time} KST)")
print()
for tid, reason in entries:
    desc = desc_map.get(tid, '')
    if desc:
        print(f"- `{tid}` · {desc}")
        print(f"  → {reason}")
    else:
        print(f"- `{tid}` — {reason}")
print()
print("📋 `~/jarvis/runtime/logs/cron.log` 에서 상세 확인")
PYEOF

# Failure Rule Engine 연동: 매칭 규칙이 있으면 자동 해결 제안 추가
RULE_ENGINE="${HOME}/jarvis/infra/scripts/failure-rule-engine.mjs"
if [[ -f "$RULE_ENGINE" ]]; then
    # macOS 호환: grep -P 대신 sed + tr 사용 (BSD grep은 -P 미지원)
    for _fail_line in $(echo "$FAILURES" | sed -nE 's/.*\[([a-zA-Z0-9_-]+)\].*/\1/p' | sort -u); do
        _match=$(/opt/homebrew/bin/node "$RULE_ENGINE" match "$_fail_line" 2>/dev/null || echo '{"match":null}')
        _resolution=$(echo "$_match" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('resolution',''))" 2>/dev/null || true)
        _confidence=$(echo "$_match" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('confidence',0))" 2>/dev/null || true)
        if [[ -n "$_resolution" && "$_confidence" != "0" ]]; then
            echo ""
            echo "🔧 **자동 해결 제안** (\`${_fail_line}\`, 신뢰도 ${_confidence}):"
            echo "> ${_resolution}"
        fi
    done
fi

_fsm_done=true
trap - ERR EXIT
node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" transition "auto-diagnose" "done" "auto-diagnose" >/dev/null 2>&1 || true