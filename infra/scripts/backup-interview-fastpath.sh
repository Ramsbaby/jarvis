#!/bin/bash
# backup-interview-fastpath.sh
# .gitignore된 interview-fast-path.js를 ~/jarvis/.local-backup/에 timestamp별 백업.
# 23:30 KST stash 사고 영구 차단용 — git reset/stash 시 디스크 휘발 위험을 백업으로 복원.
# cron 등록 권장: 매시간 (0 * * * *)

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
BACKUP_DIR="$JARVIS_HOME/.local-backup"
SOURCE="$JARVIS_HOME/infra/discord/lib/interview-fast-path.js"
TS=$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S)

# 소스 파일 존재 확인
if [[ ! -f "$SOURCE" ]]; then
  echo "[backup-interview-fastpath] CRITICAL — source missing: $SOURCE"
  echo "[backup-interview-fastpath] 가장 최근 백업으로 복원을 시도하십시오:"
  ls -t "$BACKUP_DIR"/interview-fast-path.*.js 2>/dev/null | head -3
  exit 2
fi

mkdir -p "$BACKUP_DIR"
DEST="$BACKUP_DIR/interview-fast-path.${TS}.js"
cp -p "$SOURCE" "$DEST"

# Retention: 최근 48개 백업만 유지 (48시간 = 2일)
ls -t "$BACKUP_DIR"/interview-fast-path.*.js 2>/dev/null | tail -n +49 | while read -r old; do
  rm -f "$old"
done

# 로그
LATEST_COUNT=$(ls -1 "$BACKUP_DIR"/interview-fast-path.*.js 2>/dev/null | wc -l | tr -d ' ')
echo "[backup-interview-fastpath] $TS — backup $DEST (총 $LATEST_COUNT개 보관)"
