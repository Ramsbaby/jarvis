#!/usr/bin/env bash
# cluster-completion-guard-cl-f6921eb1d5ea4c87.sh
#
# 목적: cl-f6921eb1d5ea4c87 클러스터 (부분 처리 오선언 방지) 전용 가드
#
# 기능:
#   1. 처리 대상 전체 목록과 실제 완료 항목 자동 대조
#   2. 작업 완료 선언 시 "전체 N건 중 N건 처리 완료" 형식 강제
#   3. 부분 완료 시 완료 선언 차단 (exit 1)
#   4. 누락 항목 자동 리포팅
#   5. 클러스터 재발 추적
#
# 사용:
#   cluster-completion-guard-cl-f6921eb1d5ea4c87.sh \
#     --task <task_id> \
#     --target-list <file> \
#     --completed-list <file> \
#     [--report-file <file>]
#
#   cluster-completion-guard-cl-f6921eb1d5ea4c87.sh \
#     --verify --total <N> --completed <N> \
#     [--task <id>]

set -euo pipefail

CLUSTER_ID="cl-f6921eb1d5ea4c87"
CLUSTER_NAME="Partial Completion False Declaration"
GUARD_STATE_DIR="${HOME}/jarvis/runtime/state/cluster-guards/${CLUSTER_ID}"
GUARD_LOG="${HOME}/jarvis/runtime/logs/cluster-completion-guard-${CLUSTER_ID}.log"
GUARD_REPORT="${HOME}/jarvis/runtime/reports/cluster-completion-guard-${CLUSTER_ID}.json"

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 초기화
mkdir -p "$GUARD_STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$GUARD_LOG")" 2>/dev/null || true
mkdir -p "$(dirname "$GUARD_REPORT")" 2>/dev/null || true

# 로깅 함수
_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    echo "[${timestamp}] [${level}] [${CLUSTER_ID}] ${message}" >> "$GUARD_LOG"
}

_log_console() {
    local level="$1"
    shift
    local message="$*"
    case "$level" in
        ERROR)
            echo -e "${RED}❌ ERROR: ${message}${NC}" >&2
            ;;
        WARN)
            echo -e "${YELLOW}⚠️  WARN: ${message}${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}✅ SUCCESS: ${message}${NC}"
            ;;
        INFO)
            echo -e "${BLUE}ℹ️  ${message}${NC}"
            ;;
        *)
            echo "  ${message}"
            ;;
    esac
}

# 대상 목록과 완료 목록 비교
_compare_lists() {
    local target_file="$1"
    local completed_file="$2"
    local task_id="${3:-unknown-task}"

    if [[ ! -f "$target_file" ]]; then
        _log_console ERROR "Target list file not found: $target_file"
        return 1
    fi

    if [[ ! -f "$completed_file" ]]; then
        _log_console ERROR "Completed list file not found: $completed_file"
        return 1
    fi

    local target_count=$(wc -l < "$target_file" | tr -d ' ')
    local completed_count=$(wc -l < "$completed_file" | tr -d ' ')

    _log INFO "Comparing lists for task: $task_id"
    _log INFO "Target count: $target_count, Completed count: $completed_count"

    # 누락 항목 탐지 (diff)
    local temp_missing="/tmp/missing-items-${CLUSTER_ID}-$$.txt"
    comm -23 <(sort "$target_file" | uniq) <(sort "$completed_file" | uniq) > "$temp_missing" || true

    local missing_count=$(wc -l < "$temp_missing" | tr -d ' ')

    # 결과 저장
    local result_file="${GUARD_STATE_DIR}/${task_id}-result.json"
    python3 << PYTHON_SCRIPT
import json
from datetime import datetime

result = {
    "task_id": "$task_id",
    "cluster_id": "$CLUSTER_ID",
    "timestamp": datetime.now().isoformat(),
    "target_count": $target_count,
    "completed_count": $completed_count,
    "missing_count": $missing_count,
    "completion_ratio": round($completed_count / $target_count, 3) if $target_count > 0 else 0,
    "is_complete": $completed_count == $target_count,
    "missing_items": []
}

try:
    with open("$temp_missing", "r") as f:
        result["missing_items"] = [line.strip() for line in f if line.strip()]
except:
    pass

with open("$result_file", "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(json.dumps(result, indent=2, ensure_ascii=False))
PYTHON_SCRIPT

    rm -f "$temp_missing"

    # 부분 완료 경우 경고
    if [[ "$completed_count" -lt "$target_count" ]]; then
        _log WARN "PARTIAL COMPLETION DETECTED: $completed_count/$target_count items processed"
        _log_console WARN "INCOMPLETE: $missing_count items missing (will not declare completion)"
        return 1
    else
        _log INFO "FULL COMPLETION: All $target_count items processed"
        _log_console SUCCESS "COMPLETE: All $target_count items processed"
        return 0
    fi
}

# 강제 증거 출력 (부분 완료 차단)
print_completion_evidence_with_guard() {
    local task_id="$1"
    local total="$2"
    local completed="$3"
    local remaining=$((total - completed))

    _log INFO "Printing completion evidence for task: $task_id ($completed/$total)"

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "🛡️  CLUSTER COMPLETION GUARD — ${CLUSTER_NAME}"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Task ID:                    ${task_id}"
    echo "Cluster ID:                 ${CLUSTER_ID}"
    echo "Guard Type:                 enforce-completion-evidence (Guard 1)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📊 COMPLETION VERIFICATION:"
    echo "  Total Target Items:       ${total}건"
    echo "  Completed Items:          ${completed}건"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Completion Ratio:         [${completed}/${total}] ($(( completed * 100 / total ))%)"
    echo ""

    if [[ "$completed" -eq "$total" ]]; then
        _log_console SUCCESS "✅ FULL COMPLETION: 전체 ${total}건 중 ${completed}건 처리 완료"
        echo -e "${GREEN}✅ STATUS: FULLY COMPLETED${NC}"
        echo "  → 모든 대상 항목 처리 완료 — 작업 선언 가능"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════════════════"
        echo ""
        return 0
    else
        _log WARN "PARTIAL COMPLETION BLOCKED: $completed/$total items only"
        _log_console ERROR "❌ INCOMPLETE: 전체 ${total}건 중 ${completed}건만 처리 (${remaining}건 미처리)"
        echo -e "${RED}❌ STATUS: PARTIAL COMPLETION DETECTED — COMPLETION DECLARATION BLOCKED${NC}"
        echo ""
        echo "⚠️  미처리 항목: ${remaining}건"
        echo "    → 모든 항목 처리 전까지 작업 완료 선언 불가"
        echo "    → 부분 처리 후 완료 선언은 클러스터 재발 오류 방지 가드 위반입니다"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════════════════"
        echo ""
        return 1
    fi
}

# 누락 항목 리포트 출력
print_missing_items_report() {
    local result_file="$1"

    if [[ ! -f "$result_file" ]]; then
        return 0
    fi

    python3 << PYTHON_SCRIPT
import json

try:
    with open("$result_file", "r") as f:
        result = json.load(f)

    if result.get("missing_count", 0) > 0:
        print("")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📋 MISSING ITEMS REPORT (누락 항목 자동 리포팅 — Guard 3)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print(f"  미처리 항목 수: {result['missing_count']}건")
        print("")
        if result["missing_items"]:
            for i, item in enumerate(result["missing_items"], 1):
                print(f"  {i}. {item}")
        print("")
except:
    pass
PYTHON_SCRIPT
}

# 클러스터 재발 기록
record_guard_execution() {
    local task_id="$1"
    local passed="$2"

    _log INFO "Recording guard execution: task=$task_id, passed=$passed"

    # mistake-cluster-guard.mjs를 호출하여 재발 추적
    if [[ -f "${HOME}/jarvis/infra/lib/mistake-cluster-guard.mjs" ]]; then
        if [[ "$passed" == "false" ]]; then
            node "${HOME}/jarvis/infra/lib/mistake-cluster-guard.mjs" \
                record-recurrence "$CLUSTER_ID" \
                "Task $task_id: partial completion detected and blocked by guard" 2>/dev/null || true
        fi
    fi
}

# 메인 진입점
main() {
    local cmd="${1:-}"

    case "$cmd" in
        --task)
            shift
            local task_id=""
            local target_list=""
            local completed_list=""
            local report_file=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --task) task_id="$2"; shift 2 ;;
                    --target-list) target_list="$2"; shift 2 ;;
                    --completed-list) completed_list="$2"; shift 2 ;;
                    --report-file) report_file="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done

            if [[ -z "$task_id" ]] || [[ -z "$target_list" ]] || [[ -z "$completed_list" ]]; then
                _log_console ERROR "Usage: $0 --task <id> --target-list <file> --completed-list <file>"
                return 1
            fi

            if _compare_lists "$target_list" "$completed_list" "$task_id"; then
                record_guard_execution "$task_id" "true"
                return 0
            else
                record_guard_execution "$task_id" "false"
                return 1
            fi
            ;;

        --verify)
            shift
            local task_id="unknown-task"
            local total=0
            local completed=0

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --task) task_id="$2"; shift 2 ;;
                    --total) total="$2"; shift 2 ;;
                    --completed) completed="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done

            if [[ $total -eq 0 ]]; then
                _log_console ERROR "Usage: $0 --verify --total <N> --completed <N> [--task <id>]"
                return 1
            fi

            if print_completion_evidence_with_guard "$task_id" "$total" "$completed"; then
                record_guard_execution "$task_id" "true"
                return 0
            else
                record_guard_execution "$task_id" "false"
                return 1
            fi
            ;;

        *)
            cat <<USAGE
cluster-completion-guard-cl-f6921eb1d5ea4c87.sh — 부분 처리 오선언 방지 가드

클러스터: ${CLUSTER_ID}
설명: ${CLUSTER_NAME}

사용:
  # 대상 목록과 완료 목록 비교
  $0 --task <task_id> --target-list <target_file> --completed-list <completed_file>

  # 완료 검증 및 강제 증거 출력 (부분 완료 차단)
  $0 --verify --total <N> --completed <N> [--task <id>]

기능:
  1. 처리 대상 전체 목록과 실제 완료 항목 자동 대조
  2. "전체 N건 중 N건 처리 완료" 형식 강제 출력
  3. 부분 완료 시 완료 선언 자체를 차단 (exit 1)
  4. 누락 항목 자동 리포팅
  5. 클러스터 재발 추적

로그: $GUARD_LOG
상태: $GUARD_STATE_DIR

USAGE
            return 1
            ;;
    esac
}

export -f print_completion_evidence_with_guard
main "$@"
