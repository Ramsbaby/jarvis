#!/usr/bin/env bash
# preflight-work-check.sh — 새 작업 시작 전 "이미 진행 중/완료된 게 있나?" 5초 검사
#
# 이번 세션 실수 재발 방지:
#   - Tool guard를 내가 제거 중인데 main에선 이미 "25로 상향" 작업 중이었음
#   - 결국 merge conflict + 같은 의도 중복 작업
#
# 사용:
#   bash infra/scripts/preflight-work-check.sh "<키워드>"
#   예: preflight-work-check.sh "tool-guard"
#       preflight-work-check.sh "langfuse"
#
# 출력:
#   - 최근 7일 내 관련 commit
#   - 현재 열린 worktree 목록
#   - tasks-integrity-audit 최근 결과 (관련 정책 위반 있나)
#   - main checkout의 미커밋 변경 (다른 작업자 흔적)

set -euo pipefail

KEYWORD="${1:-}"
if [[ -z "$KEYWORD" ]]; then
    echo "Usage: $0 <키워드>"
    echo "예: $0 tool-guard"
    exit 1
fi

REPO="${REPO:-/Users/ramsbaby/jarvis}"
cd "$REPO"

echo "╔══════════════════════════════════════════════════════════"
echo "║ Preflight Work Check: '$KEYWORD'"
echo "╚══════════════════════════════════════════════════════════"
echo ""

# 1. 최근 7일 commit에서 키워드 매칭
echo "📌 1. 최근 7일 commit (키워드 매칭)"
git log --since='7 days ago' --all --oneline --grep="$KEYWORD" -i | head -10 \
    | sed 's/^/   /' || echo "   (없음)"
echo ""

# 2. 최근 7일 변경 파일에서 키워드 grep
echo "📌 2. 최근 7일 변경된 파일에서 키워드 등장"
SINCE=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null)
git log --since="$SINCE" --all --name-only --pretty=format: 2>/dev/null \
    | sort -u | grep -v "^$" | while read -r f; do
    if [[ -f "$f" ]] && grep -l -i "$KEYWORD" "$f" 2>/dev/null >/dev/null; then
        echo "   $f"
    fi
done | head -10
echo ""

# 3. 현재 worktree 목록
echo "📌 3. 현재 열린 worktree"
git worktree list | sed 's/^/   /'
echo ""

# 4. main checkout 미커밋 변경
echo "📌 4. main checkout 미커밋 변경 (다른 작업자/프로세스 흔적)"
(cd "$REPO" && git status --short | head -10) | sed 's/^/   /' || echo "   (clean)"
echo ""

# 5. tasks-integrity-audit 최근 결과
echo "📌 5. tasks-integrity-audit 최근 경보 (정책 위반)"
LEDGER="${REPO}/runtime/ledger/tasks-integrity-audit.jsonl"
if [[ -f "$LEDGER" ]]; then
    tail -20 "$LEDGER" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        issues = d.get('HAS_ISSUE', [])
        if issues:
            ts = d.get('ts','?')[:16]
            print(f'   [{ts}] issues: {\", \".join(issues[:3])}')
    except: pass
" 2>/dev/null | tail -5 || echo "   (recent audits clean)"
else
    echo "   (ledger 없음)"
fi
echo ""

# 6. 메모리에서 키워드 검색
echo "📌 6. 메모리에서 관련 규칙/교정"
MEMORY_DIR="${HOME}/.claude/projects/-Users-ramsbaby-jarvis/memory"
if [[ -d "$MEMORY_DIR" ]]; then
    grep -l -i "$KEYWORD" "$MEMORY_DIR"/*.md 2>/dev/null | head -5 | while read -r f; do
        echo "   $(basename "$f")"
    done || echo "   (매칭 메모리 없음)"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💡 위에 항목 1~6 중 하나라도 관련 작업이 보이면 먼저 그 맥락 확인."
echo "   중복 작업 / 충돌 원천 차단 목적."
exit 0
