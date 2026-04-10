#!/usr/bin/env bash
set -euo pipefail

# lancedb-alert.sh — LanceDB 경고를 jarvis-system에 embed+Compact 버튼으로 전송
# Usage: lancedb-alert.sh <size_mb>

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SIZE_MB="${1:?Usage: lancedb-alert.sh <size_mb>}"
CHANNEL_ID="${JARVIS_SYSTEM_CHANNEL_ID:-}"  # jarvis-system

# Load DISCORD_TOKEN
# shellcheck source=/dev/null
source <(grep -E '^DISCORD_TOKEN=' "${BOT_HOME}/discord/.env" 2>/dev/null || true)
DISCORD_TOKEN="${DISCORD_TOKEN:-}"

if [[ -z "$DISCORD_TOKEN" ]]; then
    echo "ERROR: DISCORD_TOKEN not found in ${BOT_HOME}/discord/.env" >&2
    exit 1
fi

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
FOOTER_TEXT="macmini · $(date '+%H:%M')"

PAYLOAD=$(jq -n \
    --arg mb "$SIZE_MB" \
    --arg ts "$TIMESTAMP" \
    --arg footer "$FOOTER_TEXT" \
    '{
        embeds: [{
            title: "⚠️ LanceDB 용량 경고",
            description: ("현재 **" + $mb + "MB** — 1GB 초과. 방치 시 2GB+ 급증 선례 있음."),
            color: 16776960,
            timestamp: $ts,
            footer: { text: $footer }
        }],
        components: [{
            type: 1,
            components: [{
                type: 2,
                style: 4,
                label: "🗜️ Compact 실행",
                custom_id: "lancedb_compact"
            }]
        }]
    }')

http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages" \
    -H "Authorization: Bot ${DISCORD_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
    echo "LanceDB alert sent to jarvis-system (${SIZE_MB}MB)"
else
    echo "WARN: Discord API returned HTTP $http_code" >&2
    exit 1
fi
