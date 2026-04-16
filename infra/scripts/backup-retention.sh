#!/usr/bin/env bash
# backup-retention.sh
#
# ~/backup/jarvis-topology/ 하위 백업을 30일 retention으로 정리.
# auto-recovery로 생성되는 backup/jarvis-topology/auto-recovery/*도 30일 후 삭제.
# 토폴로지 고정 수동 백업(topology-fix-*)은 90일 유지.
#
# 월 1회 실행. 삭제 대상은 원장에 기록.
set -euo pipefail

ROOT="${HOME}/backup/jarvis-topology"
LEDGER="${HOME}/.jarvis/state/backup-retention.jsonl"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"

mkdir -p "$(dirname "$LEDGER")"

emit() {
  printf '{"ts":"%s","action":"%s","path":"%s","age_days":"%s"}\n' \
    "$TS" "$1" "$2" "$3" >> "$LEDGER"
}

[[ ! -d "$ROOT" ]] && { echo "no backup root"; exit 0; }

deleted=0
# auto-recovery/* : 30일
find "$ROOT/auto-recovery" -mindepth 1 -maxdepth 1 -type d -mtime +30 2>/dev/null | while read -r d; do
  age=$(( ( $(date +%s) - $(stat -f %m "$d") ) / 86400 ))
  emit "delete-auto-recovery" "$d" "$age"
  rm -rf "$d"
  deleted=$((deleted+1))
done

# topology-fix-* / pre-reboot-* : 90일
find "$ROOT" -mindepth 1 -maxdepth 1 -type d \( -name 'topology-fix-*' -o -name 'pre-reboot-*' \) -mtime +90 2>/dev/null | while read -r d; do
  age=$(( ( $(date +%s) - $(stat -f %m "$d") ) / 86400 ))
  emit "delete-manual-backup" "$d" "$age"
  rm -rf "$d"
  deleted=$((deleted+1))
done

emit "retention-run-complete" "$ROOT" "deleted=$deleted"
echo "✅ backup retention: deleted $deleted"
