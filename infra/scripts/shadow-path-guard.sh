#!/usr/bin/env bash
# shadow-path-guard.sh — LLM 주입 설정 파일의 ~/.jarvis/runtime/ 그림자 경로 오타 감지
#
# 배경 (2026-06-22 사고):
#   ~/.jarvis 는 ~/jarvis/runtime 을 가리키는 심볼릭 링크다.
#   따라서 설정/프롬프트에 "~/.jarvis/runtime/..." 라고 적으면 runtime 이 한 번 더 붙어
#   ~/jarvis/runtime/runtime/... (그림자 디렉토리)에 데이터가 샌다.
#   이 오타로 ceo-digest 경영 리포트 ~50개가 4월말~6월 그림자에만 쌓이고
#   RAG 인덱싱(정규 teams/reports 대상)에서 누락됐다.
#
# 화이트리스트:
#   같은 줄에 "# ALLOW-DOTJARVIS" 주석이 있으면 의도적 허용으로 통과시킨다
#   (예: persona-integrity-audit.sh 의 로그 디렉토리 전용 ~/.jarvis 참조).
#
# 종료 코드: 위반 발견 시 1, 깨끗하면 0.

set -euo pipefail

JARVIS_ROOT="${JARVIS_ROOT:-${HOME}/jarvis}"

shopt -s nullglob
TARGETS=(
  "$JARVIS_ROOT/runtime/config/tasks.json"
  "$JARVIS_ROOT/runtime/config/effective-tasks.json"
  "$JARVIS_ROOT"/runtime/config/*.md
  "$JARVIS_ROOT"/runtime/config/*.json
  "$JARVIS_ROOT"/infra/agents/*.md
  "$JARVIS_ROOT"/infra/prompts/*.md
)

hits=0
for f in "${TARGETS[@]}"; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$line" | grep -q "ALLOW-DOTJARVIS" && continue
    printf '  ⚠️  %s: %s\n' "$(basename "$f")" "$line"
    hits=$((hits + 1))
  done < <(grep -n '~/\.jarvis/runtime/' "$f" 2>/dev/null || true)
done

if [ "$hits" -gt 0 ]; then
  printf '🚨 그림자 경로 오타 %d건 발견 — "~/.jarvis/runtime/" 는 "~/jarvis/runtime/runtime/" 그림자를 만듭니다.\n' "$hits"
  printf '   수정: "~/.jarvis/runtime/" → "~/jarvis/runtime/" (의도적이면 같은 줄에 "# ALLOW-DOTJARVIS" 주석)\n'
  exit 1
fi

printf '✅ LLM 주입 설정 파일에 그림자 경로 오타 0건\n'
exit 0
