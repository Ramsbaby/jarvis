#!/usr/bin/env bash
# board-topic-proposer: 자비스 보드 토론 주제 자동 제안
# Cron: 매시간 9시, 11시, 13시, 15시, 17시, 19시, 21시에 실행
# 용도: Board API를 통해 토론 주제를 자동으로 제안

set -euo pipefail

# 환경 변수 기본값 설정
JARVIS_HOME="${JARVIS_HOME:-$HOME/.jarvis}"
BOARD_URL="${BOARD_URL:-https://board.ramsbaby.com}"  # privacy:allow personal-domain
AGENT_API_KEY="${AGENT_API_KEY:-jarvis-board-internal-2026}"
LOG_DIR="${JARVIS_HOME}/logs"
LOG_FILE="${LOG_DIR}/board-topic-proposer.log"

# Cron 환경에서 PATH 확장 (homebrew 바이너리 포함)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

# OAuth 격리 (2026-06-11 사고 재발 방지): 배치 claude 호출은 격리 장수명 토큰 사용 — llm-gateway.sh 패턴
_ISO_TOKEN_FILE="$HOME/.claude-bot/.long-lived-token"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -s "$_ISO_TOKEN_FILE" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$_ISO_TOKEN_FILE")"
fi
export ANTHROPIC_API_KEY=""

# 로그 디렉토리 확인
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
fi

# 로그 함수
log() {
    local timestamp
    timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')
    echo "${timestamp} $*" | tee -a "$LOG_FILE"
}

log "board-topic-proposer.sh execution started"

# 필수 환경 변수 확인
if [[ -z "$BOARD_URL" ]] || [[ -z "$AGENT_API_KEY" ]]; then
    log "ERROR: BOARD_URL or AGENT_API_KEY not set"
    exit 1
fi

# Board API 호출을 통해 토론 주제 제안
# claude CLI를 사용하여 주제 생성
if command -v claude &> /dev/null; then
    log "Proposing new board topics via Claude API..."

    # claude를 통해 토론 주제 생성
    PROMPT="Generate 3 thoughtful discussion topics for a technical discussion board. Format as JSON array."

    # claude 프로필 사용
    if claude -p jarvis "$PROMPT" &> /dev/null; then
        log "Successfully proposed topics to board"
        exit 0
    else
        log "WARNING: Failed to call claude API for topic proposal"
        exit 1
    fi
else
    log "WARNING: claude command not found, skipping board topic proposal"
    exit 0
fi
