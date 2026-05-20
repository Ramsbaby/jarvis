#!/usr/bin/env bash
# long-lived-token-rotate.sh — 새 long-lived token 주입 + 검증 + 헬스 체크 자동화
#
# 사용:
#   1. 주인님 별도 터미널: claude auth logout && claude setup-token
#   2. 발급된 토큰을 받아 이 스크립트 호출:
#      bash long-lived-token-rotate.sh '<새 토큰>'
#   3. 스크립트가 credentials.json 백업·주입·검증·헬스 체크까지 일괄 처리

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "사용: $0 '<new-long-lived-token>'" >&2
    exit 1
fi

NEW_TOKEN="$1"
CRED="${HOME}/.claude/.credentials.json"
TOKEN_FILE="${HOME}/.claude/.long-lived-token"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER="${BOT_HOME}/ledger/oauth-refresh-ledger.jsonl"

# 형식 검증
if [[ ! "$NEW_TOKEN" =~ ^sk-ant-oat01- ]]; then
    echo "ERROR: 토큰 형식 오류 — sk-ant-oat01- 접두사 필요" >&2
    exit 1
fi

# 백업
BACKUP="${CRED}.backup-rotate-$(date +%Y%m%d-%H%M%S)"
cp "$CRED" "$BACKUP"
echo "✅ 백업: $BACKUP"

# API ping 사전 검증 (주입 전에 새 토큰이 유효한지)
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST https://api.anthropic.com/v1/messages \
    -H "authorization: Bearer $NEW_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "content-type: application/json" \
    --data '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' || echo "000")

if [[ "$HTTP" != "200" ]]; then
    echo "❌ 새 토큰 검증 실패 (HTTP $HTTP) — credentials.json 미변경, 백업 유지" >&2
    exit 2
fi
echo "✅ 새 토큰 사전 검증 통과 (HTTP 200)"

# 토큰 파일 갱신 (600)
umask 077
printf '%s\n' "$NEW_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
echo "✅ $TOKEN_FILE 갱신 (600)"

# credentials.json 주입 (accessToken + expiresAt 1년 후)
python3 <<PYEOF
import json, time, os
p = '$CRED'
d = json.load(open(p))
d['claudeAiOauth']['accessToken'] = '$NEW_TOKEN'
d['claudeAiOauth']['expiresAt'] = int(time.time() * 1000) + 365 * 86400 * 1000
tmp = p + '.tmp'
with open(tmp, 'w') as f: json.dump(d, f, indent=2)
os.replace(tmp, p)
PYEOF
echo "✅ credentials.json 주입 완료"

# 헬스 체크 즉시 실행
if [[ -x "${BOT_HOME}/scripts/long-lived-token-healthcheck.sh" ]]; then
    bash "${BOT_HOME}/scripts/long-lived-token-healthcheck.sh" || true
fi

# Ledger 기록
mkdir -p "$(dirname "$LEDGER")"
printf '{"ts":"%s","result":"rotation","action":"long-lived-token-rotated","backup":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BACKUP" >> "$LEDGER"

echo ""
echo "🎉 토큰 회전 완료. 자비스 모든 채널이 새 토큰으로 자동 동작."
echo "백업 위치: $BACKUP (안정성 확인 후 삭제 가능)"
