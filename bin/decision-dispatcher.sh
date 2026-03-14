#!/usr/bin/env bash
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-$HOME/.jarvis}}/lib/compat.sh" 2>/dev/null || true
set -euo pipefail

# decision-dispatcher.sh — Board Meeting 결정사항 자동 실행 + 팀 성과 평가
# board-meeting.sh 종료 후 호출됨
# 위임 가능한 결정은 자동 처리, 불가능한 건 보고만

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TODAY="$(date +%F)"

# timeout 명령어 크로스플랫폼 처리 (macOS: gtimeout, Linux: timeout)
_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# Structured logging
LOG_FILE="${BOT_HOME}/logs/decision-dispatcher.log"
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true

# 의존성 검증
for _cmd in jq python3; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
        echo "FATAL: $_cmd not found" >&2
        exit 2
    fi
done

# 동시 실행 방지 (scorecard read-modify-write 경쟁조건 차단)
LOCK_FILE="/tmp/jarvis-dispatcher.lock"
if [[ -f "$LOCK_FILE" ]]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        echo "Another dispatcher is running (PID $lock_pid), exiting" >&2
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT
DECISIONS_FILE="${BOT_HOME}/state/decisions/${TODAY}.jsonl"
SCORECARD="${BOT_HOME}/state/team-scorecard.json"
DISPATCH_LOG="${BOT_HOME}/logs/decision-dispatcher.log"
DISPATCH_RESULTS="${BOT_HOME}/state/dispatch-results/${TODAY}.jsonl"

mkdir -p "$(dirname "$DISPATCH_LOG")" "$(dirname "$DISPATCH_RESULTS")"

log() { echo "[$(date -u +%FT%TZ)] dispatcher: $*" >> "$DISPATCH_LOG"; }

if [[ ! -f "$DECISIONS_FILE" ]]; then
    log "No decisions file for ${TODAY}, nothing to dispatch"
    exit 0
fi

if [[ ! -f "$SCORECARD" ]]; then
    log "ERROR: team-scorecard.json not found"
    exit 1
fi

# --- Action Registry: 결정 키워드 → 실행 가능한 l3-action 매핑 ---
# bash 3.x 호환 (declare -A 사용 불가)
# 키워드|액션타입 형식
ACTION_REGISTRY="
재시작|restart-service
restart|restart-service
스테일|kill-stale
stale|kill-stale
로그 정리|cleanup-logs
디스크 정리|cleanup-disk
결과 정리|cleanup-results
RAG 재시작|restart-rag
rag 재시작|restart-rag
rag restart|restart-rag
Vault 동기화|sync-vault
vault 동기화|sync-vault
vault sync|sync-vault
e2e 실행|run-e2e
e2e test|run-e2e
"

match_action() {
    local decision="$1"
    local result=""
    while IFS='|' read -r keyword action; do
        keyword=$(echo "$keyword" | xargs)
        action=$(echo "$action" | xargs)
        if [[ -n "$keyword" ]] && echo "$decision" | grep -qi "$keyword"; then
            result="$action"
            break
        fi
    done <<< "$ACTION_REGISTRY"
    echo "$result"
}

# 실행 불가 키워드 (보고만)
REPORT_ONLY_KEYWORDS="손절|매수|매도|TQQQ|투자|아키텍처|예산|모니터링 강화"

# --- 실제 액션 실행 함수들 ---
action_restart_service() {
    local decision="$1"
    local uid
    uid=$(id -u)
    local _err
    _err=$(mktemp)

    # 결정 내용에서 서비스 식별
    if echo "$decision" | grep -qi "orchestrator"; then
        if $IS_MACOS && launchctl list 2>/dev/null | grep -q "jarvis.orchestrator"; then
            if launchctl kickstart -k "gui/${uid}/ai.jarvis.orchestrator" 2>"$_err"; then
                rm -f "$_err"; echo "OK"; return 0
            fi
            log "WARN: orchestrator kickstart: $(cat "$_err")"
        fi
        local plist="$HOME/Library/LaunchAgents/ai.jarvis.orchestrator.plist"
        if $IS_MACOS && [[ -f "$plist" ]]; then
            if launchctl bootstrap "gui/${uid}" "$plist" 2>"$_err"; then
                rm -f "$_err"; echo "OK"; return 0
            fi
            log "WARN: orchestrator bootstrap: $(cat "$_err")"
        fi
        if ! $IS_MACOS; then
            if pm2 restart jarvis-orchestrator 2>"$_err" \
               || pm2 restart jarvis-bot 2>/dev/null \
               || pm2 restart all 2>/dev/null; then
                rm -f "$_err"; echo "OK"; return 0
            fi
            log "WARN: orchestrator pm2 restart: $(cat "$_err")"; rm -f "$_err"
            echo "FAIL:orchestrator pm2 restart failed"; return 1
        fi
        rm -f "$_err"; echo "FAIL:orchestrator plist not found"; return 1
    elif echo "$decision" | grep -qi "discord\|bot"; then
        if "${BOT_HOME}/scripts/l3-actions/restart-bot.sh" 2>"$_err"; then
            rm -f "$_err"; echo "OK"; return 0
        fi
        log "WARN: bot restart: $(cat "$_err")"; rm -f "$_err"
        echo "FAIL:bot restart failed"; return 1
    elif echo "$decision" | grep -qi "watchdog"; then
        if $IS_MACOS && launchctl kickstart -k "gui/${uid}/ai.jarvis.watchdog" 2>"$_err"; then
            rm -f "$_err"; echo "OK"; return 0
        fi
        if ! $IS_MACOS; then
            if pm2 restart jarvis-bot 2>"$_err" \
               || pm2 restart all 2>/dev/null; then
                rm -f "$_err"; echo "OK"; return 0
            fi
            log "WARN: watchdog pm2 restart: $(cat "$_err")"; rm -f "$_err"
            echo "FAIL:watchdog pm2 restart failed"; return 1
        fi
        log "WARN: watchdog kickstart: $(cat "$_err")"; rm -f "$_err"
        echo "FAIL:watchdog restart failed"; return 1
    fi
    rm -f "$_err"; echo "SKIP:unrecognized service"; return 2
}

_run_l3_action() {
    local label="$1" script="$2" max_sec="${3:-120}"
    local _err rc
    _err=$(mktemp)
    if [[ -n "$_TIMEOUT_CMD" ]]; then
        "$_TIMEOUT_CMD" "$max_sec" "$script" 2>"$_err"
        rc=$?
    else
        "$script" 2>"$_err"
        rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        rm -f "$_err"; echo "OK"; return 0
    fi
    if [[ $rc -eq 124 ]]; then
        log "WARN: ${label}: timeout after ${max_sec}s"
        rm -f "$_err"; echo "FAIL:${label} timed out"; return 1
    fi
    log "WARN: ${label}: $(tail -2 "$_err" | tr '\n' ' ')"; rm -f "$_err"
    echo "FAIL:${label} failed"; return 1
}

action_kill_stale() {
    _run_l3_action "kill-stale" "${BOT_HOME}/scripts/l3-actions/kill-stale-claude.sh"
}

action_cleanup_logs() {
    _run_l3_action "cleanup-logs" "${BOT_HOME}/scripts/l3-actions/cleanup-logs.sh"
}

action_cleanup_disk() {
    _run_l3_action "cleanup-disk" "${BOT_HOME}/scripts/l3-actions/cleanup-results.sh"
}

action_cleanup_results() {
    _run_l3_action "cleanup-results" "${BOT_HOME}/scripts/l3-actions/cleanup-results.sh"
}

action_restart_rag() {
    local uid
    uid=$(id -u)
    local _err
    _err=$(mktemp)
    if $IS_MACOS && launchctl kickstart -k "gui/${uid}/ai.jarvis.rag-watcher" 2>"$_err"; then
        rm -f "$_err"; echo "OK:rag-watcher restarted"; return 0
    fi
    if ! $IS_MACOS; then
        pm2 restart jarvis-rag-watcher 2>"$_err" && { rm -f "$_err"; echo "OK:rag-watcher restarted"; return 0; } || true
    fi
    log "WARN: rag-watcher kickstart: $(cat "$_err")"; rm -f "$_err"
    echo "FAIL:rag-watcher restart failed"; return 1
}

action_sync_vault() {
    _run_l3_action "sync-vault" "${BOT_HOME}/scripts/vault-sync.sh" 300
}

action_run_e2e() {
    _run_l3_action "run-e2e" "${BOT_HOME}/scripts/e2e-test.sh" 600
}

action_analyze_cron_failure() {
    # 크론 실패 원인 분석: 오늘 실패 로그를 추출하고 결과 저장
    local fail_log
    fail_log=$(grep "$TODAY" "${BOT_HOME}/logs/cron.log" 2>/dev/null | grep "FAILED" | tail -10)
    if [[ -z "$fail_log" ]]; then
        echo "OK:no failures found"
        return 0
    fi
    # 실패 태스크별 마지막 에러 확인
    local analysis_file="${BOT_HOME}/state/dispatch-results/cron-analysis-${TODAY}.md"
    {
        echo "# 크론 실패 분석 — ${TODAY}"
        echo ""
        echo "$fail_log" | while IFS= read -r line; do
            local task_id
            task_id=$(echo "$line" | grep -oE '\[([a-z-]+)\]' | tr -d '[]' | head -1)
            if [[ -n "$task_id" ]]; then
                echo "## ${task_id}"
                echo '```'
                echo "$line"
                # 해당 태스크의 stderr 로그 확인
                local stderr_log="${BOT_HOME}/logs/claude-stderr-${task_id}.log"
                if [[ -f "$stderr_log" ]]; then
                    echo "--- stderr (last 5 lines) ---"
                    tail -5 "$stderr_log" 2>/dev/null || true
                fi
                echo '```'
                echo ""
            fi
        done
    } > "$analysis_file"
    echo "OK:analysis saved to ${analysis_file}"
    return 0
}

# --- 결정 분류 및 실행 ---
dispatch_decision() {
    local decision="$1" team="$2"
    local action_type="REPORT_ONLY"
    local result="SKIPPED"
    local exit_code=0

    # 보고만 하는 건 먼저 체크
    if echo "$decision" | grep -qE "$REPORT_ONLY_KEYWORDS"; then
        action_type="REPORT_ONLY"
        result="DELEGATED_TO_HUMAN"
        log "REPORT_ONLY: ${decision}"
        echo "${action_type}|${result}"
        return 0
    fi

    # 키워드 매칭으로 실행 가능한 액션 찾기
    local matched=false
    local matched_action
    matched_action=$(match_action "$decision")
    if [[ -n "$matched_action" ]]; then
        action_type="$matched_action"
        matched=true
    fi

    # 크론 실패 분석 특별 처리
    if echo "$decision" | grep -qi "크론.*실패.*분석\|cron.*fail.*analy"; then
        action_type="analyze-cron"
        matched=true
    fi

    if [[ "$matched" == "false" ]]; then
        # 매칭 안 되면 보고만
        action_type="UNMATCHED"
        result="NEEDS_MANUAL_REVIEW"
        log "UNMATCHED: ${decision} (team: ${team})"
        echo "${action_type}|${result}"
        return 0
    fi

    # 실행
    log "EXECUTING: ${action_type} for: ${decision}"
    case "$action_type" in
        restart-service)
            result=$(action_restart_service "$decision") || exit_code=$?
            ;;
        kill-stale)
            result=$(action_kill_stale) || exit_code=$?
            ;;
        cleanup-logs)
            result=$(action_cleanup_logs) || exit_code=$?
            ;;
        cleanup-disk|cleanup-results)
            result=$(action_cleanup_results) || exit_code=$?
            ;;
        restart-rag)
            result=$(action_restart_rag) || exit_code=$?
            ;;
        sync-vault)
            result=$(action_sync_vault) || exit_code=$?
            ;;
        run-e2e)
            result=$(action_run_e2e) || exit_code=$?
            ;;
        analyze-cron)
            result=$(action_analyze_cron_failure) || exit_code=$?
            ;;
        *)
            result="UNKNOWN_ACTION"
            exit_code=2
            ;;
    esac

    log "RESULT: ${action_type} → ${result} (exit: ${exit_code})"
    echo "${action_type}|${result}|${exit_code}"
    return "$exit_code"
}

# --- 성과 기록 (scorecard 업데이트) ---
update_scorecard() {
    local team="$1" outcome="$2" decision="$3"
    # outcome: success | failure | skipped

    local ts
    ts=$(date -u +%FT%TZ)

    SCORECARD_TEAM="$team" SCORECARD_OUTCOME="$outcome" SCORECARD_DECISION="$decision" \
    SCORECARD_TS="$ts" SCORECARD_PATH="$SCORECARD" \
    python3 -c "
import json, os, tempfile

path = os.environ['SCORECARD_PATH']
team = os.environ['SCORECARD_TEAM']
outcome = os.environ['SCORECARD_OUTCOME']
decision = os.environ['SCORECARD_DECISION']
ts = os.environ['SCORECARD_TS']

with open(path, 'r') as f:
    data = json.load(f)

if team not in data['teams']:
    data['teams'][team] = {
        'lead': team + '-lead',
        'merit': 0, 'penalty': 0,
        'status': 'NORMAL', 'history': []
    }

t = data['teams'][team]

if outcome == 'success':
    t['merit'] += 1
elif outcome == 'failure':
    t['penalty'] += 1

t['history'].append({
    'ts': ts,
    'decision': decision[:100],
    'outcome': outcome
})
t['history'] = t['history'][-20:]

p = t['penalty']
thresholds = data['thresholds']
if p >= thresholds['disciplinary']:
    t['status'] = 'DISCIPLINARY'
elif p >= thresholds['probation']:
    t['status'] = 'PROBATION'
elif p >= thresholds['warning']:
    t['status'] = 'WARNING'
else:
    t['status'] = 'NORMAL'

dir_name = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=dir_name, suffix='.json')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
os.replace(tmp, path)
" 2>"${BOT_HOME}/logs/dispatcher-py.err" || log "WARN: scorecard update failed for ${team} — $(tail -1 "${BOT_HOME}/logs/dispatcher-py.err")"
}

# --- 주간 벌점 감쇠 (매주 월요일) ---
maybe_decay_penalties() {
    local day_of_week
    day_of_week=$(date +%a)
    if [[ "$day_of_week" != "Mon" ]]; then
        return 0
    fi

    SCORECARD_PATH="$SCORECARD" python3 -c "
import json, math, os, tempfile
from datetime import date

path = os.environ['SCORECARD_PATH']

with open(path, 'r') as f:
    data = json.load(f)

if data.get('lastDecay') == str(date.today()):
    pass  # 이미 오늘 감쇠함
else:
    rate = data.get('decayRate', 0.7)
    for team_name, t in data['teams'].items():
        t['penalty'] = math.floor(t['penalty'] * rate)
        t['merit'] = math.floor(t['merit'] * rate)
        p = t['penalty']
        thresholds = data['thresholds']
        if p >= thresholds['disciplinary']:
            t['status'] = 'DISCIPLINARY'
        elif p >= thresholds['probation']:
            t['status'] = 'PROBATION'
        elif p >= thresholds['warning']:
            t['status'] = 'WARNING'
        else:
            t['status'] = 'NORMAL'
    data['lastDecay'] = str(date.today())

    dir_name = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=dir_name, suffix='.json')
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
" 2>"${BOT_HOME}/logs/dispatcher-py.err" || log "WARN: penalty decay failed — $(tail -1 "${BOT_HOME}/logs/dispatcher-py.err")"
}

# --- 징계위원회 알림 생성 ---
check_disciplinary() {
    SCORECARD_PATH="$SCORECARD" python3 -c "
import json, os
path = os.environ['SCORECARD_PATH']
with open(path) as f:
    data = json.load(f)
alerts = []
for team_name, t in data['teams'].items():
    if t['status'] == 'DISCIPLINARY':
        alerts.append(f\"[DISCIPLINARY] {team_name} 팀장({t['lead']}): 벌점 {t['penalty']}점 — 징계위원회 소집 필요\")
    elif t['status'] == 'PROBATION':
        alerts.append(f\"[PROBATION] {team_name} 팀장({t['lead']}): 벌점 {t['penalty']}점 — 관찰 중\")
    elif t['status'] == 'WARNING':
        alerts.append(f\"[WARNING] {team_name} 팀장({t['lead']}): 벌점 {t['penalty']}점\")
if alerts:
    print('\n'.join(alerts))
" 2>"${BOT_HOME}/logs/dispatcher-py.err" || log "WARN: disciplinary check failed"
}

# --- 독립 액션 판별: scorecard 수정이나 전역 상태에 영향 없는 순수 실행 액션 ---
# 이 목록의 액션만 백그라운드 병렬화 대상 (restart-service, sync-vault, run-e2e 등 상태 변경/긴 작업은 순차 유지)
_is_parallel_safe() {
    local action_type="$1"
    case "$action_type" in
        kill-stale|cleanup-logs|cleanup-disk|cleanup-results|analyze-cron)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# ============================================================
# MAIN
# ============================================================

log "=== Dispatch start for ${TODAY} ==="

# 벌점 감쇠 (월요일만)
maybe_decay_penalties

# 이미 처리된 결정은 건너뛰기
PROCESSED_FILE="${BOT_HOME}/state/dispatch-results/.processed-${TODAY}"
touch "$PROCESSED_FILE"

DISPATCH_COUNT=0
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SUMMARY=""

# 병렬 실행 임시 결과 저장 디렉터리 (스크립트 종료 시 자동 정리)
PARALLEL_TMP_DIR=$(mktemp -d /tmp/dispatch-parallel-$$.XXXXXX)
trap 'rm -f "$LOCK_FILE"; rm -rf "$PARALLEL_TMP_DIR"' EXIT

# 1단계: 결정 파싱 및 분류 → 독립 액션은 백그라운드 병렬 실행
declare -a SERIAL_LINES=()   # 순차 처리할 결정 원본 라인
declare -a SERIAL_HASHES=()  # 대응 해시
_parallel_idx=0

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then continue; fi

    line_hash=$(echo "$line" | md5 -q 2>/dev/null || echo "$line" | shasum | cut -d' ' -f1)
    if grep -q "$line_hash" "$PROCESSED_FILE" 2>/dev/null; then
        log "SKIP (already processed): ${line}"
        continue
    fi

    decision=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('decision',''))" 2>/dev/null || echo "")
    team=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('team','unknown'))" 2>/dev/null || echo "unknown")
    status=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('status',''))" 2>/dev/null || echo "")

    if [[ -z "$decision" ]]; then continue; fi
    if [[ "$status" != "confirmed" ]]; then
        log "SKIP (not confirmed): ${decision}"
        continue
    fi

    DISPATCH_COUNT=$((DISPATCH_COUNT + 1))

    # 이 결정의 액션 타입 미리 판별
    matched_action=$(match_action "$decision")
    if echo "$decision" | grep -qi "크론.*실패.*분석\|cron.*fail.*analy"; then
        matched_action="analyze-cron"
    fi

    if [[ -n "$matched_action" ]] && _is_parallel_safe "$matched_action"; then
        # 독립 액션: 백그라운드로 실행, 결과를 임시 파일에 저장
        _pidx=$_parallel_idx
        _parallel_idx=$((_parallel_idx + 1))
        result_file="${PARALLEL_TMP_DIR}/result-${_pidx}.txt"
        (
            _out=$(dispatch_decision "$decision" "$team")
            _exit=$?
            printf '%s\n%s\n%s\n%s\n%s\n' "$_out" "$_exit" "$decision" "$team" "$line_hash" > "$result_file"
        ) &
        log "PARALLEL: ${matched_action} dispatched in background (idx=${_pidx})"
    else
        # 순차 처리 대상: 배열에 저장
        SERIAL_LINES+=("$line")
        SERIAL_HASHES+=("$line_hash")
    fi
done < "$DECISIONS_FILE"

# 병렬 작업 완료 대기
if [[ $_parallel_idx -gt 0 ]]; then
    log "Waiting for ${_parallel_idx} parallel action(s)..."
    wait
    log "All parallel actions completed"

    # 병렬 결과 집계 (순서 보장: result-0.txt, result-1.txt, ...)
    _i=0
    while [[ $_i -lt $_parallel_idx ]]; do
        result_file="${PARALLEL_TMP_DIR}/result-${_i}.txt"
        if [[ ! -f "$result_file" ]]; then
            log "WARN: parallel result file missing (idx=${_i})"
            _i=$((_i + 1))
            continue
        fi
        # 파일 형식: line1=dispatch_output, line2=exit, line3=decision, line4=team, line5=hash
        dispatch_output=$(sed -n '1p' "$result_file")
        dispatch_exit=$(sed -n '2p' "$result_file")
        decision=$(sed -n '3p' "$result_file")
        team=$(sed -n '4p' "$result_file")
        line_hash=$(sed -n '5p' "$result_file")

        action_type=$(echo "$dispatch_output" | cut -d'|' -f1)
        result_detail=$(echo "$dispatch_output" | cut -d'|' -f2)

        if [[ "$action_type" == "REPORT_ONLY" ]] || [[ "$action_type" == "UNMATCHED" ]]; then
            update_scorecard "$team" "skipped" "$decision"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            SUMMARY="${SUMMARY}\n  - [SKIP] ${decision} (${action_type})"
        elif [[ "$dispatch_exit" -eq 2 ]]; then
            update_scorecard "$team" "skipped" "$decision"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            SUMMARY="${SUMMARY}\n  - [SKIP] ${decision}: ${result_detail}"
        elif [[ "$dispatch_exit" -eq 0 ]] && echo "$result_detail" | grep -q "^OK"; then
            update_scorecard "$team" "success" "$decision"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            SUMMARY="${SUMMARY}\n  + [OK] ${decision}"
        else
            update_scorecard "$team" "failure" "$decision"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            SUMMARY="${SUMMARY}\n  ! [FAIL] ${decision}: ${result_detail}"
        fi

        jq -n --arg ts "$(date -u +%FT%TZ)" --arg decision "$decision" --arg team "$team" \
            --arg action "$action_type" --arg result "$result_detail" --argjson exit "$dispatch_exit" \
            '{ts:$ts, decision:$decision, team:$team, action:$action, result:$result, exit:$exit}' \
            >> "$DISPATCH_RESULTS"
        echo "$line_hash" >> "$PROCESSED_FILE"
        _i=$((_i + 1))
    done
fi

# 2단계: 순차 처리 (restart-service, sync-vault, run-e2e 등 의존성 있는 액션)
_sidx=0
for line in "${SERIAL_LINES[@]}"; do
    line_hash="${SERIAL_HASHES[$_sidx]}"
    _sidx=$((_sidx + 1))

    decision=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('decision',''))" 2>/dev/null || echo "")
    team=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('team','unknown'))" 2>/dev/null || echo "unknown")

    if [[ -z "$decision" ]]; then continue; fi

    dispatch_output=""
    dispatch_exit=0
    dispatch_output=$(dispatch_decision "$decision" "$team") || dispatch_exit=$?

    action_type=$(echo "$dispatch_output" | cut -d'|' -f1)
    result_detail=$(echo "$dispatch_output" | cut -d'|' -f2)

    if [[ "$action_type" == "REPORT_ONLY" ]] || [[ "$action_type" == "UNMATCHED" ]]; then
        update_scorecard "$team" "skipped" "$decision"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        SUMMARY="${SUMMARY}\n  - [SKIP] ${decision} (${action_type})"
    elif [[ "$dispatch_exit" -eq 2 ]]; then
        update_scorecard "$team" "skipped" "$decision"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        SUMMARY="${SUMMARY}\n  - [SKIP] ${decision}: ${result_detail}"
    elif [[ "$dispatch_exit" -eq 0 ]] && echo "$result_detail" | grep -q "^OK"; then
        update_scorecard "$team" "success" "$decision"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        SUMMARY="${SUMMARY}\n  + [OK] ${decision}"
    else
        update_scorecard "$team" "failure" "$decision"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        SUMMARY="${SUMMARY}\n  ! [FAIL] ${decision}: ${result_detail}"
    fi

    jq -n --arg ts "$(date -u +%FT%TZ)" --arg decision "$decision" --arg team "$team" \
        --arg action "$action_type" --arg result "$result_detail" --argjson exit "$dispatch_exit" \
        '{ts:$ts, decision:$decision, team:$team, action:$action, result:$result, exit:$exit}' \
        >> "$DISPATCH_RESULTS"
    echo "$line_hash" >> "$PROCESSED_FILE"
done

# 징계 상태 체크
DISCIPLINARY_ALERTS=$(check_disciplinary)

log "=== Dispatch complete: ${DISPATCH_COUNT} decisions, ${SUCCESS_COUNT} OK, ${FAIL_COUNT} FAIL, ${SKIP_COUNT} SKIP ==="

# --- 결과 출력 (Discord 전송 가능) ---
REPORT="[Decision Dispatch — ${TODAY} $(date +%H:%M)]
처리: ${DISPATCH_COUNT}건 (성공 ${SUCCESS_COUNT} / 실패 ${FAIL_COUNT} / 위임불가 ${SKIP_COUNT})"

if [[ -n "$SUMMARY" ]]; then
    REPORT="${REPORT}\n\n상세:$(echo -e "$SUMMARY")"
fi

if [[ -n "$DISCIPLINARY_ALERTS" ]]; then
    REPORT="${REPORT}\n\n--- 팀 성과 경고 ---\n${DISCIPLINARY_ALERTS}"
fi

echo -e "$REPORT"

# Discord 전송 (jarvis-ceo 채널)
WEBHOOK=$(jq -r '.webhooks["jarvis-ceo"]' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || echo "")
if [[ -n "$WEBHOOK" ]] && [[ "$WEBHOOK" != "null" ]] && [[ $((SUCCESS_COUNT + FAIL_COUNT)) -gt 0 ]]; then
    DISCORD_MSG=$(echo -e "$REPORT" | head -c 1950)
    curl -s -X POST "$WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg content "$DISCORD_MSG" '{content: $content}')" \
        >/dev/null 2>&1 || log "Discord send failed"
fi
