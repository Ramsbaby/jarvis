#!/usr/bin/env bash
# disable-plist-with-ledger.sh — LaunchAgent plist disable 표준 헬퍼
#
# Why: 정합화 작업에서 disable 후 ledger 누락 사례 발생 (Phase 1 28건).
#      모든 disable 작업이 이 헬퍼를 거치면 audit trail이 자동 보장됨.
#
# Usage:
#   disable-plist-with-ledger.sh <label> [reason] [phase]
#   disable-plist-with-ledger.sh com.jarvis.foo "Nexus 위임" "manual-2026-04-16"
#
# 효과:
#   1. launchctl bootout
#   2. .plist → .plist.disabled rename (ctime 자동 기록)
#   3. ~/jarvis/runtime/ledger/policy-fix-disable.jsonl 에 append-only 기록
#   4. 실패 시 exit 1 + 원장에 failure 기록

set -euo pipefail

LABEL="${1:-}"
REASON="${2:-manual disable}"
PHASE="${3:-manual}"

if [[ -z "$LABEL" ]]; then
  echo "Usage: $0 <label> [reason] [phase]" >&2
  exit 2
fi

LEDGER_DIR="${HOME}/jarvis/runtime/ledger"
LEDGER_FILE="${LEDGER_DIR}/policy-fix-disable.jsonl"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$LEDGER_DIR"

# 0. 검증
if [[ ! -f "$PLIST" ]]; then
  printf '{"ts":"%s","phase":"%s","label":"%s","action":"skip","reason":"plist_not_found","ok":false}\n' \
    "$TS_ISO" "$PHASE" "$LABEL" >> "$LEDGER_FILE"
  echo "[disable-plist] SKIP $LABEL — plist not found" >&2
  exit 1
fi

# 1. launchctl bootout (실패해도 진행)
UID_NUM=$(id -u)
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true

# 2. mv → .disabled
if mv "$PLIST" "${PLIST}.disabled"; then
  # 3. ledger
  printf '{"ts":"%s","phase":"%s","label":"%s","task_id":"%s","action":"disable","reason":"%s","plist_disabled":true,"ok":true}\n' \
    "$TS_ISO" "$PHASE" "$LABEL" "${LABEL#com.jarvis.}" "$REASON" >> "$LEDGER_FILE"
  echo "[disable-plist] OK $LABEL"
  exit 0
else
  printf '{"ts":"%s","phase":"%s","label":"%s","action":"mv_failed","reason":"%s","ok":false}\n' \
    "$TS_ISO" "$PHASE" "$LABEL" "$REASON" >> "$LEDGER_FILE"
  echo "[disable-plist] FAIL $LABEL — mv failed" >&2
  exit 1
fi