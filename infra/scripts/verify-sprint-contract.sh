#!/usr/bin/env bash
set -euo pipefail

# verify-sprint-contract.sh — Sprint Contract 성공 기준 자동 검증
#
# progress.json의 각 successCriteria를 검증:
#   - verifyCmd 있으면 실행 (exit 0 = passed)
#   - verifyCmd 비어있으면 passed=false, reason=unverified_no_verify_cmd (fail-closed)
#     2026-09-04 이전엔 "manual" 로 자동 통과시켰다 — 코더가 verifyCmd 를 비워 두면 무검증 done 이 됐고,
#     그 경로로 tasks.json 덮어쓰기 같은 작업이 '완료' 로 승인됐다. 미검증은 통과가 아니다.
#     호출자(coder-functions.sh)는 미검증 기준이 전부 verifyCmd 없음이면 사람 검토로 보류한다.
#   - e2e-test.sh 연동, 파일 존재 확인, 프로세스 상태 체크 등
#
# Usage: verify-sprint-contract.sh <task_id>
# Output: JSON array of criteria results
#   [{"id":1,"passed":true,"reason":"verifyCmd exit 0"},...]
#
# Exit codes:
#   0 — 모든 criteria passed
#   1 — 1개 이상 failed 또는 unverified
#   2 — contract 파일 없음

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/jarvis/runtime}"

TASK_ID="${1:?Usage: verify-sprint-contract.sh <task_id>}"
SC_DIR="${BOT_HOME}/state/sprint-contracts"
SC_ARCHIVE_DIR="${SC_DIR}/archive"
CONTRACT_FILE="${SC_DIR}/${TASK_ID}.json"
VERIFY_LOG="${BOT_HOME}/logs/sprint-contract-verify.log"
VERIFY_TIMEOUT=30

mkdir -p "$(dirname "$VERIFY_LOG")"

_vlog() {
    echo "[$(date '+%F %T')] [verify-contract] $1" >> "$VERIFY_LOG"
}

if [[ ! -f "$CONTRACT_FILE" ]]; then
    # 현재 위치에 없으면 archive에서 가장 최신 파일 찾기
    if [[ -d "$SC_ARCHIVE_DIR" ]]; then
        CONTRACT_FILE=$(find "$SC_ARCHIVE_DIR" -name "${TASK_ID}-*.json" -type f | sort -V | tail -1)
        if [[ -n "$CONTRACT_FILE" ]]; then
            _vlog "contract 파일을 archive에서 찾음: ${CONTRACT_FILE}"
        else
            _vlog "contract 파일 없음 (현재 위치 및 archive): ${TASK_ID}"
            echo "[]"
            exit 2
        fi
    else
        _vlog "contract 파일 없음: ${CONTRACT_FILE}"
        echo "[]"
        exit 2
    fi
fi

# timeout 명령어 탐색 (macOS: gtimeout, Linux: timeout)
_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# 코더 worktree 모드(1b): coder-functions 가 JARVIS_CODER_REPO 로 작업 사본을 넘긴다 — verifyCmd 는 그 안에서 돈다
_WT_REPO=""
if [[ -n "${JARVIS_CODER_REPO:-}" && -d "${JARVIS_CODER_REPO}" ]]; then
    if source "${BOT_HOME}/lib/coder-worktree.sh" 2>/dev/null && type coder_run_cmd &>/dev/null; then
        _WT_REPO="${JARVIS_CODER_REPO}"
        _vlog "worktree 모드: verifyCmd 를 ${_WT_REPO} 에서 실행"
    else
        # 본체에서 대신 검사하면 작업 사본의 변경이 반영되지 않은 채 참/거짓이 나온다 — 검증 불가로 끝낸다 (fail closed)
        _vlog "ERROR: JARVIS_CODER_REPO=${JARVIS_CODER_REPO} 인데 coder-worktree.sh 로드 실패 — 검증 불가"
        echo "[]"
        exit 1
    fi
fi

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

    # verifyCmd 비어있으면 미검증 → 통과 아님 (fail-closed, 2026-09-04)
    if [[ -z "$VERIFY_CMD" || "$VERIFY_CMD" == "null" ]]; then
        RESULTS=$(echo "$RESULTS" | jq \
            --argjson id "$CID" \
            '. += [{"id": $id, "passed": false, "reason": "unverified_no_verify_cmd"}]')
        _vlog "criterion #${CID}: UNVERIFIED (verifyCmd 없음 — 자동 통과 금지, 사람 검토 필요) — ${DESC:0:50}"
        HAS_FAILURE=true
        continue
    fi

    # verifyCmd 내 ~ 확장
    local_cmd="${VERIFY_CMD//\~/$HOME}"

    # 실행 — 코더 worktree 모드(1b)면 본체가 아니라 작업 사본에서 검사한다 (경로 치환 + cd)
    _vc_exit=0
    _vc_out=""
    if [[ -n "$_WT_REPO" ]]; then
        _vc_out=$(coder_run_cmd "$_WT_REPO" "$VERIFY_CMD" "$VERIFY_TIMEOUT" 2>&1) || _vc_exit=$?
    elif [[ -n "$_TIMEOUT_CMD" ]]; then
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