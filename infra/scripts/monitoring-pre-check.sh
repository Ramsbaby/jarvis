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
# tasks.json 위치: ~/jarvis/runtime/config/tasks.json 또는 ~/.jarvis 근처
if [[ -f "${HOME}/jarvis/runtime/config/tasks.json" ]]; then
    TASKS_CONFIG="${HOME}/jarvis/runtime/config/tasks.json"
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

# Crontab 내 모니터링 관련 태스크 확인
if [[ "$crontab_exists" == "true" ]]; then
    disk_alert_cron=$(crontab -l 2>/dev/null | grep -i "disk-alert" || true)
    health_check_cron=$(crontab -l 2>/dev/null | grep -i "system-health\|health-check" || true)

    if [[ -n "$disk_alert_cron" ]]; then
        log_check "crontab.disk-alert" "ok" "등록됨: $disk_alert_cron"
    else
        log_check "crontab.disk-alert" "warn" "미등록"
    fi

    if [[ -n "$health_check_cron" ]]; then
        log_check "crontab.health-check" "ok" "등록됨 (1개 이상)"
    else
        log_check "crontab.health-check" "warn" "미등록"
    fi
fi

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
declare -a CRITICAL_AGENTS=(
    "ai.jarvis.orchestrator"
    "ai.jarvis.watchdog"
    "ai.jarvis.system-health"
    "ai.jarvis.disk-alert"
)

for agent in "${CRITICAL_AGENTS[@]}"; do
    agent_info=$(launchctl list 2>/dev/null | grep "^-.*$agent" || echo "")

    if [[ -z "$agent_info" ]]; then
        # 등록되지 않음
        log_check "launchd.$agent" "fail" "미등록"
    else
        # 등록됨 - PID 확인으로 활성 여부 판단
        pid=$(echo "$agent_info" | awk '{print $1}')
        exit_code=$(echo "$agent_info" | awk '{print $2}')

        if [[ "$pid" == "-" ]]; then
            # 비활성 상태
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
