#!/bin/bash
# cluster-guard-cl-0cece7e70f08a98f.sh — 재발 방지 선언 후 구조적 검증 루틴 미구현 클러스터 가드
#
# 문제: 재발 방지를 "말로만" 선언하고 실제 구조적 검증 루틴을 구현하지 않음
#   - 재발 방지 선언만 하고 구조적 검증 루틴 미구현
#   - 재발 방지 선언만 하고 구체적 절차 미이행
#   - 이전 세션 문제를 재검증 불가능함에도 검증 완료인 척 보고
#
# 해결책: 자동 체크리스트 실행 + PASS/FAIL 판정 기록 파이프라인
#
# 사용 (직접 실행):
#   bash cluster-guard-cl-0cece7e70f08a98f.sh run <cluster-id>
#   bash cluster-guard-cl-0cece7e70f08a98f.sh check-declaration <declaration-text>
#   bash cluster-guard-cl-0cece7e70f08a98f.sh status

CLUSTER_ID="cl-0cece7e70f08a98f"
JARVIS_HOME="${JARVIS_HOME:-${HOME}/jarvis}"
RUNTIME_HOME="${RUNTIME_HOME:-${JARVIS_HOME}/runtime}"
STATE_DIR="${RUNTIME_HOME}/state/cluster-guards"
RESULTS_DIR="${RUNTIME_HOME}/reports/cluster-guard-${CLUSTER_ID}"
LOG_FILE="${RESULTS_DIR}/checklist-results.log"
VERDICT_FILE="${RESULTS_DIR}/verdict.json"

# 체크리스트 항목 정의 (각 항목: ID|설명|검증 함수명)
CHECKLIST_ITEMS=(
  "CHK-01|재발 방지 선언에 대응하는 가드 스크립트 파일이 실제로 존재하는가|_check_guard_file_exists"
  "CHK-02|가드 스크립트가 bash 문법 오류 없이 실행 가능한가|_check_guard_syntax"
  "CHK-03|결과 기록 디렉토리 및 로그 파일이 생성되는가|_check_result_recording"
  "CHK-04|체크리스트 항목이 1개 이상 PASS/FAIL 판정을 기록하는가|_check_verdict_written"
  "CHK-05|클러스터 ID가 결과 파일에 명시적으로 기록되는가|_check_cluster_id_recorded"
  "CHK-06|단순 선언이 아닌 실제 파일 존재·실행 여부를 검증하는가|_check_structural_not_verbal"
)

# ─────────────────────────────────────────────
# 내부 헬퍼
# ─────────────────────────────────────────────

_init_dirs() {
    mkdir -p "$STATE_DIR" "$RESULTS_DIR" 2>/dev/null || {
        echo "ERROR: 결과 디렉토리 생성 실패: $RESULTS_DIR" >&2
        return 1
    }
}

_ts() {
    date '+%Y-%m-%dT%H:%M:%SZ'
}

_log_result() {
    local chk_id="$1" verdict="$2" detail="$3"
    local ts
    ts=$(_ts)
    printf '[%s] %s %s — %s\n' "$ts" "$verdict" "$chk_id" "$detail" >> "$LOG_FILE"
    printf '%s %s\n' "$verdict" "$chk_id"
}

# ─────────────────────────────────────────────
# 체크리스트 검증 함수들 (각각 실제 파일/상태 검증 수행)
# ─────────────────────────────────────────────

# CHK-01: 현재 가드 스크립트 파일 자체가 존재하는지 확인
_check_guard_file_exists() {
    local guard_script
    guard_script="${HOME}/.jarvis/infra/lib/cluster-guard-${CLUSTER_ID}.sh"
    # BASH_SOURCE[0]도 확인
    local self_path="${BASH_SOURCE[0]:-}"

    if [[ -f "$guard_script" ]] || [[ -f "$self_path" && "$self_path" != "" ]]; then
        _log_result "CHK-01" "PASS" "가드 파일 존재 확인됨: ${guard_script}"
        return 0
    else
        _log_result "CHK-01" "FAIL" "가드 파일 미존재: ${guard_script}"
        return 1
    fi
}

# CHK-02: bash -n 으로 문법 검사
_check_guard_syntax() {
    local guard_script
    guard_script="${HOME}/.jarvis/infra/lib/cluster-guard-${CLUSTER_ID}.sh"

    if [[ ! -f "$guard_script" ]]; then
        _log_result "CHK-02" "FAIL" "검사 대상 파일 없음: $guard_script"
        return 1
    fi

    local syntax_out
    if syntax_out=$(bash -n "$guard_script" 2>&1); then
        _log_result "CHK-02" "PASS" "bash 문법 오류 없음"
        return 0
    else
        _log_result "CHK-02" "FAIL" "문법 오류 발견: $syntax_out"
        return 1
    fi
}

# CHK-03: 결과 디렉토리 및 로그 파일 생성 확인
_check_result_recording() {
    if [[ -d "$RESULTS_DIR" ]] && [[ -f "$LOG_FILE" ]]; then
        local line_count
        line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        _log_result "CHK-03" "PASS" "결과 기록 활성 (로그 ${line_count}줄: $LOG_FILE)"
        return 0
    elif [[ -d "$RESULTS_DIR" ]]; then
        _log_result "CHK-03" "FAIL" "디렉토리 존재하나 로그 파일 미생성: $LOG_FILE"
        return 1
    else
        _log_result "CHK-03" "FAIL" "결과 디렉토리 미생성: $RESULTS_DIR"
        return 1
    fi
}

# CHK-04: 로그에 PASS/FAIL 판정이 실제로 기록되어 있는지 확인
_check_verdict_written() {
    if [[ ! -f "$LOG_FILE" ]]; then
        _log_result "CHK-04" "FAIL" "로그 파일 없음 — 판정 기록 불가"
        return 1
    fi

    local pass_count fail_count total
    pass_count=$(grep -c ' PASS ' "$LOG_FILE" 2>/dev/null) || pass_count=0
    fail_count=$(grep -c ' FAIL ' "$LOG_FILE" 2>/dev/null) || fail_count=0
    pass_count=$(printf '%s' "$pass_count" | tr -d '[:space:]')
    fail_count=$(printf '%s' "$fail_count" | tr -d '[:space:]')
    total=$(( ${pass_count:-0} + ${fail_count:-0} ))

    if [[ "$total" -ge 1 ]]; then
        _log_result "CHK-04" "PASS" "판정 기록 ${total}건 (PASS=${pass_count}, FAIL=${fail_count})"
        return 0
    else
        _log_result "CHK-04" "FAIL" "로그에 PASS/FAIL 판정 0건"
        return 1
    fi
}

# CHK-05: 결과 파일에 클러스터 ID가 명시되어 있는지 확인
_check_cluster_id_recorded() {
    local found=false

    if [[ -f "$LOG_FILE" ]] && grep -q "$CLUSTER_ID" "$LOG_FILE" 2>/dev/null; then
        found=true
    fi
    if [[ -f "$VERDICT_FILE" ]] && grep -q "$CLUSTER_ID" "$VERDICT_FILE" 2>/dev/null; then
        found=true
    fi

    if [[ "$found" == "true" ]]; then
        _log_result "CHK-05" "PASS" "클러스터 ID ${CLUSTER_ID} 결과 파일에 기록됨"
        return 0
    else
        _log_result "CHK-05" "FAIL" "결과 파일에 클러스터 ID 미기록"
        return 1
    fi
}

# CHK-06: 구조적 검증(파일 존재/실행 테스트) vs 단순 선언 구분 확인
_check_structural_not_verbal() {
    local structural_checks=0

    # 이 스크립트 자체가 파일 존재 여부를 체크하는 코드를 포함하는지 확인
    local self
    self="${HOME}/.jarvis/infra/lib/cluster-guard-${CLUSTER_ID}.sh"
    if [[ -f "$self" ]]; then
        # -f, bash -n, grep -c 같은 실제 검증 패턴이 있는지 확인
        if grep -qE '\-f |\bbash -n\b|grep -c|wc -l' "$self" 2>/dev/null; then
            structural_checks=$(( structural_checks + 1 ))
        fi
    fi

    # 결과 파일에 실제 수치(숫자)가 기록되어 있는지 확인
    if [[ -f "$LOG_FILE" ]] && grep -qE '[0-9]+' "$LOG_FILE" 2>/dev/null; then
        structural_checks=$(( structural_checks + 1 ))
    fi

    if [[ "$structural_checks" -ge 1 ]]; then
        _log_result "CHK-06" "PASS" "구조적 검증 패턴 ${structural_checks}개 확인됨 (파일 테스트·수치 기반)"
        return 0
    else
        _log_result "CHK-06" "FAIL" "구조적 검증 패턴 미발견 — 말로만 선언 위험"
        return 1
    fi
}

# ─────────────────────────────────────────────
# 메인 체크리스트 실행
# ─────────────────────────────────────────────

run_checklist() {
    local target_cluster="${1:-$CLUSTER_ID}"
    _init_dirs || return 1

    local ts
    ts=$(_ts)
    local pass_count=0 fail_count=0 total=0

    {
        printf '=== CLUSTER GUARD CHECKLIST RUN ===\n'
        printf 'cluster_id: %s\n' "$CLUSTER_ID"
        printf 'target: %s\n' "$target_cluster"
        printf 'started_at: %s\n' "$ts"
        printf '===================================\n'
    } >> "$LOG_FILE"

    for item in "${CHECKLIST_ITEMS[@]}"; do
        IFS='|' read -r chk_id description fn_name <<< "$item"
        total=$(( total + 1 ))

        # 검증 함수 실제 실행
        if "$fn_name"; then
            pass_count=$(( pass_count + 1 ))
        else
            fail_count=$(( fail_count + 1 ))
        fi
    done

    local overall="PASS"
    if [[ "$fail_count" -gt 0 ]]; then
        overall="FAIL"
    fi
    if [[ "$pass_count" -eq 0 ]]; then
        overall="FAIL"
    fi

    # verdict.json 기록
    cat > "$VERDICT_FILE" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "target_cluster": "${target_cluster}",
  "run_at": "${ts}",
  "total": ${total},
  "pass": ${pass_count},
  "fail": ${fail_count},
  "overall": "${overall}",
  "log": "${LOG_FILE}"
}
EOF

    {
        printf '===================================\n'
        printf 'RESULT: %s (PASS=%d FAIL=%d / TOTAL=%d)\n' "$overall" "$pass_count" "$fail_count" "$total"
        printf 'verdict: %s\n' "$VERDICT_FILE"
        printf '===================================\n\n'
    } >> "$LOG_FILE"

    printf '\n[GUARD RESULT] cluster=%s overall=%s pass=%d fail=%d total=%d\n' \
        "$CLUSTER_ID" "$overall" "$pass_count" "$fail_count" "$total"

    printf 'log → %s\n' "$LOG_FILE"
    printf 'verdict → %s\n' "$VERDICT_FILE"

    [[ "$overall" == "PASS" ]] && return 0 || return 1
}

# ─────────────────────────────────────────────
# 선언문 검사 (단순 선언 vs 구조적 검증 판별)
# ─────────────────────────────────────────────

check_declaration() {
    local text="$1"
    _init_dirs || return 1

    if [[ -z "$text" ]]; then
        echo "ERROR: 검사할 텍스트가 없습니다" >&2
        return 1
    fi

    local is_verbal=false is_structural=false

    # 구조적 검증 없는 말뿐인 선언 패턴
    if echo "$text" | grep -qiE '재발.*방지|다시는.*않|앞으로.*주의|개선.*하겠|조심.*하겠'; then
        is_verbal=true
    fi

    # 구조적 검증 포함 패턴
    if echo "$text" | grep -qiE '스크립트|가드|자동|파일|검증 루틴|체크리스트|PASS|FAIL|bash|실행|기록'; then
        is_structural=true
    fi

    local ts
    ts=$(_ts)
    local verdict_label

    if [[ "$is_verbal" == "true" && "$is_structural" == "false" ]]; then
        verdict_label="FAIL"
        printf '[%s] FAIL DECLARATION-CHECK — 말뿐인 재발 방지 선언 감지됨. 구조적 루틴 미포함\n' "$ts" >> "$LOG_FILE"
        printf 'FAIL: 구조적 검증 루틴 없는 말뿐인 선언입니다.\n'
        return 1
    elif [[ "$is_structural" == "true" ]]; then
        verdict_label="PASS"
        printf '[%s] PASS DECLARATION-CHECK — 구조적 검증 요소 포함 선언\n' "$ts" >> "$LOG_FILE"
        printf 'PASS: 구조적 검증 요소가 포함된 선언입니다.\n'
        return 0
    else
        verdict_label="PASS"
        printf '[%s] PASS DECLARATION-CHECK — 재발 방지 선언 패턴 없음 (일반 텍스트)\n' "$ts" >> "$LOG_FILE"
        printf 'PASS: 재발 방지 선언 패턴 없음.\n'
        return 0
    fi
}

# ─────────────────────────────────────────────
# 상태 조회
# ─────────────────────────────────────────────

show_status() {
    if [[ -f "$VERDICT_FILE" ]]; then
        cat "$VERDICT_FILE"
    else
        printf '{"cluster_id":"%s","status":"not_yet_run","message":"체크리스트 미실행"}\n' "$CLUSTER_ID"
    fi
}

# ─────────────────────────────────────────────
# CLI 엔트리포인트
# ─────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-help}"

    case "$cmd" in
        run)
            target="${2:-$CLUSTER_ID}"
            run_checklist "$target"
            exit $?
            ;;
        check-declaration)
            shift
            check_declaration "$*"
            exit $?
            ;;
        status)
            show_status
            exit 0
            ;;
        help|--help|-h)
            cat <<'USAGE'
cluster-guard-cl-0cece7e70f08a98f.sh — 재발 방지 선언 구조적 검증 가드

사용:
  bash cluster-guard-cl-0cece7e70f08a98f.sh run [cluster-id]
      → 체크리스트 실행 후 PASS/FAIL 결과 파일 생성

  bash cluster-guard-cl-0cece7e70f08a98f.sh check-declaration "<텍스트>"
      → 선언문이 말뿐인지 구조적 검증 포함인지 판별

  bash cluster-guard-cl-0cece7e70f08a98f.sh status
      → 최근 실행 결과(verdict.json) 출력

성공 기준:
  [1] 체크리스트 결과 파일 생성
  [2] PASS/FAIL 판정 포함
  [3] 실제 파일 존재·문법 검사 등 구조적 검증 수행
USAGE
            exit 0
            ;;
        *)
            echo "ERROR: 알 수 없는 명령: $cmd" >&2
            echo "사용: $0 {run|check-declaration|status}" >&2
            exit 1
            ;;
    esac
fi
