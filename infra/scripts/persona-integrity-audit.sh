#!/usr/bin/env bash
# persona-integrity-audit.sh — JARVIS 페르소나 일관성 주간 감사
#
# 목적: 페르소나 drift(이탈) 자동 감지. 주 1회 크론으로 실행.
#
# 검사 항목:
#   1. SSoT persona.md 존재 여부
#   2. SSoT ↔ CLI rule 내용 일치 여부 (드리프트 감지)
#   3. jarvis-say.log 에서 반말 감지 빈도
#   4. Discord 봇 prompt-sections.js silent fail 재발 여부
#   5. 알림 스크립트들의 고정 텍스트에 반말 포함 여부
#
# 출력:
#   - ~/.jarvis/logs/persona-audit.log (append-only)  # ALLOW-DOTJARVIS
#   - 문제 발견 시 Discord 알림 (gate 통과 시 조용)
#
# Usage:
#   bash infra/scripts/persona-integrity-audit.sh           # 일반 감사
#   bash infra/scripts/persona-integrity-audit.sh --verbose # 상세 출력

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/infra}"
JARVIS_HOME="${HOME}/.jarvis"  # ALLOW-DOTJARVIS — 로그 디렉토리 잔존 (audit 출력 전용)
AUDIT_LOG="${JARVIS_HOME}/logs/persona-audit.log"
VERBOSE="${1:-}"

mkdir -p "$(dirname "$AUDIT_LOG")"

TS="$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S')"
ISSUES=()

log_issue() {
    ISSUES+=("$1")
    echo "❌ $1" >&2
}

log_ok() {
    [[ "$VERBOSE" == "--verbose" ]] && echo "✅ $1"
}

log_info() {
    [[ "$VERBOSE" == "--verbose" ]] && echo "ℹ️  $1"
}

echo "═══ Persona Integrity Audit @ $TS ═══"

# ────── 1. SSoT persona.md 존재 여부 ──────
SSOT_PATH="${BOT_HOME}/context/owner/persona.md"
if [[ ! -f "$SSOT_PATH" ]]; then
    log_issue "SSoT persona.md 부재: $SSOT_PATH"
    log_issue "  조치: cp ${SSOT_PATH}.example $SSOT_PATH"
else
    log_ok "SSoT persona.md 존재 ($(wc -c < "$SSOT_PATH") bytes)"
fi

# ────── 2. CLI rule 내용 일치 여부 ──────
CLI_RULE="${HOME}/.claude/rules/jarvis-persona.md"
if [[ ! -f "$CLI_RULE" ]]; then
    log_issue "CLI rule 부재: $CLI_RULE"
else
    log_ok "CLI rule 존재 ($(wc -c < "$CLI_RULE") bytes)"

    # 핵심 키워드 일치 검사
    REQUIRED_KEYWORDS=("주인님" "JARVIS" "반말" "존댓말" "KST")
    for kw in "${REQUIRED_KEYWORDS[@]}"; do
        if [[ -f "$SSOT_PATH" ]] && ! grep -q "$kw" "$CLI_RULE"; then
            log_issue "CLI rule에 핵심 키워드 '$kw' 없음"
        fi
    done
fi

# ────── 3. jarvis-say.log에서 최근 반말 감지 빈도 ──────
SAY_LOG="${JARVIS_HOME}/logs/jarvis-say.log"
if [[ -f "$SAY_LOG" ]]; then
    # 최근 7일 BANMAL-DETECTED 카운트 (macOS BSD/GNU 양쪽 호환 구현)
    SEVEN_DAYS_AGO="$(TZ=Asia/Seoul date -v-7d '+%Y-%m-%d' 2>/dev/null || TZ=Asia/Seoul date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null)"
    # 로그 포맷: [YYYY-MM-DD HH:MM:SS] [BANMAL-DETECTED] ...
    # grep으로 BANMAL 라인만 뽑고, sed로 날짜 추출, awk에서 단순 비교만
    BANMAL_COUNT=$(grep 'BANMAL-DETECTED' "$SAY_LOG" 2>/dev/null \
        | sed -E 's/^\[([0-9]{4}-[0-9]{2}-[0-9]{2}).*$/\1/' \
        | awk -v since="$SEVEN_DAYS_AGO" '$1 >= since {c++} END {print c+0}')

    log_info "최근 7일 반말 감지: ${BANMAL_COUNT}건"

    if [[ "$BANMAL_COUNT" -gt 5 ]]; then
        log_issue "최근 7일 반말 감지 ${BANMAL_COUNT}건 (임계치 5 초과) — 호출처 추적 필요"
        log_issue "  확인: grep BANMAL-DETECTED $SAY_LOG | tail -10"
    fi
else
    log_info "jarvis-say.log 없음 (아직 사용 전)"
fi

# ────── 4. Discord 봇 silent fail 재발 여부 ──────
PS_JS="${BOT_HOME}/discord/lib/prompt-sections.js"
if [[ -f "$PS_JS" ]]; then
    if grep -q "buildOwnerPersonaSection" "$PS_JS"; then
        # buildOwnerPersonaSection 함수 블록 전체를 추출하여
        # 그 안에 console.error 또는 console.warn 이 하나라도 있는지 검사
        FN_BODY=$(awk '/export function buildOwnerPersonaSection/,/^}/' "$PS_JS")
        if echo "$FN_BODY" | grep -qE 'console\.(error|warn)'; then
            log_ok "Discord 봇 buildOwnerPersonaSection에 경고 로그 존재"
        else
            log_issue "Discord 봇 buildOwnerPersonaSection silent fail 재발 — console.error 누락"
        fi
    fi
fi

# ────── 5. 알림 스크립트 고정 텍스트 반말 감사 ──────
ALERT_SCRIPTS=(
    "${BOT_HOME}/scripts/alert-send.sh"
    "${BOT_HOME}/scripts/job-alert.sh"
    "${BOT_HOME}/scripts/disk-alert.sh"
    "${BOT_HOME}/scripts/lancedb-alert.sh"
    "${BOT_HOME}/scripts/calendar-alert.sh"
)

# 고정 문자열 반말 패턴 (echo/printf 안에 들어간 것 위주)
BANMAL_IN_SCRIPTS=0
for script in "${ALERT_SCRIPTS[@]}"; do
    [[ ! -f "$script" ]] && continue
    # echo/printf 내부에서 반말 어미 검출
    # 예: echo "디스크 90% 넘었어"
    if grep -E '(echo|printf)\s+["'"'"'][^"'"'"']*(했어|됐어|이야|거든|잖아|해봐|끝\.)["'"'"']' "$script" > /dev/null 2>&1; then
        log_issue "$(basename "$script")에 반말 고정 텍스트 포함"
        BANMAL_IN_SCRIPTS=$((BANMAL_IN_SCRIPTS + 1))
    fi
done
[[ "$BANMAL_IN_SCRIPTS" -eq 0 ]] && log_ok "알림 스크립트 고정 텍스트 반말 없음"

# ────── 최종 판정 및 로그 ──────
echo ""
if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo "✅ PASS — 페르소나 무결성 이상 없음"
    echo "[$TS] [PASS] 페르소나 무결성 이상 없음" >> "$AUDIT_LOG"
    exit 0
else
    echo "❌ FAIL — ${#ISSUES[@]}개 이슈 발견"
    for issue in "${ISSUES[@]}"; do
        echo "  - $issue"
    done
    echo "[$TS] [FAIL] ${#ISSUES[@]}개 이슈: ${ISSUES[*]}" >> "$AUDIT_LOG"

    # Discord 알림 (jarvis-say.sh 래퍼 통과)
    if [[ -x "${BOT_HOME}/scripts/jarvis-say.sh" ]] && [[ -x "${BOT_HOME}/scripts/alert-send.sh" ]]; then
        MSG="$("${BOT_HOME}/scripts/jarvis-say.sh" "페르소나 무결성 감사에서 ${#ISSUES[@]}건의 이슈가 발견되었습니다. persona-audit.log 확인을 권고드립니다.")"
        bash "${BOT_HOME}/scripts/alert-send.sh" "$MSG" 2>/dev/null || true
    fi
    exit 1
fi
