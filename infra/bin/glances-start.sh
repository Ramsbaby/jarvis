#!/bin/bash

export PATH="/opt/homebrew/bin:$PATH"

# 로그 파일 위치
BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
LOG_FILE="${BOT_HOME}/logs/glances.log"
ERROR_FILE="${BOT_HOME}/logs/glances.error.log"

# 기존 glances 프로세스 종료
pkill -f "glances.*webserver" || true

# glances 실행
exec glances --webserver --port 61208 --disable-plugin gpu --time 2 >> "$LOG_FILE" 2>> "$ERROR_FILE"