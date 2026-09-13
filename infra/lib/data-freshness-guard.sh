#!/usr/bin/env bash
# data-freshness-guard.sh — 데이터 신선도 검증 가드 (cl-02f731ffc275d999)
#
# 클러스터 ID  : cl-02f731ffc275d999 (최근 7일 재발 10건)
# 대표 시드    : 데이터 이상 신호 거짓 경보 — 기저 원인 검증 미선행
# 멤버 패턴    :
#   - 성능·사용률 원인 분석 시 설정 파일 미검증 후 추측 제시
#   - 지침 문서의 진부한 데이터 그대로 인용하여 성능 비교 왜곡
#   - 검증 불가 데이터의 범위 불명확한 보고
#   - 실측 없이 추측을 원인으로 단정
#
# 목적: 보고·컨텍스트 주입 직전, 데이터 파일의 mtime을 확인해
#       기준시간(기본 30분) 이상 오래된 값 사용 시 경고를 남기고,
#       AI 컨텍스트에도 타임스탬프 표를 붙여 스스로 신선도를 판단하게 한다.
#
# 공개 API:
#   check_file_freshness <path> [max_age_min=30] [label]
#       stale이면 stderr 경고 + exit 1, fresh면 0. 파일 부재는 exit 2(WARN).
#   annotate_context_with_timestamps [watch_json]
#       설정에 나열된 파일들의 age(분)와 상태를 마크다운 표로 stdout 출력.
#       context-loader.sh가 이 출력을 DYNAMIC 섹션으로 삽입한다.
#   data_freshness_summary [watch_json] [max_age_min=30]
#       사람이 읽는 요약(색상 포함) stderr 출력, stale 발견 시 exit 1.
#   guard_cl_02f731_status
#       가드 자체 상태 요약 (설정 파일·로그 위치 등).
#
# 사용:
#   source ~/projects/jarvis/infra/lib/data-freshness-guard.sh
#   check_file_freshness "$BOT_HOME/state/cron-status.json" 30 "cron-status" || true
#   data_freshness_summary || true    # 스탠드업 크론에서 non-blocking 사용
#
# 기존 동작 보호:
#   - set -e 환경에서도 안전하게 소스되도록 setup 부분에 안전 가드
#   - 모든 실패는 exit code로 표현하되 프로세스는 죽이지 않는다 (호출자가 || true)
#   - 알 수 없는 파일/도구 부재는 조용히 스킵

# NOTE: 이 파일은 source 되어 호출되므로 set -e를 남기지 않는다.

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_02F7_ID="cl-02f731ffc275d999"
readonly _CL_02F7_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_02F7_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_02F7_ID}.jsonl"
readonly _CL_02F7_CONFIG="${_CL_02F7_STATE_DIR}/${_CL_02F7_ID}-watchlist.json"
readonly _CL_02F7_PREFIX="[data-freshness-guard ${_CL_02F7_ID}]"
readonly _CL_02F7_DEFAULT_MAX_AGE_MIN="${DATA_FRESHNESS_MAX_AGE_MIN:-30}"

_CL_02F7_YLW='\033[0;33m'
_CL_02F7_RED='\033[0;31m'
_CL_02F7_GRN='\033[0;32m'
_CL_02F7_BLU='\033[0;34m'
_CL_02F7_NC='\033[0m'

# ── 헬퍼 ────────────────────────────────────────────────────────────────────

_02f7_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_02f7_ensure_dirs() {
    mkdir -p "$_CL_02F7_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$_CL_02F7_LOG")" 2>/dev/null || true
}

# 크로스플랫폼 mtime (초 단위 epoch). 실패 시 빈 문자열.
_02f7_mtime() {
    local f="$1"
    [[ -e "$f" ]] || return 1
    # macOS BSD stat 우선, 실패 시 GNU 폴백
    stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || return 1
}

# 파일이 몇 분 오래됐는지 (정수). 실패 시 -1.
_02f7_age_minutes() {
    local f="$1" mt now
    mt="$(_02f7_mtime "$f")" || { echo "-1"; return 1; }
    now="$(date +%s)"
    echo $(( (now - mt) / 60 ))
}

_02f7_log() {
    local level="$1" func="$2" detail="$3" extra="${4:-}"
    _02f7_ensure_dirs
    printf '{"ts":"%s","cluster":"%s","level":"%s","func":"%s","detail":"%s","extra":"%s"}\n' \
        "$(_02f7_now_iso)" "$_CL_02F7_ID" "$level" "$func" \
        "${detail//\"/\'}" "${extra//\"/\'}" \
        >> "$_CL_02F7_LOG" 2>/dev/null || true
}

_02f7_warn() { printf "${_CL_02F7_YLW}⚠️  %s [WARN]  %s${_CL_02F7_NC}\n" "$_CL_02F7_PREFIX" "$*" >&2; }
_02f7_fail() { printf "${_CL_02F7_RED}❌ %s [STALE] %s${_CL_02F7_NC}\n" "$_CL_02F7_PREFIX" "$*" >&2; }
_02f7_ok()   { printf "${_CL_02F7_GRN}✅ %s [FRESH] %s${_CL_02F7_NC}\n" "$_CL_02F7_PREFIX" "$*" >&2; }
_02f7_info() { printf "${_CL_02F7_BLU}ℹ️  %s [INFO]  %s${_CL_02F7_NC}\n" "$_CL_02F7_PREFIX" "$*" >&2; }

# ── 기본 감시 목록 시딩 (없을 때만 생성; 기존 사용자 설정 파괴 금지) ──────────

_02f7_seed_default_watchlist() {
    [[ -f "$_CL_02F7_CONFIG" ]] && return 0
    _02f7_ensure_dirs
    cat > "$_CL_02F7_CONFIG" <<'JSON'
{
  "_comment": "데이터 신선도 감시 목록. label:relative_path pairs. 각 항목은 max_age_min override 가능.",
  "default_max_age_min": 30,
  "items": [
    { "label": "context-bus",     "path": "state/context-bus.md",           "max_age_min": 720 },
    { "label": "cron-status",     "path": "state/cron-status.json",         "max_age_min": 30 },
    { "label": "morning-standup", "path": "context/morning-standup.md",     "max_age_min": 1440 },
    { "label": "insight-report",  "path": "context/insight-report.md",      "max_age_min": 1440 },
    { "label": "cron-metrics",    "path": "state/cluster-recurrence-metrics.jsonl", "max_age_min": 1440 }
  ]
}
JSON
    _02f7_log "info" "seed_default_watchlist" "created default watchlist" "path=${_CL_02F7_CONFIG}"
}

# ── 공개 API ────────────────────────────────────────────────────────────────

# check_file_freshness <path> [max_age_min] [label]
#   exit 0 = fresh, 1 = stale, 2 = 파일 없음
check_file_freshness() {
    local path="${1:?path required}"
    local max_age="${2:-$_CL_02F7_DEFAULT_MAX_AGE_MIN}"
    local label="${3:-$(basename "$path")}"

    if [[ ! -e "$path" ]]; then
        _02f7_warn "$label — 파일 없음: $path"
        _02f7_log "warn" "check_file_freshness" "missing" "path=${path},label=${label}"
        return 2
    fi

    local age
    age="$(_02f7_age_minutes "$path")"
    if [[ "$age" -lt 0 ]]; then
        _02f7_warn "$label — mtime 조회 실패: $path"
        _02f7_log "warn" "check_file_freshness" "mtime_failed" "path=${path}"
        return 2
    fi

    if (( age > max_age )); then
        _02f7_fail "$label — ${age}분 경과 (임계 ${max_age}분 초과) — 원인 분석·보고 전 재수집 필요: $path"
        _02f7_log "stale" "check_file_freshness" "stale" "path=${path},age_min=${age},max=${max_age}"
        return 1
    fi

    _02f7_ok "$label — ${age}분 (임계 ${max_age}분 이내): $path"
    _02f7_log "fresh" "check_file_freshness" "fresh" "path=${path},age_min=${age},max=${max_age}"
    return 0
}

# annotate_context_with_timestamps [watch_json]
#   설정 감시 목록의 파일 상태를 마크다운 표로 stdout 출력.
#   출력이 비어있어도 컨텍스트 파괴 없이 조용히 return 0.
annotate_context_with_timestamps() {
    local watch_json="${1:-$_CL_02F7_CONFIG}"
    _02f7_seed_default_watchlist

    if ! command -v jq >/dev/null 2>&1; then
        _02f7_log "skip" "annotate_context" "jq_missing" ""
        return 0
    fi
    [[ -f "$watch_json" ]] || return 0

    local bot_home="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
    local default_max
    default_max=$(jq -r '.default_max_age_min // 30' "$watch_json" 2>/dev/null || echo 30)

    printf '## 📅 참조 데이터 신선도 (data-freshness-guard %s)\n' "$_CL_02F7_ID"
    printf '_원인 분석·보고 전에 아래 데이터의 age를 확인하고, stale 항목은 인용을 자제하거나 재수집하세요._\n\n'
    printf '| label | age(min) | 임계 | 상태 | 경로 |\n'
    printf '|---|---:|---:|---|---|\n'

    local any_stale=0
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        local label rel max_age path age status
        label=$(echo "$item" | jq -r '.label // "unnamed"')
        rel=$(echo "$item"   | jq -r '.path  // ""')
        max_age=$(echo "$item" | jq -r ".max_age_min // $default_max")
        [[ -n "$rel" ]] || continue

        # 절대경로 처리: 절대면 그대로, 상대면 BOT_HOME 기준
        if [[ "$rel" == /* ]]; then path="$rel"; else path="${bot_home}/${rel}"; fi

        if [[ ! -e "$path" ]]; then
            status="❓ 없음"; age="-"
        else
            age=$(_02f7_age_minutes "$path")
            if [[ "$age" -lt 0 ]]; then
                status="❓ 알 수 없음"; age="-"
            elif (( age > max_age )); then
                status="⚠️ STALE"; any_stale=1
            else
                status="✅ FRESH"
            fi
        fi
        printf '| %s | %s | %s | %s | %s |\n' "$label" "$age" "$max_age" "$status" "$path"
    done < <(jq -c '.items[]?' "$watch_json" 2>/dev/null)

    printf '\n_수집 시각: %s_\n' "$(_02f7_now_iso)"
    _02f7_log "info" "annotate_context" "emitted_table" "stale=${any_stale}"
    return 0
}

# data_freshness_summary [watch_json] [max_age_min]
#   사람용 요약을 stderr에 출력, stale 발견 시 exit 1 (non-blocking; 호출자가 || true).
data_freshness_summary() {
    local watch_json="${1:-$_CL_02F7_CONFIG}"
    local max_override="${2:-}"
    _02f7_seed_default_watchlist

    command -v jq >/dev/null 2>&1 || { _02f7_warn "jq 미설치 — 요약 스킵"; return 0; }
    [[ -f "$watch_json" ]] || { _02f7_warn "감시 목록 없음: $watch_json"; return 0; }

    local bot_home="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
    local default_max
    default_max="${max_override:-$(jq -r '.default_max_age_min // 30' "$watch_json" 2>/dev/null || echo 30)}"

    local total=0 fresh=0 stale=0 missing=0
    _02f7_info "데이터 신선도 요약 시작 (default_max=${default_max}분)"

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        local label rel max_age path
        label=$(echo "$item"   | jq -r '.label // "unnamed"')
        rel=$(echo "$item"     | jq -r '.path  // ""')
        max_age=$(echo "$item" | jq -r ".max_age_min // $default_max")
        [[ -n "$rel" ]] || continue
        if [[ "$rel" == /* ]]; then path="$rel"; else path="${bot_home}/${rel}"; fi
        total=$(( total + 1 ))
        if check_file_freshness "$path" "$max_age" "$label" >/dev/null 2>&1; then
            fresh=$(( fresh + 1 ))
        else
            case $? in
                1) stale=$(( stale + 1 )) ;;
                2) missing=$(( missing + 1 )) ;;
            esac
        fi
    done < <(jq -c '.items[]?' "$watch_json" 2>/dev/null)

    _02f7_info "결과 — total=${total} fresh=${fresh} stale=${stale} missing=${missing}"
    _02f7_log "info" "summary" "total=${total} fresh=${fresh} stale=${stale} missing=${missing}" ""

    if (( stale > 0 || missing > 0 )); then
        _02f7_fail "stale=${stale}, missing=${missing} — 보고 전 재검증 필요"
        return 1
    fi
    _02f7_ok "모든 감시 대상 신선함"
    return 0
}

guard_cl_02f731_status() {
    _02f7_seed_default_watchlist
    printf '%s status\n' "$_CL_02F7_PREFIX"
    printf '  config     : %s (%s)\n' "$_CL_02F7_CONFIG" "$( [[ -f "$_CL_02F7_CONFIG" ]] && echo present || echo missing )"
    printf '  log        : %s\n' "$_CL_02F7_LOG"
    printf '  default TTL: %s min\n' "$_CL_02F7_DEFAULT_MAX_AGE_MIN"
}

# 초기 시딩만 즉시 실행 (환경 파괴 없음)
_02f7_seed_default_watchlist
