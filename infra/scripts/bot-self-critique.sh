#!/usr/bin/env bash
# bot-self-critique.sh — 봇 자가비판 분석 크론
# 매일 02:45 bot-quality-check 결과를 분석해 자가비판 리포트 생성
# 출력: #jarvis-system 디스코드 채널

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
QUALITY_RESULTS_DIR="$BOT_HOME/results/quality"
CRITIQUE_RESULTS_DIR="$BOT_HOME/results/critique"
RESULTS_FILE="$CRITIQUE_RESULTS_DIR/$(date +%F).md"

mkdir -p "$CRITIQUE_RESULTS_DIR"

# ── 지난 24시간 품질 리포트 수집 ─────────────────────────────────
if [[ ! -d "$QUALITY_RESULTS_DIR" ]]; then
  echo "[self-critique] 품질 리포트 디렉토리 없음: $QUALITY_RESULTS_DIR"
  echo "## 자가비판 보고서 ($(date +%F))"
  echo ""
  echo "**⚠️ 분석 데이터 없음** — bot-quality-analyzer 아직 미실행"
  exit 0
fi

# 가장 최근 24시간 내 품질 리포트 찾기
LATEST_REPORT=$(ls -t "$QUALITY_RESULTS_DIR"/*.json 2>/dev/null | head -1)

if [[ -z "$LATEST_REPORT" ]]; then
  echo "[self-critique] 품질 리포트 파일 없음 ($QUALITY_RESULTS_DIR)"
  echo "## 자가비판 보고서 ($(date +%F))"
  echo ""
  echo "**⚠️ 분석 데이터 없음** — 아직 데이터 수집 안 됨"
  exit 0
fi

# 리포트 파일 읽기
if [[ ! -f "$LATEST_REPORT" ]]; then
  echo "[self-critique] 리포트 파일 읽기 실패: $LATEST_REPORT"
  exit 1
fi

# JSON 파싱 (jq 사용)
TOTAL_RESPONSES=$(jq -r '.metrics.total_responses // 0' "$LATEST_REPORT" 2>/dev/null || echo 0)
ERROR_COUNT=$(jq -r '.metrics.error_count // 0' "$LATEST_REPORT" 2>/dev/null || echo 0)
TIMEOUT_COUNT=$(jq -r '.metrics.timeout_count // 0' "$LATEST_REPORT" 2>/dev/null || echo 0)
AVG_RESPONSE_TIME=$(jq -r '.metrics.avg_response_time // 0' "$LATEST_REPORT" 2>/dev/null || echo 0)

# 에러율 계산
if [[ "$TOTAL_RESPONSES" -gt 0 ]]; then
  ERROR_RATE=$((ERROR_COUNT * 100 / TOTAL_RESPONSES))
else
  ERROR_RATE=0
fi

# 품질 점수 계산 (0-100)
# 에러율에 따라 감점: 에러율 5% 이상이면 10점, 10% 이상이면 20점 감점
QUALITY_SCORE=100
if [[ "$ERROR_RATE" -ge 10 ]]; then
  QUALITY_SCORE=$((QUALITY_SCORE - 20))
elif [[ "$ERROR_RATE" -ge 5 ]]; then
  QUALITY_SCORE=$((QUALITY_SCORE - 10))
fi

# 타임아웃 감점
if [[ "$TIMEOUT_COUNT" -gt 5 ]]; then
  QUALITY_SCORE=$((QUALITY_SCORE - 15))
elif [[ "$TIMEOUT_COUNT" -gt 0 ]]; then
  QUALITY_SCORE=$((QUALITY_SCORE - 5))
fi

# 응답 시간 감점
if (( $(echo "$AVG_RESPONSE_TIME > 5" | bc -l 2>/dev/null || echo 0) )); then
  QUALITY_SCORE=$((QUALITY_SCORE - 10))
fi

# 최소 점수 0으로 보정
[[ $QUALITY_SCORE -lt 0 ]] && QUALITY_SCORE=0

# ── 리포트 생성 ────────────────────────────────────────────────────
{
  echo "## 🤖 봇 자가비판 분석 ($(date +%F))"
  echo ""
  echo "### 🎯 오늘의 품질 점수: **$QUALITY_SCORE/100**"
  echo ""
  echo "#### 📊 주요 지표"
  echo "- **총 응답**: $TOTAL_RESPONSES건"
  echo "- **에러**: $ERROR_COUNT건 (에러율: $ERROR_RATE%)"
  echo "- **타임아웃**: $TIMEOUT_COUNT건"
  echo "- **평균 응답시간**: ${AVG_RESPONSE_TIME}초"
  echo ""

  # 잘한 점
  if [[ "$ERROR_RATE" -lt 5 ]]; then
    echo "#### ✅ 잘한 점"
    echo "- ✓ 에러율이 5% 미만으로 양호"
  fi

  if [[ "$TIMEOUT_COUNT" -eq 0 ]]; then
    echo "- ✓ 타임아웃 0건 — 응답 안정성 우수"
  fi

  # 개선이 필요한 점
  if [[ "$ERROR_RATE" -ge 5 ]]; then
    echo "#### ⚠️ 개선이 필요한 점"
    echo "- ⚠ 에러율 $ERROR_RATE% — 목표는 <5%"
  fi

  if [[ "$TIMEOUT_COUNT" -gt 0 ]]; then
    echo "- ⚠ 타임아웃 $TIMEOUT_COUNT건 — 응답 지연 원인 분석 필요"
  fi

  # 자가비판
  echo ""
  echo "#### 🔧 자가비판 및 개선 방안"
  if [[ "$QUALITY_SCORE" -ge 90 ]]; then
    echo "현재 상태: **양호** — 지속적인 모니터링 추천"
  elif [[ "$QUALITY_SCORE" -ge 75 ]]; then
    echo "현재 상태: **개선 필요** — 에러/타임아웃 원인 분석 필요"
  else
    echo "현재 상태: **주의** — 즉시 조사 및 개선 필요"
  fi

  echo ""
  echo "---"
  echo "_리포트 생성: $(date '+%Y-%m-%d %H:%M:%S')_"
} | tee "$RESULTS_FILE"

exit 0
