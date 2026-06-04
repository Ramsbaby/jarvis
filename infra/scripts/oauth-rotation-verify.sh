#!/usr/bin/env bash
# oauth-rotation-verify.sh
# OAuth long-lived token 자동 회전 검증 스크립트
# 2026-05-21 race condition 수정 후 자동 회전 동작 검증용
#
# Usage:
#   oauth-rotation-verify.sh --phase pre-expire|at-expire|post-expire
#
# Baseline (2026-05-21 22:11 KST):
#   expiresAt: 1779397579590 (2026-05-22 06:06:19 KST)
#   access16:  ba5652895275bdd9
#   refresh16: 6ec86673ca90b8fc
#
# Exit codes:
#   0 — all checks pass (rotation observed or expected baseline at pre-expire)
#   1 — one or more checks failed (Discord critical alert sent)
#
# Rollback:
#   launchctl bootout gui/$UID ai.jarvis.oauth-rotation-verify-{1,2,3}
#   rm ~/Library/LaunchAgents/ai.jarvis.oauth-rotation-verify-*.plist
#   rm /Users/ramsbaby/jarvis/infra/scripts/oauth-rotation-verify.sh

set -euo pipefail

# ============================================================================
# 설정
# ============================================================================
PHASE="${1:-}"
if [[ "$PHASE" == "--phase" ]]; then PHASE="${2:-auto}"; fi
PHASE="${PHASE:-auto}"

BASELINE_EXPIRES=1779397579590
BASELINE_ACCESS16="ba5652895275bdd9"
BASELINE_REFRESH16="6ec86673ca90b8fc"
BASELINE_LAST_INVALID_GRANT="2026-05-21T13:00:02Z"

CRED_FILE="/Users/ramsbaby/.claude/.credentials.json"
LEDGER="/Users/ramsbaby/jarvis/runtime/logs/oauth-rotation-verify-ledger.jsonl"
PRE_CHECK_LOG="/Users/ramsbaby/jarvis/runtime/logs/pre-cron-auth-check.log"
OAUTH_LOG="/Users/ramsbaby/jarvis/runtime/logs/oauth-refresh.log"
ALERT_SH="/Users/ramsbaby/jarvis/infra/scripts/alert.sh"

KST_NOW="$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z)"
UTC_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ============================================================================
# 검증 항목
# ============================================================================
FAIL_REASONS=()
CHECKS_JSON=""

check_pass() { CHECKS_JSON+="\"$1\":\"PASS\","; }
check_fail() { CHECKS_JSON+="\"$1\":\"FAIL\","; FAIL_REASONS+=("$1: $2"); }

# ① credentials.json 존재
if [[ ! -r "$CRED_FILE" ]]; then
    check_fail "cred_file_readable" "missing or unreadable"
    EXPIRES_NOW=0
    ACCESS16="unreadable"
    REFRESH16="unreadable"
else
    check_pass "cred_file_readable"
    EXPIRES_NOW="$(/usr/bin/python3 -c "import json; print(json.load(open('$CRED_FILE'))['claudeAiOauth'].get('expiresAt',0))" 2>/dev/null || echo 0)"
    ACCESS16="$(/usr/bin/python3 -c "import json,hashlib; print(hashlib.sha256(json.load(open('$CRED_FILE'))['claudeAiOauth']['accessToken'].encode()).hexdigest()[:16])" 2>/dev/null || echo unreadable)"
    REFRESH16="$(/usr/bin/python3 -c "import json,hashlib; print(hashlib.sha256(json.load(open('$CRED_FILE'))['claudeAiOauth']['refreshToken'].encode()).hexdigest()[:16])" 2>/dev/null || echo unreadable)"
fi

# Phase별 회전 기대 여부
ROTATION_EXPECTED="false"
case "$PHASE" in
    pre-expire) ROTATION_EXPECTED="false" ;;  # 만료 2h 전 — 회전 아직 안 일어났을 수도 있음
    at-expire|post-expire) ROTATION_EXPECTED="true" ;;
    *) ROTATION_EXPECTED="auto" ;;
esac

# ② expiresAt 증가
if [[ "$EXPIRES_NOW" -gt "$BASELINE_EXPIRES" ]]; then
    check_pass "expires_increased"
    ROTATED="true"
elif [[ "$EXPIRES_NOW" -eq "$BASELINE_EXPIRES" ]]; then
    ROTATED="false"
    if [[ "$ROTATION_EXPECTED" == "true" ]]; then
        check_fail "expires_increased" "expiresAt unchanged at $BASELINE_EXPIRES (rotation expected at $PHASE)"
    else
        check_pass "expires_increased"  # pre-expire는 미회전 정상
    fi
else
    check_fail "expires_increased" "expiresAt regressed: $EXPIRES_NOW < baseline $BASELINE_EXPIRES"
    ROTATED="false"
fi

# ③ accessToken 변경 (회전 증거)
if [[ "$ACCESS16" != "$BASELINE_ACCESS16" ]]; then
    check_pass "access_token_rotated"
else
    if [[ "$ROTATION_EXPECTED" == "true" ]]; then
        check_fail "access_token_rotated" "access SHA16 unchanged ($BASELINE_ACCESS16) at $PHASE"
    else
        check_pass "access_token_rotated"
    fi
fi

# ④ refreshToken 변경
if [[ "$REFRESH16" != "$BASELINE_REFRESH16" ]]; then
    check_pass "refresh_token_rotated"
else
    if [[ "$ROTATION_EXPECTED" == "true" ]]; then
        check_fail "refresh_token_rotated" "refresh SHA16 unchanged ($BASELINE_REFRESH16) at $PHASE"
    else
        check_pass "refresh_token_rotated"
    fi
fi

# ⑤ healthcheck (간단 GET — 5초 timeout)
HC_HTTP="$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 5 \
    -H "Authorization: Bearer $(/usr/bin/python3 -c "import json; print(json.load(open('$CRED_FILE'))['claudeAiOauth']['accessToken'])" 2>/dev/null)" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/messages" 2>/dev/null || echo "000")"
# 200/400/405 등은 인증 OK (400은 body 없음 응답이라도 토큰 valid 의미)
if [[ "$HC_HTTP" =~ ^(200|400|405)$ ]]; then
    check_pass "healthcheck_http"
elif [[ "$HC_HTTP" == "401" ]]; then
    check_fail "healthcheck_http" "HTTP 401 — token invalid"
else
    check_fail "healthcheck_http" "unexpected HTTP $HC_HTTP"
fi

# ⑥ discord-bot LaunchAgent 살아있는지
BOT_PID="$(/bin/launchctl list 2>/dev/null | /usr/bin/awk '$3=="ai.jarvis.discord-bot"{print $1}' || echo "-")"
if [[ "$BOT_PID" =~ ^[0-9]+$ ]] && [[ "$BOT_PID" -gt 0 ]]; then
    check_pass "discord_bot_alive"
else
    check_fail "discord_bot_alive" "PID=$BOT_PID (LaunchAgent not running)"
fi

# ⑦ pre-cron-auth-check — 검증 시작 시각 이후로만 새 이상 카운트
# baseline 시각: 검증 인프라 구축 시점(2026-05-21 22:18 KST = epoch 1779408000 근사)
VERIFY_BASELINE_EPOCH=1779408000
if [[ -r "$PRE_CHECK_LOG" ]]; then
    set +e
    LOG_MTIME=$(/usr/bin/stat -f "%m" "$PRE_CHECK_LOG" 2>/dev/null)
    LOG_MTIME=${LOG_MTIME:-0}
    LAST_5_FAIL=$(/usr/bin/tail -5 "$PRE_CHECK_LOG" 2>/dev/null | /usr/bin/grep -c "인증 응답 이상" 2>/dev/null)
    LAST_5_FAIL=${LAST_5_FAIL:-0}
    set -e
    if [[ "$LOG_MTIME" -gt "$VERIFY_BASELINE_EPOCH" ]] && [[ "${LAST_5_FAIL:-0}" -gt 0 ]]; then
        check_fail "pre_check_recent_clean" "$LAST_5_FAIL new '인증 응답 이상' since verify baseline (mtime=$LOG_MTIME)"
    else
        check_pass "pre_check_recent_clean"
    fi
else
    check_fail "pre_check_recent_clean" "log missing"
fi

# ⑧ oauth-refresh.log 새 invalid_grant 없음 (baseline 시각 이후, baseline 시각 자체 제외)
if [[ -r "$OAUTH_LOG" ]]; then
    # baseline 이후로 발생한 invalid_grant만 카운트 (> 비교, 동일 시각 제외)
    NEW_INVALID=$(/usr/bin/awk -v base="[$BASELINE_LAST_INVALID_GRANT]" '
        /invalid_grant/ {
            # 줄 시작에 [timestamp] 추출
            match($0, /^\[[^]]+\]/);
            if (RLENGTH > 0) {
                ts = substr($0, RSTART, RLENGTH);
                if (ts > base) c++;
            }
        }
        END { print c+0 }
    ' "$OAUTH_LOG" 2>/dev/null || echo 0)
    NEW_INVALID=$(echo "$NEW_INVALID" | head -1 | tr -d '[:space:]')
    if [[ "${NEW_INVALID:-0}" -gt 0 ]]; then
        check_fail "no_new_invalid_grant" "$NEW_INVALID new invalid_grant since baseline"
    else
        check_pass "no_new_invalid_grant"
    fi
else
    check_pass "no_new_invalid_grant"
fi

# ⑨ crontab oauth-refresh 2줄 여전히 DISABLED
set +e
CRON_DUMP="$(/usr/bin/crontab -l 2>/dev/null)"
DISABLED_COUNT=$(echo "$CRON_DUMP" | /usr/bin/grep -c "^# DISABLED-2026-05-21-race-cond.*oauth-refresh" 2>/dev/null)
DISABLED_COUNT=${DISABLED_COUNT:-0}
ACTIVE_COUNT=$(echo "$CRON_DUMP" | /usr/bin/grep -cE "^[[:space:]]*[0-9*].*oauth-refresh.*\.sh" 2>/dev/null)
ACTIVE_COUNT=${ACTIVE_COUNT:-0}
set -e
if [[ "${DISABLED_COUNT:-0}" -ge 2 ]] && [[ "${ACTIVE_COUNT:-0}" -eq 0 ]]; then
    check_pass "crontab_oauth_disabled"
else
    check_fail "crontab_oauth_disabled" "disabled=$DISABLED_COUNT active=$ACTIVE_COUNT (expected disabled>=2 active=0)"
fi

# ============================================================================
# Ledger 기록 (JSONL, append-only)
# ============================================================================
RESULT="PASS"
if [[ ${#FAIL_REASONS[@]} -gt 0 ]]; then RESULT="FAIL"; fi

CHECKS_JSON="{${CHECKS_JSON%,}}"
FAIL_JSON="[]"
if [[ ${#FAIL_REASONS[@]} -gt 0 ]]; then
    FAIL_JSON=$(printf '%s\n' "${FAIL_REASONS[@]}" | /usr/bin/python3 -c "import json,sys; print(json.dumps([l.rstrip() for l in sys.stdin]))")
fi

mkdir -p "$(dirname "$LEDGER")"
/usr/bin/python3 - <<PYEOF >> "$LEDGER"
import json
print(json.dumps({
    "kst": "$KST_NOW",
    "utc": "$UTC_NOW",
    "phase": "$PHASE",
    "result": "$RESULT",
    "rotated": "$ROTATED" == "true",
    "rotationExpected": "$ROTATION_EXPECTED",
    "expiresAt": $EXPIRES_NOW,
    "expiresBaseline": $BASELINE_EXPIRES,
    "access16": "$ACCESS16",
    "refresh16": "$REFRESH16",
    "healthcheckHttp": "$HC_HTTP",
    "botPid": "$BOT_PID",
    "checks": $CHECKS_JSON,
    "failures": $FAIL_JSON
}))
PYEOF

# ============================================================================
# Discord 알림
# ============================================================================
if [[ "$RESULT" == "FAIL" ]]; then
    FAIL_SUMMARY=$(printf '%s\n' "${FAIL_REASONS[@]}" | head -3 | /usr/bin/tr '\n' '|')
    /bin/bash "$ALERT_SH" critical \
        "OAuth Rotation FAIL ($PHASE)" \
        "회전 검증 실패. 즉시 점검 필요. $FAIL_SUMMARY" \
        '' || true
    echo "[$KST_NOW] FAIL phase=$PHASE — $FAIL_SUMMARY" >&2
    exit 1
else
    /bin/bash "$ALERT_SH" success \
        "OAuth Rotation OK ($PHASE)" \
        "모든 검증 통과. rotated=$ROTATED expiresAt=$EXPIRES_NOW" \
        '' || true
    echo "[$KST_NOW] PASS phase=$PHASE rotated=$ROTATED"
    exit 0
fi
