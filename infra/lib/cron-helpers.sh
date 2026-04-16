#!/usr/bin/env bash
# cron-helpers.sh — 크론 wrapper 공용 헬퍼 (SSoT)
#
# 사용: jarvis-cron.sh / bot-cron.sh 등 어떤 wrapper에서도 동일 source.
#   # 상단에서 BOT_HOME 정의 후
#   source "${BOT_HOME}/lib/cron-helpers.sh"
#
# 제공 함수:
#   _fsm_discord_alert <msg>
#       → Discord jarvis-system 채널에 webhook 전송. 실패는 조용히 삼킴 (알림 실패가
#         본 작업을 막지 않도록).
#   _ledger_append <file> <json_fragment>
#       → append-only 원장 기록. 호출자는 이미 조합된 JSON 한 줄을 넘긴다.
#   _permanent_disable_task <task_id> <reason> <detail> [source_tag]
#       → tasks.json 에서 해당 태스크를 enabled:false + _auto_disabled:true 로 전환,
#         auto-disable 원장 append, Discord 알림. flock 으로 동시성 보호.
#         실패 시 return 1 (호출부는 반드시 명시적으로 로그).
#
# 전제: `jq`, `python3`, `curl` 가용. BOT_HOME 정의 완료. `log` 함수가 wrapper에 있음.

# idempotent — 여러 번 source 되어도 재정의만 수행
_CRON_HELPERS_LOADED=1

_fsm_discord_alert() {
    local msg="$1"
    local webhook_url
    webhook_url=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"] // empty' \
        "${BOT_HOME}/config/monitoring.json" 2>/dev/null || true)
    if [[ -n "${webhook_url:-}" ]]; then
        local payload
        payload=$(jq -n --arg m "$msg" '{content: $m, allowed_mentions: {parse: []}}')
        curl -sS -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null 2>&1 || true
    fi
}

_ledger_append() {
    local file="$1" line="$2"
    local dir
    dir=$(dirname "$file")
    mkdir -p "$dir"
    printf '%s\n' "$line" >> "$file" 2>/dev/null || true
}

# 구조적 실패(script-not-found/not-executable) 감지 시 tasks.json auto-disable.
# Why: transient 실패가 아닌 영구 실패는 서킷브레이커 3회 대기 무의미. cron.log
#      오염 방지 + Discord 알림 + append-only 원장 기록.
_permanent_disable_task() {
    local tid="$1" reason="$2" detail="${3:-}" source_tag="${4:-cron}"
    local tasks_file="${BOT_HOME}/config/tasks.json"
    local ledger_dir="${BOT_HOME}/ledger"
    local ledger_file="${ledger_dir}/auto-disable.jsonl"
    local now_iso now_ts
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    now_ts=$(date +%s)

    python3 - "$tasks_file" "$tid" "$reason" "$detail" "$now_iso" <<'PYEOF' || return 1
import json, sys, os, fcntl
path, tid, reason, detail, now = sys.argv[1:6]
lock_path = path + '.lock'
with open(lock_path, 'w') as lockf:
    fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
    with open(path) as f: d = json.load(f)
    updated = False
    for t in d.get('tasks', []):
        if t.get('id') == tid:
            t['enabled'] = False
            t['_auto_disabled'] = True
            t['_disabled_reason'] = f'{reason}: {detail} — auto-disabled at {now}'
            updated = True
            break
    if not updated:
        sys.stderr.write(f'WARN: task id {tid} not found in {path}\n')
        sys.exit(2)
    tmp = path + '.autodisable.tmp'
    with open(tmp, 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)
PYEOF

    local ledger_line
    ledger_line=$(printf '{"ts":"%s","ts_unix":%d,"task_id":"%s","reason":"%s","detail":"%s","source":"%s"}' \
        "$now_iso" "$now_ts" "$tid" "$reason" "$detail" "$source_tag")
    _ledger_append "$ledger_file" "$ledger_line"

    _fsm_discord_alert "🚨 **태스크 auto-disable** — \`${tid}\`
사유: ${reason} | 상세: \`${detail}\`
복원: 원인 해결 후 \`infra/docs/OPERATIONS.md\` 의 Auto-Disable Recovery 체크리스트 참조"
}
