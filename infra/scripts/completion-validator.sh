#!/usr/bin/env bash
# completion-validator.sh
# 작업 완료 검증 자동화 가드
#
# 목적: 부분 완료 오선언 방지
# - 처리 대상 전체 목록과 실제 완료 항목을 자동으로 대조
# - 작업 완료 선언 시 "전체 N건 중 N건 처리 완료" 형식의 증거 강제 출력
#
# 사용:
#   completion_validator --task <task_id> [--items <file>] [--completed <file>]
#   completion_validator --verify --task <task_id> --total N --completed N
#   completion_validator --list-tasks
#
# 예:
#   completion_validator --task my-task --items target.jsonl --completed result.jsonl
#   completion_validator --verify --task my-task --total 50 --completed 50

set -euo pipefail

VALIDATOR_STATE="${HOME}/jarvis/runtime/state/completion-validator"
VALIDATOR_LOG="${HOME}/jarvis/runtime/logs/completion-validator.log"

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 초기화
mkdir -p "$VALIDATOR_STATE" 2>/dev/null || true
mkdir -p "$(dirname "$VALIDATOR_LOG")" 2>/dev/null || true

# 로깅 함수
_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    echo "[${timestamp}] [${level}] ${message}" >> "$VALIDATOR_LOG"
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
        *)
            echo "ℹ️  ${message}"
            ;;
    esac
}

# 작업 추적 파일 초기화
_init_task_tracker() {
    local task_id="$1"
    local tracker_file="$VALIDATOR_STATE/${task_id}.json"

    if [[ ! -f "$tracker_file" ]]; then
        cat > "$tracker_file" <<EOF
{
  "task_id": "${task_id}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "initialized",
  "target_items": [],
  "completed_items": [],
  "total_target": 0,
  "total_completed": 0,
  "completion_ratio": 0.0,
  "verification_history": []
}
EOF
        _log INFO "Task tracker initialized: $task_id"
    fi
}

# 대상 항목 목록 등록
_register_items() {
    local task_id="$1"
    local items_file="$2"
    local tracker_file="$VALIDATOR_STATE/${task_id}.json"

    if [[ ! -f "$items_file" ]]; then
        _log_console ERROR "Items file not found: $items_file"
        return 1
    fi

    # 파일에서 항목 개수 계산 (JSONL 형식 기준)
    local total=$(wc -l < "$items_file" | tr -d ' ')

    _log INFO "Registered target items for $task_id: $total items from $items_file"

    # tracker 파일 업데이트 (jq 대신 sed/awk로 처리)
    local temp_file="${tracker_file}.tmp"

    # Python을 사용하여 JSON 업데이트
    python3 << PYTHON_SCRIPT
import json
import sys
from datetime import datetime

tracker_file = "$tracker_file"
items_file = "$items_file"

try:
    with open(tracker_file, 'r') as f:
        tracker = json.load(f)

    # 항목 읽기
    target_items = []
    try:
        with open(items_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line:
                    target_items.append(line)
    except:
        pass

    tracker['target_items'] = target_items
    tracker['total_target'] = len(target_items)
    tracker['status'] = 'items_registered'

    with open(tracker_file, 'w') as f:
        json.dump(tracker, f, indent=2, ensure_ascii=False)

    print(f"Registered {len(target_items)} target items")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
}

# 완료 항목 등록
_register_completed() {
    local task_id="$1"
    local completed_file="$2"
    local tracker_file="$VALIDATOR_STATE/${task_id}.json"

    if [[ ! -f "$completed_file" ]]; then
        _log_console ERROR "Completed items file not found: $completed_file"
        return 1
    fi

    _log INFO "Registering completed items for $task_id from $completed_file"

    # Python을 사용하여 JSON 업데이트
    python3 << PYTHON_SCRIPT
import json
import sys
from datetime import datetime

tracker_file = "$tracker_file"
completed_file = "$completed_file"

try:
    with open(tracker_file, 'r') as f:
        tracker = json.load(f)

    # 완료 항목 읽기
    completed_items = []
    try:
        with open(completed_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line:
                    completed_items.append(line)
    except:
        pass

    tracker['completed_items'] = completed_items
    tracker['total_completed'] = len(completed_items)

    # 완료율 계산
    if tracker['total_target'] > 0:
        tracker['completion_ratio'] = tracker['total_completed'] / tracker['total_target']

    tracker['status'] = 'completed_registered'

    with open(tracker_file, 'w') as f:
        json.dump(tracker, f, indent=2, ensure_ascii=False)

    print(f"Registered {len(completed_items)} completed items")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
}

# 완료 검증 및 강제 보고
_verify_completion() {
    local task_id="$1"
    local tracker_file="$VALIDATOR_STATE/${task_id}.json"

    if [[ ! -f "$tracker_file" ]]; then
        _log_console ERROR "Task tracker not found: $task_id"
        return 1
    fi

    # tracker 파일에서 정보 추출
    python3 << PYTHON_SCRIPT
import json
import sys
from datetime import datetime

tracker_file = "$tracker_file"

try:
    with open(tracker_file, 'r') as f:
        tracker = json.load(f)

    total = tracker['total_target']
    completed = tracker['total_completed']
    ratio = tracker['completion_ratio']

    # 필수 증거 출력 (고정 형식)
    print(f"")
    print(f"═" * 60)
    print(f"📊 COMPLETION VERIFICATION REPORT")
    print(f"═" * 60)
    print(f"Task ID:          {tracker['task_id']}")
    print(f"Verification:     {datetime.now().isoformat()}")
    print(f"━" * 60)
    print(f"📋 Total Items:        {total}")
    print(f"✅ Completed Items:    {completed}")
    print(f"━" * 60)
    print(f"📈 Completion Ratio:   {completed}/{total} ({ratio*100:.1f}%)")
    print(f"━" * 60)

    # 부분 완료 경고
    if completed < total:
        print(f"${RED}⚠️  INCOMPLETE: {total - completed} items remaining${NC}")
        print(f"Status: INCOMPLETE - Do not declare completion until all items are processed")
    else:
        print(f"$GREEN✅ COMPLETE: All {total} items processed${NC}")
        print(f"Status: COMPLETE")

    print(f"═" * 60)
    print(f"")

    # 검증 이력 기록
    tracker['verification_history'].append({
        'timestamp': datetime.now().isoformat(),
        'total': total,
        'completed': completed,
        'passed': completed >= total
    })

    with open(tracker_file, 'w') as f:
        json.dump(tracker, f, indent=2, ensure_ascii=False)

    # 불완전 시 실패 코드 반환
    if completed < total:
        sys.exit(1)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
}

# 강제 증거 출력 (핵심 기능)
# 이 함수는 작업 완료 선언 시 호출되어야 함
print_completion_evidence() {
    local task_id="$1"
    local total="$2"
    local completed="$3"
    local remaining=$((total - completed))

    # 강제 형식: "전체 N건 중 N건 처리 완료"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "📊 COMPLETION EVIDENCE (작업 완료 선언 증거)"
    echo "═══════════════════════════════════════════════════════════════"
    echo "Task:                ${task_id}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Total Processed:     [${completed}/${total}]"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "$completed" -eq "$total" ]]; then
        echo -e "${GREEN}✅ SUCCESS: 전체 ${total}건 중 ${completed}건 처리 완료${NC}"
        echo "Status: FULLY COMPLETED"
    else
        echo -e "${RED}❌ INCOMPLETE: 전체 ${total}건 중 ${completed}건만 처리 (${remaining}건 미처리)${NC}"
        echo "Status: PARTIAL COMPLETION DETECTED - DO NOT DECLARE COMPLETION"
        return 1
    fi

    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

# 작업 목록 조회
_list_tasks() {
    echo "Tracked Tasks:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ! -d "$VALIDATOR_STATE" ]] || [[ -z "$(ls -A "$VALIDATOR_STATE" 2>/dev/null)" ]]; then
        echo "No tracked tasks"
        return 0
    fi

    for tracker_file in "$VALIDATOR_STATE"/*.json; do
        if [[ -f "$tracker_file" ]]; then
            python3 << PYTHON_SCRIPT
import json
import sys
from datetime import datetime

try:
    with open("$tracker_file", 'r') as f:
        tracker = json.load(f)

    task_id = tracker['task_id']
    total = tracker['total_target']
    completed = tracker['total_completed']
    status = tracker['status']

    if total > 0:
        ratio = (completed / total) * 100
        print(f"  {task_id}: {completed}/{total} ({ratio:.1f}%) [{status}]")
    else:
        print(f"  {task_id}: (no items) [{status}]")
except Exception as e:
    print(f"  Error reading {tracker_file}: {e}", file=sys.stderr)
PYTHON_SCRIPT
        fi
    done
}

# 메인 진입점
main() {
    local cmd="${1:-}"

    case "$cmd" in
        --task)
            local task_id="${2:-}"
            local items_file="${4:-}"
            local completed_file="${6:-}"

            if [[ -z "$task_id" ]]; then
                _log_console ERROR "Task ID required: --task <task_id>"
                return 1
            fi

            _init_task_tracker "$task_id"

            if [[ -n "$items_file" ]]; then
                _register_items "$task_id" "$items_file"
            fi

            if [[ -n "$completed_file" ]]; then
                _register_completed "$task_id" "$completed_file"
                _verify_completion "$task_id"
            fi
            ;;

        --verify)
            local task_id=""
            local total=""
            local completed=""

            # 파라미터 파싱
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --task) task_id="$2"; shift 2 ;;
                    --total) total="$2"; shift 2 ;;
                    --completed) completed="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done

            if [[ -z "$task_id" ]] || [[ -z "$total" ]] || [[ -z "$completed" ]]; then
                _log_console ERROR "Usage: completion-validator.sh --verify --task <id> --total <n> --completed <n>"
                return 1
            fi

            print_completion_evidence "$task_id" "$total" "$completed"
            ;;

        --list-tasks)
            _list_tasks
            ;;

        *)
            cat <<USAGE
completion-validator.sh — 작업 완료 검증 자동화 가드

사용:
  # 작업 추적 초기화 및 항목 등록
  $0 --task <task_id> --items <target_file> --completed <result_file>

  # 완료 검증 및 강제 증거 출력
  $0 --verify --task <task_id> --total <N> --completed <N>

  # 추적 중인 작업 목록
  $0 --list-tasks

형식:
  - 강제 증거 출력: "전체 N건 중 N건 처리 완료"
  - 부분 완료는 자동으로 감지 및 경고
  - 모든 항목 처리 전까지 완료 선언 불가

로그: $VALIDATOR_LOG
상태: $VALIDATOR_STATE

USAGE
            return 1
            ;;
    esac
}

# Export 함수 (외부 호출용)
export -f print_completion_evidence

main "$@"
