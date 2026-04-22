#!/usr/bin/env bash
# weekly-mistake-heatmap.sh — 주간 오답 히트맵 Discord 리포트
#
# 매주 월요일 09:00 KST 실행. 지난 7일 ledger 집계로 상위 5개 재발 패턴 +
# 스킬별 오답 발생 분포를 Discord 카드로 전송.
# 감으로가 아닌 데이터로 "우리 시스템이 어디서 자꾸 실수하는가" 가시화.
#
# 안전: 파싱/전송 실패해도 exit 0. 재발 카운터(03:30)와 체크리스트(03:45)
#        생성 후이므로 최신 state 사용.

set -uo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER="${BOT_HOME}/state/mistake-ledger.jsonl"
RECURRENCE="${BOT_HOME}/state/mistake-recurrence.json"
CHECKLIST_IDX="${BOT_HOME}/wiki/meta/checklists/INDEX.md"
LOG="${BOT_HOME}/logs/weekly-mistake-heatmap.log"

mkdir -p "$(dirname "$LOG")"
ts() { TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z'; }

if [[ ! -f "$LEDGER" ]]; then
  echo "[$(ts)] ledger 없음 — skip" >> "$LOG"
  exit 0
fi

# ─── 히트맵 생성 (Python) ───
MSG=$(LEDGER="$LEDGER" RECURRENCE="$RECURRENCE" CHECKLIST_IDX="$CHECKLIST_IDX" python3 <<'PYEOF' 2>/dev/null
import json, re, os
from collections import Counter
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))
now = datetime.now(KST)
cutoff = (now - timedelta(days=7)).timestamp()

ledger = os.environ.get('LEDGER')
recurrence_path = os.environ.get('RECURRENCE')
checklist_idx = os.environ.get('CHECKLIST_IDX')

def parse_ts(s):
    try:
        s2 = re.sub(r'([+-]\d{2}):(\d{2})$', r'\1\2', s)
        s2 = re.sub(r'\.\d+', '', s2)
        return datetime.strptime(s2, '%Y-%m-%dT%H:%M:%S%z').timestamp()
    except Exception:
        return 0

daily = Counter()
sources = Counter()
titles = []
weekly_total = 0
try:
    with open(ledger, 'r', encoding='utf-8') as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            ts_epoch = parse_ts(d.get('ts',''))
            if ts_epoch < cutoff:
                continue
            day = datetime.fromtimestamp(ts_epoch, KST).strftime('%a')
            cnt = d.get('count', len(d.get('titles', [])))
            daily[day] += cnt
            sources[d.get('source','?')] += cnt
            for t in d.get('titles', []):
                titles.append(t)
            weekly_total += cnt
except Exception:
    pass

recurring = []
try:
    with open(recurrence_path, 'r', encoding='utf-8') as f:
        r = json.load(f)
        recurring = r.get('top_recurring', [])[:3]
except Exception:
    pass

skill_dist = []
try:
    with open(checklist_idx, 'r', encoding='utf-8') as f:
        for line in f:
            m = re.match(r'\|\s*(\S+)\s*\|\s*(\d+)\s*\|', line)
            if m:
                skill_dist.append((m.group(1), int(m.group(2))))
    skill_dist.sort(key=lambda x: -x[1])
except Exception:
    pass

if weekly_total == 0 and not recurring:
    print("")
    exit(0)

DAYS_ORDER = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun']
days_bar = '\n'.join(
    f"  {d}: {'█' * min(daily.get(d,0), 20)}{'░' * max(20 - min(daily.get(d,0), 20), 0)} {daily.get(d,0)}"
    for d in DAYS_ORDER
)

lines = []
lines.append(f"📊 **주간 오답 히트맵** ({now.strftime('%Y-%m-%d %a')} 기준, 지난 7일)")
lines.append("")
lines.append(f"총 오답 등재: **{weekly_total}건** (source: " + ', '.join(f'{k}={v}' for k,v in sources.most_common(3)) + ")")
lines.append("")
lines.append("**요일별 발생량:**")
lines.append("```")
lines.append(days_bar)
lines.append("```")

if recurring:
    lines.append("**🚨 재발 패턴 TOP 3:**")
    for i, r in enumerate(recurring, 1):
        lines.append(f"{i}. [{r['count']}회] {r['sample_title'][:80]}")
    lines.append("")

if skill_dist:
    lines.append("**누적 오답 스킬별 분포 (상위 3):**")
    for s, n in skill_dist[:3]:
        lines.append(f"  · {s}: {n}건")
    lines.append("")

lines.append("리포트: ~/jarvis/runtime/wiki/meta/learned-mistakes.md")
lines.append("체크리스트: ~/jarvis/runtime/wiki/meta/checklists/INDEX.md")
print('\n'.join(lines))
PYEOF
)

if [[ -z "$MSG" ]]; then
  echo "[$(ts)] 주간 데이터 없음 — skip" >> "$LOG"
  exit 0
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "$MSG"
  exit 0
fi

# Discord 전송
# shellcheck source=/dev/null
if [[ -f "${BOT_HOME}/lib/discord-notify-bash.sh" ]]; then
  source "${BOT_HOME}/lib/discord-notify-bash.sh"
  send_discord "$MSG" 2>>"$LOG" && echo "[$(ts)] 히트맵 전송 완료" >> "$LOG" || echo "[$(ts)] 전송 실패" >> "$LOG"
else
  echo "[$(ts)] discord-notify-bash.sh 없음" >> "$LOG"
fi

exit 0
