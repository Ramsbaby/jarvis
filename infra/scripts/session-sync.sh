#!/usr/bin/env bash
# session-sync.sh — context-bus 즉시 동기화
# cron: */15 * * * *
#
# 문제: context-bus는 infra-daily(09:00)/record-daily(23:50)에만 갱신됨
#       세션 중 완료된 작업이 최대 14시간까지 반영 안 됨
#
# 해결: 최근 30분 내 대화 활동 감지 → context-bus 즉시 갱신 (haiku 사용)
#
# 설계 원칙:
#   - context-bus 마지막 갱신 시각 < 최근 대화 활동 시각이면 동기화
#   - 변화 없으면 아무것도 안 함 (조용히 종료)
#   - LLM 호출 실패해도 타임스탬프만 갱신 (best-effort)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
source "${BOT_HOME}/lib/compat.sh" 2>/dev/null || {
  IS_MACOS=false; case "$(uname -s)" in Darwin) IS_MACOS=true ;; esac
}
CONTEXT_BUS="$BOT_HOME/state/context-bus.md"
LOG_DIR="$BOT_HOME/context/discord-history"
LOG="$BOT_HOME/logs/session-sync.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# KST 기준 오늘 날짜
KST_DATE="$(TZ=Asia/Seoul date '+%Y-%m-%d')"
# 봇이 세션 단위로 YYYY-MM-DD-HHMMSS.md 파일을 생성함 (구: YYYY-MM-DD.md)
# 오늘 날짜로 시작하는 가장 최신 세션 파일을 사용
DAILY_LOG="$(ls -t "$LOG_DIR/${KST_DATE}"*.md 2>/dev/null | grep -v "user-memory" | head -1 || true)"

# 오늘 대화 로그 없으면 할 일 없음
if [[ -z "$DAILY_LOG" || ! -f "$DAILY_LOG" ]]; then
    exit 0
fi

# 최근 대화 로그 마지막 수정 시각 (epoch)
LOG_MTIME=$(stat -f %m "$DAILY_LOG" 2>/dev/null || stat -c '%Y' "$DAILY_LOG" 2>/dev/null || echo 0)
NOW=$(date +%s)
LOG_AGE=$(( NOW - LOG_MTIME ))

# 최근 30분 내 활동 없으면 건너뜀
if (( LOG_AGE > 1800 )); then
    exit 0
fi

# context-bus 마지막 갱신 시각 확인
if [[ -f "$CONTEXT_BUS" ]]; then
    BUS_MTIME=$(stat -f %m "$CONTEXT_BUS" 2>/dev/null || stat -c '%Y' "$CONTEXT_BUS" 2>/dev/null || echo 0)
    BUS_AGE=$(( NOW - BUS_MTIME ))
    # context-bus가 최근 10분 내 갱신됐으면 건너뜀 (중복 방지)
    if (( BUS_AGE < 600 )); then
        exit 0
    fi
    # 대화 로그가 context-bus보다 오래됐으면 건너뜀 (이미 최신)
    if (( LOG_MTIME <= BUS_MTIME )); then
        exit 0
    fi
else
    BUS_AGE=99999
fi

log "START — log_age=${LOG_AGE}s bus_age=${BUS_AGE}s, syncing..."

# ── Phase 1 보완: 비활동 세션 요약 파일 점검 ──────────────────────────────
# sessions.json 없으면 건너뜀
SESSIONS_JSON="$BOT_HOME/state/sessions.json"
SESSION_SUMMARY_DIR="$BOT_HOME/state/session-summaries"
if [[ -f "$SESSIONS_JSON" && -d "$SESSION_SUMMARY_DIR" ]]; then
    IDLE_COUNT=0
    while IFS= read -r -d '' summary_file; do
        SUMMARY_MTIME=$(stat -f %m "$summary_file" 2>/dev/null || stat -c '%Y' "$summary_file" 2>/dev/null || echo 0)
        SUMMARY_AGE=$(( NOW - SUMMARY_MTIME ))
        # 요약 파일이 2시간 이상 업데이트 안 된 경우 → stale 로그 기록
        if (( SUMMARY_AGE > 7200 )); then
            IDLE_COUNT=$(( IDLE_COUNT + 1 ))
        fi
    done < <(find "$SESSION_SUMMARY_DIR" -name '*.md' -print0 2>/dev/null)
    if (( IDLE_COUNT > 0 )); then
        log "INFO — ${IDLE_COUNT} session summary file(s) not updated in 2h+ (idle sessions)"
    fi
fi

# 최근 대화 내용 추출 (최근 200줄, 최대 4000자)
RECENT_CONV=$(tail -200 "$DAILY_LOG" | head -c 4000)

# 현재 context-bus 내용
CURRENT_BUS=""
if [[ -f "$CONTEXT_BUS" ]]; then
    CURRENT_BUS=$(head -c 2000 "$CONTEXT_BUS")
fi

# llm-gateway source
LLM_GATEWAY_SH="$BOT_HOME/lib/llm-gateway.sh"
if [[ ! -f "$LLM_GATEWAY_SH" ]]; then
    # llm-gateway 없으면 타임스탬프만 업데이트
    KST_NOW="$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M')"
    if ${IS_MACOS:-false}; then
        sed -i '' "s|_업데이트:.*|_업데이트: ${KST_NOW} KST (session-sync)|" "$CONTEXT_BUS" 2>/dev/null || true
    else
        sed -i "s|_업데이트:.*|_업데이트: ${KST_NOW} KST (session-sync)|" "$CONTEXT_BUS" 2>/dev/null || true
    fi
    log "DONE (no llm-gateway, timestamp only)"
    exit 0
fi

# shellcheck source=/dev/null
# source 실패 시 || true로 set -e 전파 방지 (llm_call 미정의 시 if llm_call이 127로 스킵됨)
source "$LLM_GATEWAY_SH" 2>/dev/null || true

KST_NOW="$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M')"
PROMPT="아래는 오늘 자비스 컴퍼니의 최근 대화 로그와 현재 context-bus입니다.

## 최근 대화 로그 (최근 30분)
${RECENT_CONV}

## 현재 context-bus
${CURRENT_BUS}

---
지시:
1. 최근 대화 로그(최근 30분)에서 Jarvis가 완료한 작업, 수정한 버그, 변경한 시스템 상태만 파악하세요.
2. 현재 context-bus를 기반으로, 최근 완료된 사항을 반영해 갱신된 context-bus 마크다운을 그대로 출력하세요.
3. 코드펜스(\`\`\`)를 절대 사용하지 마세요. 마크다운 원문만 출력하세요.
4. 첫 줄은 반드시: # 자비스 컴퍼니 Context Bus
5. 두 번째 줄: _업데이트: ${KST_NOW} KST (session-sync)_
6. 누적 실패 건수가 아닌 '현재 상태'를 반영하세요. 최근 로그에서 SUCCESS가 연속이면 GREEN으로 표시.
7. 변경 사항이 없으면 '변경없음' 한 단어만 응답."

OUTPUT_TMP="/tmp/session-sync-$$.json"
RESULT=""

if llm_call \
    --prompt "$PROMPT" \
    --timeout 60 \
    --model "claude-haiku-4-5-20251001" \
    --output "$OUTPUT_TMP" 2>/dev/null; then
    RESULT=$(python3 -c "import json,sys; d=json.load(open('$OUTPUT_TMP')); print(d.get('result',''))" 2>/dev/null || true)
fi
rm -f "$OUTPUT_TMP"

if [[ -n "$RESULT" && "$RESULT" != "변경없음" ]]; then
    TMP="$CONTEXT_BUS.tmp.$$"
    echo "$RESULT" > "$TMP"
    mv "$TMP" "$CONTEXT_BUS"
    log "DONE — context-bus updated by haiku"
elif [[ "$RESULT" == "변경없음" ]]; then
    log "DONE — no changes needed"
else
    # LLM 실패 시 타임스탬프만 갱신
    KST_NOW="$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M')"
    if ${IS_MACOS:-false}; then
        sed -i '' "s|_업데이트:.*|_업데이트: ${KST_NOW} KST (session-sync, llm-failed)|" "$CONTEXT_BUS" 2>/dev/null || true
    else
        sed -i "s|_업데이트:.*|_업데이트: ${KST_NOW} KST (session-sync, llm-failed)|" "$CONTEXT_BUS" 2>/dev/null || true
    fi
    log "WARN — llm failed, timestamp only"
fi
