#!/usr/bin/env bash
# test-no-external.sh — JARVIS_NO_EXTERNAL=1 이 모든 Discord/ntfy 송출 경로를 막는지 (SELF-HEAL-PLAN 1d)
# 각 경로를 실제 함수로 호출하되 JARVIS_NO_EXTERNAL=1 이므로 네트워크로 나가지 않는다.
# 판정: 임시 BOT_HOME/logs/no-external.log 에 src 별 기록 + 실제 egress-audit.log 줄 수 불변.
# 실행: bash ~/.openclaw-data/jarvis/infra/scripts/test-no-external.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_RUNTIME="${HOME}/.openclaw-data/jarvis/runtime"
T=$(mktemp -d /var/tmp/noext-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
export JARVIS_NO_EXTERNAL=1
export DISCORD_ROUTE_COOLDOWN_SECS=0   # 실제 dedup 상태 디렉터리에 마커를 남기지 않는다
export BOT_HOME="$T/runtime"
mkdir -p "$BOT_HOME"/{logs,config,state,ledger}
ln -s "$INFRA/lib" "$BOT_HOME/lib"
# 웹훅·토픽이 '있는' 설정을 줘야 함수가 송출 직전까지 간다 (가짜 URL — NO_EXTERNAL 이 못 막으면 curl 이 실패할 뿐 실채널엔 안 간다)
cat > "$BOT_HOME/config/monitoring.json" <<'EOF'
{"webhooks":{"jarvis-system":"https://127.0.0.1:9/fake","jarvis-ceo":"https://127.0.0.1:9/fake","jarvis-info":"https://127.0.0.1:9/fake"},
 "webhook":{"url":"https://127.0.0.1:9/fake"},"ntfy":{"topic":"fake-topic"}}
EOF
LOG="$BOT_HOME/logs/no-external.log"
EGRESS="$REAL_RUNTIME/logs/egress-audit.log"
EGRESS_BEFORE=$(wc -l < "$EGRESS" 2>/dev/null || echo 0)
PASSED=0; FAILURES=0
expect_src() { grep -q "src=$1" "$LOG" 2>/dev/null && PASSED=$((PASSED+1)) || { FAILURES=$((FAILURES+1)); echo "  ✗ no-external.log 에 src=$1 없음"; }; }

echo "── coder-functions.sh"
( _coder_log() { :; }; source "$INFRA/lib/coder-functions.sh" >/dev/null 2>&1
  _discord_alert "noext test"; TASK_ID=x _discord_ceo_notify "noext test" )
expect_src "coder-functions.sh:_discord_alert"
expect_src "coder-functions.sh:_discord_ceo_notify"

echo "── cron-helpers.sh"
( source "$INFRA/lib/cron-helpers.sh"; _fsm_discord_alert "noext test" )
expect_src "cron-helpers.sh:_fsm_discord_alert"

echo "── discord-notify-bash.sh / ntfy-notify.sh"
( source "$INFRA/lib/discord-notify-bash.sh"; send_discord "noext test" "jarvis-system"; echo "rc=$?" ) | grep -q "rc=0" && PASSED=$((PASSED+1)) || { FAILURES=$((FAILURES+1)); echo "  ✗ send_discord rc"; }
expect_src "discord-notify-bash.sh:send_discord"
( source "$INFRA/lib/ntfy-notify.sh"; send_ntfy "t" "noext test" )
expect_src "ntfy-notify.sh:send_ntfy"

echo "── discord-route.sh (route / raw / payload)"
( source "$INFRA/lib/discord-route.sh"
  discord_route info "noext-test-$$-$(date +%s)" "k=v" >/dev/null 2>&1
  discord_route_raw jarvis-info "noext test" >/dev/null 2>&1
  discord_route_payload info '{"title":"noext-payload-'"$$"'"}' >/dev/null 2>&1 )
expect_src "discord-route.sh:discord_route"
expect_src "discord-route.sh:discord_route_raw"
expect_src "discord-route.sh:discord_route_payload"

echo "── discord-visual.mjs"
node "$INFRA/scripts/discord-visual.mjs" --type stats --data '{"title":"noext"}' --channel jarvis-info 2>/dev/null | grep -q "NO_EXTERNAL" \
  && PASSED=$((PASSED+1)) || { FAILURES=$((FAILURES+1)); echo "  ✗ discord-visual stdout"; }
expect_src "discord-visual.mjs"

echo "── alert-send.sh"
# 2026-09-10: "Alert sent" 만 보던 것을 "sent|suppressed" 로 넓힌다.
# NO_EXTERNAL 경로는 아무것도 안 보내면서 "Alert sent"를 찍고 있었고, 그 거짓 문자열 때문에
# 감사에서 "아직 송출 중"으로 오독됐다. 이 테스트가 확인해야 할 것은 문구가 아니라
# "호출이 실패로 떨어지지 않고 외부로도 안 나갔다"이다 — 아래 expect_src 가 후자를 본다.
bash "$INFRA/scripts/alert-send.sh" info "noext-$$" "noext test" 2>/dev/null | grep -qE "Alert (sent|suppressed)" \
  && PASSED=$((PASSED+1)) || { FAILURES=$((FAILURES+1)); echo "  ✗ alert-send 성공 코드"; }
expect_src "alert-send.sh"

echo "── route-result.sh (discord 모드)"
bash "$INFRA/bin/route-result.sh" discord "noext-test" "noext test message" jarvis-info >/dev/null 2>&1
expect_src "route-result.sh"

echo "── 실채널 원장 불변"
EGRESS_AFTER=$(wc -l < "$EGRESS" 2>/dev/null || echo 0)
[[ "$EGRESS_BEFORE" == "$EGRESS_AFTER" ]] && PASSED=$((PASSED+1)) || { FAILURES=$((FAILURES+1)); echo "  ✗ egress-audit.log 증가: $EGRESS_BEFORE → $EGRESS_AFTER"; }

echo "── 미설정이면 억제 안 함 (게이트가 기본 동작을 바꾸지 않는지)"
( unset JARVIS_NO_EXTERNAL; source "$INFRA/lib/discord-notify-bash.sh"; send_discord "x" "https://127.0.0.1:9/fake"; echo "rc=$?" ) 2>/dev/null | grep -q "rc=1" \
  && PASSED=$((PASSED+1)) || { FAILURES=$((FAILURES+1)); echo "  ✗ 미설정 시 실제 curl 경로로 가야 함(가짜 URL → rc=1)"; }

echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
