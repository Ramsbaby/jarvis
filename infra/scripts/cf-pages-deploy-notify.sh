#!/usr/bin/env bash
# cf-pages-deploy-notify.sh
# Cloudflare Pages 배포 상태를 폴링해 변화 시 Discord(#jarvis-career)로 알림. # privacy:allow career-narratives
# CF는 GitHub deployment_status를 안 보내므로 CF API 직접 폴링이 유일하게 확실한 방법.
# 크론: */3 * * * * (3분 폴링). 상태 파일로 중복 알림 방지.
set -euo pipefail

ENV="${HOME}/jarvis/runtime/.env"
STATE="${HOME}/jarvis/runtime/state/cf-deploy-last.txt"
MON="${HOME}/jarvis/runtime/config/monitoring.json"
PROJECT="ramsbaby-blog-starter"

CF_KEY=$(grep '^CLOUDFLARE_API_KEY=' "$ENV" 2>/dev/null | cut -d= -f2- || true)
CF_EMAIL=$(grep '^CLOUDFLARE_EMAIL=' "$ENV" 2>/dev/null | cut -d= -f2- || true)
[ -z "${CF_KEY:-}" ] && { echo "ERROR: no CF key — skip" >&2; exit 0; }

WEBHOOK=$(python3 -c "
import json
d=json.load(open('$MON'))
def f(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k=='jarvis-career' and isinstance(v,str) and 'webhook' in v: return v  # privacy:allow career-narratives
            r=f(v)
            if r: return r
    elif isinstance(o,list):
        for x in o:
            r=f(x)
            if r: return r
    return None
print(f(d) or '')
" 2>&1 || true)
[ -z "${WEBHOOK:-}" ] && { echo "ERROR: no webhook — skip" >&2; exit 0; }

auth() { curl -s -w "\n%{http_code}" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" "$@"; }

validate_json() {
  if ! echo "$1" | jq empty 2>/dev/null; then
    return 1
  fi
  return 0
}

ACCT_RESP=$(auth "https://api.cloudflare.com/client/v4/accounts" 2>/dev/null || echo "")
[ -z "$ACCT_RESP" ] && { echo "ERROR: account API 호출 실패 — skip" >&2; exit 0; }
ACCT_CODE=$(echo "$ACCT_RESP" | tail -1)
ACCT_JSON=$(echo "$ACCT_RESP" | sed '$d')
[ "$ACCT_CODE" != "200" ] && { echo "ERROR: account 조회 실패 (HTTP $ACCT_CODE) — skip" >&2; exit 0; }
validate_json "$ACCT_JSON" || { echo "ERROR: account 응답 JSON 파싱 오류 — skip" >&2; exit 0; }
ACCT=$(echo "$ACCT_JSON" | jq -r '.result[0].id' 2>/dev/null)
[ -z "$ACCT" ] || [ "$ACCT" = "null" ] && { echo "ERROR: account ID 조회 실패 — skip" >&2; exit 0; }

DEPLOY_RESP=$(auth "https://api.cloudflare.com/client/v4/accounts/$ACCT/pages/projects/$PROJECT/deployments?per_page=1" 2>/dev/null || echo "")
[ -z "$DEPLOY_RESP" ] && { echo "ERROR: deployment API 호출 실패 — skip" >&2; exit 0; }
DEPLOY_CODE=$(echo "$DEPLOY_RESP" | tail -1)
DEPLOY_JSON=$(echo "$DEPLOY_RESP" | sed '$d')
if [ "$DEPLOY_CODE" != "200" ]; then
  if [ "$DEPLOY_CODE" = "522" ] || [ "$DEPLOY_CODE" = "503" ] || [ "$DEPLOY_CODE" = "429" ]; then
    echo "WARN: API 일시적 오류 (HTTP $DEPLOY_CODE, 다음 재시도 예상) — skip" >&2
  else
    echo "ERROR: 배포 조회 실패 (HTTP $DEPLOY_CODE) — skip" >&2
  fi
  exit 0
fi
validate_json "$DEPLOY_JSON" || { echo "ERROR: deployment 응답 JSON 파싱 오류 — skip" >&2; exit 0; }
DEPLOY=$(echo "$DEPLOY_JSON" | jq '.result[0]' 2>/dev/null)
[ -z "$DEPLOY" ] || [ "$DEPLOY" = "null" ] && { echo "ERROR: 배포 조회 실패 — skip" >&2; exit 0; }

ID=$(echo "$DEPLOY" | jq -r '.id' 2>/dev/null)
STAGE=$(echo "$DEPLOY" | jq -r '.latest_stage.name' 2>/dev/null)
STATUS=$(echo "$DEPLOY" | jq -r '.latest_stage.status' 2>/dev/null)
COMMIT=$(echo "$DEPLOY" | jq -r '.deployment_trigger.metadata.commit_hash // "?"' 2>/dev/null | cut -c1-7)
BRANCH=$(echo "$DEPLOY" | jq -r '.deployment_trigger.metadata.branch // "?"' 2>/dev/null)

[ -z "$ID" ] || [ "$ID" = "null" ] && { echo "ERROR: 배포 ID 추출 실패 — skip" >&2; exit 0; }
[ -z "$STAGE" ] || [ "$STAGE" = "null" ] && { echo "ERROR: 배포 단계 추출 실패 — skip" >&2; exit 0; }
[ -z "$STATUS" ] || [ "$STATUS" = "null" ] && { echo "ERROR: 배포 상태 추출 실패 — skip" >&2; exit 0; }

KEY="$ID:$STAGE:$STATUS"
LAST=$(cat "$STATE" 2>/dev/null || echo "")

# 첫 실행(baseline)은 알림 없이 현재 상태만 기록
if [ -z "$LAST" ]; then echo "$KEY" > "$STATE"; echo "baseline 초기화: $KEY"; exit 0; fi
# 변화 없으면 종료
[ "$KEY" = "$LAST" ] && exit 0

case "$STATUS" in
  success)
    [ "$STAGE" = "deploy" ] && { EMOJI="✅"; TITLE="배포 완료"; COLOR=3066993; } || { echo "$KEY" > "$STATE"; exit 0; } ;;
  failure)
    EMOJI="❌"; TITLE="배포 실패 (${STAGE})"; COLOR=15158332 ;;
  active|running)
    EMOJI="🔵"; TITLE="배포 진행 중 (${STAGE})"; COLOR=3447003 ;;
  *)
    echo "WARN: 알 수 없는 배포 상태: $STATUS — skip" >&2; echo "$KEY" > "$STATE"; exit 0 ;;
esac

PAYLOAD=$(jq -n \
  --arg title "$EMOJI $TITLE — blog.ramsbaby.com" \
  --arg desc "커밋 \`$COMMIT\` · branch \`$BRANCH\`" \
  --arg url "https://blog.ramsbaby.com" \
  --argjson color "$COLOR" \
  --arg footer "Cloudflare Pages · 폴링 알림" \
  '{embeds:[{title:$title, description:$desc, url:$url, color:$color, footer:{text:$footer}}]}')

WEBHOOK_RESP=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK" 2>&1)
WEBHOOK_CODE=$(echo "$WEBHOOK_RESP" | tail -1)
[ "$WEBHOOK_CODE" != "204" ] && [ "$WEBHOOK_CODE" != "200" ] && { echo "ERROR: webhook 호출 실패 (HTTP $WEBHOOK_CODE) — skip" >&2; exit 0; }
echo "$KEY" > "$STATE"
echo "INFO: 알림 전송: $TITLE ($KEY)"
