#!/usr/bin/env bash
set -euo pipefail

# update-broadcast.sh - Git 변경 감지 → jarvis-system Discord 알림
# 5분 간격 크론. 새 커밋 감지 시 변경 내용 + 조치 필요 여부를 Discord에 전송.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
STATE_FILE="$BOT_HOME/state/triggers/update-broadcast.last-sha"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
LOG="$BOT_HOME/logs/update-broadcast.log"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# --- Webhook ---
get_webhook_url() {
    [[ -f "$MONITORING_CONFIG" ]] || return 1
    jq -r '.webhooks["jarvis-system"] // .webhook.url // ""' "$MONITORING_CONFIG"
}

send_embed() {
    local title="$1" description="$2" color="$3"
    local webhook_url
    webhook_url=$(get_webhook_url) || return 1
    [[ -z "$webhook_url" ]] && return 1

    local embed_json
    embed_json=$(jq -n \
        --arg user "Jarvis" \
        --arg title "$title" \
        --arg desc "$description" \
        --argjson color "$color" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        --arg footer "$(hostname -s) · $(date '+%H:%M')" \
        '{"username":$user,"embeds":[{"title":$title,"description":$desc,"color":$color,"timestamp":$ts,"footer":{"text":$footer}}]}')

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
        -H "Content-Type: application/json" -d "$embed_json" 2>&1)
    [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]
}

# --- 커밋 메시지 → 한 줄 요약 (prefix 제거, 첫 문장만) ---
clean_commit_msg() {
    echo "$1" | sed -E 's/^[a-z]+(\([^)]*\))?:[[:space:]]*//' | cut -c1-80
}

# --- 조치 필요 여부 판단 ---
detect_action() {
    local files="$1"
    if echo "$files" | grep -qE '^discord/(discord-bot\.js|lib/)'; then
        echo "⚠️ 봇 재시작 권장"
        return
    fi
    if echo "$files" | grep -qE '^(config/tasks\.json|config/monitoring\.json|discord/personas\.json|discord/locales/)'; then
        echo "⚠️ 봇 재시작 권장"
        return
    fi
    if echo "$files" | grep -qE '^(bin/|lib/)'; then
        echo "ℹ️ 다음 크론부터 자동 적용"
        return
    fi
    # .md, .example, docs, .github 등만 바뀐 경우
    if ! echo "$files" | grep -qvE '\.(md|txt|example)$|^\.github/|^vault-starter/|^adr/|^CONTRIBUTING|^ROADMAP|^README|^LICENSE'; then
        echo "✅ 시스템 영향 없음"
        return
    fi
    echo "✅ 자동 적용됨"
}

# ============================================================================
# Main
# ============================================================================
if [[ ! -d "$BOT_HOME/.git" ]]; then exit 0; fi

current_sha=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null || true)
[[ -z "$current_sha" ]] && exit 0

if [[ ! -f "$STATE_FILE" ]]; then
    echo "$current_sha" > "$STATE_FILE"
    exit 0
fi

last_sha=$(cat "$STATE_FILE" 2>/dev/null || echo "")
[[ -z "$last_sha" ]] && { echo "$current_sha" > "$STATE_FILE"; exit 0; }
[[ "$current_sha" == "$last_sha" ]] && exit 0

if ! git -C "$BOT_HOME" cat-file -t "$last_sha" &>/dev/null; then
    send_embed "⚠️ Git 히스토리 리셋" "force push 또는 rebase 감지됨" "16776960" || true
    echo "$current_sha" > "$STATE_FILE"
    exit 0
fi

log "변경 감지: ${last_sha:0:8} → ${current_sha:0:8}"

# --- 변경 파일 + 커밋 메시지 수집 ---
changed_files=$(git -C "$BOT_HOME" diff --name-only "$last_sha..HEAD" 2>/dev/null || echo "")
commit_count=$(git -C "$BOT_HOME" rev-list --count "$last_sha..HEAD" 2>/dev/null || echo "0")

# 커밋 메시지에서 핵심 내용 추출 (feat > fix > 나머지 순, 최대 3개)
commit_subjects=""
for prefix in "feat:" "fix:" ""; do
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        msg="${line#* }"  # SHA 제거
        if [[ -z "$prefix" ]] || [[ "$msg" == ${prefix}* ]]; then
            cleaned=$(clean_commit_msg "$msg")
            # 중복 방지
            if [[ "$commit_subjects" != *"$cleaned"* ]]; then
                commit_subjects+="• ${cleaned}"$'\n'
            fi
        fi
    done <<< "$(git -C "$BOT_HOME" log --oneline --no-decorate "$last_sha..HEAD" 2>/dev/null)"
    # 3개까지만
    line_count=$(echo -n "$commit_subjects" | grep -c '•' || true)
    if (( line_count >= 3 )); then break; fi
done

# 3개 초과 시 잘라내기
if (( commit_count > 3 )); then
    commit_subjects=$(echo "$commit_subjects" | head -3)
    commit_subjects+="  외 $((commit_count - 3))건"$'\n'
fi

# 조치 필요 여부
action_line=$(detect_action "$changed_files")

# --- 메시지 조립 ---
title="🔄 Jarvis 업데이트"
description="${commit_subjects}${action_line}"

# 봇 재시작 필요하면 노랑, 아니면 파랑
color=3447003
if echo "$action_line" | grep -q "재시작"; then
    color=16776960
fi

if send_embed "$title" "$description" "$color"; then
    echo "$current_sha" > "$STATE_FILE"
    log "브로드캐스트 완료 (${commit_count}건)"
else
    log "브로드캐스트 실패"
fi
