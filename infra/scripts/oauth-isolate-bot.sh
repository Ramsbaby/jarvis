#!/usr/bin/env bash
# oauth-isolate-bot.sh — 봇·크론을 1년 long-lived 토큰으로 격리 (reuse race 구조적 소멸)
#
# 배경: 2026-05-30 reuse-race 사고 — credentials.json 1개를 봇·크론·인터랙티브·워크플로가 공유,
#       회전형 refresh_token을 동시 소비 → 토큰 패밀리 revoke → 반복 사망.
# 해법: 봇·크론을 setup-token이 발급한 1년 inference-only 토큰(CLAUDE_CODE_OAUTH_TOKEN)으로 분리.
#       이 토큰은 refresh 로직을 안 타므로(갱신키 없음) reuse race를 일으킬 주체가 못 됨.
#       인터랙티브/워크플로는 메인 ~/.claude 유지 → 죽어도 /login 1회, 봇·크론은 1년간 무사.
#
# 전제: 주인님이 먼저 발급:  CLAUDE_CONFIG_DIR=~/.claude-bot claude setup-token
#       → 출력된 sk-ant-oat01-... 토큰을 인자로 전달.
# 사용:  bash oauth-isolate-bot.sh '<sk-ant-oat01-...>'
# 롤백:  bash oauth-isolate-bot.sh --rollback
#
# 안전장치: 토큰이 실제로 살아있지 않으면(curl 200 아니면) 봇을 절대 안 건드리고 중단.

set -euo pipefail

BOT_PLIST="${HOME}/Library/LaunchAgents/ai.jarvis.discord-bot.plist"
BOT_TOKEN_FILE="${HOME}/.claude-bot/.long-lived-token"   # 봇 전용 토큰 보관 (600)
CRONTAB_MARK="CLAUDE_CODE_OAUTH_TOKEN"
TS="$(date +%Y%m%d-%H%M%S)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 롤백 모드 ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--rollback" ]]; then
  log "롤백 시작"
  latest_plist=$(ls -t "${BOT_PLIST}.iso-bak-"* 2>/dev/null | head -1 || true)
  if [[ -n "$latest_plist" ]]; then
    cp -p "$latest_plist" "$BOT_PLIST"
    log "복원: bot plist ← $(basename "$latest_plist")"
  fi
  latest_cron=$(ls -t /tmp/jarvis-crontab.iso-bak-* 2>/dev/null | head -1 || true)
  [[ -n "$latest_cron" ]] && crontab "$latest_cron" && log "복원: crontab ← $latest_cron"
  launchctl kickstart -k "gui/$(id -u)/ai.jarvis.discord-bot" 2>/dev/null && log "봇 재시작"
  log "✅ 롤백 완료 — 봇·크론이 다시 메인 ~/.claude 사용"
  exit 0
fi

# ── 인자 검증 ────────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
  echo "사용: $0 '<sk-ant-oat01-... (claude setup-token 발급 토큰)>'" >&2
  echo "  먼저: CLAUDE_CONFIG_DIR=~/.claude-bot claude setup-token" >&2
  exit 1
fi
NEW_TOKEN="$1"
if [[ ! "$NEW_TOKEN" =~ ^sk-ant-oat01- ]]; then
  echo "❌ 토큰 형식 오류 — sk-ant-oat01- 접두사 필요 (받은 값 길이: ${#NEW_TOKEN})" >&2
  exit 1
fi

# ── 안전장치: 새 토큰이 실제로 살아있는지 검증 (봇 건드리기 전에) ──────────────
log "새 토큰 사전 검증 (API ping)..."
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST https://api.anthropic.com/v1/messages \
  -H "authorization: Bearer ${NEW_TOKEN}" -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
  --data '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' 2>/dev/null || echo "000")
if [[ "$HTTP" != "200" ]]; then
  log "❌ 중단 — 새 토큰 헬스 HTTP ${HTTP} (200 아님). 봇을 건드리지 않습니다."
  log "   토큰을 다시 발급하십시오: CLAUDE_CONFIG_DIR=~/.claude-bot claude setup-token"
  exit 2
fi
log "✅ 새 토큰 살아있음 (HTTP 200) — 격리 적용 진행"

# ── 메인과 다른 토큰인지 확인 (같으면 격리 의미 없음) ─────────────────────────
MAIN_AT=$(node -e "const d=JSON.parse(require('fs').readFileSync('${HOME}/.claude/.credentials.json','utf-8'));process.stdout.write((d.claudeAiOauth?.accessToken||'').slice(0,32))" 2>/dev/null || echo "main")
if [[ "${NEW_TOKEN:0:32}" == "$MAIN_AT" ]]; then
  log "⚠️ 경고 — 새 토큰이 메인 accessToken과 동일. 별도 발급 토큰이 아닙니다. 중단."
  exit 2
fi
log "✅ 새 토큰이 메인과 다름 — 진정한 격리"

# ── 토큰 보관 (600) ──────────────────────────────────────────────────────────
mkdir -p "$(dirname "$BOT_TOKEN_FILE")"
umask 077
printf '%s\n' "$NEW_TOKEN" > "$BOT_TOKEN_FILE"
chmod 600 "$BOT_TOKEN_FILE"
log "✅ 봇 토큰 보관: ${BOT_TOKEN_FILE} (600)"

# ── 적용 1: 봇 plist에 CLAUDE_CODE_OAUTH_TOKEN 주입 ──────────────────────────
cp -p "$BOT_PLIST" "${BOT_PLIST}.iso-bak-${TS}"
if /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:CLAUDE_CODE_OAUTH_TOKEN" "$BOT_PLIST" &>/dev/null; then
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:CLAUDE_CODE_OAUTH_TOKEN ${NEW_TOKEN}" "$BOT_PLIST"
else
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:CLAUDE_CODE_OAUTH_TOKEN string ${NEW_TOKEN}" "$BOT_PLIST"
fi
log "✅ 봇 plist에 CLAUDE_CODE_OAUTH_TOKEN 주입 (백업: .iso-bak-${TS})"

# ── 적용 2: crontab 맨 위에 CLAUDE_CODE_OAUTH_TOKEN (모든 크론 일괄, DRY) ──────
crontab -l > "/tmp/jarvis-crontab.iso-bak-${TS}" 2>/dev/null || true
if crontab -l 2>/dev/null | grep -q "^${CRONTAB_MARK}="; then
  # 기존 라인 교체
  crontab -l 2>/dev/null | sed "s|^${CRONTAB_MARK}=.*|${CRONTAB_MARK}=${NEW_TOKEN}|" | crontab -
  log "✅ crontab CLAUDE_CODE_OAUTH_TOKEN 갱신 (백업: /tmp/jarvis-crontab.iso-bak-${TS})"
else
  { echo "${CRONTAB_MARK}=${NEW_TOKEN}"; crontab -l 2>/dev/null; } | crontab -
  log "✅ crontab 맨 위 CLAUDE_CODE_OAUTH_TOKEN 추가 (백업: /tmp/jarvis-crontab.iso-bak-${TS})"
fi

# ── 봇 재시작 + 생존 검증 ────────────────────────────────────────────────────
log "봇 재시작 — 격리 토큰 반영"
launchctl kickstart -k "gui/$(id -u)/ai.jarvis.discord-bot" 2>/dev/null || log "⚠️ kickstart 실패"
sleep 5
BOT_PID=$(launchctl list 2>/dev/null | grep "ai.jarvis.discord-bot" | awk '{print $1}')
if [[ -n "$BOT_PID" && "$BOT_PID" != "-" ]]; then
  log "✅ 봇 살아있음 (PID ${BOT_PID})"
else
  log "⚠️ 봇 PID 확인 실패 — 'launchctl list | grep discord-bot' 점검. 문제 시 즉시 롤백: bash $0 --rollback"
fi

# ── Ledger ───────────────────────────────────────────────────────────────────
LEDGER="${HOME}/jarvis/runtime/ledger/oauth-refresh-ledger.jsonl"
mkdir -p "$(dirname "$LEDGER")"
printf '{"ts":"%s","result":"isolation","action":"bot-isolated-to-longlived-token","plist_backup":".iso-bak-%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TS}" >> "$LEDGER"

log ""
log "🎉 격리 완료 — 봇·크론은 1년 토큰(env), 인터랙티브/워크플로는 메인 ~/.claude."
log "   이제 워크플로를 마음껏 써도 봇·크론 무사. 메인 죽으면 /login 1회(봇 무관)."
log "   롤백: bash $0 --rollback"
