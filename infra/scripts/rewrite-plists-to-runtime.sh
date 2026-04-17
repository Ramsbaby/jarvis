#!/usr/bin/env bash
set -euo pipefail
# rewrite-plists-to-runtime.sh — LaunchAgent plist의 ~/.jarvis 경로를
# ~/jarvis/runtime 경로로 일괄 치환. A2 migration Phase D 선결.
#
# Usage:
#   bash rewrite-plists-to-runtime.sh --dry-run   # 변경 사항 미리보기만
#   bash rewrite-plists-to-runtime.sh --apply     # 실제 치환 + 재등록
#
# 동작:
#   1. ~/Library/LaunchAgents/*.plist 중 ~/.jarvis 참조하는 것 탐지
#   2. 백업 → ~/backup/plists-phase-d/<TS>/
#   3. 치환: /Users/ramsbaby/jarvis/runtime/ → /Users/ramsbaby/jarvis/runtime/
#   4. 각 LaunchAgent bootout + bootstrap (재등록)
#   5. 결과 원장 기록

MODE="${1:---dry-run}"
PLIST_DIR="$HOME/Library/LaunchAgents"
BACKUP_ROOT="$HOME/backup/plists-phase-d"
TS=$(date '+%Y-%m-%d-%H%M%S')
BACKUP_DIR="$BACKUP_ROOT/$TS"
LOG="$HOME/jarvis/runtime/logs/phase-d-plists.log"
UID_NUM=$(id -u)

OLD_PREFIX="/Users/ramsbaby/jarvis/runtime/"
NEW_PREFIX="/Users/ramsbaby/jarvis/runtime/"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ ! -d "$PLIST_DIR" ]]; then die "$PLIST_DIR 없음"; fi

# 대상 plist 식별 (disabled 제외) — bash 3.2 호환 (mapfile 없음)
TARGETS=()
while IFS= read -r plist; do
    if [[ -n "$plist" ]]; then
        TARGETS+=("$plist")
    fi
done < <(grep -l "$OLD_PREFIX" "$PLIST_DIR"/*.plist 2>/dev/null || true)

log "=== Phase D plist 치환 (mode=$MODE) ==="
log "대상: ${#TARGETS[@]}개"

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
    log "치환 대상 없음"
    exit 0
fi

case "$MODE" in
    --dry-run)
        log "=== DRY RUN ==="
        for plist in "${TARGETS[@]}"; do
            name=$(basename "$plist" .plist)
            count=$(grep -c "$OLD_PREFIX" "$plist" 2>/dev/null || echo 0)
            echo "  $name: $count 건"
        done
        log "실제 실행: bash $0 --apply"
        ;;

    --apply)
        # 1. 백업
        mkdir -p "$BACKUP_DIR"
        cp -p "${TARGETS[@]}" "$BACKUP_DIR/"
        log "백업: $BACKUP_DIR (${#TARGETS[@]}개)"

        # 2. 치환 + 재등록
        applied=0
        failed=0
        for plist in "${TARGETS[@]}"; do
            name=$(basename "$plist" .plist)
            count=$(grep -c "$OLD_PREFIX" "$plist" 2>/dev/null || echo 0)

            # sed in-place (macOS 호환: -i '')
            if sed -i '' "s|$OLD_PREFIX|$NEW_PREFIX|g" "$plist" 2>>"$LOG"; then
                # bootout + bootstrap (idempotent)
                launchctl bootout "gui/${UID_NUM}/${name}" 2>/dev/null || true
                sleep 0.3
                if launchctl bootstrap "gui/${UID_NUM}" "$plist" 2>>"$LOG"; then
                    log "OK: $name (${count}건 치환 + 재등록)"
                    applied=$((applied + 1))
                else
                    log "WARN: $name 치환 OK, bootstrap 실패 (비활성 상태일 수 있음)"
                    applied=$((applied + 1))
                fi
            else
                log "FAIL: $name sed 실패"
                failed=$((failed + 1))
            fi
        done

        log "=== 완료: 적용 $applied개, 실패 $failed개 ==="
        log "롤백: cp -p $BACKUP_DIR/*.plist $PLIST_DIR/ && launchctl 재등록"
        echo "✅ plist Phase D 치환: $applied/$((applied+failed)), backup=$BACKUP_DIR"
        ;;

    *)
        die "Usage: $0 [--dry-run|--apply]"
        ;;
esac