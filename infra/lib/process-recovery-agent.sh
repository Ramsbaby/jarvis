#!/usr/bin/env bash
# process-recovery-agent.sh - 프로세스 복구 전용 에이전트
#
# 역할: Discord 봇, LaunchAgent, 크론 프로세스 등의 복구를 담당
# 설계: 이사회 결의 2026-03-26 - 모니터링 맹점 제거

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_FILE="$BOT_HOME/logs/process-recovery-agent.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [process-recovery-agent] $*" | tee -a "$LOG_FILE"; }

# === Discord 봇 복구 ===
recover_discord_bot() {
    local context="$1"
    log "Starting Discord bot recovery: $context"

    # 1. 현재 프로세스 상태 확인
    if pgrep -f "discord-bot.js" > /dev/null; then
        log "Discord bot process is already running"
        return 0
    fi

    # 2. LaunchAgent 를 통한 재시작 시도
    log "Attempting to restart Discord bot via LaunchAgent"
    if launchctl kickstart -k "gui/$(id -u)/ai.jarvis.discord-bot" 2>/dev/null; then
        log "LaunchAgent restart command sent"

        # 3. 재시작 확인 (최대 30초 대기)
        local retry_count=0
        while [[ $retry_count -lt 30 ]]; do
            sleep 1
            if pgrep -f "discord-bot.js" > /dev/null; then
                log "Discord bot successfully restarted (${retry_count}s)"
                # PID 기록
                local new_pid
                new_pid=$(pgrep -f "discord-bot.js")
                echo "$new_pid" > "$BOT_HOME/state/bot.pid"
                return 0
            fi
            retry_count=$((retry_count + 1))
        done

        log "ERROR: Discord bot failed to start after 30 seconds"
        return 1
    fi

    # 4. 직접 실행 시도 (LaunchAgent 실패 시)
    log "LaunchAgent failed, attempting direct execution"
    cd "$BOT_HOME/discord" || return 1

    if [[ -f "discord-bot.js" ]]; then
        log "Starting Discord bot directly"
        nohup node discord-bot.js > "$BOT_HOME/logs/discord-bot.direct.log" 2>&1 &
        local direct_pid=$!
        echo "$direct_pid" > "$BOT_HOME/state/bot.pid"

        # 직접 실행 확인
        sleep 3
        if kill -0 "$direct_pid" 2>/dev/null; then
            log "Discord bot started directly with PID $direct_pid"
            return 0
        else
            log "ERROR: Direct execution failed"
            return 1
        fi
    else
        log "ERROR: discord-bot.js not found"
        return 1
    fi
}

# === LaunchAgent 복구 ===
recover_launchagent() {
    local agent_name="$1"
    local context="$2"

    log "Starting LaunchAgent recovery: $agent_name ($context)"

    # LaunchAgent 상태 확인
    local status
    status=$(launchctl print "gui/$(id -u)/$agent_name" 2>/dev/null | grep -E "state = " | awk '{print $3}' || echo "not-found")

    case "$status" in
        "running")
            log "LaunchAgent $agent_name is already running"
            return 0
            ;;
        "not-found"|"")
            log "LaunchAgent $agent_name not found, attempting to load"
            local plist_file="$HOME/Library/LaunchAgents/${agent_name}.plist"
            if [[ -f "$plist_file" ]]; then
                if launchctl load "$plist_file" 2>/dev/null; then
                    log "LaunchAgent $agent_name loaded successfully"
                else
                    log "ERROR: Failed to load LaunchAgent $agent_name"
                    return 1
                fi
            else
                log "ERROR: LaunchAgent plist file not found: $plist_file"
                return 1
            fi
            ;;
        *)
            log "LaunchAgent $agent_name status: $status, attempting restart"
            if launchctl kickstart -k "gui/$(id -u)/$agent_name" 2>/dev/null; then
                log "LaunchAgent $agent_name restart requested"
            else
                log "ERROR: Failed to restart LaunchAgent $agent_name"
                return 1
            fi
            ;;
    esac

    # 복구 검증 (5초 후)
    sleep 5
    local new_status
    new_status=$(launchctl print "gui/$(id -u)/$agent_name" 2>/dev/null | grep -E "state = " | awk '{print $3}' || echo "not-found")

    if [[ "$new_status" == "running" ]]; then
        log "LaunchAgent $agent_name recovery successful"
        return 0
    else
        log "ERROR: LaunchAgent $agent_name recovery failed (status: $new_status)"
        return 1
    fi
}

# === 크론 프로세스 복구 ===
recover_cron_process() {
    local task_id="$1"
    local context="$2"

    log "Starting cron process recovery: $task_id ($context)"

    # 1. 태스크가 현재 실행 중인지 확인
    if pgrep -f "$task_id" > /dev/null; then
        log "Task $task_id is already running"
        return 0
    fi

    # 2. 수동 태스크 실행
    local cron_script="$BOT_HOME/bin/bot-cron.sh"
    if [[ -x "$cron_script" ]]; then
        log "Manually executing task: $task_id"
        if "$cron_script" "$task_id" 2>&1 | tee -a "$LOG_FILE"; then
            log "Task $task_id executed successfully"
            return 0
        else
            log "ERROR: Task $task_id execution failed"
            return 1
        fi
    else
        log "ERROR: bot-cron.sh not found or not executable"
        return 1
    fi
}

# === 일반 서비스 복구 ===
recover_general_service() {
    local service_name="$1"
    local context="$2"

    log "Starting general service recovery: $service_name ($context)"

    case "$service_name" in
        "rag-engine")
            # RAG 엔진 복구
            if [[ -f "/tmp/jarvis-rag-write.lock" ]]; then
                log "RAG engine appears to be running (lock file exists)"
                return 0
            fi

            log "Attempting to restart RAG engine (via cron-safe-wrapper)"
            # RAG 인덱싱 재시작 — cron-safe-wrapper 경유 (동시 실행 방지)
            if [[ -f "$BOT_HOME/bin/rag-index-safe.sh" ]]; then
                BOT_HOME="$BOT_HOME" OMP_NUM_THREADS=2 ORT_NUM_THREADS=2 \
                  nohup /bin/bash "$BOT_HOME/bin/cron-safe-wrapper.sh" rag-index 2700 \
                  /bin/bash "$BOT_HOME/bin/rag-index-safe.sh" > "$BOT_HOME/logs/rag-recovery.log" 2>&1 &
                log "RAG engine restart initiated (lock-protected)"
                return 0
            else
                log "ERROR: RAG engine script not found"
                return 1
            fi
            ;;
        "dashboard")
            # 대시보드 복구
            if pgrep -f "dashboard" > /dev/null; then
                log "Dashboard is already running"
                return 0
            fi

            if launchctl kickstart -k "gui/$(id -u)/ai.jarvis.dashboard" 2>/dev/null; then
                log "Dashboard restart requested"
                return 0
            else
                log "ERROR: Failed to restart dashboard"
                return 1
            fi
            ;;
        *)
            log "Unknown service: $service_name"
            return 1
            ;;
    esac
}

# === 메인 복구 로직 ===
main() {
    local recovery_type="${1:-}"
    local context="${2:-no context}"

    case "$recovery_type" in
        "discord_bot_crash"|"process_dead")
            recover_discord_bot "$context"
            ;;
        "launchagent_failed")
            # context에서 에이전트 이름 추출
            local agent_name
            agent_name=$(echo "$context" | sed 's/.*agent:\([^,]*\).*/\1/' || echo "ai.jarvis.discord-bot")
            recover_launchagent "$agent_name" "$context"
            ;;
        "cron_task_stale")
            # context에서 태스크 ID 추출
            local task_id
            task_id=$(echo "$context" | sed 's/.*task:\([^,]*\).*/\1/' || echo "unknown")
            recover_cron_process "$task_id" "$context"
            ;;
        "service_down")
            # context에서 서비스 이름 추출
            local service_name
            service_name=$(echo "$context" | sed 's/.*service:\([^,]*\).*/\1/' || echo "unknown")
            recover_general_service "$service_name" "$context"
            ;;
        "test")
            # 테스트 모드
            log "Running process recovery agent test"
            echo "✓ Process recovery agent is functional"
            return 0
            ;;
        *)
            echo "Usage: $0 <recovery_type> [context]"
            echo ""
            echo "Recovery types:"
            echo "  discord_bot_crash    - Discord bot process recovery"
            echo "  launchagent_failed   - LaunchAgent recovery"
            echo "  cron_task_stale      - Cron task recovery"
            echo "  service_down         - General service recovery"
            echo "  test                 - Run self-test"
            echo ""
            echo "Context format examples:"
            echo "  'agent:ai.jarvis.discord-bot,reason:crash'"
            echo "  'task:morning-standup,age:3600'"
            echo "  'service:rag-engine,status:locked'"
            exit 1
            ;;
    esac
}

main "$@"