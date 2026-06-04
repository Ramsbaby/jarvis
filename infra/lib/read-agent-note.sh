#!/usr/bin/env bash
# read-agent-note.sh — 에이전트 Self-Note 읽기 헬퍼
#
# Usage:
#   read-agent-note.sh TASK_ID [--markdown|--json|--prompt]
#
# 출력 모드:
#   --markdown (기본) : 마크다운 요약 (시스템 프롬프트 주입용)
#   --json            : latest.json 원본 출력
#   --prompt          : ask-claude.sh CONTEXT_EXTRA 주입용 단축 텍스트
#
# 연동:
#   - jarvis-cron.sh 또는 ask-claude.sh 호출 직전 CONTEXT_EXTRA에 결과 주입
#   - 예: CONTEXT_EXTRA="$(read-agent-note.sh council-insight --prompt)"
#   - 노트가 없으면 빈 문자열 반환 (오류 없음, set -e 안전)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
NOTES_DIR="${BOT_HOME}/agent-notes"

TASK_ID="${1:?Usage: read-agent-note.sh TASK_ID [--markdown|--json|--prompt]}"
MODE="${2:---markdown}"

LATEST_FILE="${NOTES_DIR}/${TASK_ID}/latest.json"

# 노트 없으면 조용히 종료 (빈 출력)
if [[ ! -f "$LATEST_FILE" ]]; then
    exit 0
fi

NOTE=$(cat "$LATEST_FILE")

case "$MODE" in
    --json)
        echo "$NOTE"
        ;;

    --prompt)
        # 한 줄 요약 — CONTEXT_EXTRA 주입용
        TS=$(echo "$NOTE"   | jq -r '.timestamp // "unknown"')
        AGENT=$(echo "$NOTE" | jq -r '.agent    // "unknown"')
        PATTERNS=$(echo "$NOTE" | jq -r '.patterns[]?'    | head -3 | sed 's/^/  - /')
        MISTAKES=$(echo "$NOTE" | jq -r '.mistakes[]?'    | head -3 | sed 's/^/  - /')
        SUGGESTS=$(echo "$NOTE" | jq -r '.suggestions[]?' | head -3 | sed 's/^/  - /')

        cat <<EOF
[이전 실행 Self-Note] task=${TASK_ID} agent=${AGENT} ts=${TS}
패턴(재사용):
${PATTERNS:-  (없음)}
실수(주의):
${MISTAKES:-  (없음)}
제안:
${SUGGESTS:-  (없음)}
EOF
        ;;

    --markdown|*)
        TS=$(echo "$NOTE"    | jq -r '.timestamp       // "unknown"')
        AGENT=$(echo "$NOTE" | jq -r '.agent           // "unknown"')
        DURATION=$(echo "$NOTE" | jq -r '.execution_summary.duration_s // "?"')
        COST=$(echo "$NOTE"  | jq -r '.execution_summary.cost_usd    // "?"')

        echo "## Self-Note: \`${TASK_ID}\`"
        echo "> 작성: ${AGENT} @ ${TS} | 실행: ${DURATION}s | 비용: \$${COST}"
        echo ""
        echo "### 패턴 (재사용 가능)"
        echo "$NOTE" | jq -r '.patterns[]?' | sed 's/^/- /' || echo "- (없음)"
        echo ""
        echo "### 실수 (다음 실행 시 주의)"
        echo "$NOTE" | jq -r '.mistakes[]?' | sed 's/^/- /' || echo "- (없음)"
        echo ""
        echo "### 제안"
        echo "$NOTE" | jq -r '.suggestions[]?' | sed 's/^/- /' || echo "- (없음)"
        ;;
esac
