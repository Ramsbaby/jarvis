#!/usr/bin/env bash
# cluster-guard-cl-117521116a786a9e.sh — 기존 자동화 인프라 미조사 후 중복 제안 방지 가드
#
# 클러스터 ID  : cl-117521116a786a9e (최근 7일 재발 16건)
# 대표 시드    : 기존 자동 경보 시스템 4주 방치를 미인지하고 새로운 감사 제시
# 멤버 패턴    :
#   - 기존 자동 경보 시스템 장기 미인지 — 메타 파이프라인 마비
#   - 새 자동화 제안 전 기존 감시 인프라 전수 조사 누락 — 경보 중복 생성
#   - 기존 감사 경보 미탐지하고 새 도구 필요성 제시
#   - 기존 자동 감사 체계 간과 후 신규 자동화 제안
#
# 공개 API:
#   pre_proposal_check [keyword]
#       — crontab/launchd/monitoring.json 전수 열거 후 키워드 중복 탐지
#         중복 가능성 있으면 non-zero 반환 + 경고 (DUPLICATE_RISK)
#
#   check_duplicate_automation <keyword>
#       — 기존 자동화 목록에서 keyword 관련 항목 탐색, 결과 stdout 출력
#         일치 0건이면 0, 1건 이상이면 1 반환
#
#   enumerate_existing_infra
#       — 현재 자동화 인프라를 구조화 목록으로 stdout 출력 (파이프 활용 가능)
#
#   guard_cl_117521_status
#       — 가드 상태 요약 출력
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-117521116a786a9e.sh
#   pre_proposal_check "audit"          # 새 감사 도구 제안 전 중복 체크
#   pre_proposal_check "log-rotation"   # 로그 관련 자동화 중복 체크
#
# 기존 동작 보호: 모든 함수는 경고를 stderr에 출력하고 exit code로 결과를 알린다.
#   호출자가 set -e 환경에서 차단 없이 쓰려면 || true 를 붙인다.

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_1175_ID="cl-117521116a786a9e"
readonly _CL_1175_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_1175_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_1175_ID}.jsonl"
readonly _CL_1175_CACHE="${_CL_1175_STATE_DIR}/${_CL_1175_ID}-infra-cache.json"
readonly _CL_1175_PREFIX="[pre-proposal-guard ${_CL_1175_ID}]"

# 색상 (stderr 경고용)
_CL_1175_RED='\033[0;31m'
_CL_1175_YLW='\033[0;33m'
_CL_1175_GRN='\033[0;32m'
_CL_1175_BLU='\033[0;34m'
_CL_1175_NC='\033[0m'

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_1175_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_1175_ensure_dirs() {
    mkdir -p "$_CL_1175_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$_CL_1175_LOG")" 2>/dev/null || true
}

_1175_log() {
    local level="$1" func="$2" detail="$3" extra="${4:-}"
    _1175_ensure_dirs
    printf '{"ts":"%s","cluster":"%s","level":"%s","func":"%s","detail":"%s","extra":"%s"}\n' \
        "$(_1175_now_iso)" "$_CL_1175_ID" "$level" "$func" \
        "${detail//\"/\'}" "${extra//\"/\'}" \
        >> "$_CL_1175_LOG" 2>/dev/null || true
}

_1175_warn()  { printf "${_CL_1175_YLW}⚠️  %s [WARN]  %s${_CL_1175_NC}\n" "$_CL_1175_PREFIX" "$*" >&2; }
_1175_fail()  { printf "${_CL_1175_RED}❌ %s [FAIL]  %s${_CL_1175_NC}\n" "$_CL_1175_PREFIX" "$*" >&2; }
_1175_ok()    { printf "${_CL_1175_GRN}✅ %s [OK]    %s${_CL_1175_NC}\n" "$_CL_1175_PREFIX" "$*" >&2; }
_1175_info()  { printf "${_CL_1175_BLU}ℹ️  %s [INFO]  %s${_CL_1175_NC}\n" "$_CL_1175_PREFIX" "$*" >&2; }

# ── 내부: 인프라 열거 (원시 데이터 수집) ────────────────────────────────────

# crontab 항목 목록 반환 (스케줄+스크립트명 한 줄씩)
_1175_list_cron() {
    crontab -l 2>/dev/null | grep -v '^#' | grep -v '^[[:space:]]*$' \
        | sed 's|.*/\([^/[:space:]]*\)\.sh.*|\1|' \
        | sort -u
}

# crontab 주석(설명) 목록 반환
_1175_list_cron_comments() {
    crontab -l 2>/dev/null | grep '^#' | sed 's/^# *//' | grep -v '^==='
}

# launchd plist 라벨 목록 반환 (활성 LaunchAgents + infra/launchd)
_1175_list_launchd() {
    {
        ls "${HOME}/Library/LaunchAgents/"*.plist 2>/dev/null \
            | xargs -I{} basename {} .plist 2>/dev/null
        ls "${HOME}/projects/jarvis/infra/launchd/"*.plist 2>/dev/null \
            | xargs -I{} basename {} .plist 2>/dev/null
    } | grep -v '\.bak\|\.disabled\|\.nexus_primary\|_archive' | sort -u
}

# monitoring.json 웹훅 채널 목록 반환
_1175_list_monitoring_channels() {
    local monitoring_json="${HOME}/projects/jarvis/infra/config/monitoring.json"
    if [[ -f "$monitoring_json" ]]; then
        python3 -c "
import json, sys
try:
    d = json.load(open('$monitoring_json'))
    wh = d.get('webhooks', {})
    for k, v in wh.items():
        if v: print(f'webhook:{k}')
    ntfy = d.get('ntfy', {})
    if ntfy.get('topic'): print(f'ntfy:{ntfy[\"topic\"]}')
except: pass
" 2>/dev/null
    fi
}

# jarvis/infra/lib 내 가드·스크립트 목록
_1175_list_lib_scripts() {
    ls "${HOME}/projects/jarvis/infra/lib/"*.sh 2>/dev/null \
        | xargs -I{} basename {} .sh 2>/dev/null | sort -u
}

# ── 공개 API: 1. enumerate_existing_infra ───────────────────────────────────
#
# 현재 자동화 인프라 전체를 구조화해 stdout 출력.
# 사용 예: enumerate_existing_infra | grep audit
enumerate_existing_infra() {
    local ts
    ts=$(_1175_now_iso)

    echo "=== 기존 자동화 인프라 전수 목록 (생성: ${ts}) ==="
    echo ""

    echo "## [CRON] 활성 크론 작업"
    _1175_list_cron | sed 's/^/  cron: /'
    echo ""

    echo "## [CRON-DESC] 크론 작업 설명 주석"
    _1175_list_cron_comments | sed 's/^/  desc: /'
    echo ""

    echo "## [LAUNCHD] LaunchAgent 라벨"
    _1175_list_launchd | sed 's/^/  launchd: /'
    echo ""

    echo "## [MONITOR] 모니터링 채널"
    _1175_list_monitoring_channels | sed 's/^/  channel: /'
    echo ""

    echo "## [LIB] infra/lib 스크립트"
    _1175_list_lib_scripts | sed 's/^/  lib: /'
    echo ""

    echo "=== END ==="

    _1175_log "INFO" "enumerate_existing_infra" "인프라 목록 출력 완료" ""
}

# ── 공개 API: 2. check_duplicate_automation ─────────────────────────────────
#
# check_duplicate_automation <keyword>
#
# 기존 crontab, launchd 라벨, lib 스크립트, 크론 주석에서 keyword를 검색.
# stdout 에 일치 항목 출력, stderr 에 판정 요약 출력.
# 반환: 0=중복 없음, 1=중복 가능성 있음
check_duplicate_automation() {
    local keyword="${1:-}"
    if [[ -z "$keyword" ]]; then
        _1175_warn "check_duplicate_automation: keyword 인자 필요"
        return 2
    fi

    # 소문자로 정규화
    local kw_lower
    kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    local matches=()

    # crontab 스크립트명 검색
    while IFS= read -r line; do
        [[ "$line" =~ $kw_lower ]] && matches+=("cron:${line}")
    done < <(_1175_list_cron | tr '[:upper:]' '[:lower:]')

    # crontab 주석 검색
    while IFS= read -r line; do
        local line_lower
        line_lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        [[ "$line_lower" =~ $kw_lower ]] && matches+=("cron-desc:${line}")
    done < <(_1175_list_cron_comments)

    # launchd 라벨 검색
    while IFS= read -r line; do
        local line_lower
        line_lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        [[ "$line_lower" =~ $kw_lower ]] && matches+=("launchd:${line}")
    done < <(_1175_list_launchd)

    # lib 스크립트 검색
    while IFS= read -r line; do
        [[ "$line" =~ $kw_lower ]] && matches+=("lib:${line}")
    done < <(_1175_list_lib_scripts | tr '[:upper:]' '[:lower:]')

    if [[ ${#matches[@]} -eq 0 ]]; then
        _1175_ok "키워드 '${keyword}' — 기존 자동화 중복 없음 (안전하게 제안 가능)"
        _1175_log "OK" "check_duplicate_automation" "중복 없음" "$keyword"
        return 0
    else
        _1175_fail "키워드 '${keyword}' — 기존 자동화 ${#matches[@]}건 발견! 중복 제안 위험"
        _1175_log "WARN" "check_duplicate_automation" "중복 ${#matches[@]}건" "$keyword"
        echo ""
        echo "=== 중복 가능성 있는 기존 자동화 (keyword: ${keyword}) ==="
        for m in "${matches[@]}"; do
            echo "  [발견] $m"
        done
        echo "=== 제안 전 위 항목과의 역할 중복 여부를 먼저 확인하라 ==="
        return 1
    fi
}

# ── 공개 API: 3. pre_proposal_check (핵심 가드) ─────────────────────────────
#
# pre_proposal_check [keyword]
#
# 새 자동화/감사 도구 제안 전에 반드시 호출한다.
# 1) 기존 인프라 전수 열거를 캐시에 기록
# 2) keyword 가 주어지면 중복 탐지 수행
# 3) 결과를 로그에 기록
#
# 반환: 0=안전(중복 없음 또는 keyword 미지정), 1=중복 위험 감지
pre_proposal_check() {
    local keyword="${1:-}"

    _1175_ensure_dirs

    _1175_info "새 자동화 제안 전 기존 인프라 전수 조사 시작..."

    # 1. 인프라 열거 + 캐시 저장
    local cron_count launchd_count lib_count
    cron_count=$(_1175_list_cron | wc -l | tr -d ' ')
    launchd_count=$(_1175_list_launchd | wc -l | tr -d ' ')
    lib_count=$(_1175_list_lib_scripts | wc -l | tr -d ' ')

    _1175_info "발견: cron ${cron_count}건 / launchd ${launchd_count}건 / lib ${lib_count}건"

    # 캐시에 요약 저장
    printf '{"ts":"%s","cron_count":%s,"launchd_count":%s,"lib_count":%s,"keyword":"%s"}\n' \
        "$(_1175_now_iso)" "$cron_count" "$launchd_count" "$lib_count" "${keyword:-none}" \
        > "$_CL_1175_CACHE" 2>/dev/null || true

    _1175_log "INFO" "pre_proposal_check" \
        "인프라 조사 완료 cron=${cron_count} launchd=${launchd_count} lib=${lib_count}" \
        "${keyword:-none}"

    # 2. keyword 중복 탐지
    if [[ -n "$keyword" ]]; then
        if ! check_duplicate_automation "$keyword"; then
            _1175_fail "중복 위험: 제안 전 기존 '${keyword}' 관련 자동화를 검토하라"
            _1175_log "FAIL" "pre_proposal_check" "중복 위험 감지" "$keyword"
            return 1
        fi
    else
        _1175_warn "keyword 미지정: enumerate_existing_infra 출력을 컨텍스트로 검토 후 제안하라"
        enumerate_existing_infra >&2
        _1175_log "WARN" "pre_proposal_check" "keyword 없이 호출 — 전체 목록 출력" ""
    fi

    _1175_ok "pre_proposal_check 완료 — 제안 진행 가능"
    return 0
}

# ── 공개 API: 4. guard_cl_117521_status ────────────────────────────────────

guard_cl_117521_status() {
    echo ""
    echo "=== ${_CL_1175_PREFIX} 상태 ==="
    echo "  클러스터 : ${_CL_1175_ID}"
    echo "  스크립트 : ${BASH_SOURCE[0]:-<unknown>}"
    echo "  로그     : ${_CL_1175_LOG}"
    echo "  캐시     : ${_CL_1175_CACHE}"

    if [[ -f "$_CL_1175_CACHE" ]]; then
        echo "  최근 조사: $(python3 -c "import json; d=json.load(open('$_CL_1175_CACHE')); print(d['ts'],'/ cron:',d['cron_count'],'/ launchd:',d['launchd_count'],'/ lib:',d['lib_count'])" 2>/dev/null || cat "$_CL_1175_CACHE")"
    else
        echo "  최근 조사: (없음 — pre_proposal_check 미실행)"
    fi

    local log_lines=0
    [[ -f "$_CL_1175_LOG" ]] && log_lines=$(wc -l < "$_CL_1175_LOG" | tr -d ' ')
    echo "  로그 행수: ${log_lines}"
    echo "========================================"
}

# ── 직접 실행 모드 ──────────────────────────────────────────────────────────
#
# 이 파일은 source 또는 직접 실행 모두 지원한다.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-help}" in
        check)
            pre_proposal_check "${2:-}"
            ;;
        duplicate)
            check_duplicate_automation "${2:-}"
            ;;
        enumerate)
            enumerate_existing_infra
            ;;
        status)
            guard_cl_117521_status
            ;;
        help|*)
            echo "사용:"
            echo "  $0 check [keyword]     — 새 자동화 제안 전 전수 조사 (핵심)"
            echo "  $0 duplicate <keyword> — 특정 키워드 중복 탐지"
            echo "  $0 enumerate           — 기존 인프라 전수 목록 출력"
            echo "  $0 status              — 가드 상태 요약"
            echo ""
            echo "source 모드:"
            echo "  source ~/projects/jarvis/infra/lib/cluster-guard-cl-117521116a786a9e.sh"
            echo "  pre_proposal_check audit"
            ;;
    esac
fi
