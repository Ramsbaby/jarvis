#!/usr/bin/env bash
# brand-visibility-check.sh - 브랜드 가시성 모니터링
# 목적: GitHub 및 블로그 검색 순위 추적, 브랜드 노출도 모니터링
# 스케줄: 6시간 주기 (crontab: 0 0,6,12,18 * * *)

set -euo pipefail

# ============================================================================
# 설정
# ============================================================================
LOG_DIR="${BOT_HOME:=/Users/ramsbaby/.jarvis}/logs"
LOG_FILE="${LOG_DIR}/brand-visibility.log"
RESULTS_DIR="${BOT_HOME}/results"
RESULTS_FILE="${RESULTS_DIR}/brand-visibility.json"
BRAVE_API_KEY="${BRAVE_API_KEY:-}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK_MONITORING:-}"

# 브랜드 키워드
GITHUB_KEYWORDS=("one-person AI company" "personal jarvis" "AI company-in-a-box")
BLOG_DOMAIN="blog.ramsbaby.com"

# ============================================================================
# 함수
# ============================================================================

log_info() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $msg" | tee -a "$LOG_FILE"
}

log_warn() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $msg" | tee -a "$LOG_FILE"
}

check_github_ranking() {
  local keyword="$1"
  local query="repo:ramsbaby"

  # Brave Search API 호출
  local response=$(curl -s -X GET \
    "https://api.search.brave.com/res/v1/web/search?q=${query}%20${keyword// /%20}&count=10" \
    -H "Accept: application/json" \
    -H "X-Subscription-Token: ${BRAVE_API_KEY}" 2>/dev/null || echo "{}")

  # 결과 파싱: 첫 번째 결과가 자신의 GitHub URL인지 확인
  local url=$(echo "$response" | jq -r '.web[0].url // empty' 2>/dev/null)

  if echo "$url" | grep -q "github.com/ramsbaby" 2>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

check_blog_freshness() {
  # Brave Search API로 최신 블로그 포스트 검색
  local response=$(curl -s -X GET \
    "https://api.search.brave.com/res/v1/web/search?q=site:${BLOG_DOMAIN}&count=1&sort=recency" \
    -H "Accept: application/json" \
    -H "X-Subscription-Token: ${BRAVE_API_KEY}" 2>/dev/null || echo "{}")

  local date=$(echo "$response" | jq -r '.web[0].page_age // empty' 2>/dev/null)

  if [ -n "$date" ]; then
    echo "$date"
  else
    echo "unknown"
  fi
}

send_discord_alert() {
  local status="$1"
  local details="$2"

  if [ -z "$DISCORD_WEBHOOK" ]; then
    {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: DISCORD_WEBHOOK 설정 안됨, 알림 전송 생략"
    } | tee -a "$LOG_FILE"
    return
  fi

  local color="9315184"  # RED (default)
  local title="⚠️ 브랜드 가시성 주의"

  case "$status" in
    GREEN)
      color="3066993"  # GREEN
      title="✅ 브랜드 가시성 정상"
      ;;
    YELLOW)
      color="15105570"  # YELLOW
      title="🟡 브랜드 가시성 주의"
      ;;
  esac

  local payload=$(jq -n \
    --arg title "$title" \
    --arg status "$status" \
    --arg details "$details" \
    --argjson color "$color" \
    '{embeds: [{title: $title, color: $color, fields: [{name: "상태", value: $status}, {name: "세부사항", value: $details}], timestamp: now | todate}]}')

  curl -s -X POST "$DISCORD_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "$payload" > /dev/null 2>&1 || true
}

# ============================================================================
# 메인 로직
# ============================================================================

mkdir -p "$LOG_DIR" "$RESULTS_DIR"

log_info "=== 브랜드 가시성 체크 시작 ==="

# GitHub 순위 체크
log_info "GitHub 검색 순위 체크 시작"
status="GREEN"
issues=""

for keyword in "${GITHUB_KEYWORDS[@]}"; do
  log_info "  키워드 체크: $keyword"
  rank=$(check_github_ranking "$keyword")
  if [ "$rank" -eq 1 ]; then
    log_info "  결과: $keyword → 순위 #1"
  else
    log_warn "  결과: $keyword → 순위 #unranked"
    status="YELLOW"
    issues+="- GitHub: '$keyword' 미노출\n"
  fi
done

# 블로그 체크
log_info "블로그 최종 게시일 체크 시작"
log_info "  Brave Search API로 site:${BLOG_DOMAIN} 검색"
blog_date=$(check_blog_freshness)
if [ "$blog_date" != "unknown" ]; then
  log_info "  최신 포스트 발행일: $blog_date"
else
  log_warn "  검색 결과 없음"
  status="YELLOW"
  issues+="- 블로그: 최신 포스트 미검출\n"
fi

# 상태 판정
log_info "상태 판정 시작"
log_info "평가 완료: $status"

# 결과 저장
if mkdir -p "$RESULTS_DIR" 2>/dev/null; then
  {
    jq -n \
      --arg status "$status" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg blog_date "$blog_date" \
      '{status: $status, timestamp: $timestamp, blog_last_post: $blog_date, github_keywords: "one-person AI company, personal jarvis, AI company-in-a-box"}'
  } > "$RESULTS_FILE" 2>/dev/null || true
fi

# Discord 알림
send_discord_alert "$status" "$(echo -e "$issues")"

log_info "=== 브랜드 가시성 체크 완료 ==="
exit 0
