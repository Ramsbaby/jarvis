#!/usr/bin/env bash
# cluster-guard-cl-faf6f4c1f94bd512.sh — 백그라운드 작업 중단·재실행 검증 가드
#
# 클러스터 ID  : cl-faf6f4c1f94bd512 (최근 7일 재발 13건)
# 대표 시드    : 백그라운드 작업 중단 감지 후 즉시 재실행 미수행 → 잘못된 콘텐츠 발견 지연
# 멤버 패턴    :
#   - 백그라운드 에이전트 실패 미즉시 보고, 자체 복구 후 완료만 선언
#   - 백그라운드 에이전트 프로세스 중단 후 생성 파일 미검증
#   - 반복 수정 후에도 전체 레이아웃 재검증 불충분
#   - 지시 후 '대기' 응답했으나 실제로는 즉시 실행한 불일치 보고
#
# 공개 API:
#   bg_task_verify <task_id> <expected_exit> <artifact_path>...
#       — exit code + 산출물 존재 대조; 불일치 시 non-zero 반환 + 경고
#
#   exec_declare_check <task_id> <declared_epoch> <artifact_path> [skew_sec=30]
#       — 실행 선언 타임스탬프 vs 파일 mtime 대조; ±skew 초 초과 시 경고
#
#   interruption_recovery_check <task_id> <pid_or_pidfile> <artifact_path>
#       — PID가 사라졌는데 산출물이 없으면 "재실행 필요" 경고
#
#   layout_revalidate_hook <session_id> <file_path> [threshold=3]
#       — 세션 내 수정 횟수가 threshold 이상이면 전체 레이아웃 재검증 강제
#
#   guard_cl_faf6_status
#       — 현재 가드 상태 요약 출력
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-faf6f4c1f94bd512.sh
#   bg_task_verify "agent-20260724-001" 0 "/tmp/output.pdf"
#
# 기존 동작 보호: 모든 함수는 경고를 stderr에 출력하고 exit code로 결과를 알린다.
#   호출자가 set -e 환경에서 차단 없이 쓰려면 || true 를 붙인다.

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_FAF6_ID="cl-faf6f4c1f94bd512"
readonly _CL_FAF6_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_FAF6_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_FAF6_ID}.jsonl"
readonly _CL_FAF6_MOD_COUNTS="${_CL_FAF6_STATE_DIR}/${_CL_FAF6_ID}-mod-counts.json"
readonly _CL_FAF6_PREFIX="[bg-guard ${_CL_FAF6_ID}]"

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_faf6_now_epoch() { date '+%s'; }
_faf6_now_iso()   { date '+%Y-%m-%dT%H:%M:%S'; }

_faf6_ensure_dirs() {
    mkdir -p "$_CL_FAF6_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$_CL_FAF6_LOG")" 2>/dev/null || true
}

_faf6_log() {
    local level="$1" task_id="$2" detail="$3" extra="${4:-}"
    _faf6_ensure_dirs
    printf '{"ts":"%s","cluster":"%s","level":"%s","task_id":"%s","detail":"%s","extra":"%s"}\n' \
        "$(_faf6_now_iso)" "$_CL_FAF6_ID" "$level" "$task_id" \
        "${detail//\"/\'}" "${extra//\"/\'}" \
        >> "$_CL_FAF6_LOG" 2>/dev/null || true
}

_faf6_warn()  { echo "⚠️  ${_CL_FAF6_PREFIX} [WARN]  $*" >&2; }
_faf6_fail()  { echo "❌ ${_CL_FAF6_PREFIX} [FAIL]  $*" >&2; }
_faf6_ok()    { echo "✅ ${_CL_FAF6_PREFIX} [OK]    $*" >&2; }
_faf6_info()  { echo "ℹ️  ${_CL_FAF6_PREFIX} [INFO]  $*" >&2; }

# 파일 mtime을 epoch 초로 반환 (macOS/Linux 공통)
_faf6_mtime_epoch() {
    local path="$1"
    if stat -f '%m' "$path" 2>/dev/null; then
        return 0
    fi
    # GNU stat fallback
    stat -c '%Y' "$path" 2>/dev/null
}

# ── 공개 API: 1. bg_task_verify ─────────────────────────────────────────────
#
# bg_task_verify <task_id> <expected_exit_code> <artifact_path> [<artifact_path>...]
#
# exit code + 산출물 존재를 대조.
# - expected_exit_code: 0 이면 성공 선언, 그 외는 실패 선언
# - 산출물이 하나라도 없으면 ARTIFACT_MISSING 경고
# - actual_exit (있으면 .exit 파일에서) 가 expected 와 다르면 EXIT_MISMATCH 경고
# 반환: 0=통과, 1=산출물 누락, 2=exit code 불일치, 3=둘 다 실패
bg_task_verify() {
    local task_id="$1"
    local expected_exit="$2"
    shift 2
    local artifacts=("$@")

    if [[ -z "$task_id" || -z "$expected_exit" || ${#artifacts[@]} -eq 0 ]]; then
        _faf6_warn "bg_task_verify: 인자 부족 — task_id, expected_exit, artifact_path 필요"
        return 1
    fi

    local rc=0

    # 1-A. 산출물 존재 확인
    local missing=()
    for path in "${artifacts[@]}"; do
        if [[ ! -e "$path" ]]; then
            missing+=("$path")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        _faf6_fail "[$task_id] 산출물 누락: ${missing[*]}"
        _faf6_log "FAIL" "$task_id" "ARTIFACT_MISSING" "${missing[*]}"
        rc=$((rc | 1))
    else
        _faf6_ok "[$task_id] 산출물 확인: ${artifacts[*]}"
        _faf6_log "OK" "$task_id" "ARTIFACT_VERIFIED" "${artifacts[*]}"
    fi

    # 1-B. exit code 대조 (.exit 파일이 있으면 읽기)
    local exit_file="${_CL_FAF6_STATE_DIR}/${task_id}.exit"
    if [[ -f "$exit_file" ]]; then
        local actual_exit
        actual_exit=$(cat "$exit_file" 2>/dev/null | tr -d '[:space:]')
        if [[ "$actual_exit" != "$expected_exit" ]]; then
            _faf6_fail "[$task_id] exit code 불일치: 선언=$expected_exit 실제=$actual_exit"
            _faf6_log "FAIL" "$task_id" "EXIT_MISMATCH" "declared=${expected_exit},actual=${actual_exit}"
            rc=$((rc | 2))
        else
            _faf6_ok "[$task_id] exit code 일치: $actual_exit"
        fi
    else
        _faf6_info "[$task_id] .exit 파일 없음 — exit code 대조 생략 (task_id.exit 없음)"
        _faf6_log "INFO" "$task_id" "NO_EXIT_FILE" "$exit_file"
    fi

    return $rc
}

# bg_task_record_exit — 태스크 실행 직후 exit code를 기록 (bg_task_verify가 읽음)
# 사용: some_command; bg_task_record_exit "agent-001" $?
bg_task_record_exit() {
    local task_id="$1" exit_code="$2"
    [[ -z "$task_id" || -z "$exit_code" ]] && return 1
    _faf6_ensure_dirs
    echo "$exit_code" > "${_CL_FAF6_STATE_DIR}/${task_id}.exit"
    _faf6_log "INFO" "$task_id" "EXIT_RECORDED" "exit=${exit_code}"
}

# ── 공개 API: 2. exec_declare_check ─────────────────────────────────────────
#
# exec_declare_check <task_id> <declared_epoch> <artifact_path> [skew_seconds=30]
#
# "실행 완료" 선언 시점(declared_epoch)과 산출물 파일 mtime을 대조.
# 차이가 skew_seconds 초를 초과하면 TIMESTAMP_MISMATCH 경고.
# 반환: 0=일치, 1=파일 없음, 2=타임스탬프 불일치
exec_declare_check() {
    local task_id="$1"
    local declared_epoch="$2"
    local artifact_path="$3"
    local skew_sec="${4:-30}"

    if [[ -z "$task_id" || -z "$declared_epoch" || -z "$artifact_path" ]]; then
        _faf6_warn "exec_declare_check: task_id, declared_epoch, artifact_path 필요"
        return 1
    fi

    if [[ ! -e "$artifact_path" ]]; then
        _faf6_fail "[$task_id] exec_declare_check: 파일 없음 — $artifact_path"
        _faf6_log "FAIL" "$task_id" "FILE_NOT_FOUND" "$artifact_path"
        return 1
    fi

    local file_mtime
    file_mtime=$(_faf6_mtime_epoch "$artifact_path")

    local delta=$(( file_mtime - declared_epoch ))
    # 절댓값
    local abs_delta=$(( delta < 0 ? -delta : delta ))

    if [[ $abs_delta -gt $skew_sec ]]; then
        local file_iso declared_iso
        file_iso=$(date -r "$file_mtime" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
                   || date -d "@$file_mtime" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
                   || echo "epoch:${file_mtime}")
        declared_iso=$(date -r "$declared_epoch" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
                       || date -d "@$declared_epoch" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
                       || echo "epoch:${declared_epoch}")
        _faf6_fail "[$task_id] 실행 선언-파일 타임스탬프 불일치 (${abs_delta}초 차이)" \
                   "선언=${declared_iso} 파일mtime=${file_iso}"
        _faf6_log "FAIL" "$task_id" "TIMESTAMP_MISMATCH" \
            "declared=${declared_epoch},mtime=${file_mtime},delta=${abs_delta},path=${artifact_path}"
        return 2
    fi

    _faf6_ok "[$task_id] 타임스탬프 일치 (차이 ${abs_delta}초 ≤ ${skew_sec}초): $artifact_path"
    _faf6_log "OK" "$task_id" "TIMESTAMP_VERIFIED" \
        "declared=${declared_epoch},mtime=${file_mtime},delta=${abs_delta}"
    return 0
}

# ── 공개 API: 3. interruption_recovery_check ────────────────────────────────
#
# interruption_recovery_check <task_id> <pid_or_pidfile> <artifact_path>
#
# PID가 사라졌는데 산출물도 없으면 "중단 후 재실행 필요" BLOCK을 발생.
# 반환: 0=정상(실행중 또는 완료), 1=중단+산출물 없음(재실행 필요), 2=중단+산출물 있음(완료로 간주)
interruption_recovery_check() {
    local task_id="$1"
    local pid_or_file="$2"
    local artifact_path="$3"

    if [[ -z "$task_id" || -z "$pid_or_file" || -z "$artifact_path" ]]; then
        _faf6_warn "interruption_recovery_check: task_id, pid_or_file, artifact_path 필요"
        return 1
    fi

    # PID 확인
    local pid
    if [[ -f "$pid_or_file" ]]; then
        pid=$(cat "$pid_or_file" 2>/dev/null | tr -d '[:space:]')
    else
        pid="$pid_or_file"
    fi

    local process_alive=0
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        process_alive=1
    fi

    local artifact_exists=0
    [[ -e "$artifact_path" ]] && artifact_exists=1

    if [[ $process_alive -eq 1 ]]; then
        _faf6_ok "[$task_id] 프로세스 실행 중 (PID=${pid})"
        _faf6_log "OK" "$task_id" "PROCESS_ALIVE" "pid=${pid}"
        return 0
    fi

    # 프로세스가 없음
    if [[ $artifact_exists -eq 0 ]]; then
        _faf6_fail "[$task_id] 프로세스 중단 + 산출물 없음 → 즉시 재실행 필요!" \
                   "PID=${pid} artifact=${artifact_path}"
        _faf6_log "FAIL" "$task_id" "INTERRUPTION_NO_ARTIFACT" \
            "pid=${pid},artifact=${artifact_path}"
        # 재실행 필요 마커 기록
        echo "NEEDS_RERUN" > "${_CL_FAF6_STATE_DIR}/${task_id}.recovery"
        return 1
    else
        _faf6_warn "[$task_id] 프로세스 중단됐으나 산출물 존재 — 완료로 간주 (검증 권장)"
        _faf6_log "WARN" "$task_id" "INTERRUPTION_WITH_ARTIFACT" \
            "pid=${pid},artifact=${artifact_path}"
        return 2
    fi
}

# ── 공개 API: 4. layout_revalidate_hook ─────────────────────────────────────
#
# layout_revalidate_hook <session_id> <file_path> [threshold=3]
#
# 세션 내 파일 수정 횟수를 추적. threshold 이상이면 전체 레이아웃 재검증 지시를 발행.
# 반환: 0=아직 threshold 미달, 1=threshold 도달(재검증 필요), 2=이미 재검증 완료
layout_revalidate_hook() {
    local session_id="$1"
    local file_path="$2"
    local threshold="${3:-3}"

    if [[ -z "$session_id" || -z "$file_path" ]]; then
        _faf6_warn "layout_revalidate_hook: session_id, file_path 필요"
        return 1
    fi

    _faf6_ensure_dirs

    local safe_file
    safe_file=$(printf '%s' "$file_path" | tr '/' '_' | tr ' ' '_')
    local count_file="${_CL_FAF6_STATE_DIR}/${_CL_FAF6_ID}-mod-${session_id}-${safe_file}.count"
    local revalidated_marker="${count_file%.count}.revalidated"

    # 이미 재검증 완료면 0 반환
    if [[ -f "$revalidated_marker" ]]; then
        _faf6_ok "[$session_id] 레이아웃 재검증 이미 완료: $file_path"
        return 2
    fi

    # 현재 횟수 읽기 + 증가
    local current=0
    [[ -f "$count_file" ]] && current=$(cat "$count_file" 2>/dev/null || echo 0)
    current=$(( current + 1 ))
    echo "$current" > "$count_file"

    _faf6_log "INFO" "$session_id" "MOD_COUNT" "file=${file_path},count=${current},threshold=${threshold}"

    if [[ $current -ge $threshold ]]; then
        _faf6_warn "[$session_id] 수정 횟수 ${current}회 ≥ ${threshold}회 → 전체 레이아웃 재검증 필요!" \
                   "파일: $file_path"
        _faf6_log "WARN" "$session_id" "REVALIDATE_REQUIRED" \
            "file=${file_path},count=${current},threshold=${threshold}"
        return 1
    fi

    _faf6_info "[$session_id] 수정 횟수 ${current}/${threshold}: $file_path"
    return 0
}

# layout_revalidate_mark_done — 재검증 완료 시 호출
# 사용: layout_revalidate_hook "sess-1" "file.html" && ... || { do_revalidate; layout_revalidate_mark_done "sess-1" "file.html"; }
layout_revalidate_mark_done() {
    local session_id="$1"
    local file_path="$2"

    _faf6_ensure_dirs

    local safe_file
    safe_file=$(printf '%s' "$file_path" | tr '/' '_' | tr ' ' '_')
    local count_file="${_CL_FAF6_STATE_DIR}/${_CL_FAF6_ID}-mod-${session_id}-${safe_file}.count"
    local revalidated_marker="${count_file%.count}.revalidated"

    touch "$revalidated_marker"
    echo "0" > "$count_file"
    _faf6_ok "[$session_id] 레이아웃 재검증 완료 기록됨: $file_path"
    _faf6_log "OK" "$session_id" "REVALIDATE_DONE" "file=${file_path}"
}

# ── 공개 API: 5. guard_cl_faf6_status ───────────────────────────────────────
#
# guard_cl_faf6_status
# 현재 가드 상태 요약 (마지막 N건 로그 + recovery 마커)
guard_cl_faf6_status() {
    echo "=== ${_CL_FAF6_PREFIX} 상태 요약 ==="
    echo "로그: $_CL_FAF6_LOG"

    if [[ -f "$_CL_FAF6_LOG" ]]; then
        local total fail warn ok
        total=$(wc -l < "$_CL_FAF6_LOG" 2>/dev/null || echo 0)
        fail=$(grep -c '"level":"FAIL"' "$_CL_FAF6_LOG" 2>/dev/null || echo 0)
        warn=$(grep -c '"level":"WARN"' "$_CL_FAF6_LOG" 2>/dev/null || echo 0)
        ok=$(grep -c '"level":"OK"' "$_CL_FAF6_LOG" 2>/dev/null || echo 0)
        echo "전체=${total} OK=${ok} WARN=${warn} FAIL=${fail}"
        echo ""
        echo "최근 5건:"
        tail -5 "$_CL_FAF6_LOG" 2>/dev/null || echo "(로그 없음)"
    else
        echo "(로그 파일 없음)"
    fi

    # recovery 마커 확인
    local recovery_files
    recovery_files=$(find "$_CL_FAF6_STATE_DIR" -name "*.recovery" 2>/dev/null)
    if [[ -n "$recovery_files" ]]; then
        echo ""
        echo "⚠️  재실행 필요 태스크:"
        echo "$recovery_files" | while read -r f; do
            local task
            task=$(basename "$f" .recovery)
            echo "  - $task"
        done
    fi
}

# ── 초기화 ───────────────────────────────────────────────────────────────────
_faf6_ensure_dirs
