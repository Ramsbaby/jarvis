#!/usr/bin/env bash
# mistake-recurrence-audit.sh — 오답 재발 카운터 + 임계 초과 시 Discord 알림
#
# 매일 03:30 KST cron에서 실행. 지난 7일간 mistake-ledger.jsonl의 titles를
# 패턴 fingerprint(소문자 + 특수문자 제거)로 normalize 후 카운트.
# 같은 fingerprint가 3회 이상 재발했으면 구조적 실패 → Discord 경고.
#
# 목표: "오답은 기록만 되는 게 아니라 **재발 횟수 임계**가 울리게" 구조화.
#
# 안전 원칙:
#   - 파싱 실패해도 exit 0 (다른 크론 영향 없음)
#   - Discord 전송 실패해도 exit 0
#   - --dry-run 옵션 지원

set -uo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER="${BOT_HOME}/state/mistake-ledger.jsonl"
REPORT_DIR="${BOT_HOME}/state"
REPORT_FILE="${REPORT_DIR}/mistake-recurrence.json"
LOG="${BOT_HOME}/logs/mistake-recurrence.log"
DRY_RUN="${1:-}"

mkdir -p "$REPORT_DIR" "$(dirname "$LOG")"

ts() { TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z'; }

if [[ ! -f "$LEDGER" ]]; then
  echo "[$(ts)] ledger 없음 — skip" >> "$LOG"
  exit 0
fi

# 지난 7일 epoch
CUTOFF_EPOCH=$(TZ=Asia/Seoul date -v-7d '+%s' 2>/dev/null || TZ=Asia/Seoul date -d '7 days ago' '+%s')
THRESHOLD=3  # 재발 3회 이상이면 경고

# ─── Python으로 fingerprint + 카운트 (jq만으로는 정규화 제한) ───
REPORT=$(python3 <<PYEOF 2>/dev/null
import json, re, sys
from collections import Counter
from datetime import datetime, timezone, timedelta

ledger_path = "$LEDGER"
cutoff_epoch = $CUTOFF_EPOCH
threshold = $THRESHOLD

def fingerprint(title):
    # 소문자 + 한/영/숫자만 남기고 공백 squeeze
    s = re.sub(r'[^\w가-힣]+', ' ', title.lower()).strip()
    s = re.sub(r'\s+', ' ', s)
    # 앞 60자만 (구체 단어 노이즈 흡수)
    return s[:60]

def parse_ts(ts_str):
    try:
        # "2026-04-22T21:53:55+09:00" 또는 "+0900" 형식 호환
        ts_str = re.sub(r'([+-]\d{2}):(\d{2})$', r'\1\2', ts_str)
        return datetime.strptime(ts_str, '%Y-%m-%dT%H:%M:%S%z').timestamp()
    except Exception:
        try:
            ts_str2 = re.sub(r'\.\d+', '', ts_str)
            return datetime.strptime(ts_str2, '%Y-%m-%dT%H:%M:%S%z').timestamp()
        except Exception:
            return 0

counter = Counter()
samples = {}
with open(ledger_path, 'r', encoding='utf-8') as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        ts_epoch = parse_ts(d.get('ts', ''))
        if ts_epoch < cutoff_epoch:
            continue
        for title in d.get('titles', []):
            fp = fingerprint(title)
            if not fp:
                continue
            counter[fp] += 1
            samples.setdefault(fp, []).append(title[:100])

# 임계 초과만
recurring = {fp: n for fp, n in counter.items() if n >= threshold}
result = {
    'generated_at': datetime.now(tz=timezone(timedelta(hours=9))).isoformat(timespec='seconds'),
    'window_days': 7,
    'threshold': threshold,
    'total_unique_patterns': len(counter),
    'recurring_count': len(recurring),
    'top_recurring': [
        {'fingerprint': fp, 'count': n, 'sample_title': samples[fp][0]}
        for fp, n in sorted(recurring.items(), key=lambda x: -x[1])[:10]
    ]
}
print(json.dumps(result, ensure_ascii=False, indent=2))
PYEOF
)

if [[ -z "$REPORT" ]]; then
  echo "[$(ts)] Python 파싱 실패 — skip" >> "$LOG"
  exit 0
fi

echo "$REPORT" > "$REPORT_FILE"
RECURRING_COUNT=$(echo "$REPORT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['recurring_count'])" 2>/dev/null || echo 0)

echo "[$(ts)] 재발 패턴 ${RECURRING_COUNT}건 (임계 ${THRESHOLD}회/7일)" >> "$LOG"

if [[ "$RECURRING_COUNT" -eq 0 ]]; then
  exit 0
fi

# ─── Discord 알림 (임계 초과 시) ───
if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo "[DRY RUN] 알림 예정:"
  echo "$REPORT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"🚨 오답 재발 감지 — {d['recurring_count']}개 패턴이 최근 7일 {d['threshold']}회 이상 반복\")
for item in d['top_recurring'][:3]:
    print(f\"  · [{item['count']}회] {item['sample_title']}\")
"
  exit 0
fi

# send_discord 사용 (기존 라이브러리 재활용)
# shellcheck source=/dev/null
if [[ -f "${BOT_HOME}/lib/discord-notify-bash.sh" ]]; then
  source "${BOT_HOME}/lib/discord-notify-bash.sh"
  MSG=$(echo "$REPORT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
lines = [f\"🚨 **오답 재발 감지** — {d['recurring_count']}개 패턴이 최근 {d['window_days']}일 {d['threshold']}회 이상 반복\"]
lines.append('')
for i, item in enumerate(d['top_recurring'][:5], 1):
    lines.append(f\"{i}. [{item['count']}회] {item['sample_title']}\")
lines.append('')
lines.append(f\"리포트: ~/jarvis/runtime/state/mistake-recurrence.json\")
lines.append(f\"구조적 가드가 부재하다는 신호 — oops/verify 스킬로 즉각 재발방지 훅 신설 권고\")
print('\\n'.join(lines))
")
  send_discord "$MSG" 2>>"$LOG" || echo "[$(ts)] Discord 전송 실패" >> "$LOG"
  echo "[$(ts)] Discord 알림 전송" >> "$LOG"
else
  echo "[$(ts)] discord-notify-bash.sh 없음 — Discord skip" >> "$LOG"
fi

exit 0
