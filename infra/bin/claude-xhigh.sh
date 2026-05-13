#!/usr/bin/env bash
# claude-xhigh.sh — Claude Code를 xhigh effort로 시작하는 자비스 wrapper
#
# 용도:
#   주인님이 /verify 또는 /plan-review 같이 추론 깊이가 결정적인 스킬을
#   실행하실 때 Opus 4.7의 xhigh effort를 자동 적용합니다.
#
# 사용:
#   ~/jarvis/infra/bin/claude-xhigh.sh           # 인터랙티브 세션
#   ~/jarvis/infra/bin/claude-xhigh.sh -p "..."  # print 모드
#
# 비용 영향:
#   xhigh는 medium 대비 약 2배 토큰 소비. Opus 4.7 전용.
#   가벼운 코드 리뷰는 /review (effort 무관) 사용 권장.
#
# 영구 등재:
#   2026-05-13 — Anthropic Claude Code v2.1.139 xhigh effort 도입 후 자비스
#   /verify, /plan-review 스킬에 안내 섹션 추가와 동시에 작성.

set -euo pipefail

# 모델 확인 — xhigh는 Opus 4.7 전용
if [[ "${CLAUDE_MODEL:-}" =~ sonnet|haiku ]]; then
  echo "⚠️  주인님, xhigh effort는 Opus 4.7 전용입니다. 현재 모델: ${CLAUDE_MODEL}" >&2
  echo "    Sonnet/Haiku는 --effort high까지만 가능합니다." >&2
fi

# CLI 버전 가드 — v2.1.130 이상 필요 (xhigh 도입 버전)
if command -v claude >/dev/null 2>&1; then
  ver=$(claude --version 2>/dev/null | awk '{print $1}' | tr -d '.')
  # 2.1.130 = 21130 정수 비교
  if [[ "${ver:-0}" -lt 21130 ]]; then
    echo "⚠️  주인님, Claude Code v2.1.130 미만은 xhigh effort 미지원입니다." >&2
    echo "    현재 버전: $(claude --version 2>/dev/null)" >&2
    echo "    --effort 옵션 없이 진행합니다." >&2
    exec claude "$@"
  fi
fi

exec claude --effort xhigh "$@"
