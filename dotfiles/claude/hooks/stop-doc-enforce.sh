#!/usr/bin/env bash
# stop-doc-enforce.sh — Stop hook: 미해결 doc-debt 시 exit 2로 Claude 계속 작업 강제
# exit 2 = "이 세션을 끝내지 말고 계속 작업하라"
# exit 0 = 정상 종료 허용

set -euo pipefail

BOT_HOME="${HOME}/.jarvis"
DOC_DEBT="${BOT_HOME}/state/doc-debt.json"
LOG="${BOT_HOME}/logs/doc-debt.log"
RESULT_TMP=""
trap 'rm -f "${RESULT_TMP:-}"' EXIT
RESULT_TMP=$(mktemp)

log() { echo "[$(date '+%F %T')] [doc-enforce] $*" >> "$LOG" 2>/dev/null || true; }

if [[ ! -f "$DOC_DEBT" ]]; then log "no doc-debt.json — pass"; echo "✓ doc-debt 없음" >&2; exit 0; fi

# $() + heredoc은 bash 3.2에서 파싱 버그 → 임시 파일 패턴 사용
python3 - "$DOC_DEBT" > "$RESULT_TMP" 2>/dev/null <<'PYEOF' || echo "PASS" > "$RESULT_TMP"
import json, sys

path = sys.argv[1]
try:
    debt = json.load(open(path))
except Exception:
    print("PASS")
    sys.exit(0)

debts = debt.get("debts", {})
if not debts:
    print("PASS")
    sys.exit(0)

lines = ["BLOCK"]
lines.append(f"미해결 문서 채무 {len(debts)}건 — 아래 문서를 업데이트한 후 완료하세요:")
for doc, info in debts.items():
    triggers = ", ".join(info.get("triggered_by", [])[:2])
    reason = info.get("reason", "")
    lines.append(f"  📄 {doc}")
    lines.append(f"     이유: {reason}")
    if triggers:
        lines.append(f"     변경된 코드: {triggers}")
print("\n".join(lines))
PYEOF

FIRST_LINE=$(head -1 "$RESULT_TMP")

if [[ "$FIRST_LINE" != "BLOCK" ]]; then
    log "no debts — pass"
    echo "✓ doc-debt 없음" >&2
    exit 0
fi

DEBT_MSG=$(tail -n +2 "$RESULT_TMP")
DEBT_COUNT=$(python3 -c "import sys; print(sum(1 for l in open(sys.argv[1]) if '\U0001f4c4' in l))" "$RESULT_TMP" 2>/dev/null || echo '?')
log "BLOCK: ${DEBT_COUNT}건 미해결"

cat >&2 <<MSG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
문서 채무(doc-debt) 미해결 — 종료 차단됨
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${DEBT_MSG}

지시:
1. 위 문서(~/projects/jarvis/infra/<doc_path>)를 순서대로 편집
2. 이번 세션 코드 변경 내용을 관련 섹션에 반영
3. 편집 저장 → debt 자동 해소 → Stop 재시도 시 통과
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG

exit 2
