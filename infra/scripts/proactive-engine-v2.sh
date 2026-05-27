#!/usr/bin/env bash
# proactive-engine-v2.sh — 자비스 선제 발화 데몬 v2 (영화 JARVIS 5패턴)
#
# 2026-05-14 — 1주 풀스택 Day 1 골격
# 스펙: ~/jarvis/runtime/specs/proactive-jarvis-v2-2026-05-14.md
# 결정: ~/jarvis/runtime/ledger/deep-interview-2026-05-14.jsonl
#
# v2 full (2026-05-15): 5패턴 전체 구현 완료
#   ① 맥락 추적: 삼성물산 팔로업 · AWS SAA D-day
#   ② 이벤트 감지: 크론 실패 · OAuth 만료 선제 경고
#   ④ 위험 경고: TQQQ 손절선 돌파
#   ⑤ 위트: 아침 인사 (09~11h)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG="${BOT_HOME}/logs/proactive-engine-v2.log"
STATE_DIR="${BOT_HOME}/state"
FREQ_LEDGER="${STATE_DIR}/proactive-frequency.jsonl"
EVENT_QUEUE="${STATE_DIR}/proactive-event-queue.jsonl"
POLL_INTERVAL=300  # 5분

mkdir -p "$(dirname "$LOG")" "$STATE_DIR"
COOLDOWN_DIR="${STATE_DIR}/proactive-cd"
mkdir -p "$COOLDOWN_DIR"

# 라이브러리 — discord 발화 (어제 추가한 discord_notify 래퍼 활용)
# shellcheck disable=SC1091
source "${BOT_HOME}/lib/discord-notify-bash.sh"

# 2026-05-14: tee 제거 — launchd 환경 stdout EPIPE 시 pipefail trigger 가능성 차단
# launchd가 stdout을 StandardOutPath로 리다이렉트하므로 직접 append만으로 충분
log() { printf '[%s] [proactive-v2] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ─── 싱글 인스턴스 가드 (2026-05-14 /verify 결함 1) ────────────────
# launchd KeepAlive race로 데몬 N개 가동 방지 — mkdir 원자성 (어제 retry-wrapper 패턴 재사용)
PID_LOCK_DIR="/tmp/jarvis-proactive-v2.lock.d"
if ! mkdir "$PID_LOCK_DIR" 2>/dev/null; then
    # 기존 lock 보유자가 살아있는지 확인
    if [[ -f "$PID_LOCK_DIR/pid" ]]; then
        _existing_pid=$(cat "$PID_LOCK_DIR/pid" 2>/dev/null || echo "")
        if [[ -n "$_existing_pid" ]] && kill -0 "$_existing_pid" 2>/dev/null; then
            log "🔒 다른 인스턴스 가동 중 (PID $_existing_pid) — 종료"
            exit 0
        fi
        # stale lock — 제거 후 재시도
        log "⚠️ stale lock 감지 (PID $_existing_pid 사망) — 정리 후 재진입"
        rm -rf "$PID_LOCK_DIR"
        mkdir "$PID_LOCK_DIR" || { log "🔴 lock dir 생성 실패 — exit"; exit 1; }
    else
        log "🔴 lock 디렉토리 존재하나 pid 파일 부재 — exit"
        exit 1
    fi
fi
echo $$ > "$PID_LOCK_DIR/pid"
trap 'rm -rf "$PID_LOCK_DIR"' EXIT TERM INT

# ─── CPU 가드 (2026-05-11 오답노트 영구 등재 + 2026-05-14 /verify 결함 3 강화) ──
# 데몬 자신 CPU 폭주 시 자동 종료 → launchd가 재시작 → ThrottleInterval로 폭주 방지
# /verify 결함 3: ps 빈 결과 시 안전 가정 불가 → 3회 연속 빈 결과 시 종료
_CPU_EMPTY_STREAK=0
_cpu_guard() {
    local own_cpu
    own_cpu=$(ps -o %cpu= -p $$ 2>/dev/null | tr -d ' ' | awk -F. '{print $1}')
    if [[ -z "$own_cpu" ]]; then
        _CPU_EMPTY_STREAK=$((_CPU_EMPTY_STREAK + 1))
        log "⚠️ CPU 측정 실패 (streak=$_CPU_EMPTY_STREAK)"
        if (( _CPU_EMPTY_STREAK >= 3 )); then
            log "🔴 CPU 측정 3회 연속 실패 — exit (launchd restart로 환경 리셋)"
            exit 1
        fi
        return 0
    fi
    _CPU_EMPTY_STREAK=0
    if (( own_cpu > 50 )); then
        log "🔴 CPU guard: self ${own_cpu}% > 50% — exit (launchd restart)"
        exit 1
    fi
}

# ─── 시간대 정책 (스펙 §5) ─────────────────────────────────────
# 반환: silent | critical_only | normal
get_time_mode() {
    local h
    h=$(date '+%-H')
    if (( h >= 0 && h < 6 )); then
        echo "silent"           # 00~06 수면 (주인님 기상 06:00)
    elif (( h >= 6 && h < 7 )); then
        echo "critical_only"    # 06~07 기상 직후
    elif (( h >= 7 && h < 22 )); then
        echo "normal"           # 07~22 정상
    else
        echo "critical_only"    # 22~24 휴식
    fi
}

# ─── critical 예외 (스펙 §3 — 항상 통과 5개) ───────────────────
is_critical() {
    case "$1" in
        token_bot_failure|family_message|calendar_5min|card_anomaly|interview_notice)
            return 0 ;;
        *) return 1 ;;
    esac
}

# ─── 빈도 가드 (방법 1 — 스펙 §3.1) ────────────────────────────
# 1시간 내 3회+ 발화 누적 시 후퇴 (critical 제외는 emit 함수에서)
check_frequency_guard() {
    local cutoff
    cutoff=$(($(date +%s) - 3600))
    local recent=0
    if [[ -f "$FREQ_LEDGER" ]]; then
        recent=$(awk -v cut="$cutoff" '$1 > cut {c++} END {print c+0}' "$FREQ_LEDGER")
    fi
    (( recent < 3 ))
}

# ─── FREQ_LEDGER 회전 (2026-05-14 /verify 결함 2) ──────────────────
# 24h 이전 entries 자동 정리 — 1년+ 누적 시 awk scan 비용 폭증 방지
# 매 사이클마다 호출 (비용 저렴 — 파일 크기 보통 KB 수준)
rotate_freq_ledger() {
    if [[ ! -f "$FREQ_LEDGER" ]]; then
        return 0
    fi
    local cutoff
    cutoff=$(($(date +%s) - 86400))  # 24h
    local tmp="${FREQ_LEDGER}.rotate.$$"
    awk -v cut="$cutoff" '$1 > cut' "$FREQ_LEDGER" > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]] || [[ ! -s "$FREQ_LEDGER" ]]; then
        mv "$tmp" "$FREQ_LEDGER"
    else
        rm -f "$tmp"
    fi
}

# ─── 쿨다운 헬퍼 ─────────────────────────────────────────────
# _cd_check key secs → 0=아직 쿨다운 중(발화 건너뜀) / 1=만료(발화 가능)
_cd_check() {
    local key="$1" secs="$2"
    local f="${COOLDOWN_DIR}/${key}.ts"
    [[ -f "$f" ]] || return 1
    local last elapsed
    last=$(cat "$f" 2>/dev/null || echo 0)
    elapsed=$(( $(date +%s) - last ))
    if (( elapsed < secs )); then return 0; else return 1; fi
}
_cd_set() { date +%s > "${COOLDOWN_DIR}/${1}.ts"; }

# ─── 발화 함수 (공통 게이트) ───────────────────────────────────
# arg1: 카테고리 (critical 예외 판정용)
# arg2: webhook 키 (jarvis-system 등)
# arg3: 메시지
emit() {
    local category="$1" webhook_key="$2" msg="$3"
    local mode
    mode=$(get_time_mode)

    # 게이트 1 — 시간대 정책 (critical 5개는 silent 시간에도 항상 통과 — 스펙 §3)
    # 2026-05-14 /verify BLOCKER 수정: silent 분기에 is_critical 예외 추가
    # 어제 토큰 사고가 새벽에 발생했으면 차단됐을 회로 → 패치
    if [[ "$mode" == "silent" ]] && ! is_critical "$category"; then
        log "🔇 [silent] $category 차단 (수면 시간)"
        return 0
    fi
    if [[ "$mode" == "critical_only" ]] && ! is_critical "$category"; then
        log "🔇 [critical_only] $category 차단 (출근/휴식 시간)"
        return 0
    fi

    # 게이트 2 — 빈도 가드 (critical 우회)
    if ! is_critical "$category" && ! check_frequency_guard; then
        log "🔇 [freq] $category 차단 (1시간 3회+ 누적)"
        return 0
    fi

    # 발화
    if discord_notify "$webhook_key" "$msg"; then
        log "📢 [$category → $webhook_key] $(echo "$msg" | head -c 80)"
        echo "$(date +%s) $category $webhook_key" >> "$FREQ_LEDGER"
    else
        log "❌ discord_notify 실패 — $category"
        return 1
    fi
}

# ─── 이벤트 큐 처리 (Day 2~5에 추가될 hook 출력 수신) ─────────
process_event_queue() {
    if [[ ! -f "$EVENT_QUEUE" ]]; then
        return 0
    fi
    if [[ ! -s "$EVENT_QUEUE" ]]; then
        return 0
    fi

    local tmp="${EVENT_QUEUE}.processing.$$"
    mv "$EVENT_QUEUE" "$tmp" 2>/dev/null || return 0
    touch "$EVENT_QUEUE"

    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi
        local category webhook msg
        category=$(echo "$line" | jq -r '.category // "unknown"' 2>/dev/null)
        webhook=$(echo "$line" | jq -r '.webhook // "jarvis-system"' 2>/dev/null)
        msg=$(echo "$line" | jq -r '.message // ""' 2>/dev/null)
        if [[ -z "$msg" ]]; then
            continue
        fi
        emit "$category" "$webhook" "$msg"
    done < "$tmp"
    rm -f "$tmp"
}

# ─── 패턴 1: AWS SAA-C03 D-day 카운트다운 ─────────────────────
# 시험 정보 SSoT: proactive-engine.json > exams.aws_saa
# active: false 시 발동 안 함 — 중단/재개는 JSON 파일만 수정
check_aws_countdown() {
    _cd_check "aws_countdown" 86400 && return 0
    local engine_file exam_active exam_date exam_ts diff_days
    engine_file="${STATE_DIR}/proactive-engine.json"

    # SSoT에서 시험 정보 읽기
    exam_active=$(jq -r '.exams.aws_saa.active // false' "$engine_file" 2>/dev/null || echo "false")
    if [[ "$exam_active" != "true" ]]; then return 0; fi

    exam_date=$(jq -r '.exams.aws_saa.date // ""' "$engine_file" 2>/dev/null || echo "")
    if [[ -z "$exam_date" ]]; then return 0; fi

    exam_ts=$(date -j -f '%Y-%m-%d' "$exam_date" +%s 2>/dev/null || echo "")
    if [[ -z "$exam_ts" ]]; then return 0; fi
    diff_days=$(( (exam_ts - $(date +%s)) / 86400 ))
    if (( diff_days > 10 || diff_days <= 0 )); then return 0; fi

    local urgency="📅"
    if (( diff_days <= 2 )); then urgency="🚨"; fi

    emit "aws_countdown" "jarvis" "${urgency} **AWS SAA-C03 D-${diff_days}일** (시험일: ${exam_date})
오늘 집중 권장: VPC 엔드포인트 · HA 패턴 · IAM 권한 경계.
남은 시간 최대한 활용하세요, 주인님." && _cd_set "aws_countdown"
}

# ─── 패턴 2+4: OAuth 토큰 만료 선제 경고 ─────────────────────
check_auth_expiry_proactive() {
    _cd_check "auth_expiry" 3600 && return 0
    local cred_file="${HOME}/.claude/.credentials.json"
    [[ -f "$cred_file" ]] || return 0
    local exp_ts remaining_h
    exp_ts=$(jq -r '.expiresAt // 0' "$cred_file" 2>/dev/null \
        | awk '{print int($1/1000)}' 2>/dev/null || echo 0)
    if [[ -z "$exp_ts" || "$exp_ts" == "0" ]]; then return 0; fi
    remaining_h=$(( (exp_ts - $(date +%s)) / 3600 ))

    if (( remaining_h <= 0 )); then
        emit "token_bot_failure" "jarvis-system" \
            "🔴 **Claude OAuth 만료** — 봇 전체 정지. 즉시 재인증: \`claude setup-token\`" \
            && _cd_set "auth_expiry"
    elif (( remaining_h <= 2 )); then
        emit "token_bot_failure" "jarvis-system" \
            "🚨 **OAuth ${remaining_h}h 후 만료** — 지금 재인증하지 않으면 봇이 멈춥니다." \
            && _cd_set "auth_expiry"
    elif (( remaining_h <= 6 )); then
        emit "card_anomaly" "jarvis-system" \
            "⚠️ **OAuth ${remaining_h}h 후 만료** — 오늘 안에 갱신 권장합니다." \
            && _cd_set "auth_expiry"
    fi
}

# ─── 패턴 2: 크론 연속 실패 감시 ──────────────────────────────
check_cron_failures() {
    _cd_check "cron_failures" 1800 && return 0
    local results_dir="${BOT_HOME}/state/results"
    [[ -d "$results_dir" ]] || return 0
    local err_count
    err_count=$(find "$results_dir" -name "*.err" -mmin -60 2>/dev/null | wc -l | tr -d ' ')
    if (( err_count < 3 )); then return 0; fi

    local top_errs
    top_errs=$(find "$results_dir" -name "*.err" -mmin -60 2>/dev/null \
        | head -3 | xargs -I{} basename {} .err 2>/dev/null \
        | paste -sd ',' 2>/dev/null || echo "unknown")

    emit "card_anomaly" "jarvis-system" \
        "⚠️ **크론 ${err_count}개 실패 (60분 내)**
주요: ${top_errs}
→ \`/doctor\` 점검을 권장합니다." && _cd_set "cron_failures"
}

# ─── 패턴 4: TQQQ 가격 선제 경고 ──────────────────────────────
check_tqqq_proactive() {
    _cd_check "tqqq_price" 600 && return 0
    local price
    price=$(curl -sf --max-time 5 \
        "https://query1.finance.yahoo.com/v8/finance/chart/TQQQ?interval=1m&range=1d" \
        2>/dev/null | jq -r '.chart.result[0].meta.regularMarketPrice // empty' 2>/dev/null || echo "")
    if [[ -z "$price" ]]; then return 0; fi

    local below
    below=$(awk -v p="$price" 'BEGIN{print (p+0 <= 37) ? "1" : "0"}')
    if [[ "$below" != "1" ]]; then return 0; fi

    local gap
    gap=$(awk -v p="$price" 'BEGIN{printf "%.2f", 37 - p}')
    emit "card_anomaly" "jarvis-market" \
        "🚨 **TQQQ \$${price}** — 손절선(\$37) 돌파, -\$${gap}
손절 실행 여부를 결정하세요, 주인님." && _cd_set "tqqq_price"
}

# ─── 패턴 5: 일일 위트 (아침 인사) ───────────────────────────
check_daily_wit() {
    _cd_check "daily_wit" 86400 && return 0
    local h
    h=$(date '+%-H')
    if (( h < 7 || h >= 9 )); then return 0; fi

    local idx msg
    idx=$(( $(date '+%j') % 5 ))
    case "$idx" in
        0) msg="☕ 좋은 아침입니다, 주인님. 세계 정복 전 커피 한 잔이 선행되어야 할 것 같습니다." ;;
        1) msg="🌅 주인님, 오늘 일정을 시작하시겠습니까? 물론 기상 5분은 드리겠습니다." ;;
        2) msg="⚙️ 전 시스템 정상 가동 중입니다. 주인님도 정상 가동 상태이시길 바랍니다." ;;
        3) msg="🔋 에너지 레벨 불명, 주인님. 충전 완료 상태로 판단하고 전 시스템 풀 출력 대기 중입니다." ;;
        *) msg="🤖 어제보다 나은 하루가 되길 바랍니다. 데이터는 그것이 가능하다고 말하고 있습니다." ;;
    esac
    emit "daily_wit" "jarvis" "$msg" && _cd_set "daily_wit"
}

# ─── 메인 루프 ─────────────────────────────────────────────────
log "=== proactive-engine v2 시작 (mode=$(get_time_mode), poll=${POLL_INTERVAL}s) ==="

# 2026-05-14 /verify 추가: heartbeat 카운터 — 1시간 1회 가시성 로그
_heartbeat_cnt=0
_HEARTBEAT_EVERY=12  # 12 * 5min = 60min

# 2026-05-18: 자동 재기동 — 스크립트 파일 mtime 변경 감지 시 exec으로 자기 재기동
_SCRIPT_MTIME=$(stat -f %m "$0" 2>/dev/null || echo "0")

while true; do
    _cpu_guard
    process_event_queue
    rotate_freq_ledger  # 24h 회전 (결함 2 — 매 사이클 비용 저렴)

    # 자동 재기동: 스크립트 파일 변경 감지
    _cur_mtime=$(stat -f %m "$0" 2>/dev/null || echo "0")
    if [[ "$_cur_mtime" != "$_SCRIPT_MTIME" ]]; then
        log "🔄 스크립트 변경 감지 (${_SCRIPT_MTIME} → ${_cur_mtime}) — 자동 재기동"
        exec "$0"
    fi

    # 가시성 — 빈 큐 사이클에도 데몬 살아있다는 흔적
    if (( _heartbeat_cnt % _HEARTBEAT_EVERY == 0 )); then
        log "💓 heartbeat (mode=$(get_time_mode), uptime_cycles=${_heartbeat_cnt})"
    fi
    _heartbeat_cnt=$((_heartbeat_cnt + 1))

    # ─ 패턴 직접 체크 (v2 full — 2026-05-15) ─
    # check_company_followup 제거 (2026-05-28): proactive-engine.json follow_ups는
    # Python 엔진의 STATE 저장소. bash 엔진이 REGISTRY로 오독 → 중복 메시지 근본 원인.
    # 채용 팔로업은 Python 엔진(proactive-engine.sh) + follow-ups.json이 단독 처리.
    check_aws_countdown         || true
    check_auth_expiry_proactive || true
    check_cron_failures         || true
    check_tqqq_proactive        || true
    check_daily_wit             || true

    sleep "$POLL_INTERVAL"
done
