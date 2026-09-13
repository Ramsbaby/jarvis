#!/usr/bin/env bash

# monitoring-pre-check.sh - 모니터링 인프라 사전 점검
# 목적: 모니터링 관련 작업 시작 시 각 도구의 실제 등록·활성화 상태를 자동으로 출력
# 사용: ./monitoring-pre-check.sh [--json] [--verbose]
#
# 검사 항목:
# 1. Crontab 등록 상태 (존재/활성 여부)
# 2. LaunchAgent 등록 상태 (loaded/unloaded)
# 3. LaunchAgent 프로세스 실행 상태 (PID 확인)
# 4. 주요 모니터링 스크립트 파일 존재 여부
# 5. 모니터링 도구의 의존성 파일 확인
#
# [오픈클로 이식 2026-09-10] 오픈클로 jarvis-monitoring-pre-check(04:55)로 이관됐다.
# 이 스크립트는 crontab 46행에서도 불리는데 crontab 쓰기가 이 환경에서 막혀 있어(rc=124 타임아웃)
# 스크립트 층에 가드를 둬 이중 실행을 막는다. 재개: rm ~/.openclaw-data/runtime/state/stopped/monitoring-pre-check
if [[ -f "${HOME}/.openclaw-data/runtime/state/stopped/monitoring-pre-check" ]] && [[ "${OPENCLAW_JOB:-}" != "1" ]]; then
    echo "[monitoring-pre-check] 중지 플래그 있음 — 오픈클로 잡으로 이관됨 (state/stopped/monitoring-pre-check)"
    exit 0
fi

set -eo pipefail

# 옵션 파싱
JSON_MODE=false
VERBOSE=false
crontab_line_count=0
crontab_exists=false
disk_alert_cron=""
health_check_cron=""
launchd_agents=""
launchd_count=0
missing_scripts=0
plist_count=0
plist_disabled_count=0
has_system_health="false"
has_disk_alert="false"
fail_count=0
warn_count=0
ok_count=0
orchestrator_pid=""
watchdog_pid=""
agent_info=""
pid=""
exit_code=""
ps_check=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_MODE=true ;;
        --verbose) VERBOSE=true ;;
        *) ;;
    esac
    shift
done

# 색상 및 아이콘
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

ICON_OK="✅"
ICON_WARN="⚠️"
ICON_FAIL="❌"

# 결과 저장 (bash 3.2 호환성을 위해 배열 제거)
# results와 statuses는 파일 기반으로 처리

# 로깅 함수
log_check() {
    local name="$1"
    local status="$2"
    local detail="$3"

    # 상태와 결과를 임시 파일에 저장 (bash 3.2 호환성)
    echo "$name:$status:$detail" >> /tmp/monitoring-precheck-results.log

    if [[ "$JSON_MODE" == "true" ]]; then
        printf '{"component":"%s","status":"%s","detail":"%s"}\n' "$name" "$status" "$detail"
    else
        local icon="$ICON_OK"
        if [[ "$status" == "warn" ]]; then icon="$ICON_WARN"; fi
        if [[ "$status" == "fail" ]]; then icon="$ICON_FAIL"; fi
        printf "%s %-35s %s\n" "$icon" "$name" "$detail"
    fi
}

# 홈 디렉토리 설정
JARVIS_HOME="${JARVIS_HOME:-${HOME}/.jarvis}"
JARVIS_INFRA="${JARVIS_HOME}/infra"
# tasks.json 위치: ~/.openclaw-data/runtime/config/tasks.json 또는 ~/.jarvis 근처
if [[ -f "${HOME}/.openclaw-data/runtime/config/tasks.json" ]]; then
    TASKS_CONFIG="${HOME}/.openclaw-data/runtime/config/tasks.json"
else
    TASKS_CONFIG="${JARVIS_HOME}/../jarvis/runtime/config/tasks.json"
fi

# 헤더 출력
if [[ "$JSON_MODE" == "false" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 모니터링 인프라 사전 점검"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

# ============================================================================
# 1. Crontab 상태 확인
# ============================================================================

log_check "crontab.registry" "ok" "확인 중..."

if crontab -l >/dev/null 2>&1; then
    crontab_line_count=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | wc -l)
    crontab_exists=true
    log_check "crontab.registry" "ok" "등록됨 (활성 태스크 $crontab_line_count개)"
else
    log_check "crontab.registry" "fail" "등록되지 않음 (또는 crontab 명령 불가)"
fi

# 모니터링 태스크가 '어딘가에' 등록돼 있는지 확인한다.
#
# 2026-09-10 정정: 전에는 crontab 만 봤다. 회차 6 에서 crontab 을 55줄 → 1줄로 줄이고
#   스케줄을 오픈클로 잡으로 옮기자, 살아 있는 `jarvis-system-health` 를 못 보고
#   매 실행 "미등록" 경고 → rc=1 을 냈다. 한 층만 세면 그 층 밖은 영원히 안 보인다.
#   그래서 crontab 과 오픈클로 잡을 **합집합**으로 판정한다.
oc_jobs=""
if [[ -x "$HOME/bin/openclaw" ]]; then
    oc_jobs=$("$HOME/bin/openclaw" automations list 2>/dev/null || true)
fi

check_registered() {  # check_registered <검사이름> <grep 패턴>
    local label="$1" pattern="$2" cron_hit="" oc_n=0
    # 주석·빈 줄은 등록이 아니다. 이걸 안 걸러서 crontab 주석 한 줄을
    #   "등록됨"으로 셌다(2026-09-10 실측 오탐).
    cron_hit=$(crontab -l 2>/dev/null | grep -vE '^\s*(#|$)' | grep -iE "$pattern" || true)
    oc_n=$(printf '%s\n' "$oc_jobs" | grep -icE "$pattern" || true)
    if [[ -n "$cron_hit" ]]; then
        log_check "$label" "ok" "crontab 등록됨: $(printf '%s' "$cron_hit" | head -1 | cut -c1-70)"
    elif [[ "${oc_n:-0}" -gt 0 ]]; then
        log_check "$label" "ok" "오픈클로 잡으로 등록됨 (${oc_n}건)"
    else
        log_check "$label" "warn" "두 층 어디에도 미등록 (crontab · 오픈클로 잡)"
    fi
}

check_registered "monitor.disk-alert"   "disk-alert"
check_registered "monitor.health-check" "system-health|health-check"

echo ""

# ============================================================================
# 2. LaunchAgent 등록 상태 확인
# ============================================================================

log_check "launchd.registry" "ok" "확인 중..."

# launchctl list로 등록된 agent 확인
launchd_agents=$(launchctl list 2>/dev/null | grep "ai\.jarvis" | cut -f3 | sort || true)
launchd_count=$(echo "$launchd_agents" | grep -v '^$' | wc -l)

if [[ $launchd_count -gt 0 ]]; then
    log_check "launchd.registry" "ok" "등록됨 ($launchd_count개 agent)"
else
    log_check "launchd.registry" "fail" "등록된 agent 없음"
fi

echo ""

# 핵심 모니터링 LaunchAgent 상태 확인
# 2026-09-04: system-health·disk-alert 는 5월부터 com.jarvis.* (tasks.json → cron-sync 생성) 라벨이다.
#   옛 ai.jarvis.* 라벨을 찾던 탓에 매일 "미등록" 2건이 났고, 아래 grep 도 `^-` 로 시작하는 줄만 봐서
#   PID 가 있는(=실행 중인) 데몬을 미등록으로 찍었다. 2026-06-23 이후 4건 전부 오탐이었다.
# 2026-09-10 오픈클로 이식: system-health·disk-alert 는 오픈클로 잡으로 이관됐고(launchd에 없는 게 정상),
#   ai.jarvis.watchdog 은 감시 대상인 디스코드 봇이 제거돼 함께 정지했다. 셋을 남겨두면 매일 오탐 3건이 난다.
#   기대 목록을 실제와 맞춘다. 오픈클로 쪽 발화 여부는 `openclaw cron list` 로 본다.
#   orchestrator 도 runtime/discord/lib/ 에서 돌던 디스코드 계열이라 같이 정지했다(2026-09-10).
#   결과적으로 이 목록은 비었다 — 자비스 쪽 "반드시 떠 있어야 하는 데몬"이 더는 없다는 뜻이다.
#   자비스에 상주 데몬을 다시 두게 되면 여기에 라벨을 추가한다.
declare -a CRITICAL_AGENTS=()

for agent in ${CRITICAL_AGENTS[@]+"${CRITICAL_AGENTS[@]}"}; do
    agent_info=$(launchctl list 2>/dev/null | awk -F'\t' -v l="$agent" '$3==l' || echo "")

    if [[ -z "$agent_info" ]]; then
        # 등록되지 않음
        log_check "launchd.$agent" "fail" "미등록"
    else
        # 등록됨 - PID 확인으로 활성 여부 판단
        pid=$(echo "$agent_info" | awk '{print $1}')
        exit_code=$(echo "$agent_info" | awk '{print $2}')

        if [[ "$pid" == "-" && "$exit_code" == "0" ]]; then
            # 스케줄형(StartInterval/Calendar) 에이전트는 실행 사이에 PID 가 없는 게 정상 — 종료코드 0 이면 건강
            log_check "launchd.$agent" "ok" "대기 중 (스케줄형, 마지막 종료코드 0)"
        elif [[ "$pid" == "-" ]]; then
            log_check "launchd.$agent" "warn" "등록됨 (비활성, 마지막 종료코드: $exit_code)"
        else
            # 활성 상태
            log_check "launchd.$agent" "ok" "활성 (PID: $pid)"
        fi
    fi
done

echo ""

# ============================================================================
# 3. LaunchAgent plist 파일 상태 확인
# ============================================================================

log_check "launchd.plist.files" "ok" "확인 중..."

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
plist_count=0
plist_disabled_count=0

if [[ -d "$LAUNCHD_DIR" ]]; then
    plist_count=$(ls -1 "$LAUNCHD_DIR"/*.plist 2>/dev/null | wc -l)
    plist_disabled_count=$(ls -1 "$LAUNCHD_DIR"/*.plist.disabled 2>/dev/null | wc -l)

    if [[ $plist_count -gt 0 ]]; then
        log_check "launchd.plist.files" "ok" "발견됨 ($plist_count개, 비활성 $plist_disabled_count개)"
    else
        log_check "launchd.plist.files" "warn" "plist 파일 없음"
    fi
else
    log_check "launchd.plist.files" "warn" "LaunchAgents 디렉토리 없음"
fi

echo ""

# ============================================================================
# 4. 모니터링 스크립트 파일 존재 여부
# ============================================================================

log_check "scripts.files" "ok" "확인 중..."

declare -a SCRIPTS=(
    "$JARVIS_INFRA/bin/disk-alert.sh"
    "$JARVIS_INFRA/scripts/health-check.sh"
    "$JARVIS_INFRA/scripts/system-health.sh"
    "$JARVIS_INFRA/scripts/health-check-guard.sh"
)

missing_scripts=0
for script in "${SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        is_executable=false
        if [[ -x "$script" ]]; then
            is_executable=true
        fi

        script_name=$(basename "$script")
        if [[ "$is_executable" == "true" ]]; then
            log_check "script.$script_name" "ok" "존재 (실행 가능)"
        else
            log_check "script.$script_name" "warn" "존재 (실행 불가 - 권한 확인 필요)"
            missing_scripts=$((missing_scripts + 1))
        fi
    else
        script_name=$(basename "$script")
        log_check "script.$script_name" "fail" "미존재"
        missing_scripts=$((missing_scripts + 1))
    fi
done

echo ""

# ============================================================================
# 5. 개발 큐 설정 확인
# ============================================================================

log_check "tasks.config" "ok" "확인 중..."

if [[ -f "$TASKS_CONFIG" ]]; then
    # tasks.json에 모니터링 관련 태스크 확인
    has_system_health=$(grep -q '"id".*"system-health"' "$TASKS_CONFIG" && echo "true" || echo "false")
    has_disk_alert=$(grep -q '"id".*"disk-alert"' "$TASKS_CONFIG" && echo "true" || echo "false")

    if [[ "$has_system_health" == "true" ]] || [[ "$has_disk_alert" == "true" ]]; then
        log_check "tasks.config" "ok" "발견됨"
    else
        log_check "tasks.config" "warn" "모니터링 관련 태스크 미등록"
    fi
else
    log_check "tasks.config" "fail" "tasks.json 미존재 ($TASKS_CONFIG)"
fi

echo ""

# ============================================================================
# 6. 프로세스 상태 확인
# ============================================================================

# 2026-09-10 오픈클로 이식: orchestrator 는 runtime/discord/lib/orchestrator.mjs 로 도는
# 디스코드 계열 데몬이었고 그 디렉토리를 제거했다. 정지 플래그가 있으면 없는 게 정상이다.
if [[ -f "${HOME}/.openclaw-data/runtime/state/stopped/orchestrator" ]]; then
    log_check "process.orchestrator" "ok" "의도적 정지 (state/stopped/orchestrator — 디스코드 제거로 실행 파일 소멸)"
    orchestrator_pid=""
else
log_check "process.orchestrator" "ok" "확인 중..."

orchestrator_pid=$(launchctl list 2>/dev/null | grep "ai.jarvis.orchestrator" | awk '{print $1}' || echo "")
if [[ -n "$orchestrator_pid" && "$orchestrator_pid" != "-" ]]; then
    ps_check=$(ps -p "$orchestrator_pid" 2>/dev/null || echo "")
    if [[ -n "$ps_check" ]]; then
        log_check "process.orchestrator" "ok" "실행 중 (PID: $orchestrator_pid)"
    else
        log_check "process.orchestrator" "fail" "미실행 (PID: $orchestrator_pid 없음)"
    fi
else
    log_check "process.orchestrator" "warn" "활성 PID 미확인"
fi
fi

# 2026-09-10 오픈클로 이식: ai.jarvis.watchdog 은 디스코드 봇 전용 감시자였고 봇과 함께 정지했다.
# 정지 플래그가 있으면 "없는 게 정상"이므로 경고를 내지 않는다. 플래그가 없는데 없으면 그건 진짜 이상이다.
if [[ -f "${HOME}/.openclaw-data/runtime/state/stopped/watchdog" ]]; then
    log_check "process.watchdog" "ok" "의도적 정지 (state/stopped/watchdog — 디스코드 봇 제거로 감시 대상 소멸)"
else
    log_check "process.watchdog" "ok" "확인 중..."
    watchdog_pid=$(launchctl list 2>/dev/null | grep "ai.jarvis.watchdog" | awk '{print $1}' || echo "")
    if [[ -n "$watchdog_pid" && "$watchdog_pid" != "-" ]]; then
        ps_check=$(ps -p "$watchdog_pid" 2>/dev/null || echo "")
        if [[ -n "$ps_check" ]]; then
            log_check "process.watchdog" "ok" "실행 중 (PID: $watchdog_pid)"
        else
            log_check "process.watchdog" "fail" "미실행 (PID: $watchdog_pid 없음)"
        fi
    else
        log_check "process.watchdog" "warn" "활성 PID 미확인"
    fi
fi

echo ""

# ============================================================================
# 7. 최종 요약
# ============================================================================

# 임시 파일에서 결과 집계 (bash 3.2 호환성)
fail_count=0
warn_count=0
ok_count=0

if [[ -f /tmp/monitoring-precheck-results.log ]]; then
    while IFS=: read -r name status detail; do
        [[ "$status" == "fail" ]] && fail_count=$((fail_count + 1))
        [[ "$status" == "warn" ]] && warn_count=$((warn_count + 1))
        [[ "$status" == "ok" ]] && ok_count=$((ok_count + 1))
    done < /tmp/monitoring-precheck-results.log
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$JSON_MODE" == "false" ]]; then
    echo "📊 점검 결과"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  ✅ 정상: %d개\n" "$ok_count"
    printf "  ⚠️  경고: %d개\n" "$warn_count"
    printf "  ❌ 실패: %d개\n" "$fail_count"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$VERBOSE" == "true" ]]; then
        echo "📝 상세 정보:"
        echo ""
        echo "  홈 디렉토리: $JARVIS_HOME"
        echo "  인프라 경로: $JARVIS_INFRA"
        echo "  작업 설정: $TASKS_CONFIG"
        echo ""
    fi
fi

# 임시 파일 정리
rm -f /tmp/monitoring-precheck-results.log

# 종료 코드 결정
if [[ $fail_count -gt 0 ]]; then
    exit 2  # 실패
elif [[ $warn_count -gt 0 ]]; then
    exit 1  # 경고
else
    exit 0  # 성공
fi
