#!/usr/bin/env bash
# deploy-with-smoke.sh — Jarvis 봇 변경사항 검증 후 재시작
# 문법 오류·핵심 함수 삭제 감지 시 재시작 차단
# 사용: bash ~/jarvis/runtime/scripts/deploy-with-smoke.sh

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}/lib/compat.sh" 2>/dev/null || true

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
SERVICE="ai.jarvis.discord-bot"
PASS=0; FAIL=0
RESULTS=""

ok()   { PASS=$((PASS+1)); RESULTS+="✅ $1\n"; echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); RESULTS+="❌ $1\n"; echo "  FAIL: $1"; }

echo "=== Jarvis Smoke Test ==="

# 1. JS/MJS 문법 검사 (-L로 symlink 추적 — runtime/discord/lib가 infra/discord/lib 심링크)
# 충돌 마커 별도 감지 — node --check는 <<<<<<< 를 SyntaxError로 잡지만 메시지 혼동 방지
echo ""
echo "▶ 문법 검사..."
FILES_CHECKED=0
while IFS= read -r f; do
    FILES_CHECKED=$((FILES_CHECKED+1))
    # 병합 충돌 마커 우선 검사 (더 명확한 메시지)
    if grep -qE '^(<<<<<<<|=======|>>>>>>>) ' "$f" 2>/dev/null; then
        fail "병합 충돌 마커 남음: ${f##*/} — 해결 후 재배포"
        continue
    fi
    if node --check "$f" 2>/dev/null; then
        ok "문법 OK: ${f##*/}"
    else
        fail "문법 에러: ${f##*/}"
    fi
done < <(find -L "$BOT_HOME/discord" "$BOT_HOME/lib" \
    -not -path '*/node_modules/*' \
    -not -path '*/.serena/*' \
    \( -name '*.js' -o -name '*.mjs' \) 2>/dev/null)

# 최소 10개 미만이면 find가 범위 잘못 잡음 — smoke 의미 없음
if [[ "$FILES_CHECKED" -lt 10 ]]; then
    fail "문법 검사 대상 ${FILES_CHECKED}개 — symlink 전개 실패 가능성 (정상: 50+개)"
fi

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
# 재시작 직전 err.log 크기 snapshot — 이전 사고 영향 제외용 offset
ERR_LOG="$BOT_HOME/logs/discord-bot.err.log"
ERR_SIZE_BEFORE=0
if [[ -f "$ERR_LOG" ]]; then
    ERR_SIZE_BEFORE=$(stat -f %z "$ERR_LOG" 2>/dev/null || stat -c %s "$ERR_LOG" 2>/dev/null || echo 0)
fi

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

# ── 생존 확인 (15초 대기 + launchctl 상태 + stderr 로그 검사) ─────
# 이전 버그: 10초만 기다리면 재시작 루프 중간에 잡혀서 ✅ 거짓 표시됨.
# 재수정: err.log 검사는 DEPLOY 이후 추가된 바이트만 본다 (offset diff).
echo "  (15초 대기 중...)"
sleep 15

# launchctl 상태: PID 정수 + 최근 exit code 확인
LC_LINE=$(launchctl list | awk -v s="$SERVICE" '$3==s{print}' | head -1)
LC_PID=$(echo "$LC_LINE" | awk '{print $1}')
LC_STATUS=$(echo "$LC_LINE" | awk '{print $2}')

# 재시작 이후 err.log 신규 내용만 추출
RESTART_LOOP_COUNT=0
if [[ -f "$ERR_LOG" ]]; then
    ERR_SIZE_AFTER=$(stat -f %z "$ERR_LOG" 2>/dev/null || stat -c %s "$ERR_LOG" 2>/dev/null || echo 0)
    if [[ "$ERR_SIZE_AFTER" -gt "$ERR_SIZE_BEFORE" ]]; then
        NEW_ERR=$(tail -c $((ERR_SIZE_AFTER - ERR_SIZE_BEFORE)) "$ERR_LOG" 2>/dev/null || true)
        if [[ -n "$NEW_ERR" ]]; then
            RESTART_LOOP_COUNT=$(echo "$NEW_ERR" | grep -cE "SyntaxError|Cannot find|<<<<<<<|Unexpected token" 2>/dev/null || echo 0)
        fi
    fi
fi

if [[ "$LC_PID" =~ ^[0-9]+$ ]] && [[ "$RESTART_LOOP_COUNT" -eq 0 ]]; then
    # discord-bot.log(jsonl)과 out.log 양쪽 모두 검사
    _recent_err=$(tail -20 "$BOT_HOME/logs/discord-bot.jsonl" 2>/dev/null \
        | grep -iE '"level":"error"|TypeError|SyntaxError|Cannot find|ENOENT|FATAL' \
        | tail -1 || true)
    if [[ -n "$_recent_err" ]]; then
        echo "⚠️  봇 실행 중이나 에러 감지 (PID=$LC_PID): $_recent_err"
    else
        echo "✅ 봇 정상 실행 확인 (PID=$LC_PID)"
    fi
else
    _crash_err=$(tail -30 "$BOT_HOME/logs/discord-bot.err.log" 2>/dev/null \
        | grep -iE "SyntaxError|Cannot find|<<<<<<<|Error:|TypeError|FATAL" \
        | tail -2 || echo "로그 없음")
    echo "❌ 봇 비정상 (launchctl PID=${LC_PID:-'-'}, status=${LC_STATUS:-'-'}, err출현=${RESTART_LOOP_COUNT}건)"
    echo "   최근 에러: $_crash_err"
    echo ""
    echo "   ▶ 롤백 힌트: git reset --hard HEAD~1 후 재배포"
    exit 1
fi

echo ""
echo "완료 — 변경사항이 적용됐습니다"