#!/usr/bin/env bash
# deploy-with-smoke.sh — Jarvis 봇 변경사항 검증 후 재시작
# 문법 오류·핵심 함수 삭제 감지 시 재시작 차단
# 사용: bash ~/.jarvis/scripts/deploy-with-smoke.sh

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/.jarvis}}/lib/compat.sh" 2>/dev/null || true

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
SERVICE="ai.jarvis.discord-bot"
PASS=0; FAIL=0
RESULTS=""

ok()   { PASS=$((PASS+1)); RESULTS+="✅ $1\n"; echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); RESULTS+="❌ $1\n"; echo "  FAIL: $1"; }

echo "=== Jarvis Smoke Test ==="

# 1. JS/MJS 문법 검사
echo ""
echo "▶ 문법 검사..."
while IFS= read -r f; do
    if node --check "$f" 2>/dev/null; then
        ok "문법 OK: ${f##*/}"
    else
        fail "문법 에러: ${f##*/}"
    fi
done < <(find "$BOT_HOME/discord" "$BOT_HOME/lib" \
    -not -path '*/node_modules/*' \
    \( -name '*.js' -o -name '*.mjs' \) 2>/dev/null)

# 2. 핵심 파일 존재 확인
echo ""
echo "▶ 핵심 파일 확인..."
CORE_FILES=(
    "$BOT_HOME/discord/discord-bot.js"
    "$BOT_HOME/discord/lib/handlers.js"
    "$BOT_HOME/discord/lib/claude-runner.js"
    "$BOT_HOME/discord/lib/streaming.js"
    "$BOT_HOME/discord/personas.json"
)
for f in "${CORE_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        ok "존재: ${f##*/}"
    else
        fail "없음: ${f##*/}"
    fi
done

# 3. 핵심 함수 존재 확인
echo ""
echo "▶ 핵심 함수 확인..."
if grep -q "handleMessage\|messageCreate" "$BOT_HOME/discord/lib/handlers.js" 2>/dev/null; then
    ok "handleMessage 함수 존재"
else
    fail "handleMessage 함수 없음 — handlers.js 손상 가능성"
fi

if grep -q "createClaudeSession" "$BOT_HOME/discord/lib/claude-runner.js" 2>/dev/null; then
    ok "createClaudeSession 함수 존재"
else
    fail "createClaudeSession 없음 — claude-runner.js 손상 가능성"
fi

# 4. JSON 유효성
echo ""
echo "▶ JSON 유효성..."
# 주의: tasks.json은 gitignore 비추적 운영 데이터 — git 롤백으로 복원 불가하므로 배포 차단 기준에서 제외
for f in "$BOT_HOME/discord/personas.json" "$BOT_HOME/config/effective-tasks.json"; do
    if node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" 2>/dev/null; then
        ok "JSON 유효: ${f##*/}"
    else
        fail "JSON 파싱 실패: ${f##*/}"
    fi
done
# tasks.json은 경고만 (없거나 손상돼도 배포는 진행)
if [[ -f "$BOT_HOME/config/tasks.json" ]]; then
    if node -e "JSON.parse(require('fs').readFileSync('$BOT_HOME/config/tasks.json','utf8'))" 2>/dev/null; then
        ok "JSON 유효: tasks.json"
    else
        echo "  ⚠ WARN: tasks.json JSON 파싱 실패 (배포는 계속)"
    fi
else
    echo "  ⚠ WARN: tasks.json 없음 — gitignore 비추적 파일, 별도 복구 필요 (배포는 계속)"
fi

# 5. .env 필수키 검사
echo ""
echo "▶ .env 필수키..."
ENV_FILE="$BOT_HOME/discord/.env"
REQUIRED_KEYS=(DISCORD_TOKEN OPENAI_API_KEY CHANNEL_IDS GUILD_ID)
if [[ ! -f "$ENV_FILE" ]]; then
    fail ".env 파일 없음: $ENV_FILE"
else
    for key in "${REQUIRED_KEYS[@]}"; do
        if grep -qE "^${key}=.+" "$ENV_FILE" 2>/dev/null; then
            ok ".env 키 존재: $key"
        else
            fail ".env 키 없거나 비어있음: $key"
        fi
    done
fi

# 6. node_modules 존재 확인
echo ""
echo "▶ 의존성 확인..."
if [[ -d "$BOT_HOME/discord/node_modules" ]]; then
    ok "node_modules 존재"
else
    fail "node_modules 없음 — npm install 필요: cd $BOT_HOME/discord && npm install"
fi

# ── 결과 판단 ─────────────────────────────────────────────────────
echo ""
echo "=== 결과: ${PASS}/$((PASS+FAIL)) 통과 ==="

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "❌ Smoke Test 실패 — 재시작 중단"
    echo "실패 항목:"
    echo -e "$RESULTS" | grep "❌"
    exit 1
fi

# ── 봇 재시작 ─────────────────────────────────────────────────────
echo ""
echo "▶ 봇 재시작..."
if $IS_MACOS; then
    launchctl stop "$SERVICE" 2>/dev/null || true
    sleep 2
    launchctl start "$SERVICE" 2>/dev/null || launchctl kickstart -k "gui/$(id -u)/$SERVICE" 2>/dev/null
else
    echo "[compat] 봇 재시작: pm2 restart discord-bot"
    pm2 restart discord-bot 2>/dev/null || true
fi

# ── 생존 확인 (10초 대기 — 즉시 크래시 감지) ─────────────────────
echo "  (10초 대기 중...)"
sleep 10
if pgrep -f "discord-bot.js" > /dev/null 2>&1; then
    # 재시작 직후 에러 로그 확인
    _recent_err=$(tail -20 "$BOT_HOME/logs/discord-bot.log" 2>/dev/null \
        | grep -iE "Error:|TypeError|SyntaxError|Cannot find|ENOENT|FATAL" \
        | tail -1 || true)
    if [[ -n "$_recent_err" ]]; then
        echo "⚠️  봇 실행 중이나 에러 감지: $_recent_err"
    else
        echo "✅ 봇 정상 실행 확인"
    fi
else
    _crash_err=$(tail -30 "$BOT_HOME/logs/discord-bot.log" 2>/dev/null \
        | grep -iE "Error:|TypeError|SyntaxError|Cannot find|ENOENT|FATAL" \
        | tail -1 || echo "로그 없음")
    echo "❌ 봇 프로세스 없음 — 즉시 크래시 가능성"
    echo "   마지막 에러: $_crash_err"
fi

echo ""
echo "완료 — 변경사항이 적용됐습니다"
