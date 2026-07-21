#!/usr/bin/env bash
# repo-path-guard.sh — 반복 실수 클러스터 cl-5199fed7fdccfc50 방어 가드 스크립트
#
# 클러스터 ID  : cl-5199fed7fdccfc50 (최근 7일 재발 27건)
# 반복 패턴    : 파일 읽은 후에도 저장소 판단 역전 (배포본 혼동)
# 대표 증상    : 저장소 구분 역순 오류 / 저장소 경로 미확인 후 역방향 진행
#               로컬 저장소 여럿 중 배포본 미확인 후 구버전 설정 읽음
# 목적        : 작업 시작 시 관련 저장소 경로를 자동 나열·비교하고,
#               최신 커밋 타임스탬프를 코드로 강제하여 수동 판단 의존을 제거
#
# 동작 방식:
#   1. 환경 변수 또는 인자로 추적할 저장소 경로 목록 수집
#   2. 각 저장소의 최신 커밋 타임스탬프와 해시 추출
#   3. 타임스탬프 기준으로 정렬 후 "최신본 = 가장 최근 수정 시각" 명확히
#   4. 작업 전 저장소 상태 로그 기록 → 후속 작업에서 검증
#
# 사용법:
#   source "${BOT_HOME}/lib/repo-path-guard.sh"
#   repo_guard_init              # 시스템 초기화
#   repo_guard_check <path1> [<path2> ...]  # 특정 저장소들 검증
#   repo_guard_auto_detect       # 환경 변수 기반 자동 감지
#
# 통합 방법:
#   ask-claude.sh의 "Requirement check guard" 이후에 이 가드를 호출:
#   if command -v repo_guard_auto_detect >/dev/null 2>&1; then
#       repo_guard_auto_detect "$TASK_ID" || true
#   fi

set -euo pipefail

# ═════════════════════════════════════════════════════════════════════════════════
# [Config]
# ═════════════════════════════════════════════════════════════════════════════════

REPO_GUARD_STATE_DIR="${BOT_HOME:-$HOME/jarvis/runtime}/state/repo-guard"
REPO_GUARD_LOG="${REPO_GUARD_STATE_DIR}/repo-paths-$(date +%F).log"
REPO_GUARD_SNAPSHOT="${REPO_GUARD_STATE_DIR}/repo-snapshot-${TASK_ID:-unknown}.json"

# ═════════════════════════════════════════════════════════════════════════════════
# [1] repo_guard_init — 가드 상태 디렉토리 초기화
# ═════════════════════════════════════════════════════════════════════════════════
repo_guard_init() {
    mkdir -p "$REPO_GUARD_STATE_DIR"
    chmod 755 "$REPO_GUARD_STATE_DIR"
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [2] repo_guard_get_latest_commit — 저장소의 최신 커밋 정보 추출
# ═════════════════════════════════════════════════════════════════════════════════
# 입력: 저장소 경로
# 출력: JSON 형식 {path, hash, timestamp_unix, timestamp_iso}
#
# 클러스터 패턴: "배포본은 이 경로일 거다" 수동 추정 후 파일 읽음
# 방어: git log를 통해 객관적 사실 (커밋 시각)을 기계적으로 추출
repo_guard_get_latest_commit() {
    local repo_path="$1"

    if [[ ! -d "$repo_path" ]]; then
        printf '[repo-guard] ERROR: not a directory: %s\n' "$repo_path" >&2
        return 1
    fi

    if [[ ! -d "${repo_path}/.git" ]]; then
        printf '[repo-guard] ERROR: not a git repository: %s\n' "$repo_path" >&2
        return 1
    fi

    local hash commit_timestamp_iso commit_timestamp_unix

    # git log에서 최신 커밋의 해시와 시각 추출
    # %H = 커밋 해시, %aI = ISO 형식 시각 (UTC 포함)
    hash=$(git -C "$repo_path" log -1 --format='%H' 2>/dev/null) || return 1
    commit_timestamp_iso=$(git -C "$repo_path" log -1 --format='%aI' 2>/dev/null) || return 1

    # ISO 형식을 Unix timestamp로 변환
    # macOS: date -j -f %Y-%m-%dT%H:%M:%S+%Z
    # Linux: date -d "2026-07-09T04:30:00+00:00" +%s
    if command -v gdate >/dev/null 2>&1; then
        # gdate: GNU coreutils on macOS
        commit_timestamp_unix=$(gdate -d "$commit_timestamp_iso" +%s 2>/dev/null) || \
            commit_timestamp_unix=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "${commit_timestamp_iso:0:19}+0000" +%s 2>/dev/null) || \
            commit_timestamp_unix="0"
    else
        # BSD date (macOS default)
        commit_timestamp_unix=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "${commit_timestamp_iso:0:19}+0000" +%s 2>/dev/null) || \
            commit_timestamp_unix="0"
    fi

    # 결과를 JSON으로 출력
    printf '{"path":"%s","hash":"%s","timestamp_iso":"%s","timestamp_unix":%s}\n' \
        "$repo_path" "$hash" "$commit_timestamp_iso" "$commit_timestamp_unix"
}

# ═════════════════════════════════════════════════════════════════════════════════
# [3] repo_guard_check — 여러 저장소를 비교 검증
# ═════════════════════════════════════════════════════════════════════════════════
# 입력: 저장소 경로 1, 저장소 경로 2, ...
# 출력: 타임스탬프 기준 정렬된 저장소 목록 (최신 순)
#
# 핵심: "최신본 = 가장 최근 수정 시각"을 코드로 구현
#       사용자의 "어떤 것이 최신이지?" 추측을 배제
repo_guard_check() {
    local -a repo_paths=("$@")
    local -a commit_infos=()

    if [[ ${#repo_paths[@]} -eq 0 ]]; then
        printf '[repo-guard] ERROR: repo_guard_check called with no arguments\n' >&2
        return 1
    fi

    # 각 저장소의 커밋 정보 수집
    for repo_path in "${repo_paths[@]}"; do
        if repo_info=$(repo_guard_get_latest_commit "$repo_path" 2>/dev/null); then
            commit_infos+=("$repo_info")
        else
            printf '[repo-guard] WARN: failed to get commit info for %s\n' "$repo_path" >&2
        fi
    done

    if [[ ${#commit_infos[@]} -eq 0 ]]; then
        printf '[repo-guard] ERROR: no valid repositories found\n' >&2
        return 1
    fi

    # JSON 배열로 변환 후 타임스탬프 기준 역순 정렬 (최신 먼저)
    local sorted_json
    sorted_json=$(printf '%s\n' "${commit_infos[@]}" | \
        jq -s 'sort_by(.timestamp_unix) | reverse')

    # 정렬 결과를 출력
    printf '%s\n' "$sorted_json"

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [4] repo_guard_auto_detect — 환경 변수 기반 자동 감지 및 기록
# ═════════════════════════════════════════════════════════════════════════════════
# 입력: TASK_ID (선택) / JARVIS_REPOS 환경 변수
# 동작:
#   1. JARVIS_REPOS에서 저장소 경로 파싱 (콜론/스페이스 구분)
#   2. 현재 저장소 (pwd)도 포함
#   3. repo_guard_check 호출 후 결과를 로그/스냅샷에 기록
#   4. 최신 저장소를 JARVIS_LATEST_REPO로 환경변수 설정
#
# 클러스터 패턴: "어느 저장소가 배포본이지?" 무의식적 추측
# 방어: 자동으로 저장소들을 비교하고 명확히 제시
repo_guard_auto_detect() {
    local task_id="${1:-${TASK_ID:-unknown}}"
    local -a repos_to_check=()

    repo_guard_init || return 1

    # [1] 현재 작업 디렉토리 추가
    if [[ -d ".git" ]]; then
        repos_to_check+=("$(pwd)")
    fi

    # [2] JARVIS_REPOS 환경 변수 파싱 (콜론/스페이스 구분)
    if [[ -n "${JARVIS_REPOS:-}" ]]; then
        IFS=':' read -ra repo_array <<< "$JARVIS_REPOS" || true
        for repo in "${repo_array[@]}"; do
            repo=$(echo "$repo" | xargs)  # trim whitespace
            if [[ -n "$repo" && -d "$repo/.git" ]]; then
                repos_to_check+=("$repo")
            fi
        done
    fi

    # [3] 상위 경로의 저장소들도 자동 감지
    # 클러스터 패턴: 로컬 저장소 여럿 중 배포본 미확인
    local current_dir
    current_dir=$(pwd)
    local check_depth=0
    while [[ "$check_depth" -lt 3 ]]; do
        current_dir=$(dirname "$current_dir")
        if [[ "$current_dir" == "/" ]]; then
            break
        fi
        if [[ -d "${current_dir}/.git" ]] && \
           [[ " ${repos_to_check[@]} " != *" ${current_dir} "* ]]; then
            repos_to_check+=("$current_dir")
        fi
        ((check_depth++))
    done

    # [4] 중복 제거
    local -a unique_repos=()
    for repo in "${repos_to_check[@]:-}"; do
        if [[ -z "$repo" ]]; then
            continue
        fi
        local found=0
        for existing in "${unique_repos[@]:-}"; do
            if [[ "$existing" == "$repo" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            unique_repos+=("$repo")
        fi
    done

    if [[ ${#unique_repos[@]} -eq 0 ]]; then
        printf '[repo-guard] WARN: no git repositories found for task %s\n' "$task_id" >&2
        return 1
    fi

    # [5] 저장소들 검증 및 비교
    local check_result
    check_result=$(repo_guard_check "${unique_repos[@]}" 2>&1) || return 1

    # [6] 결과 저장
    {
        printf '[%s] TASK=%s\n' "$(date -u +%FT%TZ)" "$task_id"
        printf 'Detected repositories (sorted by commit timestamp, newest first):\n'
        printf '%s\n' "$check_result" | jq -r '.[] | "  [\(.timestamp_iso)] \(.path) (hash: \(.hash[0:8])...)"'
        printf '\n'
    } | tee -a "$REPO_GUARD_LOG" >/dev/null

    # [7] 스냅샷 저장 (JSON 형식)
    {
        printf '{\n'
        printf '  "task_id": "%s",\n' "$task_id"
        printf '  "captured_at": "%s",\n' "$(date -u +%FT%TZ)"
        printf '  "repositories": %s\n' "$check_result"
        printf '}\n'
    } > "$REPO_GUARD_SNAPSHOT"

    # [8] 최신 저장소를 환경변수로 설정
    local latest_repo
    latest_repo=$(printf '%s' "$check_result" | jq -r '.[0].path')
    export JARVIS_LATEST_REPO="$latest_repo"

    printf '[repo-guard] ✅ Repository audit complete. Latest repo: %s\n' "$latest_repo" >&2
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [5] repo_guard_validate — 작업 중간에 저장소 일관성 검증
# ═════════════════════════════════════════════════════════════════════════════════
# 용도: 작업 수행 중 저장소가 예상과 다를 경우 경고
repo_guard_validate() {
    local expected_repo="${1:-.}"

    if [[ ! -d "${expected_repo}/.git" ]]; then
        printf '[repo-guard] ERROR: expected repository not found: %s\n' "$expected_repo" >&2
        return 1
    fi

    local current_repo
    current_repo=$(pwd)

    if [[ "$current_repo" != "$expected_repo" ]]; then
        printf '[repo-guard] WARN: working directory mismatch\n' >&2
        printf '  Expected: %s\n' "$expected_repo" >&2
        printf '  Current:  %s\n' "$current_repo" >&2
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [Entrypoint]
# ═════════════════════════════════════════════════════════════════════════════════

# 스크립트로 직접 실행된 경우
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    repo_guard_init

    # CLI 사용법
    cmd="${1:-auto}"
    case "$cmd" in
        init)
            repo_guard_init
            printf '[repo-guard] Initialized\n'
            ;;
        check)
            if [[ $# -lt 2 ]]; then
                printf 'Usage: repo-path-guard.sh check <repo1> [<repo2> ...]\n' >&2
                exit 1
            fi
            shift
            repo_guard_check "$@" || exit 1
            ;;
        auto)
            repo_guard_auto_detect "${TASK_ID:-unknown}" || exit 1
            ;;
        validate)
            if [[ $# -lt 2 ]]; then
                printf 'Usage: repo-path-guard.sh validate <expected_repo>\n' >&2
                exit 1
            fi
            repo_guard_validate "$2" || exit 1
            ;;
        *)
            printf 'Unknown command: %s\n' "$cmd" >&2
            printf 'Usage: repo-path-guard.sh [init|check|auto|validate]\n' >&2
            exit 1
            ;;
    esac
fi
