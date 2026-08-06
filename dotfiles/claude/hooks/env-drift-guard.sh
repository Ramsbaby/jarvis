#!/usr/bin/env bash
# env-drift-guard.sh — settings.json 의 env 와 실제 프로세스 환경이 어긋나면 세션 시작 시 알린다
#
# 계기: 2026-08-06. CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 이 4월 21일 커밋으로 들어갔고
#   8월 5일에 settings.json 에서 지웠는데도 auto memory 가 계속 꺼져 있었다.
#   원인은 8월 1일부터 살아 있던 부모 프로세스(`claude rc`)가 옛 환경을 물고 있었고,
#   그 자식 세션 14개가 전부 그걸 상속받은 것이다.
#   **파일을 고쳐도 이미 뜬 프로세스의 환경은 안 바뀐다.** 그 틈이 106일간 안 보였다.
#
# 무엇을 잡는가:
#   ① settings.json env 에 정의된 키인데 실제 환경 값이 다르다 → 낡은 프로세스가 물고 있다
#   ② settings.json 에 없는데 환경에 살아 있는 기능차단 변수(*DISABLE*) → 유령 설정
#
# 차단하지 않는다. 세션 시작 시 사실만 알린다.
set -uo pipefail

SETTINGS="${HOME}/.claude/settings.json"
[[ -f "$SETTINGS" ]] || exit 0
command -v jq >/dev/null || exit 0

drift=""

# ① 정의된 키의 값 불일치
while IFS=$'\t' read -r key want; do
  [[ -n "$key" ]] || continue
  have="${!key-__UNSET__}"
  if [[ "$have" != "__UNSET__" && "$have" != "$want" ]]; then
    drift+="  · ${key}: 설정=${want} 이지만 실제 환경=${have}"$'\n'
  fi
done < <(jq -r '.env // {} | to_entries[] | "\(.key)\t\(.value)"' "$SETTINGS" 2>/dev/null)

# ② 설정에 없는데 환경에 살아 있는 기능차단 변수
defined="$(jq -r '.env // {} | keys[]' "$SETTINGS" 2>/dev/null)"
while IFS='=' read -r key val; do
  case "$key" in
    *DISABLE*|*_OFF) ;;
    *) continue ;;
  esac
  # 런타임이 자체적으로 넣는 값은 제외
  case "$key" in CLAUDE_CODE_SESSION_*|CLAUDE_CODE_ENTRYPOINT) continue ;; esac
  if ! grep -qx -- "$key" <<<"$defined"; then
    drift+="  · ${key}=${val} — settings.json 에 없는데 환경에 살아 있다(낡은 부모 프로세스 상속 의심)"$'\n'
  fi
done < <(env | grep -E '^(CLAUDE|ENABLE_)' 2>/dev/null)

[[ -n "$drift" ]] || exit 0

msg="⚠️ 환경변수 드리프트 — settings.json 을 고쳐도 이미 떠 있는 프로세스에는 반영되지 않습니다.
${drift}조치: 해당 값을 settings.json 의 env 에 명시하면 상속값을 덮어씁니다(2026-08-06 auto memory 사례).
      또는 부모 프로세스를 재시작합니다."

jq -n --arg m "$msg" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $m
  }
}'
exit 0
