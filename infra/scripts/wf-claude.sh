#!/usr/bin/env bash
# wf-claude.sh — 워크플로/병렬작업 전용 claude 런처 (2026-05-30)
#
# 문제: 워크플로는 N개 claude 에이전트를 거의 동시에 spawn → 전부 메인 금고(~/.claude)의
#   회전형 refresh_token을 공유 → 동시 갱신 시 reuse race → 토큰 패밀리 revoke → 전멸.
#   (봇은 메시지를 1~2개씩 순차 처리라 race 확률 낮음. 워크플로는 8개 동시라 최악.)
#
# 해법(실측 검증 2026-05-30): 메인의 현재 access_token을 CLAUDE_CODE_OAUTH_TOKEN env로 주입.
#   - env 토큰은 credentials.json을 안 읽고 '갱신을 시도하지 않음'(SDK 우선순위: env > 파일).
#   - access_token은 만료 전까지 유효(revoke 대상은 refresh_token뿐). 공유해도 '사용'만 → 충돌 불가.
#   - 검증: 같은 env access_token으로 claude 3개 동시 실행 → 3/3 성공, 메인 credentials mtime 불변.
#   ∴ 이 런처로 띄운 세션에서 워크플로를 돌리면 N개 에이전트가 env 토큰을 상속 → race 원천 차단.
#
# 만료: access_token은 ~8h 수명. 이 런처는 '실행 시점'의 신선한 토큰을 추출하므로 매 기동마다 최신.
#   세션이 8h 넘게 살면 그 안에서 만료될 수 있으나, 워크플로 작업은 분 단위라 무관.
#
# 사용:
#   bash wf-claude.sh                  # 새 워크플로 세션 (정적 토큰)
#   bash wf-claude.sh --continue       # 기존 대화를 정적 토큰으로 이어받아 재개
#   bash wf-claude.sh -p "..."         # 비대화형
#
# 메인 무간섭: 이 런처는 메인 credentials.json을 read만 한다(write/갱신 없음).

set -euo pipefail

CRED="${HOME}/.claude/.credentials.json"
[[ -f "$CRED" ]] || { echo "❌ 메인 credentials 없음 ($CRED) — 'claude /login' 필요" >&2; exit 1; }

# 메인 access_token 추출 (read only, 값 노출 없이 env로만 전달)
MTOK="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('${CRED}','utf-8')).claudeAiOauth?.accessToken||'')" 2>/dev/null)"
[[ -n "$MTOK" ]] || { echo "❌ access_token 추출 실패 — credentials 손상? 'claude /login' 필요" >&2; exit 1; }

# 만료 잔여 점검 (만료 임박하면 경고 — 갱신은 메인 세션/oauth-refresh에 위임)
_REMAIN_S="$(node -e "const e=JSON.parse(require('fs').readFileSync('${CRED}','utf-8')).claudeAiOauth?.expiresAt||0; process.stdout.write(String(Math.floor((e-Date.now())/1000)))" 2>/dev/null || echo 0)"
if (( _REMAIN_S < 1800 )); then
  echo "⚠️  메인 access_token 만료까지 ${_REMAIN_S}s — 곧 만료. 워크플로가 길면 중간에 끊길 수 있음(메인 세션에서 갱신 후 재기동 권장)." >&2
fi

echo "🔒 워크플로 정적 토큰 세션 — 메인 access_token을 env 주입 (갱신 안 함, race 면역). 잔여 ${_REMAIN_S}s" >&2
exec env CLAUDE_CODE_OAUTH_TOKEN="$MTOK" claude "$@"
