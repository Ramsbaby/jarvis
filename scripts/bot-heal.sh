#!/usr/bin/env bash
# bot-heal.sh — 봇 시작 실패 시 Claude가 자동 진단·수정
# tmux 세션(jarvis-heal) 안에서 실행됨 → PTY 환경 보장
# 수정만 수행, 재시작은 launchd가 자연스럽게 처리 (preflight 재실행)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-$HOME/.jarvis}}/lib/compat.sh" 2>/dev/null || true

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
ERROR_REASON="${1:-알 수 없는 시작 실패}"
LOG_FILE="$BOT_HOME/logs/bot-heal.log"
MONITORING="$BOT_HOME/config/monitoring.json"
HEAL_LOCK="$BOT_HOME/state/heal-in-progress"
RECOVERY_LEARNINGS_FILE="$BOT_HOME/state/recovery-learnings.md"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [heal] $*" | tee -a "$LOG_FILE"; }

send_ntfy() {
    local title="$1" msg="$2" priority="${3:-default}"
    local topic
    topic=$(python3 -c "import json; d=json.load(open('$MONITORING')); print(d.get('ntfy',{}).get('topic',''))" 2>/dev/null || echo "")
    if [[ -n "$topic" ]]; then
        curl -sf --max-time 5 \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: robot" \
            -d "$msg" \
            "https://ntfy.sh/${topic}" >/dev/null 2>&1 || true
    fi
}

# 중복 복구 방지
if [[ -f "$HEAL_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$HEAL_LOCK" 2>/dev/null || stat -c '%Y' "$HEAL_LOCK" 2>/dev/null || echo 0) ))
    if (( lock_age < 600 )); then
        log "복구 세션 이미 진행 중 (${lock_age}s ago) — 종료"
        exit 0
    fi
fi
echo $$ > "$HEAL_LOCK"
trap 'rm -f "$HEAL_LOCK"' EXIT

log "=== 자동복구 시작 ==="
log "원인: $ERROR_REASON"

send_ntfy "Jarvis 자동복구 시작" "$ERROR_REASON\n\n모니터링: ssh 후 tmux attach -t jarvis-heal" "high"

# ── 하드코딩 사전 패치 (Claude 없이 즉시 처리 가능한 알려진 패턴) ──────────────
HARDCODED_FIXED=false

# 패턴 1: .env 소멸 → 백업에서 즉시 복원
ENV_FILE="$BOT_HOME/discord/.env"
ENV_BACKUP="$BOT_HOME/state/config-backups/.env.backup"
if [[ ! -f "$ENV_FILE" && -f "$ENV_BACKUP" ]]; then
    log "[hardcode] .env 없음 → 백업 자동 복원: $ENV_BACKUP"
    cp "$ENV_BACKUP" "$ENV_FILE"
    log "[hardcode] ✅ .env 복원 완료 ($(wc -l < "$ENV_FILE")줄)"
    HARDCODED_FIXED=true
fi

# 패턴 2: ActionRowBuilder CJS/ESM 충돌 → streaming.js 상태 검증 및 수정
if echo "$ERROR_REASON" | grep -q "ActionRowBuilder"; then
    STREAMING="$BOT_HOME/discord/lib/streaming.js"
    if [[ -f "$STREAMING" ]]; then
        # named import 감지: 단일행("import { ... } from") 또는 멀티라인("import {\n  ...\n} from") 모두 처리
        if python3 -c "
import re, sys
content = open('${STREAMING}').read()
# 멀티라인 포함 named import 패턴
bad = re.search(r\"^import \{[\s\S]*?\} from 'discord\.js';\", content, re.MULTILINE)
sys.exit(0 if bad else 1)
" 2>/dev/null; then
            log "[hardcode] ActionRowBuilder named import 감지 → CJS 우회 방식으로 수정"
            # 파일 수정 전 백업
            cp "$STREAMING" "${STREAMING}.bak-$(date +%s)"
            # python3으로 안전하게 수정: 멀티라인 import → default import
            export HEAL_STREAMING_PATH="$STREAMING"
            python3 - <<'PYEOF' && log "[hardcode] ✅ streaming.js CJS fix 적용" && HARDCODED_FIXED=true || log "[hardcode] ❌ streaming.js 수정 실패 — 백업 유지"
import re, sys
streaming = sys.argv[1] if len(sys.argv) > 1 else ""
# 파일 경로는 환경변수로 전달 (heredoc 내부에서 bash 변수 불가)
import os
path = os.environ.get("HEAL_STREAMING_PATH", "")
if not path:
    sys.exit(1)
with open(path, 'r') as f:
    content = f.read()
# 멀티라인 포함 named import → default import 교체
# 기존 import에서 변수명 추출
m = re.search(r"^import \{([\s\S]*?)\} from 'discord\.js';", content, re.MULTILINE)
if not m:
    sys.exit(1)
vars_str = re.sub(r'\s+', '', m.group(1))  # 공백/개행 제거
fixed = re.sub(
    r"^import \{[\s\S]*?\} from 'discord\.js';",
    f"// discord.js is CJS — use default import to avoid ESM named-export errors\nimport discordPkg from 'discord.js';\nconst {{ {vars_str} }} = discordPkg;",
    content,
    flags=re.MULTILINE
)
if fixed == content:
    sys.exit(1)  # 치환 없으면 실패
with open(path, 'w') as f:
    f.write(fixed)
print("ok")
PYEOF
        else
            log "[hardcode] streaming.js CJS fix 이미 적용됨 — 다른 파일 문제일 수 있음"
            BAD_FILE=$(grep -rl "import {.*ActionRowBuilder.*} from 'discord.js'" "$BOT_HOME/discord/" --include="*.js" 2>/dev/null | head -1 || true)
            if [[ -n "$BAD_FILE" ]]; then
                log "[hardcode] 문제 파일 발견: $BAD_FILE — 수동 확인 필요"
            fi
        fi
    fi
fi

if $HARDCODED_FIXED; then
    log "=== 하드코딩 패치 적용 완료 — launchd가 봇을 재시작합니다 ==="
    {
        echo ""
        echo "## $(date '+%Y-%m-%d %H:%M') — 하드코딩 자동복구 성공"
        echo "- 원인: $ERROR_REASON"
        echo "- 해결: hardcoded patch 적용"
    } >> "$RECOVERY_LEARNINGS_FILE" 2>/dev/null || true
    exit 0
fi

# ── 에러 컨텍스트 수집 ─────────────────────────────────────────────────────────
PREFLIGHT_LOG=$(tail -30 "$BOT_HOME/logs/preflight.log" 2>/dev/null || echo "없음")
BOT_ERR=$(tail -50 "$BOT_HOME/logs/discord-bot.err.log" 2>/dev/null | tail -20 || echo "없음")
BOT_LOG_ERRORS=$(tail -50 "$BOT_HOME/logs/discord-bot.out.log" 2>/dev/null \
    | grep -iE "Error:|TypeError|SyntaxError|Cannot find|ENOENT|FATAL" \
    | tail -10 || echo "없음")

# ── 과거 복구 학습 로드 ─────────────────────────────────────────────────────────
PAST_LEARNINGS="없음"
if [[ -f "$RECOVERY_LEARNINGS_FILE" ]]; then
    PAST_LEARNINGS=$(tail -30 "$RECOVERY_LEARNINGS_FILE" 2>/dev/null || echo "없음")
fi

HEAL_PROMPT="[Jarvis 봇 자동복구 태스크]

Discord 봇이 시작 실패했습니다. 원인을 분석하고 파일을 수정해주세요.
수정이 완료되면 봇은 launchd가 자동으로 재시작합니다 — 재시작 명령은 실행하지 마세요.

## 실패 원인
${ERROR_REASON}

## preflight 검증 로그
${PREFLIGHT_LOG}

## 봇 stderr (최근)
${BOT_ERR}

## 봇 에러 로그 라인
${BOT_LOG_ERRORS}

## 과거 복구 이력 (참고)
${PAST_LEARNINGS}

(위 이력에서 같은 원인이 반복된다면 근본 원인을 찾아 영구 수정하라)

## 수행 지시
1. 위 정보를 바탕으로 실패 원인을 정확히 파악하라
2. 문제가 있는 파일을 Read로 확인하라
3. 문제를 수정하라 (Edit 또는 Bash 사용)
4. JSON 파일 수정 시 반드시 유효성 확인: node -e \"JSON.parse(require('fs').readFileSync('<파일>','utf8'))\"
5. 수정 완료 후 마지막 줄에 반드시 출력: 복구완료: <수정한 파일명과 내용 한 줄 요약>

중요: 봇 재시작 명령(launchctl, deploy-with-smoke.sh 등) 실행 금지 — launchd가 자동 처리"

log "Claude에게 복구 요청 중... (최대 5분)"

HEAL_RESULT=""
HEAL_EXIT=0
HEAL_RESULT=$("$BOT_HOME/bin/ask-claude.sh" \
    "bot-heal" \
    "$HEAL_PROMPT" \
    "Read,Edit,Bash" \
    "300" \
    "1.00" \
    2>>"$LOG_FILE") || HEAL_EXIT=$?

if [[ $HEAL_EXIT -ne 0 ]]; then
    log "Claude 복구 실패 (exit $HEAL_EXIT) — 수동 개입 필요"
    send_ntfy "Jarvis 자동복구 실패" "Claude가 해결하지 못했습니다.\n로그: ~/.jarvis/logs/bot-heal.log\n수동 확인 필요" "urgent"
    # 실패 이력 기록
    {
        echo ""
        echo "## $(date '+%Y-%m-%d %H:%M') — 복구 실패"
        echo "- 원인: $ERROR_REASON"
        echo "- Claude exit: $HEAL_EXIT"
        echo "- 결과: 수동 개입 필요"
    } >> "$RECOVERY_LEARNINGS_FILE" 2>/dev/null || true
    # 세션 정리 (다음 복구 시도가 새 세션으로 시작할 수 있게)
    ( sleep 3 && tmux kill-session -t jarvis-heal 2>/dev/null ) &
    exit 1
fi

log "Claude 완료: $HEAL_RESULT"
send_ntfy "Jarvis 자동복구 완료" "$HEAL_RESULT\n\n봇이 곧 재기동됩니다." "default"
log "=== 복구 완료 — launchd가 봇을 재시작합니다 ==="
# 성공 이력 기록
{
    echo ""
    echo "## $(date '+%Y-%m-%d %H:%M') — 복구 성공"
    echo "- 원인: $ERROR_REASON"
    echo "- 해결: $HEAL_RESULT"
} >> "$RECOVERY_LEARNINGS_FILE" 2>/dev/null || true
# 세션 정리 (좀비 방지 — 스스로를 kill할 수 없으므로 백그라운드 지연 처리)
( sleep 3 && tmux kill-session -t jarvis-heal 2>/dev/null ) &
