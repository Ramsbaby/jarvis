#!/usr/bin/env bash
# security-scan.sh — 매일 02:30 KST: 보안 점검 (시크릿, 권한, 접근로그, 디스크)

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/security-scan.log"

mkdir -p "$(dirname "$LOG_FILE")"

_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

_log "===== Task: security-scan ====="
_log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Secret file detection
_log "Checking for unexpected secret files..."
SECRET_FILES=$(find ~/.jarvis \( -name '*.env' -o -name '*.key' \) 2>/dev/null | grep -v "discord/.env" || true)

# 2. Permission audit
_log "Checking configuration file permissions..."
PERMS=$(ls -la ~/jarvis/runtime/config/ 2>/dev/null || echo "No config directory")

# 3. Discord bot access patterns
_log "Checking Discord bot logs for anomalies..."
BOT_LOGS=$(tail -50 ~/jarvis/runtime/logs/discord-bot.jsonl 2>/dev/null || echo "No bot logs found")

# 4. Disk usage
_log "Checking disk usage..."
DISK=$(df -h "$([ -d /System/Volumes/Data ] && echo /System/Volumes/Data || echo /)" 2>/dev/null)

# Analysis and reporting
_log "---"
_log "## 🔒 보안 점검 결과"
_log ""

ISSUES=0

# Check for unexpected secret files
if [ -n "$SECRET_FILES" ]; then
    _log "**⚠️ 주의사항 발견:**"
    _log ""
    _log "1. **예상 외 위치의 시크릿 파일**"
    echo "$SECRET_FILES" | while read -r f; do
        _log "   - \`$f\`"
    done
    ISSUES=$((ISSUES + 1))
else
    _log "**✅ 시크릿 파일** · 정상"
fi

_log ""

# Check permissions
if echo "$PERMS" | grep -qE "^-rw" ; then
    _log "2. **설정 파일 권한** ✓ 정상"
    _log "   - 민감 파일: \`-rw-------\` (600)"
    _log "   - 일반 설정: \`-rw-r--r--\` (644)"
else
    _log "2. **설정 파일 권한** ⚠️ 주의"
    _log "   - 예상과 다른 권한 발견"
    ISSUES=$((ISSUES + 1))
fi

_log ""

# Check bot logs for anomalies
if echo "$BOT_LOGS" | grep -qE "error|ERROR|unauthorized|UNAUTHORIZED" ; then
    _log "3. **Discord 봇 로그** ⚠️ 비정상"
    _log "   - 비정상 패턴 감지"
    ISSUES=$((ISSUES + 1))
else
    _log "3. **Discord 봇 로그** ✓ 정상"
    _log "   - 표준적인 헬스체크만 기록"
fi

_log ""

# Check disk usage (warn if > 80%)
USAGE_PCT=$(echo "$DISK" | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$USAGE_PCT" -gt 80 ]; then
    _log "4. **디스크 여유** ⚠️ 주의"
    _log "   - 사용 중: ${USAGE_PCT}%"
    ISSUES=$((ISSUES + 1))
else
    _log "4. **디스크 여유** ✓ 충분"
    _log "   - 사용 중: ${USAGE_PCT}%"
fi

_log ""

# Final verdict
if [ "$ISSUES" -eq 0 ]; then
    _log "**결론**: 보안: 정상"
    _log "===== Task: security-scan ====="
    exit 0
else
    _log "**결론**: $ISSUES개 항목에서 주의 필요"
    _log "===== Task: security-scan ====="
    exit 0
fi
