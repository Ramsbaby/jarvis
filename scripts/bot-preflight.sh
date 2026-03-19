#!/usr/bin/env bash
# bot-preflight.sh — Discord 봇 시작 전 검증 + AI 자동복구 래퍼
#
# 동작 흐름:
#   1. 설정 파일 검증
#   2. 실패 시 → tmux(jarvis-heal) 세션에서 ask-claude.sh 실행 → AI가 직접 수정
#   3. 180초 대기 후 exit 1 → launchd가 재시작 → 다시 검증
#   4. 통과 시 → 현재 설정 백업 → exec node (프로세스 교체)

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
BOT_SCRIPT="$BOT_HOME/discord/discord-bot.js"
ENV_FILE="$BOT_HOME/discord/.env"
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"
MONITORING="$BOT_HOME/config/monitoring.json"
LOG_FILE="$BOT_HOME/logs/preflight.log"
BACKUP_DIR="$BOT_HOME/state/config-backups"
HEAL_ATTEMPTS_FILE="$BOT_HOME/state/heal-attempts"
MAX_HEAL_ATTEMPTS=3
FAST_CRASH_FILE="$BOT_HOME/state/fast-crash-count"
FAST_CRASH_THRESHOLD=3    # N회 빠른 크래시 시 heal 트리거
FAST_CRASH_WINDOW_SEC=10  # 기동 후 N초 이내 종료 = 빠른 크래시 (node 시작 오버헤드 + 여유)

mkdir -p "$BACKUP_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [preflight] $*" | tee -a "$LOG_FILE"; }

send_ntfy() {
    local msg="$1"
    local topic
    topic=$(python3 -c "import json; d=json.load(open('$MONITORING')); print(d.get('ntfy',{}).get('topic',''))" 2>/dev/null || echo "")
    if [[ -n "$topic" ]]; then
        curl -sf --max-time 5 \
            -H "Title: Jarvis 봇 시작 실패" \
            -H "Priority: urgent" \
            -H "Tags: x,robot" \
            -d "$msg" \
            "https://ntfy.sh/${topic}" >/dev/null 2>&1 || true
    fi
}

# 실패: AI 자동복구 세션 시작 → 180초 대기 → exit 1 (launchd 재시작 트리거)
fail_and_heal() {
    local reason="$1"
    log "FAIL: $reason"

    # ── 복구 시도 횟수 확인 ────────────────────────────────────────────────────
    local attempts=0
    if [[ -f "$HEAL_ATTEMPTS_FILE" ]]; then
        attempts=$(cat "$HEAL_ATTEMPTS_FILE" 2>/dev/null || echo 0)
    fi

    # 6시간 이상 안정적이었으면 카운터 자동 리셋 (일시적 장애가 영구 차단하지 않게)
    if [[ -f "$HEAL_ATTEMPTS_FILE" ]]; then
        last_attempt_age=$(( $(date +%s) - $(stat -f %m "$HEAL_ATTEMPTS_FILE" 2>/dev/null || stat -c '%Y' "$HEAL_ATTEMPTS_FILE" 2>/dev/null || echo 0) ))
        if (( last_attempt_age > 21600 )); then
            log "6시간 이상 경과 — 복구 카운터 자동 리셋 (이전 시도: ${attempts}회)"
            rm -f "$HEAL_ATTEMPTS_FILE"
            attempts=0
        fi
    fi

    if (( attempts >= MAX_HEAL_ATTEMPTS )); then
        log "CRITICAL: 복구 시도 ${MAX_HEAL_ATTEMPTS}회 초과 — 수동 개입 필요"
        send_ntfy "Jarvis 자동복구 한도 초과 (${MAX_HEAL_ATTEMPTS}회). 수동 개입 필요: $reason"
        log "300초 대기 (launchd 스팸 방지)..."
        sleep 300
        exit 1
    fi

    echo $(( attempts + 1 )) > "$HEAL_ATTEMPTS_FILE"
    log "복구 시도 $(( attempts + 1 ))/${MAX_HEAL_ATTEMPTS}"

    # ── heal-in-progress 락 확인 (watchdog과의 중복 heal 방지) ────────────────────
    local heal_lock="$BOT_HOME/state/heal-in-progress"
    if [[ -f "$heal_lock" ]]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -f %m "$heal_lock" 2>/dev/null || stat -c '%Y' "$heal_lock" 2>/dev/null || echo 0) ))
        if (( lock_age < 600 )); then
            log "heal 이미 진행 중 (${lock_age}s ago) — 신규 기동 생략, 완료 대기"
            sleep 30
            exit 1
        else
            log "WARN: 오래된 heal 락 제거 (${lock_age}s) — 재기동 허용"
            rm -f "$heal_lock"
        fi
    fi

    # tmux에서 AI 복구 세션 실행 (PTY 환경 — claude -p 정상 동작 보장)
    if tmux has-session -t jarvis-heal 2>/dev/null; then
        log "복구 세션(jarvis-heal) 이미 실행 중 — 완료 대기"
    else
        log "복구 세션 시작: tmux jarvis-heal"
        # HOME/PATH 명시 전달 (tmux는 launchd 환경 미상속, OAuth 인증은 ~/.claude/ 자동 탐색)
        tmux new-session -d -s jarvis-heal \
            -e "BOT_HOME=$BOT_HOME" \
            -e "HOME=$HOME" \
            -e "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
            "bash '$BOT_HOME/scripts/bot-heal.sh' $(printf '%q' "$reason")" \
            2>/dev/null || {
            # tmux 없는 환경 폴백: ntfy만 발송
            log "WARN: tmux 없음 — ntfy 알림만 발송"
            send_ntfy "봇 시작 실패 (수동 개입 필요): $reason"
        }
    fi

    BACKOFF_DELAYS=(30 90 180)
    local delay_idx=$(( attempts < ${#BACKOFF_DELAYS[@]} ? attempts : ${#BACKOFF_DELAYS[@]} - 1 ))
    local sleep_sec="${BACKOFF_DELAYS[$delay_idx]}"
    log "${sleep_sec}초 대기 후 재시도 (시도 $(( attempts + 1 ))/${MAX_HEAL_ATTEMPTS})..."
    sleep "$sleep_sec"
    exit 1
}

log "=== preflight 검증 시작 ==="

# ── node 바이너리 확인 (가장 먼저) ────────────────────────────────────────────
if [[ ! -x "$NODE_BIN" ]]; then
    fail_and_heal "node 없음: $NODE_BIN"
fi

# ── 봇 스크립트 확인 ──────────────────────────────────────────────────────────
if [[ ! -f "$BOT_SCRIPT" ]]; then
    fail_and_heal "discord-bot.js 없음: $BOT_SCRIPT"
fi

# ── .env 파일 확인 (없으면 백업에서 자동 복원 시도) ────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    ENV_BACKUP="$BACKUP_DIR/.env.backup"
    if [[ -f "$ENV_BACKUP" ]]; then
        log "WARN: .env 없음 — 백업에서 자동 복원: $ENV_BACKUP"
        cp "$ENV_BACKUP" "$ENV_FILE"
        log "✅ .env 백업 복원 완료 ($(wc -l < "$ENV_FILE")줄)"
    else
        fail_and_heal ".env 없음 — 백업도 없음. 수동 복구 필요: $ENV_FILE"
    fi
fi

# ── .env 필수키 확인 ──────────────────────────────────────────────────────────
REQUIRED_KEYS=(DISCORD_TOKEN OPENAI_API_KEY CHANNEL_IDS GUILD_ID)
MISSING_KEYS=()
for key in "${REQUIRED_KEYS[@]}"; do
    if ! grep -qE "^${key}=.+" "$ENV_FILE" 2>/dev/null; then
        MISSING_KEYS+=("$key")
    fi
done
if [[ ${#MISSING_KEYS[@]} -gt 0 ]]; then
    fail_and_heal ".env 필수키 없거나 비어있음: ${MISSING_KEYS[*]}"
fi

# ── JSON 유효성 검사 ──────────────────────────────────────────────────────────
JSON_CONFIGS=(
    "$BOT_HOME/discord/personas.json"
    "$BOT_HOME/config/tasks.json"
)
for json_file in "${JSON_CONFIGS[@]}"; do
    [[ -f "$json_file" ]] || continue
    if ! "$NODE_BIN" -e "JSON.parse(require('fs').readFileSync('$json_file','utf8'))" 2>/dev/null; then
        fail_and_heal "JSON 파싱 실패: $(basename "$json_file") — 문법 오류로 봇 시작 불가"
    fi
done

# ── 검증 통과 → 현재 설정 백업 저장 ──────────────────────────────────────────
for json_file in "${JSON_CONFIGS[@]}"; do
    [[ -f "$json_file" ]] || continue
    cp "$json_file" "$BACKUP_DIR/$(basename "$json_file").backup"
done
cp "$ENV_FILE" "$BACKUP_DIR/.env.backup"
log "백업 저장 완료"

# 검증 통과 → 복구 시도 카운터 리셋
rm -f "$HEAL_ATTEMPTS_FILE"

log "검증 통과 → 봇 시작 (모니터링 모드)"

# exec 대신 직접 실행: 종료 후 빠른 크래시 여부 판단 가능
# (launchd는 bash PID를 추적 → node 종료 후 bash도 종료 → launchd가 재시작)
_start_ts=$(date +%s)
"$NODE_BIN" "$BOT_SCRIPT"
_exit_code=$?
_runtime=$(( $(date +%s) - _start_ts ))

if (( _exit_code != 0 && _runtime < FAST_CRASH_WINDOW_SEC )); then
    # 빠른 크래시 감지 (SyntaxError, import 실패 등 런타임 즉사)
    _fast_count=0
    if [[ -f "$FAST_CRASH_FILE" ]]; then
        _fast_count=$(cat "$FAST_CRASH_FILE" 2>/dev/null || echo 0)
    fi
    _fast_count=$(( _fast_count + 1 ))
    echo "$_fast_count" > "$FAST_CRASH_FILE"
    log "빠른 크래시 감지 (runtime=${_runtime}s, exit=${_exit_code}, count=${_fast_count}/${FAST_CRASH_THRESHOLD})"

    if (( _fast_count >= FAST_CRASH_THRESHOLD )); then
        rm -f "$FAST_CRASH_FILE"
        _last_err=$(tail -30 "$BOT_HOME/logs/discord-bot.err.log" 2>/dev/null \
            | grep -iE "Error:|SyntaxError|TypeError|Cannot find|ENOENT" \
            | tail -1 || echo "알 수 없음")
        fail_and_heal "빠른 크래시 ${_fast_count}회 반복 (runtime<${FAST_CRASH_WINDOW_SEC}s): ${_last_err}"
    fi
else
    # 정상 실행(오래 돌았거나 정상 종료) → 빠른 크래시 카운터 리셋
    if [[ -f "$FAST_CRASH_FILE" ]]; then
        log "정상 실행 후 종료 (runtime=${_runtime}s) → fast-crash 카운터 리셋"
        rm -f "$FAST_CRASH_FILE"
    fi
fi

exit $_exit_code
