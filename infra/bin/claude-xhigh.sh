#!/usr/bin/env bash
# claude-xhigh.sh — Wrapper that starts Claude Code with --effort xhigh.
#
# Purpose:
#   For skills where reasoning depth is decisive (e.g. /verify, /plan-review),
#   this wrapper auto-applies Opus 4.7's xhigh effort so the user does not
#   have to type the flag every time.
#
# Usage:
#   claude-xhigh.sh             # interactive session
#   claude-xhigh.sh -p "..."    # print mode
#
# Cost impact:
#   xhigh consumes about 2x tokens vs medium. Opus 4.7 only.
#   For lighter code review use /review (effort-agnostic).
#
# Provenance:
#   Added 2026-05-13 after Anthropic Claude Code v2.1.139 introduced
#   the xhigh effort level. Bundled with guidance sections in the
#   /verify and /plan-review skill bodies.

set -euo pipefail

# Model guard — xhigh is Opus 4.7 only.
if [[ "${CLAUDE_MODEL:-}" =~ sonnet|haiku ]]; then
  echo "WARN: xhigh effort is Opus 4.7 only. Current model: ${CLAUDE_MODEL}" >&2
  echo "      Sonnet/Haiku support up to --effort high." >&2
fi

# CLI version guard — v2.1.130+ required (xhigh introduction version).
if command -v claude >/dev/null 2>&1; then
  ver=$(claude --version 2>/dev/null | awk '{print $1}' | tr -d '.')
  # 2.1.130 = 21130 as an integer comparison.
  if [[ "${ver:-0}" -lt 21130 ]]; then
    echo "WARN: Claude Code v2.1.130+ required for --effort xhigh." >&2
    echo "      Current version: $(claude --version 2>/dev/null)" >&2
    echo "      Falling back to default effort." >&2
    exec claude "$@"
  fi
fi

exec claude --effort xhigh "$@"
