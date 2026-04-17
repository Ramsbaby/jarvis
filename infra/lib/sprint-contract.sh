#!/usr/bin/env bash
# sprint-contract.sh — Sprint Contract 관리 라이브러리
#
# Anthropic 3-에이전트 아키텍처 Sprint Contract 패턴:
#   Generator와 Evaluator가 "코딩 전에 성공 기준을 협상"하는 구조.
#   태스크 실행 전 성공 기준(contract) 정의 → 반복 검증 → 완료/실패 판정.
#
# 사용법: source "${BOT_HOME}/lib/sprint-contract.sh"
# 의존: BOT_HOME, jq, _coder_log()
#
# 주요 함수:
#   sc_init_dirs          — 디렉토리 초기화
#   sc_exists             — 특정 태스크 contract 존재 여부
#   sc_create             — progress.json 생성
#   sc_read               — progress.json 읽기
#   sc_update_iteration   — iteration 결과 기록
#   sc_mark_criterion     — 개별 criterion 검증 결과 갱신
#   sc_check_complete     — 전체 criteria verified 여부
#   sc_check_exhausted    — maxIterations 초과 여부
#   sc_archive            — 완료/실패 시 archive 이동
#   sc_current_iteration  — 현재 iteration 번호
#   sc_unverified_criteria — 미검증 criteria 목록 (JSON)
#   sc_build_contract_prompt — contract 생성용 프롬프트 조립

: "${BOT_HOME:?BOT_HOME must be set before sourcing sprint-contract.sh}"

SC_DIR="${BOT_HOME}/state/sprint-contracts"
SC_ARCHIVE_DIR="${SC_DIR}/archive"

# --- 디렉토리 초기화 ---
sc_init_dirs() {
    mkdir -p "$SC_DIR" "$SC_ARCHIVE_DIR"
}

# --- contract 파일 경로 ---
_sc_path() {
    local task_id="$1"
    echo "${SC_DIR}/${task_id}.json"
}

# --- contract 존재 여부 ---
sc_exists() {
    local task_id="$1"
    [[ -f "$(_sc_path "$task_id")" ]]
}

# --- contract 생성 ---
# sc_create <task_id> <objective> <success_criteria_json> [max_iterations]
# success_criteria_json: [{"id":1,"description":"...","verifyCmd":"..."},...]
#   verifyCmd 없으면 "manual" 자동 검증 불가 표시
sc_create() {
    local task_id="$1"
    local objective="$2"
    local criteria_json="$3"
    local max_iterations="${4:-5}"

    sc_init_dirs

    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%S+09:00')

    # criteria에 verified: false 기본값 추가
    local enriched_criteria
    enriched_criteria=$(echo "$criteria_json" | jq '[.[] | . + {verified: false}]' 2>/dev/null) || {
        _coder_log "SPRINT_CONTRACT: criteria JSON 파싱 실패: ${criteria_json:0:200}"
        return 1
    }

    local contract
    contract=$(jq -n \
        --arg taskId "$task_id" \
        --arg createdAt "$now" \
        --arg status "in_progress" \
        --arg objective "$objective" \
        --argjson successCriteria "$enriched_criteria" \
        --argjson maxIterations "$max_iterations" \
        '{
            taskId: $taskId,
            createdAt: $createdAt,
            status: $status,
            contract: {
                objective: $objective,
                successCriteria: $successCriteria,
                maxIterations: $maxIterations
            },
            iterations: []
        }') || {
        _coder_log "SPRINT_CONTRACT: contract JSON 생성 실패"
        return 1
    }

    echo "$contract" > "$(_sc_path "$task_id")"
    _coder_log "SPRINT_CONTRACT: 생성 완료 (task=${task_id}, criteria=$(echo "$enriched_criteria" | jq 'length')건)"
    return 0
}

# --- contract 읽기 ---
sc_read() {
    local task_id="$1"
    local path
    path=$(_sc_path "$task_id")
    if [[ -f "$path" ]]; then
        cat "$path"
    else
        echo ""
    fi
}

# --- 현재 iteration 번호 (0-based count) ---
sc_current_iteration() {
    local task_id="$1"
    local path
    path=$(_sc_path "$task_id")
    if [[ -f "$path" ]]; then
        jq '.iterations | length' "$path" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# --- maxIterations 초과 여부 ---
sc_check_exhausted() {
    local task_id="$1"
    local path
    path=$(_sc_path "$task_id")
    [[ -f "$path" ]] || return 1

    local current max
    current=$(jq '.iterations | length' "$path" 2>/dev/null || echo "0")
    max=$(jq '.contract.maxIterations' "$path" 2>/dev/null || echo "5")

    (( current >= max ))
}

# --- 미검증 criteria 목록 (JSON array) ---
sc_unverified_criteria() {
    local task_id="$1"
    local path
    path=$(_sc_path "$task_id")
    if [[ -f "$path" ]]; then
        jq '[.contract.successCriteria[] | select(.verified == false)]' "$path" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# --- 전체 criteria verified 여부 ---
sc_check_complete() {
    local task_id="$1"
    local unverified
    unverified=$(sc_unverified_criteria "$task_id")
    local count
    count=$(echo "$unverified" | jq 'length' 2>/dev/null || echo "1")
    (( count == 0 ))
}

# --- 개별 criterion 검증 결과 갱신 ---
# sc_mark_criterion <task_id> <criterion_id> <passed:true/false> [reason]
sc_mark_criterion() {
    local task_id="$1"
    local criterion_id="$2"
    local passed="$3"
    local reason="${4:-}"
    local path
    path=$(_sc_path "$task_id")
    [[ -f "$path" ]] || return 1

    local verified="false"
    [[ "$passed" == "true" ]] && verified="true"

    local updated
    updated=$(jq \
        --argjson cid "$criterion_id" \
        --argjson verified "$verified" \
        '.contract.successCriteria = [.contract.successCriteria[] |
            if .id == $cid then .verified = $verified else . end]' \
        "$path" 2>/dev/null) || return 1

    echo "$updated" > "$path"
    _coder_log "SPRINT_CONTRACT: criterion #${criterion_id} → passed=${passed} (task=${task_id})"
}

# --- iteration 결과 기록 ---
# sc_update_iteration <task_id> <criteria_results_json>
# criteria_results_json: [{"id":1,"passed":true,"reason":"..."},...]
sc_update_iteration() {
    local task_id="$1"
    local criteria_results="$2"
    local path
    path=$(_sc_path "$task_id")
    [[ -f "$path" ]] || return 1

    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%S+09:00')
    local current_num
    current_num=$(jq '.iterations | length' "$path" 2>/dev/null || echo "0")
    local next_num=$(( current_num + 1 ))

    # criteria 결과에 따라 verified 필드 업데이트
    local cid passed
    while IFS= read -r line; do
        cid=$(echo "$line" | jq -r '.id' 2>/dev/null)
        passed=$(echo "$line" | jq -r '.passed' 2>/dev/null)
        if [[ -n "$cid" && "$cid" != "null" ]]; then
            sc_mark_criterion "$task_id" "$cid" "$passed"
        fi
    done < <(echo "$criteria_results" | jq -c '.[]' 2>/dev/null)

    # iteration 엔트리 추가
    local updated
    updated=$(jq \
        --argjson num "$next_num" \
        --arg startedAt "$now" \
        --arg completedAt "$now" \
        --argjson criteriaResults "$criteria_results" \
        '.iterations += [{
            number: $num,
            startedAt: $startedAt,
            completedAt: $completedAt,
            criteriaResults: $criteriaResults
        }]' \
        "$path" 2>/dev/null) || return 1

    echo "$updated" > "$path"
    _coder_log "SPRINT_CONTRACT: iteration #${next_num} 기록 완료 (task=${task_id})"
}

# --- 상태 업데이트 ---
sc_set_status() {
    local task_id="$1"
    local new_status="$2"
    local path
    path=$(_sc_path "$task_id")
    [[ -f "$path" ]] || return 1

    local updated
    updated=$(jq --arg s "$new_status" '.status = $s' "$path" 2>/dev/null) || return 1
    echo "$updated" > "$path"
}

# --- archive 이동 ---
sc_archive() {
    local task_id="$1"
    local final_status="${2:-completed}"
    local path
    path=$(_sc_path "$task_id")
    [[ -f "$path" ]] || return 0

    sc_init_dirs
    sc_set_status "$task_id" "$final_status"

    local now
    now=$(date '+%Y%m%d-%H%M%S')
    mv "$path" "${SC_ARCHIVE_DIR}/${task_id}-${now}.json"
    _coder_log "SPRINT_CONTRACT: archive 이동 (task=${task_id}, status=${final_status})"
}

# --- contract 생성용 프롬프트 조립 ---
# Claude에게 성공 기준 정의를 요청하는 프롬프트 생성
sc_build_contract_prompt() {
    local task_name="$1"
    local task_prompt="$2"

    cat <<SCEOF
[Sprint Contract 생성 요청]

아래 태스크의 성공 기준(Success Criteria)을 정의하라.

## 태스크
- 이름: ${task_name}
- 설명: ${task_prompt}

## 출력 형식 (반드시 이 JSON만 출력, 다른 텍스트 없이):
\`\`\`json
{
  "objective": "1줄 요약",
  "maxIterations": 3,
  "successCriteria": [
    {
      "id": 1,
      "description": "검증 가능한 기준 설명",
      "verifyCmd": "bash 명령어 (exit 0=통과, exit 1=실패). 자동 검증 불가 시 빈 문자열"
    }
  ]
}
\`\`\`

## 규칙
- successCriteria는 1~5개, 구체적이고 검증 가능하게
- verifyCmd: 파일 존재 확인(test -f), 프로세스 상태(pgrep), e2e 테스트(~/jarvis/runtime/scripts/e2e-test.sh), 문법 검사(bash -n, node --check) 등 활용
- 자동 검증 불가한 기준은 verifyCmd를 빈 문자열("")로 설정
- maxIterations: 태스크 복잡도에 따라 2~5
- JSON 블록만 출력하라. 설명/인사말 없이 \`\`\`json ... \`\`\` 블록만
SCEOF
}

# --- Claude 응답에서 contract JSON 파싱 ---
sc_parse_contract_response() {
    local response="$1"

    # ```json ... ``` 블록 추출
    local json_block
    json_block=$(echo "$response" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d' 2>/dev/null)

    # 블록 추출 실패 시 전체에서 JSON 오브젝트 추출 시도
    if [[ -z "$json_block" ]] || ! echo "$json_block" | jq empty 2>/dev/null; then
        json_block=$(echo "$response" | grep -oP '\{[^{}]*"objective"[^{}]*\}' 2>/dev/null || true)
        # 중첩 JSON 시도
        if [[ -z "$json_block" ]] || ! echo "$json_block" | jq empty 2>/dev/null; then
            json_block=$(echo "$response" | python3 -c "
import sys, json, re
text = sys.stdin.read()
match = re.search(r'\{.*\"objective\".*\}', text, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj))
    except: pass
" 2>/dev/null || true)
        fi
    fi

    if [[ -n "$json_block" ]] && echo "$json_block" | jq '.objective' >/dev/null 2>&1; then
        echo "$json_block"
        return 0
    fi

    return 1
}

# 단독 실행 테스트
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 기본 _coder_log 스텁 (source 없이 실행 시)
    _coder_log() { echo "[$(date '+%F %T')] [sprint-contract] $1"; }

    case "${1:-help}" in
        create-test)
            sc_create "test-task" "테스트 목적" \
                '[{"id":1,"description":"파일 존재 확인","verifyCmd":"test -f /tmp/test.txt"},{"id":2,"description":"수동 검증","verifyCmd":""}]' 3
            echo "생성 완료:"
            sc_read "test-task"
            ;;
        read)
            sc_read "${2:?task_id 필요}"
            ;;
        verify-status)
            if sc_check_complete "${2:?task_id 필요}"; then
                echo "모든 criteria 검증 완료"
            else
                echo "미검증 criteria 존재:"
                sc_unverified_criteria "$2"
            fi
            ;;
        archive)
            sc_archive "${2:?task_id 필요}" "${3:-completed}"
            ;;
        *)
            echo "Usage: $0 {create-test|read <id>|verify-status <id>|archive <id> [status]}"
            ;;
    esac
fi