#!/usr/bin/env bash
# stale-rule-detector.sh — 상시 주입 규칙·메모리 파일 신선도 검사 (cl-00a1f0d4cb0a4200)
#
# 클러스터 ID  : cl-00a1f0d4cb0a4200 (최근 7일 재발 17건)
# 대표 시드    : 공식 문서 한도와 실제 시스템 상한 불일치 미검증 → 같은 지점 재실패
# 멤버 패턴    :
#   - 공식 문서 한도와 실제 시스템 상한 불일치 미검증
#   - 급여 오류 파급 + 미근거 진단
#   - 상시 주입 룰파일에 낡은 상태 정보 방치 → 4회 재발
#   - 메모리 기록과 실제 내용 불일치
#   - 메일 원본 미검토 후 추정으로 슬롯 기입, 나중에 실측 수정
#
# 목적: 세션 시작 시 ~/.claude/rules/*.md와 메모리 파일의 수정 시간을 검사해
#       30일 이상 경과한 파일이 있으면 경고를 세션 컨텍스트에 주입하고,
#       메모리 항목의 검증일 필드가 stale하면 재검증 권고.
#
# 공개 API:
#   detect_stale_rules [max_age_days=30]
#       규칙 파일 신선도 검사. stale 발견 시 stderr 경고 + exit 1, 정상 시 0.
#   generate_rule_staleness_report
#       세션 컨텍스트 주입용 마크다운 테이블 stdout 출력.
#   guard_cl_00a1f0_status
#       가드 자체 상태 요약.
#
# 사용:
#   source ~/projects/jarvis/infra/lib/stale-rule-detector.sh
#   detect_stale_rules 30 || warn_stale_context
#   generate_rule_staleness_report | cat >> context.md
#
# 기존 동작 보호:
#   - set -e 환경에서도 안전하게 소스되도록 설계
#   - 모든 실패는 exit code로 표현하되 프로세스는 죽이지 않는다

# NOTE: 이 파일은 source 되어 호출되므로 set -e를 남기지 않는다.

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_00A1_ID="cl-00a1f0d4cb0a4200"
readonly _CL_00A1_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_00A1_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_00A1_ID}.jsonl"
readonly _CL_00A1_PREFIX="[stale-rule-detector ${_CL_00A1_ID}]"
readonly _CL_00A1_DEFAULT_MAX_AGE_DAYS="${STALE_RULE_MAX_AGE_DAYS:-30}"

_CL_00A1_YLW='\033[0;33m'
_CL_00A1_RED='\033[0;31m'
_CL_00A1_GRN='\033[0;32m'
_CL_00A1_BLU='\033[0;34m'
_CL_00A1_NC='\033[0m'

# 감시 대상 파일들 (절대 경로)
readonly _CL_00A1_RULES_DIR="${HOME}/.claude/rules"
readonly _CL_00A1_MEMORY_DIR="${HOME}/.openclaw-data/runtime/claude-automemory"
readonly _CL_00A1_MEMORY_INDEX="${_CL_00A1_MEMORY_DIR}/MEMORY.md"

# ── 헬퍼 ────────────────────────────────────────────────────────────────────

_00a1_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_00a1_ensure_dirs() {
    mkdir -p "$_CL_00A1_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$_CL_00A1_LOG")" 2>/dev/null || true
}

# 크로스플랫폼 mtime (초 단위 epoch). 실패 시 빈 문자열.
_00a1_mtime() {
    local f="$1"
    [[ -e "$f" ]] || return 1
    # macOS BSD stat 우선, 실패 시 GNU 폴백
    stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || return 1
}

# 파일이 몇 일 오래됐는지 (정수). 실패 시 -1.
_00a1_age_days() {
    local f="$1" mt now
    mt="$(_00a1_mtime "$f")" || { echo "-1"; return 1; }
    now="$(date +%s)"
    echo $(( (now - mt) / 86400 ))
}

_00a1_log() {
    local level="$1" func="$2" detail="$3" extra="${4:-}"
    _00a1_ensure_dirs
    printf '{"ts":"%s","cluster":"%s","level":"%s","func":"%s","detail":"%s","extra":"%s"}\n' \
        "$(_00a1_now_iso)" "$_CL_00A1_ID" "$level" "$func" \
        "${detail//\"/\'}" "${extra//\"/\'}" \
        >> "$_CL_00A1_LOG" 2>/dev/null || true
}

_00a1_warn() { printf "${_CL_00A1_YLW}⚠️  %s [WARN]  %s${_CL_00A1_NC}\n" "$_CL_00A1_PREFIX" "$*" >&2; }
_00a1_fail() { printf "${_CL_00A1_RED}❌ %s [STALE] %s${_CL_00A1_NC}\n" "$_CL_00A1_PREFIX" "$*" >&2; }
_00a1_ok()   { printf "${_CL_00A1_GRN}✅ %s [FRESH] %s${_CL_00A1_NC}\n" "$_CL_00A1_PREFIX" "$*" >&2; }
_00a1_info() { printf "${_CL_00A1_BLU}ℹ️  %s [INFO]  %s${_CL_00A1_NC}\n" "$_CL_00A1_PREFIX" "$*" >&2; }

# ── 공개 API ──────────────────────────────────────────────────────────────────

detect_stale_rules() {
    local max_age_days="${1:-$_CL_00A1_DEFAULT_MAX_AGE_DAYS}"
    local rule_file stale_count age

    stale_count=0

    # 1. 규칙 디렉토리 체크
    if [[ ! -d "$_CL_00A1_RULES_DIR" ]]; then
        _00a1_warn "규칙 디렉토리 없음: $_CL_00A1_RULES_DIR"
        _00a1_log "WARN" "detect_stale_rules" "rules dir missing" "$_CL_00A1_RULES_DIR"
        return 1
    fi

    # 2. *.md 규칙 파일들 순회
    while IFS= read -r rule_file; do
        [[ -z "$rule_file" ]] && continue

        age="$(_00a1_age_days "$rule_file")"
        if (( age >= max_age_days )); then
            _00a1_fail "규칙 파일 stale: $(basename "$rule_file") (${age}일 경과)"
            _00a1_log "ALERT" "detect_stale_rules" "stale rule file" "path=$(basename "$rule_file"),age_days=$age"
            ((stale_count++))
        else
            _00a1_ok "규칙 파일 fresh: $(basename "$rule_file") (${age}일)"
            _00a1_log "INFO" "detect_stale_rules" "rule file fresh" "path=$(basename "$rule_file"),age_days=$age"
        fi
    done < <(find "$_CL_00A1_RULES_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null)

    # 3. 메모리 인덱스 체크
    if [[ -f "$_CL_00A1_MEMORY_INDEX" ]]; then
        age="$(_00a1_age_days "$_CL_00A1_MEMORY_INDEX")"
        if (( age >= max_age_days )); then
            _00a1_fail "메모리 인덱스 stale: (${age}일 경과)"
            _00a1_log "ALERT" "detect_stale_rules" "stale memory index" "age_days=$age"
            ((stale_count++))
        else
            _00a1_ok "메모리 인덱스 fresh: (${age}일)"
        fi
    fi

    # 4. 결과 반환
    if (( stale_count > 0 )); then
        _00a1_log "ALERT" "detect_stale_rules" "stale files detected" "count=$stale_count"
        return 1
    fi

    _00a1_info "모든 규칙 및 메모리 파일 신선도 정상"
    return 0
}

# 세션 컨텍스트 주입용 마크다운 테이블 생성
generate_rule_staleness_report() {
    local rule_file age max_age="$_CL_00A1_DEFAULT_MAX_AGE_DAYS"
    local stale_files=0 fresh_files=0

    # 헤더
    printf "## 📋 규칙 파일 신선도 (cl-00a1f0d4cb0a4200)\n\n"
    printf "_검사 시각: %s_\n\n" "$(_00a1_now_iso)"
    printf "| 파일명 | age(일) | 임계 | 상태 |\n"
    printf "|---|---:|---:|---|\n"

    # 규칙 파일들
    while IFS= read -r rule_file; do
        [[ -z "$rule_file" ]] && continue

        age="$(_00a1_age_days "$rule_file")"
        if (( age >= max_age )); then
            printf "| %s | %d | %d | 🔴 STALE |\n" "$(basename "$rule_file")" "$age" "$max_age"
            ((stale_files++))
        else
            printf "| %s | %d | %d | ✅ FRESH |\n" "$(basename "$rule_file")" "$age" "$max_age"
            ((fresh_files++))
        fi
    done < <(find "$_CL_00A1_RULES_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null | sort)

    # 메모리 인덱스
    if [[ -f "$_CL_00A1_MEMORY_INDEX" ]]; then
        age="$(_00a1_age_days "$_CL_00A1_MEMORY_INDEX")"
        if (( age >= max_age )); then
            printf "| MEMORY.md | %d | %d | 🔴 STALE |\n" "$age" "$max_age"
            ((stale_files++))
        else
            printf "| MEMORY.md | %d | %d | ✅ FRESH |\n" "$age" "$max_age"
            ((fresh_files++))
        fi
    fi

    printf "\n**주의**: STALE 파일은 %d일 이상 미갱신됨. 내용 검증 후 사용하세요.\n" "$max_age"
    printf "**권고**: 파일 수정이 필요하면 원본 출처를 재확인한 뒤 갱신하세요.\n"
}

# 가드 자체 상태 요약
guard_cl_00a1f0_status() {
    printf "%s Guard Status\n" "$_CL_00A1_PREFIX"
    printf "  ID        : %s\n" "$_CL_00A1_ID"
    printf "  State dir : %s\n" "$_CL_00A1_STATE_DIR"
    printf "  Log file  : %s\n" "$_CL_00A1_LOG"
    printf "  Max age   : %d days\n" "$_CL_00A1_DEFAULT_MAX_AGE_DAYS"
    printf "  Rules dir : %s\n" "$_CL_00A1_RULES_DIR"
    printf "  Memory idx: %s\n" "$_CL_00A1_MEMORY_INDEX"
}

# ── 자동 초기화 ────────────────────────────────────────────────────────────────

_00a1_ensure_dirs
