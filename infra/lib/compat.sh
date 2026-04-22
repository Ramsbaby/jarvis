#!/usr/bin/env bash
# lib/compat.sh — Cross-platform compatibility layer
# Usage: source "$(dirname "$0")/../lib/compat.sh"
#
# Provides OS-agnostic wrappers for macOS-specific commands.
# On Linux/Docker: uses PM2 equivalents instead of launchctl.

# A2 마이그레이션(2026-04-17) 이후 런타임 경로는 ~/jarvis/runtime 단일 기준.
# 구버전 경로(~/.jarvis, ~/.local/share/jarvis)는 호환성 심링크로만 유지됨.
export JARVIS_HOME="${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}"
export IS_MACOS=false
export IS_LINUX=false
export IS_DOCKER=false

case "$(uname -s)" in
  Darwin) IS_MACOS=true ;;
  Linux)  IS_LINUX=true ;;
esac

[[ -f /.dockerenv ]] && IS_DOCKER=true

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