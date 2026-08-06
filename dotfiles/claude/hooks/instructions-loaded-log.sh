#!/usr/bin/env bash
# instructions-loaded-log.sh — 어떤 지시 파일이 언제·왜 로드됐는지 원장에 남긴다 (InstructionsLoaded 훅)
#
# 계기: 2026-08-06. auto memory 가 2026-04-21 커밋 dd3d693 으로 106일간 꺼져 있었고,
#   다시 켠 뒤에도 "MEMORY.md 가 실제로 로드됐는가"를 확인할 방법이 추측밖에 없었다.
#   공식 InstructionsLoaded 훅은 CLAUDE.md 와 .claude/rules/*.md 의 로드를 이벤트로 준다.
#   이 훅은 차단하지 않는다 — 공식 문서상 이 이벤트의 exit code 는 무시된다. 계측 전용이다.
#
# 원장: ~/jarvis/runtime/state/instructions-loaded.jsonl
#   조회: node ~/jarvis/infra/scripts/instructions-loaded-report.mjs
set -uo pipefail

LEDGER="${BOT_HOME:-${HOME}/jarvis/runtime}/state/instructions-loaded.jsonl"
MAXBYTES=$((5 * 1024 * 1024))

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || exit 0

# 원장 rotation — 훅은 세션마다 파일 수만큼 발화하므로 상한을 둔다
if [[ -f "$LEDGER" ]]; then
  size=$(stat -f "%z" "$LEDGER" 2>/dev/null || echo 0)
  if (( size > MAXBYTES )); then
    gzip -c "$LEDGER" > "${LEDGER%.jsonl}-$(date +%Y%m%d-%H%M%S).jsonl.gz" 2>/dev/null || true
    : > "$LEDGER"
  fi
fi

printf '%s' "$input" | jq -c --arg ts "$(date -Iseconds)" '{
  ts: $ts,
  session_id: (.session_id // null),
  reason:     (.load_reason // .hook_event_name // null),
  file:       (.file_path // null),
  cwd:        (.cwd // null)
}' >> "$LEDGER" 2>/dev/null || true

exit 0
