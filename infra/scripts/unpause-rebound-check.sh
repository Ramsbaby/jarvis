#!/usr/bin/env bash
# unpause-rebound-check.sh — unpause 후 재-paused 자동 감시
#
# Why: 정합화 Phase 2c에서 4개 task를 unpause + failures reset만 함 (땜질 우려).
#      근본 원인 미수정 시 며칠 내 다시 paused될 가능성. 이를 자동 감지하면
#      "땜질 검증 실패"를 명시적으로 알림 → 진짜 fix 유도.
#
# Usage: tasks.json에 등록 (schedule: "23 9 * * *", 매일 09:23)
# 산출물: ~/.jarvis/ledger/unpause-rebound.jsonl
#
# 로직:
#   1. cron-manager.json의 paused 객체 = 현재 paused task 목록
#   2. policy-fix-disable.jsonl에서 "action":"unpause" 기록 = 우리가 unpause한 task
#   3. unpause했는데 다시 paused면 → REBOUND 감지 → Discord 알람 + ledger
#   4. 7일 이상 안정적이면 → STABLE 마킹 (한 번만)

set -euo pipefail

MGR="${HOME}/.jarvis/state/cron-manager.json"
DISABLE_LEDGER="${HOME}/.jarvis/ledger/policy-fix-disable.jsonl"
REBOUND_LEDGER="${HOME}/.jarvis/ledger/unpause-rebound.jsonl"
CONFIG="${HOME}/.jarvis/config/monitoring.json"

mkdir -p "$(dirname "$REBOUND_LEDGER")"

if [[ ! -f "$MGR" ]] || [[ ! -f "$DISABLE_LEDGER" ]]; then
  echo "[unpause-rebound] required files missing — skip"
  exit 0
fi

TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Python으로 핵심 로직 (jq보다 가독성)
python3 - "$MGR" "$DISABLE_LEDGER" "$REBOUND_LEDGER" "$TS_ISO" << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone, timedelta

mgr_path, ledger_path, rebound_path, ts_iso = sys.argv[1:5]

with open(mgr_path) as f:
    mgr = json.load(f)
currently_paused = set(mgr.get('paused', {}).keys())

# unpause 기록 추출 (가장 최근만)
unpaused = {}  # task_id -> {ts, reason}
with open(ledger_path) as f:
    for line in f:
        try:
            d = json.loads(line)
        except:
            continue
        if d.get('action') == 'unpause':
            tid = d.get('task_id')
            if tid:
                unpaused[tid] = {'ts': d.get('ts'), 'reason': d.get('reason', '')}

# 이전 rebound 기록 (중복 알람 방지)
already_alerted = set()
already_stable = set()
if os.path.exists(rebound_path):
    with open(rebound_path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except:
                continue
            if d.get('status') == 'rebound':
                already_alerted.add(d.get('task_id'))
            elif d.get('status') == 'stable':
                already_stable.add(d.get('task_id'))

# 분류
rebounds = []
stables = []
now = datetime.now(timezone.utc)
for tid, info in unpaused.items():
    if tid in currently_paused:
        if tid not in already_alerted:
            rebounds.append({'task_id': tid, 'unpaused_at': info['ts'], 'reason': info['reason']})
    else:
        # 7일 이상 안정 + 아직 stable 마킹 안 했으면
        try:
            unp_ts = datetime.fromisoformat(info['ts'].replace('Z', '+00:00'))
            if (now - unp_ts) >= timedelta(days=7) and tid not in already_stable:
                stables.append({'task_id': tid, 'unpaused_at': info['ts']})
        except:
            pass

# ledger 기록
new_lines = []
for r in rebounds:
    new_lines.append(json.dumps({
        'ts': ts_iso, 'status': 'rebound', 'task_id': r['task_id'],
        'unpaused_at': r['unpaused_at'], 'note': '땜질 검증 실패 — 근본 원인 수정 필요',
    }, ensure_ascii=False))
for s in stables:
    new_lines.append(json.dumps({
        'ts': ts_iso, 'status': 'stable', 'task_id': s['task_id'],
        'unpaused_at': s['unpaused_at'], 'note': '7일 안정 — fix 검증됨',
    }, ensure_ascii=False))

if new_lines:
    with open(rebound_path, 'a') as f:
        for l in new_lines:
            f.write(l + '\n')

# 출력
if rebounds:
    print(f'[unpause-rebound] 🔴 REBOUND {len(rebounds)}건:')
    for r in rebounds:
        print(f"  - {r['task_id']} (unpaused_at={r['unpaused_at'][:10]})")
if stables:
    print(f'[unpause-rebound] ✅ STABLE {len(stables)}건 (7일 검증 완료):')
    for s in stables:
        print(f"  - {s['task_id']}")
if not rebounds and not stables:
    print('[unpause-rebound] no new events')

# Discord 알림 (rebound만)
if rebounds:
    config_path = os.path.expanduser('~/.jarvis/config/monitoring.json')
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        webhook = cfg.get('webhooks', {}).get('jarvis-system')
        if webhook:
            import urllib.request
            lines = ['🔴 **unpause 후 재-paused 감지 (땜질 검증 실패)**\n']
            for r in rebounds:
                lines.append(f"  • `{r['task_id']}` — unpaused {r['unpaused_at'][:10]} → 다시 paused")
            lines.append('\n근본 원인 수정 필요 — `cron-manager.json` paused 사유 + cron.log 추적')
            msg = '\n'.join(lines)
            data = json.dumps({'content': msg}).encode()
            req = urllib.request.Request(webhook, data=data, headers={'Content-Type': 'application/json'})
            urllib.request.urlopen(req, timeout=5)
    except Exception as e:
        print(f'[unpause-rebound] discord notify failed: {e}', file=sys.stderr)
PYEOF
