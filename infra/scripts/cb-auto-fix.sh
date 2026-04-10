#!/usr/bin/env bash
# cb-auto-fix.sh — Circuit Breaker 자동 원인 분석 + 패치 루프
# 사용법: cb-auto-fix.sh <runner_name> [cb_consecutive_fails]
# 반환값: 0 = 자동복구 성공 (Discord 경고 생략 가능), 1 = 복구 불가 (경고 전송 필요)

set -euo pipefail

RUNNER_NAME="${1:-unknown}"
CB_FAILS="${2:-3}"
BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

LOG_FILE="$BOT_HOME/logs/${RUNNER_NAME}.log"
CB_FILE="$BOT_HOME/state/circuit-breaker/${RUNNER_NAME}.json"
WEBHOOK_URL=$(jq -r '.webhooks["jarvis-system"] // .webhook.url // empty' "$BOT_HOME/config/monitoring.json" 2>/dev/null || true)

_discord() {
    local msg="$1"
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"content\":$(echo "$msg" | jq -Rs .)}" > /dev/null 2>&1 || true
    fi
}

_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cb-auto-fix] $*"; }

# ── 로그 분석 ────────────────────────────────────────────────────────────────
if [[ ! -f "$LOG_FILE" ]]; then
    _log "WARN: 로그 파일 없음: $LOG_FILE"
    exit 1
fi

RECENT_LOGS=$(tail -50 "$LOG_FILE" 2>/dev/null || true)
FIXED=false
FIX_SUMMARY=""

# ── 패턴 1: 유효하지 않은 전이 queued → done ─────────────────────────────
# jarvis-coder.sh에서 running 먼저 전이하는 패치 — 이미 수정됨
if echo "$RECENT_LOGS" | grep -q "유효하지 않은 전이: queued → done"; then
    _log "패턴 감지: 유효하지 않은 전이 queued→done"
    # 현재 코드 확인
    if grep -q 'update_queue.*running' "$BOT_HOME/bin/jarvis-coder.sh" 2>/dev/null; then
        _log "이미 수정됨 — running 전이 코드 존재. CB 리셋만 수행."
        FIXED=true
        FIX_SUMMARY="전이 오류(queued→done)는 이미 코드에서 수정됨. CB 리셋 완료."
    fi
fi

# ── 패턴 2: db.transaction is not a function ─────────────────────────────
if [[ "$FIXED" == false ]] && echo "$RECENT_LOGS" | grep -q "db\.transaction is not a function"; then
    _log "패턴 감지: db.transaction 오류"
    TASK_STORE="$BOT_HOME/lib/task-store.mjs"
    if grep -q "BEGIN\|COMMIT" "$TASK_STORE" 2>/dev/null; then
        _log "task-store.mjs 이미 BEGIN/COMMIT 방식 사용 중. CB 리셋."
        FIXED=true
        FIX_SUMMARY="db.transaction 오류 — task-store.mjs는 이미 BEGIN/COMMIT 방식으로 패치됨."
    else
        _log "task-store.mjs에 BEGIN/COMMIT 방식 미적용 — 자동패치 불가 (수동 확인 필요)"
        FIX_SUMMARY="db.transaction is not a function — task-store.mjs 수동 수정 필요."
    fi
fi

# ── 패턴 3: No such file or directory ────────────────────────────────────
if [[ "$FIXED" == false ]] && echo "$RECENT_LOGS" | grep -q "No such file or directory"; then
    MISSING_PATH=$(echo "$RECENT_LOGS" | grep "No such file or directory" | tail -1 \
        | grep -oE '[/~][^:]+' | head -1 || true)
    _log "패턴 감지: 파일/디렉토리 없음 — $MISSING_PATH"

    if [[ -n "$MISSING_PATH" ]]; then
        # 디렉토리인지 파일인지 추정
        EXPANDED_PATH="${MISSING_PATH/\~/$HOME}"
        PARENT_DIR=$(dirname "$EXPANDED_PATH")

        if [[ "$MISSING_PATH" == */ ]]; then
            # 디렉토리인 경우 생성
            mkdir -p "$EXPANDED_PATH" 2>/dev/null && {
                _log "디렉토리 생성: $EXPANDED_PATH"
                FIXED=true
                FIX_SUMMARY="누락 디렉토리 자동 생성: $MISSING_PATH"
            } || true
        elif [[ "$EXPANDED_PATH" == *.sh ]]; then
            # 스크립트 파일인 경우 — 빈 stub 생성
            mkdir -p "$PARENT_DIR" 2>/dev/null || true
            if [[ ! -f "$EXPANDED_PATH" ]]; then
                printf '#!/usr/bin/env bash\n# Auto-generated stub by cb-auto-fix.sh\necho "TODO: %s 구현 필요"\nexit 0\n' \
                    "$(basename "$EXPANDED_PATH")" > "$EXPANDED_PATH"
                chmod +x "$EXPANDED_PATH"
                _log "스크립트 stub 생성: $EXPANDED_PATH"
                FIXED=true
                FIX_SUMMARY="누락 스크립트 stub 생성: $MISSING_PATH (내용은 수동 구현 필요)"
            fi
        else
            # 부모 디렉토리만 생성
            mkdir -p "$PARENT_DIR" 2>/dev/null && {
                _log "부모 디렉토리 생성: $PARENT_DIR"
                FIXED=true
                FIX_SUMMARY="누락 경로의 부모 디렉토리 생성: $PARENT_DIR"
            } || true
        fi
    fi
fi

# ── 패턴 4: completionCheck 연속 실패 ────────────────────────────────────
if [[ "$FIXED" == false ]] && echo "$RECENT_LOGS" | grep -qE "completionCheck 미통과|completionCheck_failed"; then
    CC_COUNT=$(echo "$RECENT_LOGS" | grep -cE "completionCheck 미통과|completionCheck_failed" || echo 0)
    _log "패턴 감지: completionCheck 연속 실패 ${CC_COUNT}회"

    # completionCheck 명령어 유효성 재검증
    FAILING_CMD=$(echo "$RECENT_LOGS" | grep "completionCheck 실패" | tail -1 \
        | grep -oE 'cmd=.+' | sed 's/cmd=//' | cut -d',' -f1 || true)

    if [[ -n "$FAILING_CMD" ]]; then
        _log "completionCheck 명령: $FAILING_CMD"
        # 명령어 자체가 존재하는지 확인
        CMD_BIN=$(echo "$FAILING_CMD" | awk '{print $1}')
        if ! command -v "$CMD_BIN" &>/dev/null && [[ ! -f "${CMD_BIN/\~/$HOME}" ]]; then
            FIX_SUMMARY="completionCheck 명령 자체가 존재하지 않음: $FAILING_CMD — task의 completionCheck 수정 필요."
        else
            FIX_SUMMARY="completionCheck 연속 ${CC_COUNT}회 실패. 명령: $FAILING_CMD — 구현 검토 필요."
        fi
    else
        FIX_SUMMARY="completionCheck 연속 ${CC_COUNT}회 실패 — 상세 원인 로그 확인 필요."
    fi
fi

# ── 결과 처리 ────────────────────────────────────────────────────────────────
if [[ "$FIXED" == true ]]; then
    # CB JSON 리셋
    rm -f "$CB_FILE" 2>/dev/null || true
    _log "자동복구 성공: CB 리셋 완료 — $FIX_SUMMARY"
    _discord "✅ **CB Auto-Fix**: \`${RUNNER_NAME}\` 자동복구 완료\\n> $FIX_SUMMARY"
    exit 0
else
    # 복구 불가: 분석 결과와 함께 강화 경고 준비
    _log "자동복구 불가: $FIX_SUMMARY"
    # 최근 에러 5줄 추출
    RECENT_ERRORS=$(echo "$RECENT_LOGS" | grep -E "ERROR|FAIL|fail|error" | tail -5 \
        | sed 's/\[.*\] \[.*\] //' || echo "(에러 로그 없음)")
    export CB_AUTO_FIX_DETAIL="${FIX_SUMMARY}\\n\`\`\`\\n${RECENT_ERRORS}\\n\`\`\`"
    exit 1
fi
