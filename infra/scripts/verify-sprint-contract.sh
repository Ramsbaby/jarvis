#!/usr/bin/env bash
set -euo pipefail

# verify-sprint-contract.sh — Sprint Contract 성공 기준 자동 검증
#
# progress.json의 각 successCriteria를 검증:
#   - verifyCmd 있으면 실행 (exit 0 = passed)
#   - verifyCmd 비어있으면 "manual" 표시 (자동 검증 불가 → passed=true로 간주)
#   - e2e-test.sh 연동, 파일 존재 확인, 프로세스 상태 체크 등
#
# Usage: verify-sprint-contract.sh <task_id>
# Output: JSON array of criteria results
#   [{"id":1,"passed":true,"reason":"verifyCmd exit 0"},...]
#
# Exit codes:
#   0 — 모든 criteria passed (또는 manual)
#   1 — 1개 이상 failed
#   2 — contract 파일 없음

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"

TASK_ID="${1:?Usage: verify-sprint-contract.sh <task_id>}"
SC_DIR="${BOT_HOME}/state/sprint-contracts"
CONTRACT_FILE="${SC_DIR}/${TASK_ID}.json"
VERIFY_LOG="${BOT_HOME}/logs/sprint-contract-verify.log"
VERIFY_TIMEOUT=30

mkdir -p "$(dirname "$VERIFY_LOG")"

_vlog() {
    echo "[$(date '+%F %T')] [verify-contract] $1" >> "$VERIFY_LOG"
}

if [[ ! -f "$CONTRACT_FILE" ]]; then
    _vlog "contract 파일 없음: ${CONTRACT_FILE}"
    echo "[]"
    exit 2
fi

# timeout 명령어 탐색 (macOS: gtimeout, Linux: timeout)
_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# --- criteria 순회 검증 ---
CRITERIA_COUNT=$(jq '.contract.successCriteria | length' "$CONTRACT_FILE" 2>/dev/null || echo "0")

if [[ "$CRITERIA_COUNT" -eq 0 ]]; then
    _vlog "criteria 없음 (task=${TASK_ID})"
    echo "[]"
    exit 0
fi

RESULTS="[]"
HAS_FAILURE=false

for (( i=0; i<CRITERIA_COUNT; i++ )); do
    CID=$(jq -r ".contract.successCriteria[$i].id" "$CONTRACT_FILE")
    DESC=$(jq -r ".contract.successCriteria[$i].description" "$CONTRACT_FILE")
    VERIFY_CMD=$(jq -r ".contract.successCriteria[$i].verifyCmd // \"\"" "$CONTRACT_FILE")
    ALREADY_VERIFIED=$(jq -r ".contract.successCriteria[$i].verified" "$CONTRACT_FILE")

    # 이미 verified된 criterion은 재검증 없이 passed
    if [[ "$ALREADY_VERIFIED" == "true" ]]; then
        RESULTS=$(echo "$RESULTS" | jq \
            --argjson id "$CID" \
            '. += [{"id": $id, "passed": true, "reason": "already_verified"}]')
        _vlog "criterion #${CID}: already_verified (${DESC:0:50})"
        continue
    fi

    # verifyCmd 비어있으면 manual → 자동 통과
    if [[ -z "$VERIFY_CMD" || "$VERIFY_CMD" == "null" ]]; then
        RESULTS=$(echo "$RESULTS" | jq \
            --argjson id "$CID" \
            '. += [{"id": $id, "passed": true, "reason": "manual_no_verify_cmd"}]')
        _vlog "criterion #${CID}: manual (자동 검증 불가, passed 간주) — ${DESC:0:50}"
        continue
    fi

    # verifyCmd 내 ~ 확장
    local_cmd="${VERIFY_CMD//\~/$HOME}"

    # 실행
    _vc_exit=0
    _vc_out=""
    if [[ -n "$_TIMEOUT_CMD" ]]; then
        _vc_out=$($_TIMEOUT_CMD "$VERIFY_TIMEOUT" bash -c "$local_cmd" 2>&1) || _vc_exit=$?
    else
        _vc_out=$(bash -c "$local_cmd" 2>&1) || _vc_exit=$?
    fi

    if [[ $_vc_exit -eq 0 ]]; then
        RESULTS=$(echo "$RESULTS" | jq \
            --argjson id "$CID" \
            --arg reason "verifyCmd exit 0" \
            '. += [{"id": $id, "passed": true, "reason": $reason}]')
        _vlog "criterion #${CID}: PASSED — ${DESC:0:50}"
    elif [[ $_vc_exit -eq 124 ]]; then
        # timeout
        RESULTS=$(echo "$RESULTS" | jq \
            --argjson id "$CID" \
            --arg reason "timeout (${VERIFY_TIMEOUT}s)" \
            '. += [{"id": $id, "passed": false, "reason": $reason}]')
        _vlog "criterion #${CID}: TIMEOUT — ${DESC:0:50}"
        HAS_FAILURE=true
    else
        # 실패 사유: 출력의 처음 200자
        reason_text="verifyCmd exit ${_vc_exit}"
        if [[ -n "$_vc_out" ]]; then
            reason_text="${reason_text}: ${_vc_out:0:200}"
        fi
        RESULTS=$(echo "$RESULTS" | jq \
            --argjson id "$CID" \
            --arg reason "$reason_text" \
            '. += [{"id": $id, "passed": false, "reason": $reason}]')
        _vlog "criterion #${CID}: FAILED (exit=${_vc_exit}) — ${DESC:0:50}"
        HAS_FAILURE=true
    fi
done

echo "$RESULTS"

if [[ "$HAS_FAILURE" == "true" ]]; then
    _vlog "검증 결과: 1개 이상 FAILED (task=${TASK_ID})"
    exit 1
else
    _vlog "검증 결과: 전체 PASSED (task=${TASK_ID})"
    exit 0
fi