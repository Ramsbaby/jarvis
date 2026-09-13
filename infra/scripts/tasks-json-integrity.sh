#!/usr/bin/env bash
set -euo pipefail
# tasks-json-integrity.sh — tasks.json 해시·개수 기록 + 직전 백업 대비 변경 감지 + 백업(14일 회전)
# SELF-HEAL-PLAN 2d (2026-09-04). tasks-integrity-audit.sh 가 매일 10:07 호출하고, 단독 실행도 된다.
#
# 배경: 코더 자가치유 루프가 runtime/ 을 통째로 날린 9/2 사고 뒤에도 tasks.json 이 바뀌면 아무도 몰랐다.
#   "설정 변조 감지 시간 = 무한" 을 ≤24h 로 내리는 센서. 자동 조치는 없다 — 감지·백업·원장만.
#
# 판정(level):
#   critical — 파일 없음/파싱 실패, 개수 변화 |Δ|≥5, 삭제된 태스크 ≥5
#   notice   — 해시가 바뀜(무엇이 바뀌었는지 id·필드 단위로 적음)
#   ok       — 직전 백업과 동일
# 원인 단서(evidence): mtime, 창(직전 감사~지금) 안의 코더 활동 줄 수, 쓰기 차단 원장 건수
#   (tasks.json 은 gitignore 라 커밋은 없다 — 세션 단서로 대신한다)
#
# 출력: stdout JSON 1줄. 텍스트 요약은 --text.
# 백업: ${JARVIS_TASKS_BACKUP_DIR:-~/backup/jarvis-topology/tasks-json}/tasks-YYYYMMDD-HHMMSS.json
#   내용이 직전 백업과 같으면 새로 쓰지 않는다. 14일 지난 것은 지우되 최신 1개는 항상 남긴다.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
TASKS_FILE="${JARVIS_TASKS_FILE:-${BOT_HOME}/config/tasks.json}"
BACKUP_DIR="${JARVIS_TASKS_BACKUP_DIR:-${HOME}/backup/jarvis-topology/tasks-json}"
LEDGER_FILE="${BOT_HOME}/ledger/tasks-integrity-audit.jsonl"
CODER_LOG="${BOT_HOME}/logs/jarvis-coder.log"
GUARD_LEDGER="${BOT_HOME}/state/runtime-guard.jsonl"
RETAIN_DAYS="${JARVIS_TASKS_BACKUP_DAYS:-14}"
MODE="${1:-}"

mkdir -p "$BACKUP_DIR"

TASKS_FILE="$TASKS_FILE" BACKUP_DIR="$BACKUP_DIR" LEDGER_FILE="$LEDGER_FILE" CODER_LOG="$CODER_LOG" \
GUARD_LEDGER="$GUARD_LEDGER" RETAIN_DAYS="$RETAIN_DAYS" MODE="$MODE" python3 - <<'PYEOF'
import glob, hashlib, json, os, sys, time
from datetime import datetime, timezone

tasks_file = os.environ['TASKS_FILE']
backup_dir = os.environ['BACKUP_DIR']
ledger_file = os.environ['LEDGER_FILE']
coder_log = os.environ['CODER_LOG']
guard_ledger = os.environ['GUARD_LEDGER']
retain_days = int(os.environ['RETAIN_DAYS'])
mode = os.environ['MODE']
now = time.time()

def emit(rep):
    if mode == '--text':
        print(rep['text'])
    else:
        print(json.dumps(rep, ensure_ascii=False))
    sys.exit(0)

def sha(b): return hashlib.sha256(b).hexdigest()

def task_index(doc):
    out = {}
    for t in doc.get('tasks', []):
        tid = t.get('id')
        if tid: out[tid] = t
    return out

# ── 현재 파일 ──────────────────────────────────────────────────────────────
rep = {'sha256': None, 'task_count': None, 'enabled_count': None, 'mtime': None,
       'prev_sha256': None, 'prev_count': None, 'count_delta': None,
       'added': [], 'removed': [], 'changed': [], 'baseline': None, 'backup_written': None,
       'evidence': {}, 'level': 'ok', 'reasons': []}
try:
    raw = open(tasks_file, 'rb').read()
    doc = json.loads(raw)
    idx = task_index(doc)
except FileNotFoundError:
    rep.update(level='critical', reasons=['tasks.json 없음: %s' % tasks_file])
    rep['text'] = '🔴 **tasks.json 무결성**: 파일이 없습니다 — %s' % tasks_file
    emit(rep)
except Exception as e:
    rep.update(level='critical', reasons=['tasks.json 파싱 실패: %s' % e])
    rep['text'] = '🔴 **tasks.json 무결성**: JSON 파싱 실패 — %s' % e
    emit(rep)

rep['sha256'] = sha(raw)
rep['task_count'] = len(idx)
rep['enabled_count'] = sum(1 for t in idx.values() if t.get('enabled', True) is not False and not t.get('disabled', False))
mtime = os.path.getmtime(tasks_file)
rep['mtime'] = datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S')

# ── 직전 원장(전일 감사) ────────────────────────────────────────────────────
prev_ts = None
try:
    with open(ledger_file) as f:
        for line in f:
            try: r = json.loads(line)
            except Exception: continue
            if 'ts_unix' in r: prev_ts = r['ts_unix']
            integ = r.get('integrity') or {}
            if integ.get('sha256'):
                rep['prev_sha256'] = integ['sha256']; rep['prev_count'] = integ.get('task_count')
except FileNotFoundError:
    pass

# ── 직전 백업(기준선) ──────────────────────────────────────────────────────
def list_backups():
    # 이름(초 단위)이 아니라 mtime(나노초) 순 — 같은 초에 여러 번 써도 '직전' 이 맞다
    return sorted(glob.glob(os.path.join(backup_dir, 'tasks-*.json')), key=lambda p: (os.stat(p).st_mtime_ns, p))

backups = list_backups()
base_idx, base_sha = None, None
if backups:
    try:
        braw = open(backups[-1], 'rb').read()
        base_idx = task_index(json.loads(braw)); base_sha = sha(braw)
        rep['baseline'] = os.path.basename(backups[-1])
    except Exception as e:
        rep['reasons'].append('기준선 백업 읽기 실패: %s' % e)
if rep['prev_count'] is None and base_idx is not None:
    rep['prev_count'] = len(base_idx)
if rep['prev_sha256'] is None and base_sha:
    rep['prev_sha256'] = base_sha

# ── 차이 계산 ───────────────────────────────────────────────────────────────
if base_idx is not None:
    rep['added'] = sorted(set(idx) - set(base_idx))
    rep['removed'] = sorted(set(base_idx) - set(idx))
    for tid in sorted(set(idx) & set(base_idx)):
        a, b = base_idx[tid], idx[tid]
        if a != b:
            keys = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
            rep['changed'].append({'id': tid, 'keys': keys})
if rep['prev_count'] is not None:
    rep['count_delta'] = rep['task_count'] - rep['prev_count']

# ── 판정 ────────────────────────────────────────────────────────────────────
hash_changed = bool(rep['prev_sha256']) and rep['prev_sha256'] != rep['sha256']
if rep['count_delta'] is not None and abs(rep['count_delta']) >= 5:
    rep['level'] = 'critical'; rep['reasons'].append('태스크 개수 %+d (%d→%d)' % (rep['count_delta'], rep['prev_count'], rep['task_count']))
if len(rep['removed']) >= 5:
    rep['level'] = 'critical'; rep['reasons'].append('태스크 %d개 삭제' % len(rep['removed']))
if rep['level'] != 'critical' and hash_changed:
    rep['level'] = 'notice'; rep['reasons'].append('해시 변경')
if rep['prev_sha256'] is None:
    rep['reasons'].append('기준선 없음 (첫 실행) — 이번 상태를 기준선으로 백업')

# ── 원인 단서: 창(직전 감사~지금) 안의 활동 ─────────────────────────────────
ev = rep['evidence']
win_start = prev_ts or (now - 86400)
ev['window_start'] = datetime.fromtimestamp(win_start).strftime('%Y-%m-%d %H:%M:%S')
ev['mtime_in_window'] = mtime >= win_start
coder_lines = 0
try:
    for line in open(coder_log, errors='replace'):
        if '큐 비어있음' in line or not line.startswith('['): continue
        try:
            ts = datetime.strptime(line[1:20], '%Y-%m-%d %H:%M:%S').timestamp()
        except ValueError:
            continue
        if ts >= win_start: coder_lines += 1
except FileNotFoundError:
    pass
ev['coder_activity_lines'] = coder_lines
guard_blocks = 0
try:
    for line in open(guard_ledger, errors='replace'):
        try: r = json.loads(line)
        except Exception: continue
        ts = r.get('ts', '')
        try:
            t = datetime.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
        if t >= win_start: guard_blocks += 1
except FileNotFoundError:
    pass
ev['guard_blocks'] = guard_blocks

# ── 백업 + 회전 ─────────────────────────────────────────────────────────────
if base_sha != rep['sha256']:
    # 같은 초에 두 번 써도 서로 덮지 않도록 해시 앞 8자를 붙인다
    name = 'tasks-%s-%s.json' % (datetime.now().strftime('%Y%m%d-%H%M%S'), rep['sha256'][:8])
    tmp = os.path.join(backup_dir, '.' + name + '.tmp')
    with open(tmp, 'wb') as f: f.write(raw)
    os.replace(tmp, os.path.join(backup_dir, name))
    rep['backup_written'] = name
    backups = list_backups()
pruned = 0
for p in backups[:-1]:  # 최신 1개는 항상 남긴다
    if now - os.path.getmtime(p) > retain_days * 86400:
        os.remove(p); pruned += 1
rep['pruned'] = pruned
rep['backup_total'] = len(list_backups())

# ── 텍스트 요약 ─────────────────────────────────────────────────────────────
icon = {'ok': '🟢', 'notice': '🟡', 'critical': '🔴'}[rep['level']]
lines = ['%s **tasks.json 무결성**: %s' % (icon, ', '.join(rep['reasons']) or '직전 기준선과 동일')]
lines.append('태스크 %d건(enabled %d) · sha256 %s · 수정 %s · 백업 %d개%s' % (
    rep['task_count'], rep['enabled_count'], rep['sha256'][:12], rep['mtime'], rep['backup_total'],
    ' (+%s)' % rep['backup_written'] if rep['backup_written'] else ''))
if rep['added']: lines.append('  ＋ 추가 %d: %s' % (len(rep['added']), ', '.join('`%s`' % i for i in rep['added'][:10])))
if rep['removed']: lines.append('  － 삭제 %d: %s' % (len(rep['removed']), ', '.join('`%s`' % i for i in rep['removed'][:10])))
if rep['changed']:
    lines.append('  ± 변경 %d:' % len(rep['changed']))
    for c in rep['changed'][:10]:
        lines.append('    • `%s` (%s)' % (c['id'], ', '.join(c['keys'])))
    if len(rep['changed']) > 10: lines.append('    … 외 %d건' % (len(rep['changed']) - 10))
if rep['level'] != 'ok':
    lines.append('  단서: 창 %s~ · 수정시각 창 안=%s · 코더 활동 %d줄 · 쓰기차단 %d건' % (
        ev['window_start'], '예' if ev['mtime_in_window'] else '아니오', coder_lines, guard_blocks))
    if rep['baseline']:
        lines.append('  복원: `cp %s %s`' % (os.path.join(backup_dir, rep['baseline']), tasks_file))
rep['text'] = '\n'.join(lines)
emit(rep)
PYEOF
