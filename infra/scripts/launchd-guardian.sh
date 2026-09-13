#!/usr/bin/env bash

# [오픈클로 이식 2026-09-10] jarvis-launchd-guardian(*/3) 으로 이관. OPENCLAW_JOB=1 로 통과한다.
# crontab 6행이 남아 있으나 crontab 쓰기가 막혀(rc=124) 스크립트 층에서 이중 실행을 막는다.
# 재개: rm ~/.openclaw-data/runtime/state/stopped/launchd-guardian
if [[ -f "${HOME}/.openclaw-data/runtime/state/stopped/launchd-guardian" ]] && [[ "${OPENCLAW_JOB:-}" != "1" ]]; then
    echo "[launchd-guardian] 중지 플래그 있음 — 오픈클로로 이관됨"
    exit 0
fi

set -euo pipefail

# launchd-guardian.sh - Cron-based LaunchAgent watchdog (SPOF safety net)
# Runs every 3 minutes via cron. Detects unloaded launchd services and re-registers them.
# Ensures critical LaunchAgents remain registered after system sleep or restart.

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
# Cross-platform compat
source "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh" 2>/dev/null || true

# launchd-guardian is macOS-only; exit gracefully on other platforms
if ! $IS_MACOS; then
    echo "[compat] launchd-guardian skipped on non-macOS"
    exit 0
fi
LOG_FILE="$BOT_HOME/logs/launchd-guardian.log"
ROUTE_RESULT="$BOT_HOME/bin/route-result.sh"
UID_NUM=$(id -u)

# KeepAlive services: must always have a running PID
KEEPALIVE_SERVICES=(
    # "ai.jarvis.discord-bot"  # [오픈클로 이식 2026-09-10] 디스코드 제거로 감시 대상 소멸. 복구 시 주석 해제.
    # "ai.jarvis.watchdog"     # [오픈클로 이식 2026-09-10] watchdog.sh는 디스코드 봇 전용 감시자다. 같이 정지.
    "ai.jarvis.cloudflared-tunnel"
    "ai.jarvis.board"
    # [회차8 2026-09-12] 실측으로 메운 사각지대 — 이 5종은 KeepAlive 인데 감시 목록에 없었다.
    #   launchd 가 직접 띄우는 상주 데몬이라 죽어도 오픈클로는 모른다.
    #   입사(9/14) 후 무인 운전에서 이게 가장 큰 노출이었다.
    "ai.jarvis.github-runner"
    "ai.jarvis.interview-verifier"
    "ai.jarvis.launchagents-watcher"
    "ai.jarvis.rag-watcher"
    "ai.openclaw.glances"
)

# StartInterval / StartCalendarInterval services: 주기 실행. 실행 사이 PID=- 는 정상이다.
# 2026-09-10 오픈클로 이식: symlink-audit·board-watchdog 는 오픈클로 잡으로 옮기고 plist 를 격리했다.
#   plist 파일이 없으면 check_loaded 가 즉시 return 하므로 되살리진 않지만, 목록을 실제와 맞춘다.
# [회차8 2026-09-12] Calendar 발화 2종 추가.
INTERVAL_SERVICES=(
    # [회차8 2026-09-12] com.jarvis.memory-sync 제거 — 오픈클로 잡 `jarvis-memory-sync` 로 이관했다.
    #   목록에 남겨두면 guardian 이 bootout 한 서비스를 매 15분마다 되살려 이중 실행이 된다.
    #   **이관은 '새 쪽을 켜는 것'과 '옛 쪽을 끄는 것'과 '되살리는 감시자를 끄는 것' 세 가지다.**
    # vault-auto-link 는 구조상 잔류 — 실측 실행시간 81분(06:30→07:51)으로
    #   오픈클로 command 페이로드 상한(900초)의 5배다. launchd 가 맞는 자리다.
    "com.jarvis.vault-auto-link"
)

# [회차8 2026-09-12] 발화조건 검사.
#   계기 — 2026-04~05 calendar-alert 가 StartInterval 을 잃고 넉 달간 미실행이었는데,
#   launchd 에 로드돼 있었기 때문에 모든 감사가 "정상"으로 셌다.
#   **등록돼 있다는 것과 발화한다는 것은 다르다.** 로드 검사만으로는 이 상태를 못 잡는다.
check_trigger() {
    local service="$1"
    local plist_file="${PLIST_DIR}/${service}.plist"
    [[ -f "$plist_file" ]] || return 0
    local keys
    keys=$(/usr/bin/python3 - "$plist_file" <<'PY' 2>/dev/null
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    sys.exit(0)
found = [k for k in ('KeepAlive', 'StartInterval', 'StartCalendarInterval', 'WatchPaths', 'QueueDirectories')
         if d.get(k)]
print(','.join(found))
PY
)
    if [[ -z "$keys" ]]; then
        log "ERROR: $service 에 발화조건이 없다 (KeepAlive·StartInterval·Calendar 전부 없음) — 로드돼 있어도 영원히 안 돈다"
        trigger_missing=$(( trigger_missing + 1 ))
    fi
}

PLIST_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [guardian] $*" >> "$LOG_FILE"; }

# Hourly heartbeat only (minute 00-02 to match */3 cron)
minute=$(date +%M)
is_heartbeat=false
if [[ "$minute" == "00" || "$minute" == "01" || "$minute" == "02" ]]; then
    is_heartbeat=true
fi

recovered=0
trigger_missing=0   # [회차8] 발화조건이 사라진 서비스 수 — 로드 검사로는 안 잡히는 상태

check_loaded() {
    local service="$1"
    local plist_file="${PLIST_DIR}/${service}.plist"
    if [[ ! -f "$plist_file" ]]; then return 0; fi
    local status_line
    # 3번째 필드(Label) 정확 일치. 부분매칭 버그 방지 (ai.jarvis.board vs ai.jarvis.board-watchdog).
    # 2026-04-17 사건 root cause: grep "ai.jarvis.board"가 board-watchdog 라인을 매칭해서
    # unload된 서비스를 "loaded"로 오판 → bootstrap 경로 미발동 → 1시간 장애.
    status_line=$(launchctl list 2>/dev/null | awk -v s="$service" '$3 == s' || true)
    if [[ -z "$status_line" ]]; then
        log "RECOVERY: $service not loaded, re-registering"
        if launchctl bootstrap "gui/${UID_NUM}" "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via bootstrap"
        elif launchctl load "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via load (fallback)"
        else
            log "ERROR: Failed to register $service"
            return 0
        fi
        recovered=$(( recovered + 1 ))
    fi
}

# KeepAlive: must always have a running PID — kickstart if PID=-
for service in "${KEEPALIVE_SERVICES[@]}"; do
    plist_file="${PLIST_DIR}/${service}.plist"
    if [[ ! -f "$plist_file" ]]; then continue; fi
    # 동일 부분매칭 버그 방지 — awk로 Label 정확 일치만 매칭.
    status_line=$(launchctl list 2>/dev/null | awk -v s="$service" '$3 == s' || true)
    if [[ -z "$status_line" ]]; then
        log "RECOVERY: $service not loaded, re-registering"
        if launchctl bootstrap "gui/${UID_NUM}" "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via bootstrap"
        elif launchctl load "$plist_file" 2>/dev/null; then
            log "RECOVERY: $service registered via load (fallback)"
        else
            log "ERROR: Failed to register $service"
            continue
        fi
        recovered=$(( recovered + 1 ))
    else
        pid=$(echo "$status_line" | awk '{print $1}')
        if [[ "$pid" == "-" ]]; then
            log "RECOVERY: $service not running (PID=-), kickstarting"

            # 연속 실패 카운터: 3회 이상이면 npm install 후 재시작
            FAIL_FILE="/tmp/jarvis-guardian-${service//[^a-zA-Z0-9]/-}-fails"
            fail_count=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
            fail_count=$(( fail_count + 1 ))
            echo "$fail_count" > "$FAIL_FILE"

            if [[ "$fail_count" -ge 3 && "$service" == "ai.jarvis.discord-bot" ]]; then
                # 2026-07-25: npm install 재시도 상한 도입.
                #   이전에는 실행 직후 무조건 카운터를 0으로 되돌려, 기동 실패 원인이
                #   그대로 남아 있으면 9분마다 무한 반복했다(당일 480회 관측).
                NPM_STAMP="/tmp/jarvis-guardian-npm-last"
                npm_last=$(cat "$NPM_STAMP" 2>/dev/null || echo 0)
                now_ts=$(date +%s)
                if (( now_ts - npm_last > 21600 )); then
                    log "RECOVERY: $service failed ${fail_count}x — running npm install to repair"
                    # launchd 환경은 PATH 미상속 → node/npm 절대경로 + PATH export 필수
                    # (bash SC2168: 'local' 키워드는 함수 외부에서 쓰면 set -e와 충돌 → 일반 변수로)
                    NODE_BIN="${NODE_BIN:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"
                    NPM_BIN="${NPM_BIN:-$(command -v npm 2>/dev/null || echo /opt/homebrew/bin/npm)}"
                    if [[ -x "$NODE_BIN" && -x "$NPM_BIN" ]]; then
                        # npm 내부에서 `env node` 호출 → PATH에 node 디렉토리 필요
                        export PATH="$(dirname "$NODE_BIN"):${PATH:-/usr/bin:/bin}"
                        "$NPM_BIN" install --prefix "$BOT_HOME/discord" --silent 2>>"$LOG_FILE" || true
                    else
                        log "ERROR: node($NODE_BIN) 또는 npm($NPM_BIN) 바이너리 없음 — npm install 불가"
                    fi
                    echo "$now_ts" > "$NPM_STAMP"
                    log "RECOVERY: npm install done, kickstarting"
                else
                    log "RECOVERY: $service failed ${fail_count}x — npm install 생략(최근 6시간 내 시도함), kickstart만 진행"
                fi
            fi

            # kickstart 시도
            launchctl kickstart -k "gui/${UID_NUM}/${service}" 2>/dev/null || true

            # 2026-07-25: 기동 성공을 실제로 확인한 뒤에만 실패 카운터를 초기화한다.
            #   이전에는 kickstart 전에 무조건 0으로 되돌려 '시도했으니 성공'으로 취급했고,
            #   그래서 같은 실패가 영원히 반복돼도 카운터가 3을 넘지 못했다.
            sleep 3
            if launchctl print "gui/${UID_NUM}/${service}" 2>/dev/null | grep -qE '^[[:space:]]*pid = [0-9]+'; then
                echo "0" > "$FAIL_FILE"
                log "RECOVERY: $service 기동 확인 — 실패 카운터 초기화"
            else
                log "RECOVERY: $service 아직 미기동 — 실패 카운터 유지(${fail_count})"
            fi

            # 3회 이상 kickstart 실패 시 강제 재등록 (bootout + bootstrap). 보조 방어막.
            # 2026-04-17 1시간 장애의 진짜 root cause는 위 `awk $3 == s` fix (status_line 오판 버그)였음.
            # 이 블록은 drop-down 케이스 — loaded 상태인데 PID=- stuck (launchd ThrottleInterval 의심)
            # 에 대비한 2차 장치. 탐지(awk)가 먼저 작동하면 check_loaded 경로로 bootstrap 되어 여기까진 도달 X.
            if [[ "$fail_count" -ge 3 && "$service" != "ai.jarvis.discord-bot" ]]; then
                log "RECOVERY: $service kickstart failed ${fail_count}x — escalating to bootout+bootstrap"
                launchctl bootout "gui/${UID_NUM}/${service}" 2>/dev/null || true
                sleep 1
                if launchctl bootstrap "gui/${UID_NUM}" "$plist_file" 2>/dev/null; then
                    log "RECOVERY: $service re-bootstrapped (stuck state cleared)"
                    echo "0" > "$FAIL_FILE"
                else
                    log "ERROR: $service bootstrap failed after bootout — manual intervention needed"
                fi
            fi

            recovered=$(( recovered + 1 ))
        else
            # 정상 실행 중이면 실패 카운터 초기화
            FAIL_FILE="/tmp/jarvis-guardian-${service//[^a-zA-Z0-9]/-}-fails"
            echo "0" > "$FAIL_FILE"
        fi
    fi
done

# StartInterval: check loaded + detect stalled execution
# If the service's log hasn't been updated in 3x its interval, kickstart it.
WATCHDOG_LOG="$BOT_HOME/logs/watchdog.log"
WATCHDOG_INTERVAL=180  # seconds (must match plist StartInterval)
STALL_MULTIPLIER=10   # 180*10=1800s(30분) — 실제 관측 최대 주기 ~1080s(18분) 기준 넉넉한 버퍼

for service in "${INTERVAL_SERVICES[@]+"${INTERVAL_SERVICES[@]}"}"; do
    check_loaded "$service"

    # Stall detection: if log file hasn't been written in INTERVAL * STALL_MULTIPLIER, kickstart
    if [[ "$service" == "ai.jarvis.watchdog" && -f "$WATCHDOG_LOG" ]]; then
        log_mtime=$(stat -c '%Y' "$WATCHDOG_LOG" 2>/dev/null || stat -f %m "$WATCHDOG_LOG" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        log_age=$(( now_epoch - log_mtime ))
        stall_threshold=$(( WATCHDOG_INTERVAL * STALL_MULTIPLIER ))
        if [[ "$log_age" -gt "$stall_threshold" ]]; then
            log "RECOVERY: $service stalled (log age=${log_age}s > ${stall_threshold}s), kickstarting"
            launchctl kickstart -k "gui/${UID_NUM}/${service}" 2>/dev/null || true
            recovered=$(( recovered + 1 ))
        fi
    fi
done

# [회차8 2026-09-12] 발화조건 검사 — 감시 대상 전체를 본다.
#   등록 여부와 발화 여부는 다르다. 이 루프가 없으면 "로드됐지만 영원히 안 도는" 상태가 정상으로 셈해진다.
for service in "${KEEPALIVE_SERVICES[@]}" "${INTERVAL_SERVICES[@]}"; do
    check_trigger "$service"
done

# Send alert on recovery
if (( recovered > 0 )); then
    if [[ -x "$ROUTE_RESULT" ]]; then
        "$ROUTE_RESULT" discord "guardian" "[Bot Guardian] Recovered ${recovered} service(s)" 2>/dev/null || true
    fi
fi

# Heartbeat log (hourly only)
if [[ "$is_heartbeat" == "true" ]]; then
    total=$(( ${#KEEPALIVE_SERVICES[@]} + ${#INTERVAL_SERVICES[@]} ))
    log "Heartbeat: checked ${total} services, recovered=$recovered, trigger_missing=$trigger_missing"
fi

# [회차8] 발화조건 소실은 **실패로 끝낸다** — 오픈클로 failureAlert 가 받아야 사람이 안다.
#   조용히 로그만 남기면 2026-04 calendar-alert 처럼 넉 달을 모른 채 지난다.
if (( trigger_missing > 0 )); then
    echo "[guardian] 발화조건 없는 서비스 ${trigger_missing}건 — launchd 에 로드돼 있어도 실행되지 않는다" >&2
    exit 1
fi
exit 0