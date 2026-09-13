#!/usr/bin/env bash
# pre-proposal-check.sh — 새 자동화/감사 도구 제안 전 기존 인프라 전수 조사
#
# 클러스터 : cl-117521116a786a9e
# 목적     : 새 자동화를 제안하기 전에 이 스크립트를 실행해 기존 crontab·launchd·
#            monitoring.json을 열거하고, 제안 키워드와의 중복 여부를 판정한다.
#
# 사용:
#   bash pre-proposal-check.sh <keyword>         # 중복 탐지 포함
#   bash pre-proposal-check.sh                   # 전체 목록만 출력
#   bash pre-proposal-check.sh --full <keyword>  # 전체 목록 + 중복 탐지
#
# 종료 코드:
#   0  — 중복 없음 (안전하게 제안 가능)
#   1  — 중복 가능성 있음 (제안 전 기존 항목 검토 필요)
#   2  — 사용법 오류

set -o pipefail

JARVIS_HOME="${JARVIS_HOME:-${HOME}/projects/jarvis}"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
CLUSTER_ID="cl-117521116a786a9e"
LOG_FILE="${JARVIS_RUNTIME}/logs/pre-proposal-check.log"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

_ts()   { date '+%Y-%m-%dT%H:%M:%S'; }
_log()  { printf '[%s] [pre-proposal-check] %s\n' "$(_ts)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
_sep()  { printf '%s\n' "────────────────────────────────────────────────────────────────"; }

# ── 수집 함수 ──────────────────────────────────────────────────────────────

_collect_cron() {
    crontab -l 2>/dev/null | grep -v '^[[:space:]]*$'
}

_collect_cron_scripts() {
    # 실행되는 .sh 파일명만 추출
    crontab -l 2>/dev/null | grep -v '^#' | grep -v '^[[:space:]]*$' \
        | grep -oE '[^/[:space:]]+\.sh' | sort -u
}

_collect_cron_comments() {
    crontab -l 2>/dev/null | grep '^#' | sed 's/^# *//' | grep -v '^===' | grep -v '^$'
}

_collect_launchd_labels() {
    {
        ls "${HOME}/Library/LaunchAgents/"*.plist 2>/dev/null | xargs -I{} basename {} 2>/dev/null
        ls "${JARVIS_HOME}/infra/launchd/"*.plist 2>/dev/null | xargs -I{} basename {} 2>/dev/null
    } | grep -v '\.bak\|\.disabled\|\.nexus_primary\|_archive' \
      | sed 's/\.plist$//' | sort -u
}

_collect_lib_scripts() {
    ls "${JARVIS_HOME}/infra/lib/"*.sh 2>/dev/null | xargs -I{} basename {} .sh 2>/dev/null | sort -u
}

_collect_monitoring() {
    local mj="${JARVIS_HOME}/infra/config/monitoring.json"
    [[ -f "$mj" ]] && python3 -c "
import json
try:
    d = json.load(open('$mj'))
    for k, v in d.get('webhooks', {}).items():
        if v: print('webhook-channel: ' + k)
    ntfy = d.get('ntfy', {})
    if ntfy.get('topic'): print('ntfy-topic: ' + ntfy['topic'])
except Exception as e:
    print('(읽기 오류: ' + str(e) + ')')
" 2>/dev/null || echo "(monitoring.json 없음)"
}

# ── 출력 함수 ──────────────────────────────────────────────────────────────

_print_full_inventory() {
    local ts
    ts=$(_ts)

    echo ""
    _sep
    printf "  기존 자동화 인프라 전수 목록  (%s)\n" "$ts"
    printf "  클러스터 가드: %s\n" "$CLUSTER_ID"
    _sep

    echo ""
    echo "▸ CRON 작업 설명 (crontab -l 주석)"
    _collect_cron_comments | sed 's/^/    /'

    echo ""
    echo "▸ CRON 실행 스크립트"
    _collect_cron_scripts | sed 's/^/    /'

    echo ""
    echo "▸ LaunchAgent 라벨"
    _collect_launchd_labels | sed 's/^/    /'

    echo ""
    echo "▸ infra/lib 스크립트"
    _collect_lib_scripts | sed 's/^/    /'

    echo ""
    echo "▸ 모니터링 채널 (monitoring.json)"
    _collect_monitoring | sed 's/^/    /'

    echo ""
    _sep
}

# ── 중복 탐지 함수 ──────────────────────────────────────────────────────────

_find_duplicates() {
    local keyword="$1"
    local kw_lower
    kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    local hits=()

    # crontab 주석
    while IFS= read -r line; do
        local ll
        ll=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        [[ "$ll" == *"$kw_lower"* ]] && hits+=("  [cron-설명]  $line")
    done < <(_collect_cron_comments)

    # crontab 스크립트명
    while IFS= read -r line; do
        [[ "$line" == *"$kw_lower"* ]] && hits+=("  [cron-스크립트] $line")
    done < <(_collect_cron_scripts | tr '[:upper:]' '[:lower:]')

    # launchd
    while IFS= read -r line; do
        local ll
        ll=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        [[ "$ll" == *"$kw_lower"* ]] && hits+=("  [launchd]     $line")
    done < <(_collect_launchd_labels)

    # lib 스크립트
    while IFS= read -r line; do
        [[ "$line" == *"$kw_lower"* ]] && hits+=("  [lib]         $line")
    done < <(_collect_lib_scripts | tr '[:upper:]' '[:lower:]')

    if [[ ${#hits[@]} -gt 0 ]]; then
        echo ""
        printf "⚠️  중복 가능성: 키워드 '%s' — %d건 발견\n" "$keyword" "${#hits[@]}"
        _sep
        for h in "${hits[@]}"; do
            echo "$h"
        done
        _sep
        echo "제안 전 위 항목과의 역할 중복 여부를 먼저 확인하라."
        echo ""
        return 1
    else
        echo ""
        printf "✅ 키워드 '%s' — 기존 자동화 중복 없음 (안전하게 제안 가능)\n" "$keyword"
        echo ""
        return 0
    fi
}

# ── 메인 ───────────────────────────────────────────────────────────────────

main() {
    local mode="check"
    local keyword=""

    case "${1:-}" in
        --full)
            mode="full"
            keyword="${2:-}"
            ;;
        --help|-h)
            echo "사용: $0 [--full] [keyword]"
            echo "  keyword 없음: 전체 인프라 목록만 출력"
            echo "  keyword 지정: 중복 탐지 후 종료 코드로 판정"
            echo "  --full keyword: 전체 목록 + 중복 탐지"
            exit 0
            ;;
        *)
            keyword="${1:-}"
            ;;
    esac

    _log "호출 mode=${mode} keyword=${keyword:-none}"

    if [[ "$mode" == "full" ]] || [[ -z "$keyword" ]]; then
        _print_full_inventory
    fi

    if [[ -n "$keyword" ]]; then
        if ! _find_duplicates "$keyword"; then
            _log "중복 감지 keyword=${keyword}"
            exit 1
        fi
        _log "중복 없음 keyword=${keyword}"
        exit 0
    fi

    # keyword 없이 호출 시 목록만 출력하고 0 반환
    _log "목록 출력 완료 (keyword 미지정)"
    exit 0
}

main "$@"
