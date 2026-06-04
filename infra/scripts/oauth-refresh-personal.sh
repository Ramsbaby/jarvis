#!/usr/bin/env bash
# oauth-refresh-personal.sh — 비활성화됨 (2026-05-31)
#
# 비활성화 이유: Personal 계정은 Claude CLI가 유일한 갱신 주체.
# 외부 스크립트가 refreshToken을 호출하면 CLI와 race → token family revoke.
# → Claude CLI가 자체적으로 credentials.json을 갱신함. 개입 금지.
#
# 재활성화 조건: 절대 재활성화 금지. 단일 주체 원칙 위반.
LOG="${HOME}/jarvis/runtime/logs/oauth-refresh-personal.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S KST')] [oauth-refresh-personal] NO-OP — Personal CLI 단독 갱신 정책. 개입 안 함." >> "$LOG" 2>/dev/null || true
exit 0
