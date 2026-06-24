#!/usr/bin/env bash
# metacog-guard.sh — 구조적 취약점 사전 점검 체크리스트 가드
#
# 클러스터 ID : cl-a092fb85afd92ba8
# 목적        : 대화 시작 또는 복잡한 문제 진단 시 메타인지 취약점을 조기 발견,
#               자가진단 결과를 JSONL로 기록해 회고 시 정량 측정 지원.
#
# 사용법:
#   ~/jarvis/infra/guards/metacog-guard.sh [context_label]
#   context_label: 점검 맥락 식별자 (기본값 "manual")
#
# 성공 기준:
#   [1] ~/jarvis/runtime/logs/metacog-diagnose.jsonl 에 JSONL 레코드 기록
#   [2] 취약점 미충족 항목이 있으면 exit 1, 전부 통과 시 exit 0

set -euo pipefail

# ── 경로 상수 ──────────────────────────────────────────────────────────────────
JARVIS_HOME="${HOME}/jarvis"
LOG_FILE="${JARVIS_HOME}/runtime/logs/metacog-diagnose.jsonl"
CLUSTER_ID="cl-a092fb85afd92ba8"
CONTEXT_LABEL="${1:-manual}"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ── 로그 디렉토리 보장 ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"

# ── 체크리스트 정의 ────────────────────────────────────────────────────────────
# 각 항목: "ID|설명|점검 명령(exit 0=통과, 非0=실패)"
# 점검 명령이 비어 있으면 수동 플래그 기반으로 처리 (AUTO_ONLY=false 일 때 항상 통과)
declare -a CHECKS=(
    "C01|tasks.json 문법 유효성|python3 -m json.tool --no-ensure-ascii '${JARVIS_HOME}/runtime/config/tasks.json' > /dev/null 2>&1"
    "C02|orchestrator 프로세스 생존|pgrep -f 'orchestrator' > /dev/null 2>&1"
    "C03|discord-bot 프로세스 생존|pgrep -f 'discord-bot' > /dev/null 2>&1"
    "C04|guards 디렉토리 존재|test -d '${JARVIS_HOME}/infra/guards'"
    "C05|discord-route.sh 존재|test -f '${JARVIS_HOME}/infra/lib/discord-route.sh'"
    "C06|런타임 로그 디렉토리 존재|test -d '${JARVIS_HOME}/runtime/logs'"
    "C07|메타인지 로그 쓰기 가능|touch '${LOG_FILE}' > /dev/null 2>&1"
    "C08|디스크 여유 20GB 이상|awk '(NR==2){if(\$4+0>=20971520) exit 0; else exit 1}' <(df -k ${HOME})"
)

# ── 점검 실행 ─────────────────────────────────────────────────────────────────
passed=0
failed=0
total=${#CHECKS[@]}
declare -a result_items=()

for check in "${CHECKS[@]}"; do
    IFS='|' read -r check_id desc cmd <<< "$check"
    if eval "$cmd" 2>/dev/null; then
        status="PASS"
        ((passed++)) || true
    else
        status="FAIL"
        ((failed++)) || true
    fi
    # JSON 배열 원소 생성
    result_items+=("{\"id\":\"${check_id}\",\"desc\":\"${desc}\",\"status\":\"${status}\"}")
done

# ── JSONL 레코드 작성 ─────────────────────────────────────────────────────────
items_json=$(IFS=,; echo "[${result_items[*]}]")

overall="PASS"
[ "$failed" -gt 0 ] && overall="FAIL"

jq -nc \
    --arg ts        "$TIMESTAMP" \
    --arg cluster   "$CLUSTER_ID" \
    --arg context   "$CONTEXT_LABEL" \
    --arg overall   "$overall" \
    --argjson total "$total" \
    --argjson pass  "$passed" \
    --argjson fail  "$failed" \
    --argjson items "$items_json" \
    '{
        timestamp:  $ts,
        cluster_id: $cluster,
        context:    $context,
        overall:    $overall,
        summary:    {total: $total, passed: $pass, failed: $fail},
        checks:     $items
    }' >> "$LOG_FILE"

# ── 콘솔 출력 ─────────────────────────────────────────────────────────────────
echo "[metacog-guard] cluster=${CLUSTER_ID} context=${CONTEXT_LABEL} overall=${overall} passed=${passed}/${total}"
if [ "$failed" -gt 0 ]; then
    echo "[metacog-guard] 실패 항목:"
    for item in "${result_items[@]}"; do
        if echo "$item" | grep -q '"status":"FAIL"'; then
            echo "  - $(echo "$item" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["id"], d["desc"])')"
        fi
    done
fi

# ── 종료 코드 ─────────────────────────────────────────────────────────────────
[ "$failed" -eq 0 ]
