#!/usr/bin/env bash
# sensor-prompt.sh — Phase 0.5 Sensor + Learning (Claude Code CLI)
#
# 2단 구조:
#   (1) 학습(learning) — infra/bin/feedback-loop-cli.mjs 호출로
#        detectFeedback + userMemory 기록을 Discord와 공유 (SSoT).
#   (2) 관측(observation) — JSONL 원장 2종 기록 (Phase 0 측정용).
#
# 두 경로 모두 non-blocking. 하나 실패해도 나머지는 진행.
#
# JSONL: ~/.jarvis/state/feedback-score.jsonl / reask-tracker.jsonl
# 학습 저장: ~/.jarvis/state/users/{ownerId}.json (corrections/facts 배열)

set -euo pipefail

STATE_DIR="${HOME}/.jarvis/state"
FEEDBACK_CLI="${HOME}/.jarvis/bin/feedback-loop-cli.mjs"  # ~/.jarvis/bin → ~/projects/jarvis/infra/bin 심링크
mkdir -p "$STATE_DIR"

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    p = d.get('prompt', '') or d.get('user_prompt', '')
    print(p[:1000])
except Exception:
    pass
" 2>/dev/null || echo "")

SESSION_ID=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('session_id', ''))
except Exception:
    pass
" 2>/dev/null || echo "")

if [[ -z "$PROMPT" ]]; then exit 0; fi

# ─────────────────────────────────────────────────────────────
# (1) 학습 — 공통 모듈에 위임 (userMemory + wiki 반영까지)
#     결과 JSON을 RESULT에 담아 관측 분기에 활용 (DRY: 감지 로직 중복 제거)
# ─────────────────────────────────────────────────────────────
RESULT='{}'
if [[ -x "$FEEDBACK_CLI" ]]; then
  PAYLOAD=$(python3 -c "import sys,json; print(json.dumps({'text': sys.argv[1], 'source': 'claude-code-cli'}))" "$PROMPT")
  RESULT=$(printf '%s' "$PAYLOAD" | node "$FEEDBACK_CLI" 2>/dev/null || echo '{}')
fi

FEEDBACK=$(echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    fb = d.get('fb') or {}
    print(fb.get('type', ''))
except Exception:
    pass
" 2>/dev/null || echo "")

if [[ -z "$FEEDBACK" ]]; then
  # 피드백 없음 → prompt 캐시만 갱신하고 종료
  echo "$PROMPT" | head -c 500 > "/tmp/claude-sensor-last-prompt-${SESSION_ID}" 2>/dev/null || true
  exit 0
fi

# ─────────────────────────────────────────────────────────────
# (2) 관측 — JSONL 원장 2종 append
# ─────────────────────────────────────────────────────────────
LAST_TRACE_FILE="/tmp/claude-sensor-last-trace-${SESSION_ID}"
LAST_TRACE_ID=""
if [[ -f "$LAST_TRACE_FILE" ]]; then
  LAST_TRACE_ID=$(cat "$LAST_TRACE_FILE" 2>/dev/null || true)
fi

TS=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
SAFE_PROMPT=$(python3 -c "import sys,json; print(json.dumps(sys.argv[1][:200]))" "$PROMPT")

# feedback-score.jsonl (positive=1.0, negative=0.0, correction=0.3, remember=skip)
SCORE=""
case "$FEEDBACK" in
  positive) SCORE="1.0" ;;
  negative) SCORE="0.0" ;;
  correction) SCORE="0.3" ;;
esac

if [[ -n "$SCORE" && -n "$LAST_TRACE_ID" ]]; then
  printf '{"ts":"%s","source":"claude-code-cli","traceId":"%s","sessionId":"%s","feedbackType":"%s","score":%s,"comment":%s}\n' \
    "$TS" "$LAST_TRACE_ID" "$SESSION_ID" "$FEEDBACK" "$SCORE" "$SAFE_PROMPT" \
    >> "$STATE_DIR/feedback-score.jsonl" 2>/dev/null || true
fi

# reask-tracker.jsonl (negative/correction만)
if [[ "$FEEDBACK" == "negative" || "$FEEDBACK" == "correction" ]]; then
  LAST_PROMPT_FILE="/tmp/claude-sensor-last-prompt-${SESSION_ID}"
  PREV_PROMPT='""'
  if [[ -f "$LAST_PROMPT_FILE" ]]; then
    PREV_PROMPT=$(python3 -c "import sys,json; print(json.dumps(open(sys.argv[1]).read()[:240]))" "$LAST_PROMPT_FILE" 2>/dev/null || echo '""')
  fi
  printf '{"ts":"%s","source":"claude-code-cli","sessionId":"%s","feedbackType":"%s","feedbackText":%s,"prevPrompt":%s,"lastTraceId":"%s"}\n' \
    "$TS" "$SESSION_ID" "$FEEDBACK" "$SAFE_PROMPT" "$PREV_PROMPT" "${LAST_TRACE_ID:-}" \
    >> "$STATE_DIR/reask-tracker.jsonl" 2>/dev/null || true
fi

# 현재 prompt 저장 (다음 턴의 prevPrompt용)
echo "$PROMPT" | head -c 500 > "/tmp/claude-sensor-last-prompt-${SESSION_ID}" 2>/dev/null || true

exit 0
