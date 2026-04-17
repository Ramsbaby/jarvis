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
LEDGER="${HOME}/jarvis/runtime/state/backup-retention.jsonl"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"

mkdir -p "$(dirname "$LEDGER")"

emit() {
  printf '{"ts":"%s","action":"%s","path":"%s","age_days":"%s"}\n' \
    "$TS" "$1" "$2" "$3" >> "$LEDGER"
}

if [[ ! -d "$ROOT" ]]; then echo "no backup root"; exit 0; fi

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

# ═══════════════════════════════════════════════════════════════════════
# A2 migration 추가 (2026-04-17): ~/.jarvis-backup-*, ~/.jarvis.backup-*
# 이들은 migration 시 생성되는 전체 백업. 7일 retention.
# ═══════════════════════════════════════════════════════════════════════
HOME_DELETED=0
for pattern in "$HOME"/.jarvis-backup-* "$HOME"/.jarvis.backup-*; do
    for dir in $pattern; do
        [ -d "$dir" ] || continue
        mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
        age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
        if (( age_days >= 7 )); then
            size_mb=$(du -sm "$dir" 2>/dev/null | awk '{print $1}')
            emit "delete-home-backup" "$dir" "age=${age_days}d,size=${size_mb}MB"
            rm -rf "$dir"
            HOME_DELETED=$((HOME_DELETED+1))
        else
            emit "keep-home-backup" "$dir" "age=${age_days}d"
        fi
    done
done

emit "home-backup-retention-complete" "$HOME" "deleted=$HOME_DELETED"
echo "✅ backup retention: topology=$deleted, home-backup=$HOME_DELETED"