#!/usr/bin/env bash
# runaway-process-guard.sh — 개별 프로세스 CPU 폭주 감지 + 자동 재시작
#
# Why: 2026-07-27 avconferenced(맥 화상/화면공유 데몬)가 17일 21시간 동안 CPU 38% 를
#   상시 점유했으나 어떤 감시도 잡지 못했다. system-doctor 는 CPU '총량'만 보고,
#   watchdog 은 자비스 서비스만 본다 → 개별 시스템 프로세스 폭주는 사각지대였다.
#   주인님이 "맥미니가 뻗은 것 같다"고 체감하실 때까지 아무 경보가 없었다.
#
# 판정: CPU 임계 초과 + '정당한 사용 중이 아님' 이 연속 N회 관측될 때만 폭주로 본다.
#   avconferenced 는 화면공유 중이면 정상적으로 CPU 를 쓰므로, 세션이 없는데도
#   CPU 를 태우는 경우만 잡는다(오탐 방지 — 접속 중 재시작하면 세션이 끊긴다).
#
# 조치: kill(TERM) 만 한다. launchd 가 즉시 재기동하므로 가역적이다.
set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
STATE_FILE="$BOT_HOME/state/runaway-guard.json"
LOG="$BOT_HOME/logs/runaway-process-guard.log"
CPU_THRESHOLD="${RUNAWAY_CPU_THRESHOLD:-30}"   # %
STRIKES_NEEDED="${RUNAWAY_STRIKES:-2}"          # 연속 관측 횟수 (30분 주기 × 2 = 1시간 지속)
DRYRUN="${RUNAWAY_DRYRUN:-0}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"
log() { echo "[$(TZ=Asia/Seoul date '+%F %T')] $*" >> "$LOG"; }

# 감시 대상: "프로세스명|정당사용판정함수"
WATCH_NAMES=(avconferenced)

# avconferenced 는 화면공유 세션이 살아 있으면 CPU 를 쓰는 게 정상이다.
_legitimately_busy_avconferenced() {
    pgrep -f "ScreensharingAgent" >/dev/null 2>&1
}
_legitimately_busy() {
    case "$1" in
        avconferenced) _legitimately_busy_avconferenced ;;
        *) return 1 ;;
    esac
}

_cpu_of() {
    # ps 의 %CPU 는 생애 평균에 가까우므로 top 으로 현재값을 읽는다.
    # [2026-08-20 수정] top -l 1 은 macOS 에서 항상 0.0 을 반환한다 — 첫 샘플에는
    #   CPU 델타를 계산할 이전 스냅샷이 없기 때문. 이 버그로 2026-07-27 생성 이후
    #   이 가드는 한 번도 폭주를 잡지 못했다(로그 전체가 cpu=0.0%). -l 2 로 두 번
    #   샘플링해 두 번째(실측) 값을 읽는다.
    top -l 2 -pid "$1" -stats cpu 2>/dev/null | tail -1 | tr -d ' %' | grep -E '^[0-9.]+$' || echo 0
}

_read_strikes() {
    [[ -f "$STATE_FILE" ]] || { echo 0; return; }
    python3 -c "
import json,sys
try: print(json.load(open('$STATE_FILE')).get('$1',0))
except Exception: print(0)
" 2>/dev/null || echo 0
}

_write_strikes() {
    python3 -c "
import json,os
p='$STATE_FILE'
try: d=json.load(open(p))
except Exception: d={}
d['$1']=$2
json.dump(d, open(p,'w'), ensure_ascii=False, indent=2)
" 2>/dev/null || true
}

_notify() {
    local msg="$1"
    if [[ -f "$HOME/jarvis/infra/lib/discord-route.sh" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/jarvis/infra/lib/discord-route.sh" 2>/dev/null || true
        discord_route_raw jarvis-system "$msg" 2>/dev/null || true
    fi
}

restarted=0
for name in "${WATCH_NAMES[@]}"; do
    pid="$(pgrep -x "$name" | head -1 || true)"
    if [[ -z "$pid" ]]; then
        _write_strikes "$name" 0
        continue
    fi

    cpu="$(_cpu_of "$pid")"
    cpu_int="${cpu%%.*}"; cpu_int="${cpu_int:-0}"

    if (( cpu_int < CPU_THRESHOLD )); then
        _write_strikes "$name" 0
        log "OK ${name} pid=${pid} cpu=${cpu}% (임계 ${CPU_THRESHOLD}% 미만)"
        continue
    fi

    if _legitimately_busy "$name"; then
        _write_strikes "$name" 0
        log "SKIP ${name} cpu=${cpu}% — 정당 사용 중(화면공유 세션 활성)"
        continue
    fi

    strikes=$(( $(_read_strikes "$name") + 1 ))
    _write_strikes "$name" "$strikes"
    log "STRIKE ${name} pid=${pid} cpu=${cpu}% strikes=${strikes}/${STRIKES_NEEDED}"

    if (( strikes >= STRIKES_NEEDED )); then
        if [[ "$DRYRUN" == "1" ]]; then
            log "DRYRUN — 재시작 생략 (${name} cpu=${cpu}%)"
        else
            kill "$pid" 2>/dev/null && log "RESTART ${name} pid=${pid} cpu=${cpu}% → TERM 전송 (launchd 자동 재기동)" \
                || log "ERROR ${name} pid=${pid} 종료 실패"
            _write_strikes "$name" 0
            restarted=$((restarted + 1))
            _notify "🔧 **폭주 프로세스 자동 재시작** — \`${name}\` 이 화면공유 세션 없이 CPU ${cpu}% 를 ${STRIKES_NEEDED}회 연속 점유하여 재시작했습니다. (launchd 가 즉시 되살립니다)"
        fi
    fi
done

log "완료 — 재시작 ${restarted}건"
exit 0
