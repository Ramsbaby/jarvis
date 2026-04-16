#!/usr/bin/env bash
# bot-heal.sh — 봇 시작 실패 시 Claude가 자동 진단·수정
# tmux 세션(jarvis-heal) 안에서 실행됨 → PTY 환경 보장
# 수정만 수행, 재시작은 launchd가 자연스럽게 처리 (preflight 재실행)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/.jarvis}}/lib/compat.sh" 2>/dev/null || true

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
ERROR_REASON="${1:-알 수 없는 시작 실패}"
LOG_FILE="$BOT_HOME/logs/bot-heal.log"
MONITORING="$BOT_HOME/config/monitoring.json"
HEAL_LOCK="$BOT_HOME/state/heal-in-progress"
RECOVERY_LEARNINGS_FILE="$BOT_HOME/state/recovery-learnings.md"
HEAL_FAIL_LEDGER="$BOT_HOME/state/heal-fail-ledger"
MAX_SAME_CAUSE_FAILURES=3

# log: watchdog이 nohup ... >> bot-heal.log 2>&1 로 호출하므로
# tee 대신 직접 append — 중복 라인 방지
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [heal] $*" >> "$LOG_FILE"; }

# Shared ntfy function
source "${BOT_HOME}/lib/ntfy-notify.sh"

# 중복 복구 방지
if [[ -f "$HEAL_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -c '%Y' "$HEAL_LOCK" 2>/dev/null || stat -f %m "$HEAL_LOCK" 2>/dev/null || echo 0) ))
    if (( lock_age < 600 )); then
        log "복구 세션 이미 진행 중 (${lock_age}s ago) — 종료"
        exit 0
    fi
fi
echo $$ > "$HEAL_LOCK"
trap 'rm -f "$HEAL_LOCK"' EXIT

# ── 동일 원인 서킷브레이커 ────────────────────────────────────────────────────
# 원인 시그니처: 에러 타입만 추출 (타임스탬프/PID 제거)
_cause_sig=$(echo "$ERROR_REASON" | sed 's/[0-9]\{1,\}회/N회/g; s/PID=[0-9]*/PID=X/g' | md5sum 2>/dev/null | cut -c1-12 || echo "unknown")
mkdir -p "$(dirname "$HEAL_FAIL_LEDGER")"
_fail_count=0
if [[ -f "$HEAL_FAIL_LEDGER" ]]; then
    _fail_count=$(grep -c "^${_cause_sig}|" "$HEAL_FAIL_LEDGER" 2>/dev/null || echo 0)
fi
if (( _fail_count >= MAX_SAME_CAUSE_FAILURES )); then
    log "=== 서킷브레이커: 동일 원인 ${_fail_count}회 연속 실패 — heal 중단 ==="
    log "원인: $ERROR_REASON"
    log "같은 패턴으로 ${MAX_SAME_CAUSE_FAILURES}회 이상 실패. 수동 개입 필요."
    send_ntfy "Jarvis 자동복구 차단 (서킷브레이커)" "동일 원인 ${_fail_count}회 연속 실패\n${ERROR_REASON}\n\n수동 개입 필요. 리셋: rm $HEAL_FAIL_LEDGER" "urgent"
    exit 1
fi

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

# 패턴 3: LRUCache ESM/CJS 충돌 → named import를 default import로 변환
# 14회 연속 실패(3/21~3/30)의 원인 패턴. "LRUCache is not a constructor" 또는 "does not provide an export named 'LRUCache'"
if echo "$ERROR_REASON" | grep -qE "LRUCache|lru-cache"; then
    BAD_FILES=$(grep -rl "import.*{.*LRUCache.*}.*from.*'lru-cache'" "$BOT_HOME/discord/" "$BOT_HOME/infra/discord/" --include="*.js" 2>/dev/null || true)
    if [[ -n "$BAD_FILES" ]]; then
        while IFS= read -r BAD_FILE; do
            [[ -z "$BAD_FILE" ]] && continue
            log "[hardcode] lru-cache named import 감지: $BAD_FILE"
            cp "$BAD_FILE" "${BAD_FILE}.bak-$(date +%s)"
            # named import → default import
            sed -i '' \
                "s|import { LRUCache } from 'lru-cache';|import LRUCachePkg from 'lru-cache';\nconst { LRUCache } = LRUCachePkg;|g" \
                "$BAD_FILE" 2>/dev/null || \
            sed -i \
                "s|import { LRUCache } from 'lru-cache';|import LRUCachePkg from 'lru-cache';\nconst { LRUCache } = LRUCachePkg;|g" \
                "$BAD_FILE" 2>/dev/null || true
            # default import인데 new LRUCache()가 안 되는 경우: LRUCache가 .default에 있을 수 있음
            if grep -q "import LRUCache from 'lru-cache'" "$BAD_FILE" 2>/dev/null; then
                sed -i '' \
                    "s|import LRUCache from 'lru-cache';|import lruCacheDefault from 'lru-cache';\nconst LRUCache = lruCacheDefault.default || lruCacheDefault;|g" \
                    "$BAD_FILE" 2>/dev/null || \
                sed -i \
                    "s|import LRUCache from 'lru-cache';|import lruCacheDefault from 'lru-cache';\nconst LRUCache = lruCacheDefault.default || lruCacheDefault;|g" \
                    "$BAD_FILE" 2>/dev/null || true
            fi
            log "[hardcode] lru-cache CJS fix 적용: $BAD_FILE"
            HARDCODED_FIXED=true
        done <<< "$BAD_FILES"
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

# ── Gotchas 로드 (알려진 실패 패턴 + 해결책, resolved 항목 제외) ─────────────────
GOTCHAS_FILE="$BOT_HOME/state/gotchas.md"
GOTCHAS_CONTENT="없음"
if [[ -f "$GOTCHAS_FILE" ]]; then
    # "수정 완료" 표시된 G-항목은 이미 해결됐으므로 복구 프롬프트에서 제외
    # python3으로 섹션 파싱: "상태: ...수정 완료" 줄 포함된 블록은 skip
    GOTCHAS_CONTENT=$(python3 - <<'PYEOF' 2>/dev/null || cat "$GOTCHAS_FILE" 2>/dev/null || echo "없음"
import os, re
bot_home = os.environ.get("BOT_HOME", os.path.expanduser("~/.jarvis"))
path = os.path.join(bot_home, "state", "gotchas.md")
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
# 섹션 분리: ## G-NNN: ... 블록 단위
# resolved 판단: 블록 내에 "수정 완료" 문자열 포함 여부
header_pattern = re.compile(r'^(## G-\d+:)', re.MULTILINE)
parts = header_pattern.split(content)
# parts[0] = 파일 헤더, 이후 [heading, body] 쌍
result = [parts[0]]
i = 1
while i + 1 < len(parts):
    heading = parts[i]
    body = parts[i+1]
    if "수정 완료" not in body and "RESOLVED" not in body:
        result.append(heading + body)
    i += 2
print("".join(result).strip() or "없음")
PYEOF
)
fi

HEAL_PROMPT="[Jarvis 봇 자동복구 태스크]

Discord 봇이 시작 실패했습니다. 원인을 분석하고 파일을 수정해주세요.
수정이 완료되면 봇은 launchd가 자동으로 재시작합니다 — 재시작 명령은 실행하지 마세요.

## ⚠️ 알려진 실패 패턴 (Gotchas) — 반드시 먼저 확인하라
${GOTCHAS_CONTENT}

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
1. 실패 원인을 위 Gotchas 패턴과 먼저 대조하라 — 일치하면 해당 해결책을 즉시 적용
2. 일치하는 Gotcha가 없으면 에러 로그를 분석해 원인을 파악하라
3. 문제가 있는 파일을 Read로 확인하라
4. 문제를 수정하라 (Edit 또는 Bash 사용)
5. JSON 파일 수정 시 반드시 유효성 확인: node -e \"JSON.parse(require('fs').readFileSync('<파일>','utf8'))\"
6. 수정 완료 후 마지막 줄에 반드시 출력: 복구완료: <수정한 파일명과 내용 한 줄 요약>

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
    # 서킷브레이커 원장에 실패 기록
    echo "${_cause_sig}|$(date '+%Y-%m-%d %H:%M')|FAIL|exit=${HEAL_EXIT}|${ERROR_REASON}" >> "$HEAL_FAIL_LEDGER" 2>/dev/null || true
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

# ── Post-heal 검증: 봇이 실제로 시작되는지 15초 대기 후 확인 ──────────────────
log "검증 대기 중... (15초)"
sleep 15
_bot_pid=$(pgrep -f "discord-bot.js" 2>/dev/null | head -1 || true)
if [[ -z "$_bot_pid" ]]; then
    log "POST-HEAL 검증 실패: Claude는 성공 보고했으나 봇 프로세스 미기동"
    send_ntfy "Jarvis 자동복구 검증 실패" "Claude 성공 보고 후 봇 미기동\n${ERROR_REASON}\n\n봇이 시작되지 않았습니다." "high"
    # 서킷브레이커 원장에 검증 실패 기록
    echo "${_cause_sig}|$(date '+%Y-%m-%d %H:%M')|VERIFY_FAIL|${ERROR_REASON}" >> "$HEAL_FAIL_LEDGER" 2>/dev/null || true
    {
        echo ""
        echo "## $(date '+%Y-%m-%d %H:%M') — 복구 검증 실패"
        echo "- 원인: $ERROR_REASON"
        echo "- Claude 결과: $HEAL_RESULT"
        echo "- 검증: 봇 프로세스 미기동 — 허위 성공"
    } >> "$RECOVERY_LEARNINGS_FILE" 2>/dev/null || true
    ( sleep 3 && tmux kill-session -t jarvis-heal 2>/dev/null ) &
    exit 1
fi
log "POST-HEAL 검증 성공: 봇 PID=$_bot_pid 확인"

# 서킷브레이커 원장 리셋 — 이 원인 패턴 성공했으므로 카운터 초기화
if [[ -f "$HEAL_FAIL_LEDGER" ]]; then
    grep -v "^${_cause_sig}|" "$HEAL_FAIL_LEDGER" > "${HEAL_FAIL_LEDGER}.tmp" 2>/dev/null || true
    mv "${HEAL_FAIL_LEDGER}.tmp" "$HEAL_FAIL_LEDGER" 2>/dev/null || true
fi

send_ntfy "Jarvis 자동복구 완료" "$HEAL_RESULT\n\n봇 PID=$_bot_pid 확인." "default"
log "=== 복구 완료 — 봇 정상 기동 확인 (PID=$_bot_pid) ==="
# 성공 이력 기록
{
    echo ""
    echo "## $(date '+%Y-%m-%d %H:%M') — 복구 성공"
    echo "- 원인: $ERROR_REASON"
    echo "- 해결: $HEAL_RESULT"
} >> "$RECOVERY_LEARNINGS_FILE" 2>/dev/null || true
# 세션 정리 (좀비 방지 — 스스로를 kill할 수 없으므로 백그라운드 지연 처리)
( sleep 3 && tmux kill-session -t jarvis-heal 2>/dev/null ) &
