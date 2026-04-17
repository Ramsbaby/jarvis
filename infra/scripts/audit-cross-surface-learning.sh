#!/usr/bin/env bash
# audit-cross-surface-learning.sh — Phase 0.5 재발 방지 가드레일
#
# Jarvis 뇌 공유 원칙의 진짜 지표: 교정/사실이 모든 활성 표면에서 균형 있게 쌓이는가.
# 특정 표면(discord-bot / claude-code-cli)만 계속 write하고 다른 표면이 7일간 0건이면
# → 파이프라인이 끊겨있거나 훅이 실종된 것. 즉시 오너에게 알림.
#
# 실행: 매주 월요일 07:00 (crontab 등록 필요)
# 출력: ~/jarvis/runtime/logs/cross-surface-audit.log + 이상 시 Discord 알림

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG="${BOT_HOME}/logs/cross-surface-audit.log"
USERS_DIR="${BOT_HOME}/state/users"
OWNER_ID=$(python3 -c "import json; print(json.load(open('${BOT_HOME}/config/user_profiles.json'))['owner']['discordId'])" 2>/dev/null || echo "")

TS=$(date '+%Y-%m-%d %H:%M:%S')

if [[ -z "$OWNER_ID" ]] || [[ ! -f "${USERS_DIR}/${OWNER_ID}.json" ]]; then
  echo "[$TS] ❌ owner userMemory 없음 — audit skip" >> "$LOG"
  exit 0
fi

# 지난 7일간 source별 write 건수 집계
SUMMARY=$(python3 - "${USERS_DIR}/${OWNER_ID}.json" << 'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta

path = sys.argv[1]
data = json.load(open(path))
cutoff = datetime.now(timezone.utc) - timedelta(days=7)

def count_by_source(items):
    out = {}
    for it in items:
        if not isinstance(it, dict):
            continue
        added = it.get('addedAt')
        source = it.get('source', 'unknown')
        if not added:
            continue
        try:
            ts = datetime.fromisoformat(added.replace('Z', '+00:00'))
            if ts < cutoff:
                continue
        except Exception:
            continue
        out[source] = out.get(source, 0) + 1
    return out

facts = count_by_source(data.get('facts', []))
corrs = count_by_source(data.get('corrections', []))

# 활성 표면 정의
expected_surfaces = ['discord-bot', 'claude-code-cli']

# 어느 표면이 7일간 0건인가?
missing = []
for s in expected_surfaces:
    if facts.get(s, 0) == 0 and corrs.get(s, 0) == 0:
        missing.append(s)

print(json.dumps({
    'facts_by_source': facts,
    'corrections_by_source': corrs,
    'missing_surfaces': missing,
    'total_facts_7d': sum(facts.values()),
    'total_corrections_7d': sum(corrs.values()),
}, ensure_ascii=False))
PYEOF
)

echo "[$TS] $SUMMARY" >> "$LOG"

# missing_surfaces 있으면 로그 경고 (디스코드 알림은 운영 상황에 맞춰 스크립트 외부에서 추가)
MISSING=$(echo "$SUMMARY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(d['missing_surfaces']))")
if [[ -n "$MISSING" ]]; then
  MSG="⚠️ 크로스 표면 학습 불균형 — 7일간 0건: ${MISSING} (점검: 훅 배선/프로세스 가동)"
  echo "[$TS] ALERT: $MSG — $SUMMARY" >> "$LOG"
fi

exit 0