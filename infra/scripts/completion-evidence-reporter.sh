#!/usr/bin/env bash
# completion-evidence-reporter.sh
#
# 목적: [2] 강제 증거 출력 가드 — 작업 완료 선언 시 "전체 N건 중 N건 처리 완료" 형식 의무화
#
# 기능:
#   1. 완료 상태 자동 검증 및 증거 출력
#   2. 부분 완료 오선언 차단 (exit 1)
#   3. 완료 증거를 JSON 파일로 자동 저장
#   4. cl-f6921eb1d5ea4c87 클러스터 재발 기록
#
# 사용:
#   completion-evidence-reporter.sh \
#     --task <task_id> \
#     --total <N> \
#     --completed <N> \
#     [--cluster-id cl-f6921eb1d5ea4c87] \
#     [--save-evidence <json_file>]
#
# 반환값:
#   0 = 완료 (전체 == 완료)
#   1 = 불완료 (전체 > 완료)

set -euo pipefail

CLUSTER_ID="${CLUSTER_ID:-cl-f6921eb1d5ea4c87}"
EVIDENCE_DIR="${HOME}/jarvis/runtime/reports/completion-evidence"
mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 사용법 출력
print_usage() {
    cat <<USAGE
completion-evidence-reporter.sh — 작업 완료 증거 자동 생성 및 보고

사용:
  $0 --task <task_id> --total <N> --completed <N> [옵션]

옵션:
  --task <id>            작업 ID (필수)
  --total <N>            전체 대상 건수 (필수)
  --completed <N>        실제 완료 건수 (필수)
  --cluster-id <id>      클러스터 ID (기본값: cl-f6921eb1d5ea4c87)
  --save-evidence <file> 증거를 JSON으로 저장할 파일 경로
  --detail <text>        추가 설명 (선택)

반환값:
  0 = 완료 (전체 == 완료)
  1 = 불완료 (전체 > 완료)

예시:
  $0 --task skill-synthesis-verify --total 5 --completed 5
  → 전체 5건 중 5건 처리 완료 — exit 0

  $0 --task skill-synthesis-verify --total 5 --completed 3
  → 전체 5건 중 3건 처리 (2건 미처리) — exit 1, 부분 처리 오선언 차단
USAGE
}

# 증거 출력 및 검증
print_completion_evidence() {
    local task_id="$1"
    local total="$2"
    local completed="$3"
    local remaining=$((total - completed))
    local pct=$((completed * 100 / total))

    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}📋 COMPLETION EVIDENCE REPORT — [2] 강제 증거 출력 가드${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Task ID:              ${task_id}"
    echo "  Cluster ID:           ${CLUSTER_ID}"
    echo "  Guard Type:           enforce-completion-evidence"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${MAGENTA}📊 COMPLETION STATUS:${NC}"
    echo "     전체 대상 항목:    ${total}건"
    echo "     완료 항목:         ${completed}건"
    echo "     미처리 항목:       ${remaining}건"
    echo "     완료율:           [${completed}/${total}] (${pct}%)"
    echo ""

    if [[ "$completed" -eq "$total" ]]; then
        echo -e "  ${GREEN}✅ STATUS: FULLY COMPLETED${NC}"
        echo -e "  ${GREEN}전체 ${total}건 중 ${completed}건 처리 완료${NC}"
        echo ""
        echo "  ▶ 모든 대상 항목 처리 완료 — 작업 선언 가능"
        echo ""
        echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        return 0
    else
        echo -e "  ${RED}❌ STATUS: INCOMPLETE — PARTIAL COMPLETION DETECTED${NC}"
        echo -e "  ${RED}전체 ${total}건 중 ${completed}건만 처리 (${remaining}건 미처리)${NC}"
        echo ""
        echo -e "  ${YELLOW}⚠️  미처리 항목: ${remaining}건${NC}"
        echo "     → 모든 항목 처리 전까지 작업 완료 선언 불가"
        echo "     → 부분 처리 후 완료 선언은 cl-f6921eb1d5ea4c87 클러스터 재발 오류"
        echo ""
        echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        return 1
    fi
}

# 증거를 JSON으로 저장
save_evidence_json() {
    local task_id="$1"
    local total="$2"
    local completed="$3"
    local save_file="$4"

    local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local is_complete=$([ "$completed" -eq "$total" ] && echo "true" || echo "false")

    python3 << PYTHON_EOF
import json
from datetime import datetime

evidence = {
    "task_id": "$task_id",
    "cluster_id": "$CLUSTER_ID",
    "timestamp": "$timestamp",
    "total_items": $total,
    "completed_items": $completed,
    "missing_items": $((total - completed)),
    "completion_ratio": round($completed / $total, 3) if $total > 0 else 0,
    "is_complete": $is_complete,
    "completion_statement": "전체 $total건 중 $completed건 처리 완료",
    "status": "COMPLETE" if $is_complete else "INCOMPLETE"
}

with open("$save_file", "w") as f:
    json.dump(evidence, f, indent=2, ensure_ascii=False)
PYTHON_EOF

    echo "  ℹ️  증거 저장: $save_file"
}

# 메인
main() {
    if [[ $# -eq 0 ]]; then
        print_usage
        return 1
    fi

    local task_id=""
    local total=0
    local completed=0
    local save_evidence=""
    local detail=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task) task_id="$2"; shift 2 ;;
            --total) total="$2"; shift 2 ;;
            --completed) completed="$2"; shift 2 ;;
            --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
            --save-evidence) save_evidence="$2"; shift 2 ;;
            --detail) detail="$2"; shift 2 ;;
            --help|-h) print_usage; return 0 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$task_id" ]] || [[ $total -eq 0 ]]; then
        echo "Error: --task and --total are required" >&2
        print_usage
        return 1
    fi

    # 증거 출력
    if print_completion_evidence "$task_id" "$total" "$completed"; then
        # 완료 증거 저장
        if [[ -n "$save_evidence" ]]; then
            save_evidence_json "$task_id" "$total" "$completed" "$save_evidence"
        fi
        return 0
    else
        # 부분 완료 증거도 저장
        if [[ -n "$save_evidence" ]]; then
            save_evidence_json "$task_id" "$total" "$completed" "$save_evidence"
        fi
        return 1
    fi
}

main "$@"
