#!/usr/bin/env bash
# rate-limit-check.sh — rate-tracker.json 기반 Claude Max 사용률 확인
# Claude -p 불필요. 순수 bash + python3.
set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TRACKER="$BOT_HOME/state/rate-tracker.json"
LIMIT=900

if [[ ! -f "$TRACKER" ]]; then
    echo "Rate limit: 정상 (데이터 없음)"
    exit 0
fi

COUNT=$(python3 - "$TRACKER" "$LIMIT" << 'PYEOF' || echo "Rate limit: 정상 (오류 처리됨)"
import json, sys
from datetime import datetime, timedelta, timezone

tracker_path = sys.argv[1]
limit = int(sys.argv[2])

try:
    data = json.load(open(tracker_path))
except Exception:
    print(f"Rate limit: 정상 (파싱 불가)")
    sys.exit(0)

now = datetime.now(timezone.utc)
cutoff_ms = int((now - timedelta(hours=5)).timestamp() * 1000)

# 밀리초 타임스탬프 배열 형식
if isinstance(data, list):
    # data가 숫자 배열 (밀리초): [1776365862202, ...]
    count = sum(1 for ts in data if isinstance(ts, int) and ts >= cutoff_ms)
elif isinstance(data, dict) and 'timestamps' in data:
    # data가 {timestamps: [1776365862202, ...]}
    count = sum(1 for ts in data['timestamps'] if isinstance(ts, int) and ts >= cutoff_ms)
else:
    print("Rate limit: 정상 (형식 불명)")
    sys.exit(0)

pct = round(count / limit * 100, 1)
if pct >= 90:
    print(f"🚨 Rate limit 위험: {count}/{limit} ({pct}%) — critical 태스크만 실행")
elif pct >= 80:
    print(f"⚠️ Rate limit 경고: {count}/{limit} ({pct}%) — optional 태스크 스킵 권고")
else:
    print(f"Rate limit: 정상 {count}/{limit} ({pct}%)")
PYEOF
)

echo "$COUNT"