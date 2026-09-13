#!/bin/bash
# 카카오 access_token 자동 갱신 (6h 만료, refresh_token으로 재발급)
# 2026-09-09 ~/openclaw/scripts → infra/scripts 이전. 오픈클로 state dir 의존 제거.
# 시크릿: $BOT_HOME/secrets/kakao.env (KAKAO_REST_API_KEY, KAKAO_CLIENT_SECRET)
# 토큰:   $BOT_HOME/secrets/kakao-token.json (access_token, refresh_token, expires_at)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
trap 'echo "❌ kakao-token-refresh.sh line $LINENO" >&2' ERR

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
SECRETS_DIR="$BOT_HOME/secrets"
ENV_FILE="$SECRETS_DIR/kakao.env"
TOKEN_FILE="$SECRETS_DIR/kakao-token.json"

[ -f "$ENV_FILE" ] || { echo "ENV_MISSING: $ENV_FILE" >&2; exit 1; }
[ -f "$TOKEN_FILE" ] || { echo "TOKEN_MISSING: $TOKEN_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${KAKAO_REST_API_KEY:?}" "${KAKAO_CLIENT_SECRET:?}"

read -r REFRESH_TOKEN EXPIRES_AT < <(python3 -c "
import json; d=json.load(open('$TOKEN_FILE'))
print(d['refresh_token'], d.get('expires_at','-'))")

# 5시간 이상 남으면 스킵
if [ "$EXPIRES_AT" != "-" ]; then
  EXPIRES_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${EXPIRES_AT%%.*}" +%s 2>/dev/null || echo 0)
  REMAINING=$(( EXPIRES_EPOCH - $(date +%s) ))
  if [ "$REMAINING" -gt 18000 ]; then
    echo "TOKEN_VALID: ${REMAINING}s remaining ($(( REMAINING / 3600 ))h)"; exit 0
  fi
fi

echo "TOKEN_EXPIRED_OR_EXPIRING: refreshing..."
RESPONSE=$(curl -sS -X POST "https://kauth.kakao.com/oauth/token" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "client_id=${KAKAO_REST_API_KEY}" \
  --data-urlencode "refresh_token=${REFRESH_TOKEN}" \
  --data-urlencode "client_secret=${KAKAO_CLIENT_SECRET}")

# 응답 검증 + 파일 갱신 (토큰 값은 stdout에 내지 않는다)
RESPONSE="$RESPONSE" TOKEN_FILE="$TOKEN_FILE" OLD_REFRESH="$REFRESH_TOKEN" python3 - <<'PY'
import json, os, sys, datetime, tempfile
r = json.loads(os.environ['RESPONSE'])
if 'error' in r:
    print(f"REFRESH_FAILED: {r.get('error')} {r.get('error_description','')}"); sys.exit(1)
exp = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(r['expires_in']))
data = {'access_token': r['access_token'],
        'refresh_token': r.get('refresh_token') or os.environ['OLD_REFRESH'],
        'expires_at': exp.strftime('%Y-%m-%dT%H:%M:%S.000Z')}
p = os.environ['TOKEN_FILE']
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix='.kakao-token.')
with os.fdopen(fd, 'w') as f: json.dump(data, f, indent=2)
os.chmod(tmp, 0o600); os.replace(tmp, p)
print(f"REFRESH_SUCCESS expires_at={data['expires_at']} refresh_rotated={'refresh_token' in r}")
PY
