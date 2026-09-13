#!/usr/bin/env bash
# check-rule-drift.sh — 정책 파일과 규칙·SSoT 동기화 검사 (cl-a405499fa67279d6)
#
# 클러스터 ID  : cl-a405499fa67279d6 (최근 7일 재발 4건)
# 대표 시드    : 정책 확정 후 상시 주입 룰파일 미갱신 (드리프트)
# 멤버 패턴    :
#   - 정책 확정 후 상시 주입 룰파일 미갱신 (드리프트)
#   - 상시 주입 프롬프트 드리프트 — 정책은 갱신, 룰파일은 미동
#   - 계획 실행 직전 기존 상태 확인 미실시
#   - 버전·정책·원장 검증 없이 선택 후 단언 → 사후 불일치 발견
#
# 목적: 정책 파일(~/.claude/rules/jarvis.md 등)과 관련 SSoT 파일들의
#       수정 시간을 검사해 정책이 최신이지만 SSoT가 오래된 경우 경고를 출력한다.
#
# 공개 API:
#   check_rule_drift [threshold_minutes=180]
#       정책-SSoT 동기화 상태 검사. 불일치 발견 시 stderr 경고 + exit 1, 정상 시 0.
#   generate_drift_report
#       세션 컨텍스트 주입용 마크다운 테이블 stdout 출력.
#
# 사용:
#   source ~/projects/jarvis/infra/lib/check-rule-drift.sh
#   check_rule_drift 180 || warn_drift_context
#   generate_drift_report | cat >> context.md
#
# 기존 동작 보호:
#   - set -e 환경에서도 안전하게 소스되도록 설계
#   - 모든 실패는 exit code로 표현하되 프로세스는 죽이지 않는다

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CLA405_ID="cl-a405499fa67279d6"
readonly _CLA405_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CLA405_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CLA405_ID}.jsonl"
readonly _CLA405_PREFIX="[check-rule-drift ${_CLA405_ID}]"
readonly _CLA405_DEFAULT_THRESHOLD_MIN=180

_CLA405_YLW='\033[0;33m'
_CLA405_RED='\033[0;31m'
_CLA405_GRN='\033[0;32m'
_CLA405_BLU='\033[0;34m'
_CLA405_NC='\033[0m'

# ── 헬퍼 ────────────────────────────────────────────────────────────────────

_cla405_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_cla405_ensure_dirs() {
    mkdir -p "$_CLA405_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$_CLA405_LOG")" 2>/dev/null || true
}

# 크로스플랫폼 mtime (초 단위 epoch). 실패 시 빈 문자열.
_cla405_mtime() {
    local f="$1"
    [[ -e "$f" ]] || return 1
    stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || return 1
}

# 두 파일의 시간 차이를 분 단위로 반환 (policy - ssot)
_cla405_time_diff_min() {
    local policy_file="$1" ssot_file="$2"
    local policy_time ssot_time diff_sec

    policy_time="$(_cla405_mtime "$policy_file")" || { echo "9999"; return 1; }
    ssot_time="$(_cla405_mtime "$ssot_file")" || { echo "9999"; return 1; }

    diff_sec=$(( policy_time - ssot_time ))
    echo $(( diff_sec / 60 ))
}

_cla405_log() {
    local level="$1" func="$2" detail="$3" extra="${4:-}"
    _cla405_ensure_dirs
    printf '{"ts":"%s","cluster":"%s","level":"%s","func":"%s","detail":"%s","extra":"%s"}\n' \
        "$(_cla405_now_iso)" "$_CLA405_ID" "$level" "$func" \
        "${detail//\"/\'}" "${extra//\"/\'}" \
        >> "$_CLA405_LOG" 2>/dev/null || true
}

_cla405_warn() { printf "${_CLA405_YLW}⚠️  %s [WARN]  %s${_CLA405_NC}\n" "$_CLA405_PREFIX" "$*" >&2; }
_cla405_fail() { printf "${_CLA405_RED}❌ %s [DRIFT] %s${_CLA405_NC}\n" "$_CLA405_PREFIX" "$*" >&2; }
_cla405_ok()   { printf "${_CLA405_GRN}✅ %s [SYNC]  %s${_CLA405_NC}\n" "$_CLA405_PREFIX" "$*" >&2; }
_cla405_info() { printf "${_CLA405_BLU}ℹ️  %s [INFO]  %s${_CLA405_NC}\n" "$_CLA405_PREFIX" "$*" >&2; }

# 정책-SSoT 쌍 검사 헬퍼
_cla405_check_pair() {
    local policy_file="$1" ssot_file="$2" threshold_min="$3"
    local diff_min

    [[ -f "$policy_file" ]] || {
        _cla405_warn "정책 파일 없음: $(basename "$policy_file")"
        return 0
    }

    [[ -f "$ssot_file" ]] || {
        _cla405_warn "SSoT 파일 없음: $(basename "$ssot_file")"
        return 0
    }

    diff_min="$(_cla405_time_diff_min "$policy_file" "$ssot_file")" || return 0

    if (( diff_min > threshold_min )); then
        _cla405_fail "$(basename "$policy_file") (신) → $(basename "$ssot_file") (구) | 차이 ${diff_min}분"
        _cla405_log "ALERT" "check_rule_drift" "policy-ssot drift" \
            "policy=$(basename "$policy_file"),ssot=$(basename "$ssot_file"),diff_min=$diff_min"
        return 1
    elif (( diff_min < -threshold_min )); then
        _cla405_warn "이상: $(basename "$ssot_file") (신) → $(basename "$policy_file") (구) | 차이 $((0 - diff_min))분"
        _cla405_log "WARN" "check_rule_drift" "ssot newer than policy" \
            "policy=$(basename "$policy_file"),ssot=$(basename "$ssot_file"),diff_min=$diff_min"
        return 0
    else
        _cla405_ok "$(basename "$policy_file") ↔ $(basename "$ssot_file") 동기화됨"
        _cla405_log "INFO" "check_rule_drift" "policy-ssot in sync" \
            "policy=$(basename "$policy_file"),ssot=$(basename "$ssot_file"),diff_min=$diff_min"
        return 0
    fi
}

# ── 공개 API ──────────────────────────────────────────────────────────────────

check_rule_drift() {
    local threshold_min="${1:-$_CLA405_DEFAULT_THRESHOLD_MIN}"
    local drift_count=0

    _cla405_ensure_dirs

    # Claude Code 인터페이스 규칙
    local jarvis_rules="${HOME}/.claude/rules/jarvis.md"
    local claude_md="${HOME}/projects/jarvis/CLAUDE.md"
    local persona_discord="${HOME}/.openclaw-data/runtime/context/owner/persona-discord.md"
    local persona_discord_emotional="${HOME}/.openclaw-data/runtime/context/owner/persona-discord-emotional.md"

    # 검사: jarvis.md ↔ CLAUDE.md
    _cla405_check_pair "$jarvis_rules" "$claude_md" "$threshold_min" || ((drift_count++))

    # 검사: jarvis.md ↔ persona-discord.md
    _cla405_check_pair "$jarvis_rules" "$persona_discord" "$threshold_min" || ((drift_count++))

    # 검사: jarvis.md ↔ persona-discord-emotional.md
    _cla405_check_pair "$jarvis_rules" "$persona_discord_emotional" "$threshold_min" || ((drift_count++))

    # 디스코드 봇 규칙
    local autonomy_levels="${HOME}/.openclaw-data/runtime/config/autonomy-levels.md"
    _cla405_check_pair "$autonomy_levels" "$persona_discord" "$threshold_min" || ((drift_count++))

    # 결과 반환
    if (( drift_count > 0 )); then
        _cla405_log "ALERT" "check_rule_drift" "drift detected" "count=$drift_count"
        return 1
    fi

    _cla405_info "모든 정책-SSoT 파일 동기화 상태 정상"
    return 0
}

# 세션 컨텍스트 주입용 마크다운 테이블 생성
generate_drift_report() {
    local threshold_min="$_CLA405_DEFAULT_THRESHOLD_MIN"
    local diff_min drift_count=0 sync_count=0

    local jarvis_rules="${HOME}/.claude/rules/jarvis.md"
    local claude_md="${HOME}/projects/jarvis/CLAUDE.md"
    local persona_discord="${HOME}/.openclaw-data/runtime/context/owner/persona-discord.md"
    local persona_discord_emotional="${HOME}/.openclaw-data/runtime/context/owner/persona-discord-emotional.md"
    local autonomy_levels="${HOME}/.openclaw-data/runtime/config/autonomy-levels.md"

    # 헤더
    printf "## ⚠️ 정책-규칙 동기화 검사 (cl-a405499fa67279d6)\n\n"
    printf "_검사 시각: %s_\n\n" "$(_cla405_now_iso)"
    printf "| 정책 파일 | SSoT 파일 | 차이(분) | 상태 |\n"
    printf "|---|---|---:|---|\n"

    # 검사 쌍들
    local pairs=(
        "$jarvis_rules:$claude_md"
        "$jarvis_rules:$persona_discord"
        "$jarvis_rules:$persona_discord_emotional"
        "$autonomy_levels:$persona_discord"
    )

    for pair in "${pairs[@]}"; do
        local policy_file="${pair%:*}"
        local ssot_file="${pair#*:}"

        [[ -f "$policy_file" ]] || continue
        [[ -f "$ssot_file" ]] || continue

        diff_min="$(_cla405_time_diff_min "$policy_file" "$ssot_file")" || continue

        if (( diff_min > threshold_min )); then
            printf "| %s | %s | %d | 🔴 미동기 |\n" \
                "$(basename "$policy_file")" "$(basename "$ssot_file")" "$diff_min"
            ((drift_count++))
        elif (( diff_min < -threshold_min )); then
            printf "| %s | %s | %d | ⚠️ 역순 |\n" \
                "$(basename "$policy_file")" "$(basename "$ssot_file")" "$((0 - diff_min))"
        else
            printf "| %s | %s | %d | ✅ 동기화 |\n" \
                "$(basename "$policy_file")" "$(basename "$ssot_file")" "$diff_min"
            ((sync_count++))
        fi
    done

    printf "\n**주의**: 정책 파일이 최신이지만 SSoT가 오래되면 드리프트 위험\n"
    printf "**권고**: 정책 수정 후 %d분 이내에 관련 SSoT도 갱신하세요\n" "$threshold_min"
}
