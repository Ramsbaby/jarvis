#!/usr/bin/env bash
set -euo pipefail

# update-broadcast.sh - Git 변경 감지 → jarvis-system Discord 알림
# 5분 간격 크론. 새 커밋 감지 시 한글 요약 + 조치 필요 여부를 Discord에 전송.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

# Prevent nested claude
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
STATE_FILE="$BOT_HOME/state/triggers/update-broadcast.last-sha"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
LOG="$BOT_HOME/logs/update-broadcast.log"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# 디버깅: 크론 실행 확인
log "=== 스크립트 실행 시작 (PID: $$) ==="

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# --- Webhook ---
get_webhook_url() {
    [[ -f "$MONITORING_CONFIG" ]] || return 1
    jq -r '.webhooks["jarvis-system"] // .webhook.url // ""' "$MONITORING_CONFIG"
}

send_embed() {
    local title="$1" description="$2" color="$3" channel="${4:-jarvis-system}"
    local webhook_url
    webhook_url=$(jq -r --arg ch "$channel" '.webhooks[$ch] // .webhook.url // ""' "$MONITORING_CONFIG" 2>/dev/null || echo "")
    if [[ -z "$webhook_url" ]]; then return 1; fi

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

# --- 조치 필요 여부 판단 ---
detect_action() {
    local files="$1"
    if echo "$files" | grep -qE '^discord/(discord-bot\.js|lib/)'; then
        echo "⚠️ 봇 재시작 권장"; return
    fi
    if echo "$files" | grep -qE '^(config/tasks\.json|config/monitoring\.json|discord/personas\.json|discord/locales/)'; then
        echo "⚠️ 봇 재시작 권장"; return
    fi
    if echo "$files" | grep -qE '^(bin/|lib/)'; then
        echo "ℹ️ 다음 크론부터 자동 적용"; return
    fi
    if ! echo "$files" | grep -qvE '\.(md|txt|example)$|^\.github/|^vault-starter/|^adr/|^CONTRIBUTING|^ROADMAP|^README|^LICENSE'; then
        echo "✅ 시스템 영향 없음"; return
    fi
    echo "✅ 자동 적용됨"
}

# --- Auto-deploy (새 커밋 감지 시) ---
auto_deploy() {
    local changed_files="$1"

    # 봇 재시작이 필요한 변경인지 판단 (detect_action 함수 재활용)
    local action
    action=$(detect_action "$changed_files")

    if echo "$action" | grep -q "봇 재시작 권장"; then
        log "Auto-deploy: 봇 재시작 필요 변경 감지 — smoke test 시작"
        # 로컬 커밋이 이미 소스 오브 트루스 — origin은 public export 타겟이므로 merge 불필요
        # (origin/main은 sanitized 버전이라 merge 시 충돌 발생)

        # smoke test + 재시작
        if bash "$BOT_HOME/scripts/deploy-with-smoke.sh" >> "$LOG" 2>&1; then
            log "Auto-deploy: smoke test 통과, 봇 재시작 완료"
            send_embed "🚀 자동 배포 완료" "smoke test 통과 · 봇 재시작 성공" 3066993 "jarvis-system" || true
        else
            log "Auto-deploy: smoke test 실패, git 롤백"
            # 롤백 전 gitignore 비추적 운영 파일 백업 (git reset이 복원 못하므로)
            local _ts; _ts=$(date +%s)
            cp "$BOT_HOME/config/tasks.json" "$BOT_HOME/config/tasks.json.pre-rollback-${_ts}" 2>/dev/null || true
            git -C "$BOT_HOME" reset --hard HEAD~1 >> "$LOG" 2>&1 || true
            send_embed "🚨 자동 배포 실패" "smoke test 실패 — 이전 버전으로 롤백됨" 15158332 "jarvis-system" || true
            return 1
        fi
    else
        # 봇 재시작 불필요한 변경 (scripts/, bin/ 등) → 로컬 코드 자동 적용됨, 별도 조치 불필요
        log "Auto-deploy: 재시작 불필요 변경 — 로컬 적용 완료 (merge 생략)"
    fi
}

# --- 커밋 메시지 → claude 한글 요약 ---
summarize_commits_kr() {
    local commit_msgs="$1"
    local changed_files="$2"

    # 변경된 디렉토리 요약 (상위 3개)
    local dir_summary
    dir_summary=$(echo "$changed_files" | awk -F/ 'NF>1{print $1}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s(%s건) ", $2, $1}')

    local prompt
    local file_count
    file_count=$(echo "$changed_files" | grep -c . 2>/dev/null || echo "0")

    prompt="아래는 Jarvis 시스템의 git 커밋 내역이다. 이걸 Discord에 표시할 한글 요약으로 바꿔라.

커밋 메시지:
${commit_msgs}

변경 영역: ${dir_summary}
변경 파일 수: ${file_count}개

규칙:
- 불릿(•) 형식, 줄 수 제한 없음 (변경사항 빠짐없이 모두 나열)
- 각 줄은 70자 이내, 구어체 금지
- 무엇을 왜 변경했는지 구체적으로 써라 (예: 'rag-quality-check.sh UTC 타임존 오변환 → KST 9시간 오탐 알림 수정')
- 버그 수정은 증상과 원인을 함께 써라 (예: '좀비 에이전트 3일간 미정리 → watchdog 감지 패턴 보강')
- 신규 파일은 파일명과 용도를 써라 (예: 'kill-team.sh 신규 — 팀 에이전트 일괄 종료 스크립트')
- '스크립트 수정', '문서 정비', '라이브러리 업데이트' 같은 뭉뚱그린 표현 금지
- 기술 용어 OK, 하지만 비개발자도 대략 알 수 있게
- 여러 커밋이 같은 주제면 하나로 합치되, 중요한 변경은 각각 써라
- 불릿 외의 텍스트 출력 금지 (인사말, 설명, 마크다운 등 절대 금지)"

    local result=""
    local claude_exit_code=0
    # claude -p 사용 (timeout 30초, 저비용)
    if command -v claude >/dev/null 2>&1; then
        _sum_cmd=()
        if [[ -n "${_TIMEOUT_CMD:-}" ]]; then _sum_cmd+=("${_TIMEOUT_CMD}" 30); fi
        _sum_cmd+=(claude -p "$prompt")
        result=$("${_sum_cmd[@]}" \
            --model claude-haiku-4-5-20251001 \
            --max-turns 3 \
            2>&1) || claude_exit_code=$?

        # Timeout 또는 명령 실패 시 로깅
        if [[ $claude_exit_code -ne 0 ]]; then
            log "Claude 요약 실패 (exit code: $claude_exit_code, 일반 fallback 사용)"
        fi
    fi

    # claude 실패 또는 에러 메시지 출력 시 fallback
    if [[ -z "$result" ]] || echo "$result" | grep -q "^Error:\|Reached max turns\|error_"; then
        log "Claude 응답 에러 감지 또는 공백, fallback 사용"
        result=$(echo "$commit_msgs" | sed -E 's/^[a-z]+(\([^)]*\))?:[[:space:]]*/• /')
    fi

    # 앞뒤 공백/빈줄 정리
    echo "$result" | sed '/^$/d'
}

# ============================================================================
# Main
# ============================================================================
if [[ ! -d "$BOT_HOME/.git" ]]; then exit 0; fi

current_sha=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null || true)
if [[ -z "$current_sha" ]]; then exit 0; fi

if [[ ! -f "$STATE_FILE" ]]; then
    echo "$current_sha" > "$STATE_FILE"
    exit 0
fi

last_sha=$(cat "$STATE_FILE" 2>/dev/null || echo "")
if [[ -z "$last_sha" ]]; then echo "$current_sha" > "$STATE_FILE"; exit 0; fi
if [[ "$current_sha" == "$last_sha" ]]; then exit 0; fi

if ! git -C "$BOT_HOME" cat-file -t "$last_sha" &>/dev/null; then
    send_embed "⚠️ Git 히스토리 리셋" "force push 또는 rebase 감지됨" "16776960" "jarvis-system" || true
    echo "$current_sha" > "$STATE_FILE"
    exit 0
fi

log "변경 감지: ${last_sha:0:8} → ${current_sha:0:8}"

# --- 데이터 수집 ---
changed_files=$(git -C "$BOT_HOME" diff --name-only "$last_sha..HEAD" 2>/dev/null || echo "")
commit_count=$(git -C "$BOT_HOME" rev-list --count "$last_sha..HEAD" 2>/dev/null || echo "0")
commit_msgs=$(git -C "$BOT_HOME" log --format='%s' "$last_sha..HEAD" 2>/dev/null || echo "")

# --- 한글 요약 생성 ---
korean_summary=$(summarize_commits_kr "$commit_msgs" "$changed_files")
action_line=$(detect_action "$changed_files")

# --- 메시지 조립 ---
title="🔄 Jarvis 업데이트"
file_count=$(echo "$changed_files" | grep -c . 2>/dev/null || echo "0")
dir_summary=$(echo "$changed_files" | awk -F/ 'NF>1{print $1}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s(%s) ", $2, $1}')
meta_line="📦 커밋 ${commit_count}건 · 파일 ${file_count}개 · ${dir_summary}"
description="${korean_summary}"$'\n'"${meta_line}"$'\n'"${action_line}"

# 봇 재시작 필요하면 노랑, 아니면 파랑
color=3447003
if echo "$action_line" | grep -q "재시작"; then
    color=16776960
fi

# 업데이트 알림은 jarvis-system 채널로
if send_embed "$title" "$description" "$color" "jarvis-system"; then
    echo "$current_sha" > "$STATE_FILE"
    log "브로드캐스트 완료 (${commit_count}건): ${korean_summary}"
else
    log "브로드캐스트 실패"
fi

# --- 자동 배포 (알림 전송 성공 여부와 무관하게 실행) ---
auto_deploy "$changed_files" || true
