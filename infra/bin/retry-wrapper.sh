#!/usr/bin/env bash
set -euo pipefail

# retry-wrapper.sh - Retry wrapper with exponential backoff for ask-claude.sh
# Usage: retry-wrapper.sh <task-id> <prompt> [allowed-tools] [timeout] [max-budget]

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true
RETRY_LOG="${BOT_HOME}/logs/retry.jsonl"

# Load .env for BOARD_URL and AGENT_API_KEY
if [[ -z "${BOARD_URL:-}" && -f "${JARVIS_HOME:-${HOME}/.local/share/jarvis}/.env" ]]; then
    set -a; source "${JARVIS_HOME:-${HOME}/.local/share/jarvis}/.env"; set +a
fi

# --- Arguments ---
TASK_ID="${1:?Usage: retry-wrapper.sh TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET] [RETENTION]}"
PROMPT="${2:?Usage: retry-wrapper.sh TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET] [RETENTION]}"
ALLOWED_TOOLS="${3:-Read}"
TIMEOUT="${4:-180}"
MAX_BUDGET="${5:-}"
RESULT_RETENTION="${6:-7}"
MODEL="${7:-}"
# 8번째 인수: tasks.json retry.max → bot-cron.sh가 전달 (없으면 3 기본값)
MAX_RETRIES="${8:-3}"
BACKOFF_DELAYS=(5 10 20 40)

mkdir -p "$(dirname "$RETRY_LOG")"

# --- Source semaphore ---
. "$BOT_HOME/bin/semaphore.sh"

# --- Temp file + semaphore management ---
RESULT_TMP="/tmp/claude-retry-${TASK_ID}-$$.out"
ACQUIRED_SLOT=""
_HEARTBEAT_PID=""
cleanup_slot() {
    if [[ -n "${_HEARTBEAT_PID:-}" ]]; then
        kill "$_HEARTBEAT_PID" 2>/dev/null || true
        _HEARTBEAT_PID=""
    fi
    rm -f "$RESULT_TMP" "${RESULT_TMP}.stderr"
    if [[ -n "$ACQUIRED_SLOT" ]]; then
        release_slot "$ACQUIRED_SLOT"
        ACQUIRED_SLOT=""
    fi
}
trap cleanup_slot EXIT

ACQUIRED_SLOT=$(acquire_slot) || {
    echo "All semaphore slots busy, skipping task $TASK_ID" >&2
    # exit 100 = 세마포어 포화 신호 (retry-wrapper가 실행조차 못한 것)
    # jarvis-coder.sh가 이를 감지해 retry 카운트 소모 없이 재큐잉함
    exit 100
}

# --- Live log streaming to Board ---
if [[ -n "${BOARD_URL:-}" && -n "${AGENT_API_KEY:-}" && -n "${TASK_ID:-}" ]]; then
    _board_log_patch() {
        local msg="$1"
        local payload; payload=$(jq -n --arg m "$msg" '{"log_entry": $m}')
        curl -sf --max-time 5 \
            -X PATCH "${BOARD_URL}/api/dev-tasks/${TASK_ID}" \
            -H "Content-Type: application/json" \
            -H "x-agent-key: ${AGENT_API_KEY}" \
            -d "$payload" > /dev/null 2>&1 || true
    }

    # 태스크 제목 가져오기 (로그 메시지에 포함 — "작업 완료"만으로는 무엇을 했는지 알 수 없음)
    _TASK_TITLE=$(curl -sf --max-time 3 \
        "${BOARD_URL}/api/dev-tasks/${TASK_ID}" \
        -H "x-agent-key: ${AGENT_API_KEY}" \
        2>/dev/null | jq -r '.title // empty' | cut -c1-50) || _TASK_TITLE=""

    _START_TS=$(date +%s)

    # 시작 로그: 제목 포함, 중복 시각 제거 (UI 왼쪽 타임스탬프로 이미 표시됨)
    if [[ -n "${_TASK_TITLE:-}" ]]; then
        _board_log_patch "⚙️ 작업 시작 — ${_TASK_TITLE}"
    else
        _board_log_patch "⚙️ 작업 시작"
    fi

    # Background heartbeat: every 30s — 경과 시간 표시
    (
        while true; do
            sleep 30
            _elapsed=$(( $(date +%s) - _START_TS ))
            _board_log_patch "⏳ 진행 중 (${_elapsed}s 경과)"
        done
    ) &
    _HEARTBEAT_PID=$!
fi

# --- Error classification by exit code ---
classify_exit_code() {
    local code="$1"
    case "$code" in
        0)   echo "success" ;;
        2)   echo "non-retryable" ;;
        124) echo "non-retryable" ;; # timeout — 재시도해도 동일하게 실패
        127) echo "non-retryable" ;; # command not found — 재시도해도 동일하게 실패 (md5sum 등 누락 명령어)
        137) echo "retryable" ;;
        143) echo "retryable" ;;
        1)   echo "retryable" ;;
        *)   echo "retryable" ;;
    esac
}

# --- Error classification by stdout+stderr content ---
classify_error() {
    local result_file="$1"
    local stderr_file="${result_file}.stderr"
    local check_files=("$result_file")
    if [[ -f "$stderr_file" ]]; then check_files+=("$stderr_file"); fi
    if grep -qi "rate_limit\|rate limit\|429\|hit your limit\|you've hit\|usage limit" "${check_files[@]}" 2>/dev/null; then echo "RATE_LIMITED"
    elif grep -qi "overloaded\|503\|capacity" "${check_files[@]}" 2>/dev/null; then echo "OVERLOADED"
    elif grep -qi "authentication\|unauthorized\|401" "${check_files[@]}" 2>/dev/null; then echo "AUTH_ERROR"
    elif grep -qi "context_length\|too.long\|too.large" "${check_files[@]}" 2>/dev/null; then echo "TOO_LONG"
    else echo "UNKNOWN"; fi
}

# --- JSONL log entry ---
log_retry() {
    local attempt="$1" exit_code="$2" classification="$3" duration_s="$4"
    printf '{"timestamp":"%s","task_id":"%s","attempt":%d,"exit_code":%d,"classification":"%s","duration_s":%s}\n' \
        "$(date -u +%FT%TZ)" "$TASK_ID" "$attempt" "$exit_code" "$classification" "$duration_s" \
        >> "$RETRY_LOG"
}

# --- Retry loop ---
for attempt in $(seq 1 "$MAX_RETRIES"); do
    start_s=$(date +%s)

    exit_code=0
    DEV_TASK_ID="$TASK_ID" "$BOT_HOME/bin/ask-claude.sh" "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" "$TIMEOUT" "$MAX_BUDGET" "$RESULT_RETENTION" "$MODEL" \
        > "$RESULT_TMP" 2>"${RESULT_TMP}.stderr" || exit_code=$?

    end_s=$(date +%s)
    duration_s=$(( end_s - start_s ))

    # Classify by exit code first
    classification=$(classify_exit_code "$exit_code")

    # INC-1/2 안전장치: exit=1이지만 Discord 전송 성공(sent id=) 시 success로 강제
    # council-insight, dev-run-async에서 SDK 내부 exit=1이지만 기능은 성공한 케이스 대응
    # 패턴 확장: "sent id=" 또는 "sent id =" (공백 포함) 대응
    if [[ "$exit_code" -eq 1 && -f "$RESULT_TMP" ]] && grep -qE "sent\s+id\s*=" "$RESULT_TMP" 2>/dev/null; then
        classification="success"
        printf '{"timestamp":"%s","task_id":"%s","attempt":%d,"override":"exit1_but_sent_id_found"}\n' \
            "$(date -u +%FT%TZ)" "$TASK_ID" "$attempt" >> "$RETRY_LOG"
    fi

    # If retryable by exit code, refine classification from output
    if [[ "$classification" == "retryable" && "$exit_code" -ne 0 ]]; then
        stdout_class=$(classify_error "$RESULT_TMP")
        case "$stdout_class" in
            AUTH_ERROR|TOO_LONG)
                classification="non-retryable"
                ;;
            RATE_LIMITED)
                classification="rate_limited"
                ;;
            OVERLOADED)
                classification="retryable"
                ;;
        esac
    fi

    log_retry "$attempt" "$exit_code" "$classification" "$duration_s"

    # --- Output quality check (exit_code=0이어도 결과 품질 검증) ---
    if [[ "$classification" == "success" ]]; then
        RESULT_LEN=0
        if [[ -f "$RESULT_TMP" ]]; then
            RESULT_LEN=$(wc -c < "$RESULT_TMP" | tr -d ' ')
        fi
        RESULT_HAS_ERROR=false
        if [[ -f "$RESULT_TMP" ]] && grep -qiE "^Error:|^\[Error\]|\"error\":" "$RESULT_TMP" 2>/dev/null; then
            RESULT_HAS_ERROR=true
        fi

        if [[ "$RESULT_LEN" -eq 0 ]]; then
            classification="retryable"
            printf '{"timestamp":"%s","task_id":"%s","attempt":%d,"quality_fail":"empty_output"}\n' \
                "$(date -u +%FT%TZ)" "$TASK_ID" "$attempt" >> "$RETRY_LOG"
        elif [[ "$RESULT_HAS_ERROR" == "true" ]]; then
            classification="retryable"
            printf '{"timestamp":"%s","task_id":"%s","attempt":%d,"quality_fail":"error_in_output"}\n' \
                "$(date -u +%FT%TZ)" "$TASK_ID" "$attempt" >> "$RETRY_LOG"
        fi
    fi

    # Success - output result and exit
    if [[ "$classification" == "success" ]]; then
        cat "$RESULT_TMP"
        exit 0
    fi

    # Non-retryable - fail immediately
    if [[ "$classification" == "non-retryable" ]]; then
        cat "$RESULT_TMP" >&2
        exit "$exit_code"
    fi

    # Last attempt exhausted
    if [[ "$attempt" -eq "$MAX_RETRIES" ]]; then
        break
    fi

    # Compute backoff delay
    delay="${BACKOFF_DELAYS[$((attempt - 1))]}"
    if [[ "$classification" == "rate_limited" ]]; then
        # Rate limit은 5시간 윈도우 기반 → 짧은 재시도는 무의미
        # 1차: 5분, 2차: 15분 대기 (크론 다음 실행까지 양보)
        delay=$(( 300 * attempt ))
    fi

    sleep "$delay"
done

# --- Classify failure reason (detailed, for cron.log + proposals) ---
classify_failure() {
    local exit_code="$1"
    local stderr_file="$2"

    if [[ $exit_code -eq 124 ]]; then
        echo "TIMEOUT"
    elif [[ -f "$stderr_file" ]] && grep -qiE "rate.limit|429|overloaded|too many|hit your limit|you've hit|usage limit" "$stderr_file" 2>/dev/null; then
        echo "RATE_LIMIT"
    elif [[ -f "$stderr_file" ]] && grep -qiE "401|authentication|unauthorized|api.key" "$stderr_file" 2>/dev/null; then
        echo "AUTH_ERROR"
    elif [[ -f "$stderr_file" ]] && grep -qiE "context_length|too.long|too.large" "$stderr_file" 2>/dev/null; then
        echo "CONTEXT_TOO_LONG"
    else
        echo "UNKNOWN"
    fi
}

# --- Check repeated failures and auto-propose ---
check_repeated_failures() {
    local task_id="$1"
    local fail_class="$2"
    local cron_log="${BOT_HOME}/logs/cron.log"
    local tracker="${BOT_HOME}/rag/teams/proposals-tracker.md"

    # Count same TASK_ID + same class in last 24h from cron.log
    local cutoff
    cutoff=$(date -v-24H +%F 2>/dev/null || date -d '24 hours ago' +%F 2>/dev/null || echo "")
    if [[ -z "$cutoff" ]]; then
        return 0
    fi

    local count=0
    if [[ -f "$cron_log" ]]; then
        count=$(grep "\[${task_id}\].*\[FAILED:${fail_class}\]" "$cron_log" 2>/dev/null \
            | awk -v cutoff="$cutoff" '$0 >= cutoff' \
            | wc -l | tr -d ' ' || echo "0")
    fi

    # 3+ failures of same type → auto-propose + Discord alert
    if [[ "$count" -ge 3 ]]; then
        # Discord 알림 (proposals-tracker 유무와 무관하게 항상 전송)
        # 중복 알림 방지: 오늘 날짜 기준 sentinel 파일 확인
        local sentinel
        sentinel="${BOT_HOME}/logs/.repeated-fail-${task_id}-${fail_class}-$(date +%F)"
        if [[ ! -f "$sentinel" ]]; then
            touch "$sentinel" 2>/dev/null || true
            "$BOT_HOME/bin/route-result.sh" alert "$task_id" \
                "🔴 반복 실패 감지: [$task_id] $fail_class ${count}회 연속 — 점검 필요" 2>/dev/null || true
        fi

        if [[ -f "$tracker" ]]; then
            local proposal_id entry
            proposal_id="P-$(date +%m%d)-auto"
            entry="| ${proposal_id} | [${task_id}] ${fail_class} 반복 실패 (${count}회+) | L2 | ⏳ 대기 | $(date +%F) |"

            # Avoid duplicate proposals for same task+class today
            if ! grep -q "\[${task_id}\] ${fail_class}" "$tracker" 2>/dev/null; then
                # Insert before the "반복 패턴 감지" section
                if grep -q "아직 등록된 제안 없음" "$tracker" 2>/dev/null; then
                    if ${IS_MACOS:-false}; then
                        sed -i '' "s|_아직 등록된 제안 없음_|${entry}|" "$tracker" 2>/dev/null || true
                    else
                        sed -i "s|_아직 등록된 제안 없음_|${entry}|" "$tracker" 2>/dev/null || true
                    fi
                else
                    if ${IS_MACOS:-false}; then
                        sed -i '' "/^## 📌 반복 패턴 감지/i\\
${entry}" "$tracker" 2>/dev/null || true
                    else
                        sed -i "/^## 📌 반복 패턴 감지/i\\
${entry}" "$tracker" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    fi
}

# All retries exhausted - classify, log, and alert
STDERR_FILE="${BOT_HOME}/logs/claude-stderr-${TASK_ID}.log"
# stdout(result)과 stderr 모두 확인 (rate limit 메시지는 stdout에 오는 경우 있음)
FAIL_CLASS=$(classify_failure "$exit_code" "$STDERR_FILE")
if [[ "$FAIL_CLASS" == "UNKNOWN" && -f "$RESULT_TMP" ]]; then
    if grep -qiE "rate.limit|429|hit your limit|you've hit|usage limit|too many" "$RESULT_TMP" 2>/dev/null; then
        FAIL_CLASS="RATE_LIMIT"
    fi
fi

# 최후의 안전장치: RESULT_TMP에서 "sent id=" 발견 시 SUCCESS로 강제 전환 (exit=1 무시)
# MT-3 버그: exit code 대신 출력 내용 기반 성공 판정 추가
if [[ "$exit_code" -eq 1 && "$FAIL_CLASS" == "UNKNOWN" && -f "$RESULT_TMP" ]] && grep -qE "sent\s+id\s*=" "$RESULT_TMP" 2>/dev/null; then
    printf '{"timestamp":"%s","task_id":"%s","output_contains_sent_id":"forced_success"}\n' \
        "$(date -u +%FT%TZ)" "$TASK_ID" >> "$RETRY_LOG"
    cat "$RESULT_TMP"
    exit 0
fi

# Log to cron.log with failure classification
CRON_LOG="${BOT_HOME}/logs/cron.log"
printf '[%s] [%s] [FAILED:%s] exit=%d retries=%d\n' \
    "$(date '+%F %H:%M:%S')" "$TASK_ID" "$FAIL_CLASS" "${exit_code:-1}" "$MAX_RETRIES" \
    >> "$CRON_LOG"

# FAILED:UNKNOWN 시 stdout 앞 300자를 cron.log에 추가 기록 (원인 추적용)
if [[ "$FAIL_CLASS" == "UNKNOWN" && -f "$RESULT_TMP" ]]; then
    _stdout_snippet=$(head -c 300 "$RESULT_TMP" 2>/dev/null | tr '\n' ' ')
    if [[ -n "$_stdout_snippet" ]]; then
        printf '[%s] [%s] [STDOUT_SNIPPET] %s\n' \
            "$(date '+%F %H:%M:%S')" "$TASK_ID" "$_stdout_snippet" \
            >> "$CRON_LOG"
    fi
fi

# RATE_LIMIT은 Claude Max 한도 소진 — 예측 가능한 상황, Discord 알림 불필요
if [[ "$FAIL_CLASS" == "RATE_LIMIT" ]]; then
    cat "$RESULT_TMP" >&2
    exit "${exit_code:-1}"
fi

# Check for repeated failure pattern → auto-propose
check_repeated_failures "$TASK_ID" "$FAIL_CLASS"

# 사람이 읽을 수 있는 실패 사유 생성
human_reason() {
    local cls="$1" code="$2" result_file="$3" stderr_file="$4"
    case "$cls" in
        TIMEOUT)       echo "⏱️ 실행 시간 초과 (${TIMEOUT}s 초과)" ;;
        AUTH_ERROR)    echo "🔑 API 인증 오류 — API 키 확인 필요" ;;
        CONTEXT_TOO_LONG) echo "📄 프롬프트 너무 김 — 컨텍스트 축소 필요" ;;
        RATE_LIMIT)    echo "🚦 Claude Max 한도 초과 — 자동 리셋 대기" ;;
        *)
            # UNKNOWN: 실제 에러 메시지 한 줄 추출
            local snippet=""
            for f in "$result_file" "$stderr_file"; do
                [[ -f "$f" ]] || continue
                snippet=$(grep -v '^$' "$f" 2>/dev/null \
                    | grep -v '^{' \
                    | tail -1 \
                    | cut -c1-120)
                if [[ -n "$snippet" ]]; then break; fi
            done
            # result JSON에서 "result" 필드 추출 시도
            if [[ -z "$snippet" && -f "$result_file" ]]; then
                snippet=$(grep -o '"result":"[^"]*"' "$result_file" 2>/dev/null \
                    | head -1 \
                    | sed 's/"result":"//;s/"$//' \
                    | cut -c1-120)
            fi
            if [[ -n "$snippet" ]]; then
                echo "❌ 알 수 없는 오류 (exit=$code)\n사유: $snippet"
            else
                echo "❌ 알 수 없는 오류 (exit=$code)"
            fi
            ;;
    esac
}

REASON=$(human_reason "$FAIL_CLASS" "${exit_code:-1}" "$RESULT_TMP" "$STDERR_FILE")

"$BOT_HOME/bin/route-result.sh" alert "$TASK_ID" \
    "⚠️ $TASK_ID 실패 (재시도 ${MAX_RETRIES}회)\n$REASON"

cat "$RESULT_TMP" >&2
exit "${exit_code:-1}"
