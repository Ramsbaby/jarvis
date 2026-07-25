#!/usr/bin/env bash
# lib/compat.sh — Cross-platform compatibility layer
# Usage: source "$(dirname "$0")/../lib/compat.sh"
#
# Provides OS-agnostic wrappers for macOS-specific commands.
# On Linux/Docker: uses PM2 equivalents instead of launchctl.

# JARVIS_HOME 은 "저장소 루트"(~/jarvis)다. 런타임 폴더가 아니다.
#   근거(2026-07-25 실측): 코드 176곳이 "$JARVIS_HOME/runtime/..." · "$JARVIS_HOME/infra/..." 로
#   루트를 가정하고, LaunchAgent 20개 모두 JARVIS_HOME=~/jarvis 를 주입한다.
# 정정 이력: 이전 값은 "${BOT_HOME:-${HOME}/jarvis/runtime}" 이었다. 그 경우
#   "$JARVIS_HOME/runtime/..." 이 ~/jarvis/runtime/runtime/... 으로 풀려 그림자 폴더에 데이터가 샜다.
#   BOT_HOME 은 한 단계 아래(런타임)를 가리키므로 JARVIS_HOME 의 대체값이 될 수 없다.
export JARVIS_HOME="${JARVIS_HOME:-${HOME}/jarvis}"
# 런타임 경로가 필요하면 이 변수를 쓴다 (루트/런타임 혼동 방지).
export JARVIS_RUNTIME="${JARVIS_RUNTIME:-${JARVIS_HOME}/runtime}"
export IS_MACOS=false
export IS_LINUX=false
export IS_DOCKER=false

case "$(uname -s)" in
  Darwin) export IS_MACOS=true ;;
  Linux)  export IS_LINUX=true ;;
esac

[[ -f /.dockerenv ]] && export IS_DOCKER=true

# launchctl load wrapper
launchctl_load() {
  local plist="$1"
  if $IS_MACOS; then
    launchctl load "$plist"
  else
    echo "[compat] launchctl_load skipped on non-macOS (use: pm2 start ecosystem.config.cjs)"
  fi
}

# launchctl unload wrapper
launchctl_unload() {
  local plist="$1"
  if $IS_MACOS; then
    launchctl unload "$plist"
  else
    echo "[compat] launchctl_unload skipped on non-macOS"
  fi
}

# 서비스 재시작 wrapper
# Usage: jarvis_restart <service_name>
# service_name: discord-bot | rag-watcher | watchdog | event-watcher
jarvis_restart() {
  local svc="${1:-jarvis-bot}"
  if $IS_MACOS; then
    launchctl kickstart -k "gui/$(id -u)/ai.jarvis.${svc}" 2>/dev/null || \
    launchctl stop "ai.jarvis.${svc}" && launchctl start "ai.jarvis.${svc}"
  else
    pm2 restart "$svc" 2>/dev/null || { echo "[compat] pm2 restart $svc failed" >&2; return 1; }
  fi
}

# 서비스 상태 확인
jarvis_status() {
  if $IS_MACOS; then
    launchctl list | grep jarvis
  else
    if command -v pm2 &>/dev/null; then pm2 list; else echo "[compat] pm2 not installed"; return 1; fi
  fi
}