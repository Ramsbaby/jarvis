#!/usr/bin/env bash
# claude-model-audit — Anthropic Claude API 사용자를 위한 모델 버전 자동 audit
#
# 기능:
#   - 사용자 코드베이스에서 deprecated 모델 ID 발견 시 알림
#   - 정책 SSoT (model-policy.json) 단일 파일 기반
#   - Discord / Slack / Email 알림 (선택)
#
# 사용:
#   bash audit.sh                                    # default policy + 현재 디렉토리 검사
#   POLICY=./config/model-policy.json bash audit.sh  # 명시 정책
#   AUDIT_PATHS=src,lib bash audit.sh                # 검사 경로 명시 (콤마 구분)
#   NOTIFY_WEBHOOK=https://... bash audit.sh         # Discord/Slack webhook
#
# 환경변수 (모두 선택):
#   POLICY              - model-policy.json 경로 (default: ./config/model-policy.json)
#   AUDIT_PATHS         - 검사 경로 (콤마 구분, default: 현재 디렉토리)
#   AUDIT_EXCLUDE       - 제외 패턴 (default: node_modules,.git,docs)
#   NOTIFY_WEBHOOK      - Discord/Slack webhook URL (선택)
#   LOG_FILE            - 로그 경로 (default: ./audit.log)
#
# Exit code: 0 = PASS, 1 = 위반 발견, 2 = config error

set -uo pipefail

POLICY="${POLICY:-./config/model-policy.json}"
AUDIT_PATHS="${AUDIT_PATHS:-.}"
AUDIT_EXCLUDE="${AUDIT_EXCLUDE:-node_modules,.git,docs,packages/claude-model-audit}"
LOG_FILE="${LOG_FILE:-./audit.log}"
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if ! command -v jq >/dev/null 2>&1; then
    _log "ERROR: jq required (brew install jq)"
    exit 2
fi

if [ ! -f "$POLICY" ]; then
    _log "ERROR: policy file not found: $POLICY"
    _log "       샘플 생성: cp ./config/model-policy.example.json $POLICY"
    exit 2
fi

DEPRECATED=$(jq -r '.deprecated[]?' "$POLICY")
LATEST_OPUS=$(jq -r '.currentLatest.opus // ""' "$POLICY")
LATEST_SONNET=$(jq -r '.currentLatest.sonnet // ""' "$POLICY")
LATEST_HAIKU=$(jq -r '.currentLatest.haiku // ""' "$POLICY")

_log "audit start — latest: opus=$LATEST_OPUS sonnet=$LATEST_SONNET haiku=$LATEST_HAIKU"
_log "audit paths: $AUDIT_PATHS / exclude: $AUDIT_EXCLUDE"

# 검사 경로 → array
IFS=',' read -ra PATHS_ARR <<< "$AUDIT_PATHS"
EXCLUDE_GREP=$(echo "$AUDIT_EXCLUDE" | tr ',' '|')

VIOLATIONS=""
TOTAL=0

for dep in $DEPRECATED; do
    HITS=$(grep -rEln "$dep" "${PATHS_ARR[@]}" 2>/dev/null \
        | grep -vE "$EXCLUDE_GREP|$POLICY|audit\.(sh|log)|\.gitignore|README|LICENSE|\.example\.(json|yaml|toml)$" \
        || true)
    if [ -n "$HITS" ]; then
        COUNT=$(echo "$HITS" | wc -l | tr -d ' ')
        VIOLATIONS+="$dep ($COUNT 파일):\n$HITS\n\n"
        TOTAL=$((TOTAL + COUNT))
    fi
done

if [ "$TOTAL" -eq 0 ]; then
    _log "PASS: 모델 정책 위반 0건"
    exit 0
fi

_log "FAIL: $TOTAL 건 위반"
echo -e "$VIOLATIONS" | tee -a "$LOG_FILE"

# Webhook 알림 (Discord / Slack 형식)
if [ -n "$NOTIFY_WEBHOOK" ]; then
    SUMMARY=$(echo -e "$VIOLATIONS" | head -10)
    PAYLOAD=$(jq -nc --arg c "🚨 Claude 모델 정책 위반 $TOTAL건 발견\n\`\`\`\n$SUMMARY\n\`\`\`" '{content: $c}')
    curl -s -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$NOTIFY_WEBHOOK" >/dev/null 2>&1 \
        && _log "Webhook 알림 송출 완료" \
        || _log "Webhook 알림 실패 (계속 진행)"
fi

exit 1
