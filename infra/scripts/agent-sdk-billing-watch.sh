#!/usr/bin/env bash
# agent-sdk-billing-watch.sh — Anthropic Agent SDK 과금 정책 변경 모니터
#
# 목적: Anthropic 공식 문서에서 Agent SDK / headless 관련 과금 정책을 주기적으로
#       수집하고, 변경이 감지되면 jarvis-system 채널로 경보를 발송한다.
#
# 성공 기준:
#   [1] 스크립트 존재 + 문법 오류 없음
#   [2] Anthropic 공식 페이지 fetch → 결과 파일 생성
#   [3] 변경 감지 시 Discord jarvis-system 경보 발송
#   [4] tasks.json에 주기적 실행 스케줄 등록
#
# 검사 대상 URL:
#   - https://www.anthropic.com/pricing
#   - https://docs.anthropic.com/en/docs/agents-and-tools/overview (Agent SDK 문서)
#
# 상태 파일: $BOT_HOME/state/agent-sdk-billing-watch/
#   - last-hash.txt      : 이전 체크 콘텐츠 해시
#   - last-check.txt     : 마지막 체크 타임스탬프
#   - last-content.txt   : 이전 체크 원문 (diff 용)
# 결과 파일: $BOT_HOME/results/tech-anthropic-agent-sdk-billing-watch/YYYY-MM-DD.md

set -uo pipefail

# ── 경로 설정 ──────────────────────────────────────────────────────────────────
JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
BOT_HOME="${BOT_HOME:-$JARVIS_HOME/runtime}"
LOG_FILE="$BOT_HOME/logs/agent-sdk-billing-watch.log"
STATE_DIR="$BOT_HOME/state/agent-sdk-billing-watch"
RESULT_DIR="$BOT_HOME/results/tech-anthropic-agent-sdk-billing-watch"
TODAY=$(date +%Y-%m-%d)
RESULT_FILE="$RESULT_DIR/$TODAY.md"

mkdir -p "$STATE_DIR" "$RESULT_DIR" "$(dirname "$LOG_FILE")"

# ── Discord 라우터 로드 ────────────────────────────────────────────────────────
if [ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ]; then
    source "$JARVIS_HOME/infra/lib/discord-route.sh"
else
    echo "[WARN] discord-route.sh 없음 — Discord 발송 불가"
fi

_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── 검사 대상 ─────────────────────────────────────────────────────────────────
TARGETS=(
    "https://www.anthropic.com/pricing"
    "https://docs.anthropic.com/en/docs/about-claude/models/overview"
    "https://www.anthropic.com/api"
)

# Agent SDK / 과금 관련 키워드 (대소문자 무관)
KEYWORDS=(
    "agent sdk"
    "headless"
    "agentic"
    "per-session"
    "billing"
    "pricing"
    "credits"
    "token"
    "usage"
)

# ── 유틸 함수 ─────────────────────────────────────────────────────────────────
extract_relevant_text() {
    local url="$1"
    # curl로 HTML 가져온 뒤 텍스트만 추출 (태그·스크립트 제거)
    curl -sL --max-time 30 --user-agent "Mozilla/5.0 Jarvis-BillingWatch/1.0" "$url" 2>/dev/null \
        | sed 's/<script[^>]*>.*<\/script>//gI' \
        | sed 's/<style[^>]*>.*<\/style>//gI' \
        | sed 's/<[^>]*>//g' \
        | grep -v '^[[:space:]]*$' \
        | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g' \
        | tr -s ' \t' ' ' \
        | grep -iE "$(IFS='|'; echo "${KEYWORDS[*]}")" \
        || true
}

compute_hash() {
    printf '%s' "$1" | md5
}

# ── 메인 로직 ─────────────────────────────────────────────────────────────────
_log "=== Agent SDK 과금 정책 모니터 시작 ==="

COMBINED_CONTENT=""
FETCH_ERRORS=0
FETCH_SUCCESS=0

for URL in "${TARGETS[@]}"; do
    _log "Fetching: $URL"
    TEXT=$(extract_relevant_text "$URL")
    if [ -z "$TEXT" ]; then
        _log "[WARN] $URL 에서 관련 텍스트 없음 (fetch 실패 또는 키워드 미검출)"
        FETCH_ERRORS=$((FETCH_ERRORS + 1))
        continue
    fi
    FETCH_SUCCESS=$((FETCH_SUCCESS + 1))
    COMBINED_CONTENT="${COMBINED_CONTENT}
=== ${URL} ===
${TEXT}"
done

if [ $FETCH_SUCCESS -eq 0 ]; then
    _log "[ERROR] 모든 URL fetch 실패 — 네트워크 또는 차단 문제"
    # 에러도 결과 파일에 기록
    {
        echo "# Agent SDK 과금 모니터 — $TODAY"
        echo ""
        echo "**상태**: FETCH_FAIL"
        echo "**시각**: $(date '+%Y-%m-%d %H:%M KST')"
        echo ""
        echo "모든 대상 URL fetch 실패. 네트워크 연결 또는 차단 여부 확인 필요."
    } > "$RESULT_FILE"
    exit 1
fi

# ── 해시 비교 (변경 감지) ──────────────────────────────────────────────────────
CURRENT_HASH=$(compute_hash "$COMBINED_CONTENT")
HASH_FILE="$STATE_DIR/last-hash.txt"
PREV_CONTENT_FILE="$STATE_DIR/last-content.txt"
PREV_HASH=""

if [ -f "$HASH_FILE" ]; then
    PREV_HASH=$(cat "$HASH_FILE")
fi

CHANGED=false
DIFF_SUMMARY=""
if [ -n "$PREV_HASH" ] && [ "$PREV_HASH" != "$CURRENT_HASH" ]; then
    CHANGED=true
    _log "[CHANGE DETECTED] 해시 변경: $PREV_HASH → $CURRENT_HASH"
    # diff 요약 (최대 30줄)
    if [ -f "$PREV_CONTENT_FILE" ]; then
        DIFF_SUMMARY=$(diff <(cat "$PREV_CONTENT_FILE") <(echo "$COMBINED_CONTENT") \
            | grep '^[<>]' | head -30 || true)
    fi
elif [ -z "$PREV_HASH" ]; then
    _log "[FIRST RUN] 초기 베이스라인 저장"
else
    _log "[NO CHANGE] 정책 변경 없음 (hash=$CURRENT_HASH)"
fi

# ── 상태 저장 ─────────────────────────────────────────────────────────────────
echo "$CURRENT_HASH" > "$HASH_FILE"
echo "$COMBINED_CONTENT" > "$PREV_CONTENT_FILE"
date '+%Y-%m-%d %H:%M KST' > "$STATE_DIR/last-check.txt"

# ── 결과 파일 작성 ────────────────────────────────────────────────────────────
{
    echo "# Agent SDK 과금 정책 모니터 — $TODAY"
    echo ""
    echo "**실행 시각**: $(date '+%Y-%m-%d %H:%M KST')"
    echo "**Fetch 성공**: $FETCH_SUCCESS / ${#TARGETS[@]}"
    echo "**콘텐츠 해시**: \`$CURRENT_HASH\`"
    echo "**변경 감지**: $([ "$CHANGED" = "true" ] && echo "YES ⚠️" || echo "NO ✅")"
    echo ""
    echo "## 검사 대상 URL"
    for URL in "${TARGETS[@]}"; do
        echo "- $URL"
    done
    echo ""
    echo "## 추출된 키워드 관련 콘텐츠"
    echo ""
    echo "$COMBINED_CONTENT" | head -200
    echo ""
    if [ "$CHANGED" = "true" ] && [ -n "$DIFF_SUMMARY" ]; then
        echo "## 변경 diff (최대 30줄)"
        echo '```'
        echo "$DIFF_SUMMARY"
        echo '```'
    fi
} > "$RESULT_FILE"

_log "결과 파일 저장: $RESULT_FILE"

# ── Discord 경보 (변경 감지 시) ───────────────────────────────────────────────
if [ "$CHANGED" = "true" ]; then
    _log "Discord jarvis-system 채널로 경보 발송"

    DIFF_SHORT=$(echo "$DIFF_SUMMARY" | head -10 | tr '\n' ' ' | cut -c1-300)
    DIFF_DISPLAY="${DIFF_SHORT:-변경 내용 diff 없음}"

    if declare -f discord_route > /dev/null 2>&1; then
        discord_route critical \
            "⚠️ Anthropic Agent SDK 과금 정책 변경 감지" \
            "감지시각=$(date '+%Y-%m-%d %H:%M KST'),해시변경=${PREV_HASH}→${CURRENT_HASH},결과파일=$RESULT_FILE,요약=${DIFF_DISPLAY}"
    else
        _log "[WARN] discord_route 함수 없음 — 경보 발송 불가"
    fi
elif [ -z "$PREV_HASH" ]; then
    # 첫 실행: 베이스라인 설정 알림 (info)
    if declare -f discord_route > /dev/null 2>&1; then
        discord_route info \
            "Agent SDK 과금 모니터 베이스라인 설정 완료" \
            "시각=$(date '+%Y-%m-%d %H:%M KST'),해시=${CURRENT_HASH},대상URL=${#TARGETS[@]}개,Fetch성공=${FETCH_SUCCESS}개"
    fi
fi

_log "=== 완료 (changed=$CHANGED, success=$FETCH_SUCCESS/${#TARGETS[@]}) ==="
exit 0
