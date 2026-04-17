#!/usr/bin/env bash
# policy-fix-verify-24h.sh — Phase 1 disable 24h 후 자동 검증
set -euo pipefail
LOG=~/jarvis/runtime/logs/policy-fix-verify.log
echo "[verify] $(date '+%Y-%m-%d %H:%M:%S KST')" >> "$LOG"

# 새 매니페스트 생성
node ~/jarvis/runtime/scripts/policy-fix-classify.mjs >> "$LOG" 2>&1

# C-1이었던 28개의 새 카테고리 추출 (어떻게 변했는지)
PRE=/tmp/c1-labels.txt
RESULT=$(python3 -c "
import csv
with open('$HOME/jarvis/runtime/state/policy-fix-manifest.csv') as f:
    rows = {row['Label']: row for row in csv.DictReader(f)}
with open('$PRE') as f:
    targets = [l.strip() for l in f if l.strip()]
ok=fail=missing=0
detail=[]
for label in targets:
    r = rows.get(label)
    if not r:
        missing += 1
        detail.append(f'❓ {label}: missing from manifest')
    elif r['NexusLastSuccess'] and '2026-04-1' in r['NexusLastSuccess']:
        ok += 1
    else:
        fail += 1
        detail.append(f'⚠️ {label}: nexusLastSuccess={r[\"NexusLastSuccess\"] or \"none\"}')
print(f'OK={ok} FAIL={fail} MISSING={missing}')
for d in detail[:10]: print(d)
")
echo "$RESULT" >> "$LOG"

# Discord 알림
node ~/jarvis/runtime/scripts/discord-send-msg.mjs "jarvis-system" "## 🔍 Phase 1 24h 검증 결과

\`\`\`
$RESULT
\`\`\`

세부: \`tail -50 ~/jarvis/runtime/logs/policy-fix-verify.log\`" 2>/dev/null || true