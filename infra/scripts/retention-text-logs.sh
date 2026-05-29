#!/usr/bin/env bash
# retention-text-logs.sh — 디스코드 봇 텍스트 로그 회전 (err.log/out.log)
#
# [2026-05-29 결함 수리 #9]
#   배경: retention-jsonl.sh가 JSONL만 관리, discord-bot.err.log/out.log는 무한 누적.
#         감사관 적발: err.log 1,265줄(82KB) + out.log 1MB+. SyntaxError 잔재 누적.
#   해결: 일정 크기 초과 시 timestamp suffix 붙여 gzip 압축 후 archive.
#         원본은 truncate(copytruncate 패턴) — 봇 프로세스 파일 디스크립터 유지.
#
# 매일 04:30 KST 실행 (retention-jsonl.sh 직후).

set -uo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
ARCHIVE_DIR="${BOT_HOME}/archive/text-logs"
LOG="${BOT_HOME}/logs/retention-text-logs.log"

ROTATE_MB="${ROTATE_MB_TEXT:-10}"           # 10MB 초과 시 회전
KEEP_ARCHIVE_DAYS="${KEEP_ARCHIVE_DAYS:-90}" # gzip 보관 90일

mkdir -p "$ARCHIVE_DIR"

_log() { printf '[%s] [retention-text-logs] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

_log "=== 시작 ==="

SIZE_LIMIT=$((ROTATE_MB * 1024 * 1024))
ROTATED=0
SKIPPED=0

# 대상 텍스트 로그
TARGETS=(
    "${BOT_HOME}/logs/discord-bot.err.log"
    "${BOT_HOME}/logs/discord-bot.out.log"
    "${BOT_HOME}/logs/proactive-engine.log"
    "${BOT_HOME}/logs/proactive-engine-v2.log"
    "${BOT_HOME}/logs/mistake-extractor.log"
    "${BOT_HOME}/logs/insight-extractor.log"
    "${BOT_HOME}/logs/mistake-to-skill.log"
    "${BOT_HOME}/logs/mistake-circuit-healthcheck-err.log"
)

for target in "${TARGETS[@]}"; do
    [ ! -f "$target" ] && { SKIPPED=$((SKIPPED + 1)); continue; }
    SIZE=$(stat -f%z "$target" 2>/dev/null || stat -c%s "$target" 2>/dev/null || echo 0)
    [ "$SIZE" -lt "$SIZE_LIMIT" ] && continue

    BASENAME=$(basename "$target")
    TS=$(date '+%Y%m%d-%H%M%S')
    ARCHIVE="${ARCHIVE_DIR}/${BASENAME}.${TS}.gz"

    # gzip 압축 (원본은 그대로) — 봇 프로세스 fd 보호
    if gzip -c "$target" > "$ARCHIVE" 2>/dev/null; then
        # archive 성공 후 원본 truncate (copytruncate 패턴)
        : > "$target"
        ROTATED=$((ROTATED + 1))
        _log "회전: $BASENAME ($SIZE bytes → $ARCHIVE)"
    else
        _log "❌ gzip 실패: $target"
    fi
done

# 오래된 archive 정리 (90일 초과)
DELETED=0
while IFS= read -r old; do
    rm -f "$old" && DELETED=$((DELETED + 1))
done < <(find "$ARCHIVE_DIR" -name '*.gz' -mtime +"$KEEP_ARCHIVE_DAYS" 2>/dev/null)

_log "=== 완료 — rotated=$ROTATED, skipped=$SKIPPED, archive_deleted=$DELETED ==="
exit 0
