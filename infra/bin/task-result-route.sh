#!/usr/bin/env bash
set -euo pipefail

# route-result.sh - Route results to Discord, ntfy, file, or alert
# Usage: route-result.sh <mode> <task-id> <message>

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
CONFIG="${BOT_HOME}/config/monitoring.json"

# --- Config check ---
[[ -f "$CONFIG" ]] || { echo "ERROR: $CONFIG not found" >&2; exit 1; }

# --- Discord 중복 전송 방어 게이트 ---
# 같은 TASK_ID가 DEDUP_WINDOW_S 이내 Discord로 이미 전송된 경우 차단
# 원인: run_cron 다중 호출, LaunchAgent+Nexus 이중 트리거 등 모든 경우 방어
_DEDUP_DIR="${BOT_HOME}/state/dedup"
_DEDUP_WINDOW_S="${DEDUP_WINDOW_S:-300}"  # 기본 5분, 환경변수로 조정 가능
mkdir -p "$_DEDUP_DIR"

_discord_dedup_check() {
    local task_id="$1"
    local channel="${2:-default}"
    local dedup_key="${task_id}__${channel}"
    local dedup_file="${_DEDUP_DIR}/${dedup_key}.last_sent"
    local now
    now=$(date +%s)
    if [[ -f "$dedup_file" ]]; then
        local last_sent
        last_sent=$(cat "$dedup_file" 2>/dev/null || echo 0)
        local elapsed=$(( now - last_sent ))
        if [[ $elapsed -lt $_DEDUP_WINDOW_S ]]; then
            echo "DEDUP_SKIP: ${task_id} — ${elapsed}s 전 이미 전송 (차단 창: ${_DEDUP_WINDOW_S}s)" >&2
            return 1  # 차단
        fi
    fi
    echo "$now" > "$dedup_file"
    return 0  # 허용
}

# --- Shared libraries ---
source "${BOT_HOME}/lib/ntfy-notify.sh"
source "${BOT_HOME}/lib/discord-notify-bash.sh"

# --- Arguments ---
MODE="${1:?Usage: route-result.sh <discord|ntfy|alert|file|all> TASK_ID MESSAGE [CHANNEL]}"
TASK_ID="${2:?Usage: route-result.sh MODE TASK_ID MESSAGE}"
MESSAGE="${3:?Usage: route-result.sh MODE TASK_ID MESSAGE}"
CHANNEL="${4:-}"  # optional: channel name from tasks.json discordChannel field

# --- Marker extraction (before clean_message) ---
# CHART_DATA:<json>  → QuickChart 이미지 embed
# EMBED_DATA:<json>  → Discord rich embed (color card)
# CV2_DATA:<json>    → Discord Components V2 container card
CHART_JSON=""
EMBED_JSON=""
CV2_JSON=""
if printf '%s' "$MESSAGE" | grep -q '^CHART_DATA:'; then
    CHART_JSON=$(printf '%s' "$MESSAGE" | grep '^CHART_DATA:' | head -1 | sed 's/^CHART_DATA://')
    MESSAGE=$(printf '%s' "$MESSAGE" | grep -v '^CHART_DATA:' || true)
fi
if printf '%s' "$MESSAGE" | grep -q '^EMBED_DATA:'; then
    EMBED_JSON=$(printf '%s' "$MESSAGE" | grep '^EMBED_DATA:' | head -1 | sed 's/^EMBED_DATA://')
    MESSAGE=$(printf '%s' "$MESSAGE" | grep -v '^EMBED_DATA:' || true)
fi
if printf '%s' "$MESSAGE" | grep -q 'CV2_DATA:'; then
    CV2_JSON=$(printf '%s' "$MESSAGE" | grep 'CV2_DATA:' | head -1 | sed 's/.*CV2_DATA://')
    MESSAGE=$(printf '%s' "$MESSAGE" | grep -v 'CV2_DATA:' || true)
fi

# --- Message quality filter (central pre-send hook) ---
# Strips internal debug/noise lines before sending to any external channel
clean_message() {
    local msg="$1"
    # Remove noise patterns: internal paths, debug logs, SQL artifacts
    msg=$(echo "$msg" | grep -vE \
        '^\[insight\] Saved to |^sent id=|^SELECT .last_insert|^\[debug\]|^\[trace\]|^Fallback:|^NODE_PATH=|^cd /tmp/' \
        || true)
    # Trim leading/trailing blank lines
    msg=$(echo "$msg" | sed -e '/./,$!d' -e ':a' -e '/^[[:space:]]*$/{ $d; N; ba' -e '}')
    # Strip URLs (Discord 썸네일/임베드 방지)
    # 마크다운 링크 [text](url) → text만 보존, 나머지 URL은 제거
    msg=$(echo "$msg" | sed -E 's|\[([^]]*)\]\(https?://[^ )>]*\)|\1|g; s|https?://[^ )>]+||g')
    # If everything got filtered, keep original (safety)
    # 단, 원본이 순수 노이즈(sent id=, SELECT, debug 패턴)만 있으면 복원 금지
    if [[ -z "$msg" ]]; then
        local orig_clean
        orig_clean=$(echo "$1" | grep -vE \
            '^\[insight\] Saved to |^sent id=|^SELECT .last_insert|^\[debug\]|^\[trace\]|^Fallback:|^NODE_PATH=|^cd /tmp/' \
            | sed '/./!d' || true)
        if [[ -n "$orig_clean" ]]; then
            msg="$1"
        fi
    fi
    echo "$msg"
}

MESSAGE=$(clean_message "$MESSAGE")

# --- Format for Discord (table→list, heading normalization, etc.) ---
FORMAT_SCRIPT="${BOT_HOME}/bin/format-discord.mjs"
if [[ -f "$FORMAT_SCRIPT" ]]; then
    FORMATTED=$(printf '%s' "$MESSAGE" | node "$FORMAT_SCRIPT" 2>/dev/null) || true
    if [[ -n "$FORMATTED" ]]; then MESSAGE="$FORMATTED"; fi
fi

# --- Webhook URL resolver ---
get_webhook_url() {
    local url
    if [[ -n "$CHANNEL" ]]; then
        url=$(jq -r --arg ch "$CHANNEL" '.webhooks[$ch] // .webhook.url' "$CONFIG")
        if [[ -z "$url" || "$url" == "null" ]]; then url=$(jq -r '.webhook.url' "$CONFIG"); fi
    else
        url=$(jq -r '.webhook.url' "$CONFIG")
    fi
    printf '%s' "$url"
}

# --- Rich embed sender (Discord color card) ---
send_embed() {
    local embed_json="$1"
    local webhook_url
    webhook_url=$(get_webhook_url)
    local payload
    payload=$(jq -n --argjson embed "$embed_json" '{"embeds":[$embed], "allowed_mentions": {"parse": []}}')
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload") || true
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        echo "WARN: embed webhook returned HTTP $http_code" >&2
    fi
}

# --- CV2 sender (Discord Components V2 container card) ---
send_cv2() {
    local cv2_json="$1"
    local webhook_url
    webhook_url=$(get_webhook_url)

    local payload
    payload=$(node -e "
const cv2 = JSON.parse(process.argv[1]);
const { color = 5763719, blocks = [] } = cv2;
const comps = blocks.map(b => ({
  type: 10,
  content: (b && typeof b === 'object' && b.content) ? b.content : String(b)
})).filter(b => b.content && b.content.trim());
if (!comps.length) process.exit(0);
const container = { type: 17, accent_color: color, components: comps };
console.log(JSON.stringify({ flags: 32768, components: [container], allowed_mentions: { parse: [] } }));
" "$cv2_json" 2>/dev/null) || return 0

    if [[ -z "$payload" ]]; then return 0; fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload") || true
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        echo "WARN: cv2 webhook returned HTTP $http_code" >&2
    fi
}

# --- Chart embed sender (QuickChart.io → Discord image embed) ---
send_chart_embed() {
    local chart_json="$1"
    local webhook_url
    webhook_url=$(get_webhook_url)

    # Build QuickChart GET URL (node for safe URL encoding)
    local chart_url
    chart_url=$(node -e "process.stdout.write('https://quickchart.io/chart?w=700&h=350&bkg=white&c=' + encodeURIComponent(process.argv[1]))" "$chart_json" 2>/dev/null) || return 0
    if [[ -z "$chart_url" ]]; then return 0; fi

    local payload
    payload=$(jq -n --arg url "$chart_url" '{"embeds":[{"image":{"url":$url},"color":3447003}], "allowed_mentions": {"parse": []}}')
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload") || true
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        echo "WARN: chart embed webhook returned HTTP $http_code" >&2
    fi
}

# --- Noise gate: 순수 성공/무변경 메시지 → 전송 안 함 (로그만) ---
_is_noise() {
    local msg="$1"
    local trimmed
    trimmed=$(echo "$msg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n')
    # 20자 미만 단순 완료
    if [[ ${#trimmed} -lt 20 ]]; then
        case "$trimmed" in
            *정상*|*완료*|*성공*|*ok*|*OK*|*변경*없*|*no*change*|*No*output*) return 0 ;;
        esac
    fi
    # 순수 성공 패턴 (전체가 이 패턴이면 노이즈)
    local cleaned
    cleaned=$(echo "$msg" | grep -viE '^[[:space:]]*$|^정상|^변경.*없|^no (changes|output|new)|^완료|^성공|^ok$|^all (good|clear|pass)' || true)
    if [[ -z "$cleaned" ]]; then return 0; fi
    return 1
}

# --- Severity detection: 메시지 내용으로 심각도 판별 ---
_detect_severity() {
    local msg="$1"
    if echo "$msg" | grep -qiE '실패|FAIL|error|critical|장애|급락|OOM|exit [1-9]|ABORTED|crash'; then
        echo "error"
    elif echo "$msg" | grep -qiE '경고|WARN|주의|임계|timeout|stale|degraded|CB.*임박'; then
        echo "warning"
    else
        echo "info"
    fi
}

# --- Standard header: 태스크명 + 시각 + 상태 이모지 자동 삽입 ---
_build_header() {
    local task_id="$1"
    local severity="$2"
    local emoji
    case "$severity" in
        error)   emoji="🔴" ;;
        warning) emoji="🟡" ;;
        *)       emoji="🟢" ;;
    esac
    local kst_time
    kst_time=$(TZ=Asia/Seoul date '+%H:%M' 2>/dev/null || date '+%H:%M')
    echo "> ${emoji} **${task_id}** · ${kst_time} KST"
}

# --- Embed color by severity (Uptime Kuma 패턴) ---
_severity_embed_color() {
    case "$1" in
        error)   echo "15548997" ;;  # red
        warning) echo "16705372" ;;  # yellow
        *)       echo "5763719"  ;;  # green
    esac
}

# --- Discord: 2000-char chunking (task-specific; simple sends use lib/discord-notify-bash.sh) ---
route_to_discord() {
    local message="$1"
    local webhook_url
    webhook_url=$(get_webhook_url)
    local total=${#message}
    local offset=0

    # CV2_DATA가 있으면 텍스트 중복 전송 생략 — 카드가 메인 콘텐츠
    if [[ -z "$CV2_JSON" ]]; then
        while [[ $offset -lt $total ]]; do
            local chunk="${message:$offset:1990}"
            local payload
            payload=$(jq -n --arg content "$chunk" '{"content": $content, "flags": 4, "allowed_mentions": {"parse": []}}')
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
                -H "Content-Type: application/json" \
                -d "$payload") || true
            if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
                echo "ERROR: Discord webhook returned HTTP $http_code for task $TASK_ID" >&2
            fi
            offset=$((offset + 1990))
            # Rate limit protection between chunks
            if [[ $offset -lt $total ]]; then sleep 1; fi
        done
    fi

    # --- Rich embed (if EMBED_DATA present, send as color card) ---
    if [[ -n "$EMBED_JSON" ]]; then
        sleep 0.3
        send_embed "$EMBED_JSON"
    fi

    # --- CV2 card (if CV2_DATA present, send as Components V2 container) ---
    if [[ -n "$CV2_JSON" ]]; then
        sleep 0.3
        send_cv2 "$CV2_JSON"
    fi

    # --- Chart embed (append after text/embed if CHART_JSON present) ---
    if [[ -n "$CHART_JSON" ]]; then
        sleep 0.5
        send_chart_embed "$CHART_JSON"
    fi
}


# --- Route by mode ---
case "$MODE" in
    discord)
        # Dedup gate: 같은 태스크가 DEDUP_WINDOW_S 이내 이미 Discord로 전송됐으면 차단
        if ! _discord_dedup_check "$TASK_ID" "${CHANNEL:-default}"; then
            exit 0
        fi
        # Noise gate: 순수 성공 메시지는 Discord 전송 생략
        if [[ -z "$EMBED_JSON" && -z "$CV2_JSON" && -z "$CHART_JSON" ]] && _is_noise "$MESSAGE"; then
            echo "NOISE_GATE: $TASK_ID — 순수 성공, Discord 전송 생략" >&2
        else
            # Severity 판별 + 표준 헤더 삽입
            _SEVERITY=$(_detect_severity "$MESSAGE")
            _HEADER=$(_build_header "$TASK_ID" "$_SEVERITY")
            MESSAGE="${_HEADER}
${MESSAGE}"
            # error/warning → 자동 embed 래핑 (EMBED_DATA가 없는 경우만)
            if [[ -z "$EMBED_JSON" && "$_SEVERITY" != "info" ]]; then
                _COLOR=$(_severity_embed_color "$_SEVERITY")
                # 메시지 길이가 4096(embed description 한도) 이내면 embed로
                if [[ ${#MESSAGE} -le 4000 ]]; then
                    EMBED_JSON="{\"description\":$(printf '%s' "$MESSAGE" | jq -Rs .),\"color\":${_COLOR}}"
                    route_to_discord ""  # 빈 텍스트 + embed
                else
                    route_to_discord "$MESSAGE"
                fi
            else
                route_to_discord "$MESSAGE"
            fi
        fi
        ;;
    ntfy)
        send_ntfy "${BOT_NAME:-Bot}: $TASK_ID" "$MESSAGE"
        ;;
    alert)
        "$BOT_HOME/scripts/alert.sh" warning "$TASK_ID" "$MESSAGE"
        ;;
    file)
        # No-op: results already saved by ask-claude.sh
        echo "Result for $TASK_ID saved to results directory."
        ;;
    all)
        route_to_discord "$MESSAGE"
        send_ntfy "${BOT_NAME:-Bot}: $TASK_ID" "$MESSAGE"
        echo "Result for $TASK_ID saved to results directory."
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        echo "Valid modes: discord, ntfy, alert, file, all" >&2
        exit 2
        ;;
esac