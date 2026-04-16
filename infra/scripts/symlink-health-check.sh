#!/usr/bin/env bash
set -euo pipefail
# symlink-health-check.sh — 디렉토리 symlink 건전성 자동 검증
#
# ~/.jarvis/ 의 핵심 디렉토리 symlink이 깨졌는지 매시간 검증.
# 깨지면 즉시 Discord + ntfy 알림 → 수동 복구 안내.
#
# 크론: 매시간 (e2e-test와 별도 — symlink은 e2e보다 빈번히 체크)

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LOG="${BOT_HOME}/logs/symlink-health.log"
ROUTE="${BOT_HOME}/bin/route-result.sh"

log() { echo "[$(date '+%F %T')] [symlink-health] $*" >> "$LOG" 2>/dev/null; }

# 필수 symlink 목록 (macOS bash 3 호환 — declare -A 미지원)
SYMLINK_LINKS="${BOT_HOME}/bin ${BOT_HOME}/scripts ${BOT_HOME}/lib ${BOT_HOME}/discord/lib ${BOT_HOME}/discord/discord-bot.js"

# 필수 파일 (symlink 아니어도 존재해야 함)
REQUIRED_FILES="${BOT_HOME}/discord/.env ${BOT_HOME}/config/monitoring.json ${BOT_HOME}/config/user_profiles.json"

BROKEN=""
MISSING=""

# symlink 검증
for link in $SYMLINK_LINKS; do
  if [[ ! -L "$link" ]]; then
    BROKEN="${BROKEN}\n- \`${link}\` — symlink 아님"
  elif [[ ! -e "$link" ]]; then
    BROKEN="${BROKEN}\n- \`${link}\` — dangling symlink (대상 없음)"
  fi
done

# 필수 파일 검증
for f in $REQUIRED_FILES; do
  if [[ ! -f "$f" ]]; then
    MISSING="${MISSING}\n- \`${f}\`"
  fi
done

if [[ -n "$BROKEN" || -n "$MISSING" ]]; then
  MSG="🚨 **Symlink Health Check 실패**"
  [[ -n "$BROKEN" ]] && MSG="${MSG}\n\n**깨진 symlink:**${BROKEN}"
  [[ -n "$MISSING" ]] && MSG="${MSG}\n\n**누락 파일:**${MISSING}"
  MSG="${MSG}\n\n복구: \`cd ~/jarvis && bash infra/scripts/symlink-repair.sh\`"

  log "FAIL: broken=${BROKEN} missing=${MISSING}"

  # Discord 알림
  if [[ -x "$ROUTE" ]]; then
    "$ROUTE" discord symlink-health "$MSG" jarvis-system 2>/dev/null || true
  fi

  # ntfy 직접 전송 (봇 다운 시에도 도달)
  _ntfy_topic=$(jq -r '.ntfy.topic // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || true)
  if [[ -n "$_ntfy_topic" ]]; then
    curl -sf --max-time 5 \
      -H "Title: Jarvis symlink 깨짐" \
      -H "Priority: urgent" \
      -d "$(echo -e "$MSG" | sed 's/[*`]//g')" \
      "https://ntfy.sh/${_ntfy_topic}" 2>/dev/null || true
  fi

  exit 1
else
  log "OK: 모든 symlink + 필수 파일 정상"
  exit 0
fi
