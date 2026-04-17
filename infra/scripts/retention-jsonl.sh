#!/usr/bin/env bash
# retention-jsonl.sh — JSONL 원장 무한 성장 방지
#
# 정책:
#   - 파일 크기 > ROTATE_MB (기본 20MB) 시 .1로 rotate
#   - .1이 이미 있으면 .2 → .3 ... 최대 KEEP_N (기본 3)까지 보존
#   - KEEP_N 초과분은 gzip 압축 후 별도 ~/.jarvis/archive/ 에 이동
#   - 압축본도 KEEP_ARCHIVE_DAYS (기본 90일) 넘으면 삭제
#
# 실행: 매일 새벽 크론 (아래 crontab 추가 필요)
# 대상: ~/.jarvis/state/*.jsonl + ~/.jarvis/logs/ 중 센서 관련 파일

set -euo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
ARCHIVE_DIR="${BOT_HOME}/archive/jsonl"
LOG="${BOT_HOME}/logs/retention-jsonl.log"

ROTATE_MB="${ROTATE_MB:-20}"
KEEP_N="${KEEP_N:-3}"
KEEP_ARCHIVE_DAYS="${KEEP_ARCHIVE_DAYS:-90}"

mkdir -p "$ARCHIVE_DIR"

TS=$(date '+%Y-%m-%d %H:%M:%S')
SIZE_LIMIT=$((ROTATE_MB * 1024 * 1024))

# 관리 대상 파일 — Phase 0 센서 원장 + Nexus 텔레메트리 + 기존 지속 로그
TARGETS=(
    "${BOT_HOME}/state/response-ledger.jsonl"
    "${BOT_HOME}/state/feedback-score.jsonl"
    "${BOT_HOME}/state/reask-tracker.jsonl"
    "${BOT_HOME}/state/tool-guard-trips.jsonl"
    "${BOT_HOME}/state/permission-denied.jsonl"
    "${BOT_HOME}/state/mcp-tool-call.jsonl"
    "${BOT_HOME}/state/commitments.jsonl"
    "${BOT_HOME}/state/tool-call-ledger.jsonl"
    "${BOT_HOME}/logs/nexus-telemetry.jsonl"
    "${BOT_HOME}/logs/discord-bot.jsonl"
    "${BOT_HOME}/logs/cross-surface-audit.log"
)

rotate_one() {
    local f="$1"
    if [[ ! -f "$f" ]]; then return 0; fi
    local size
    size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null || echo 0)
    if [[ "$size" -lt "$SIZE_LIMIT" ]]; then return 0; fi

    local base
    base=$(basename "$f")

    # Tail rotate .N → .(N+1)
    local i=$((KEEP_N))
    while [[ "$i" -gt 0 ]]; do
        local src="${f}.${i}"
        if [[ -f "$src" ]]; then
            if [[ "$i" -eq "$KEEP_N" ]]; then
                # KEEP_N 초과분 gzip 후 archive 이동
                local archived="${ARCHIVE_DIR}/${base}.$(date -r "$src" '+%Y%m%d-%H%M%S').gz"
                gzip -c "$src" > "$archived" 2>/dev/null && rm -f "$src" \
                    && echo "[$TS] archive: $base.$i → $archived" >> "$LOG"
            else
                mv "$src" "${f}.$((i+1))" 2>/dev/null
            fi
        fi
        i=$((i-1))
    done

    # 현재 파일 → .1
    mv "$f" "${f}.1" 2>/dev/null
    # 빈 파일 재생성 (append 기다리는 프로세스 깨지지 않게)
    : > "$f"
    echo "[$TS] rotate: $base (size=${size}B → .1)" >> "$LOG"
}

archive_cleanup() {
    find "$ARCHIVE_DIR" -name '*.gz' -type f -mtime "+${KEEP_ARCHIVE_DAYS}" -delete 2>/dev/null || true
}

echo "[$TS] === retention-jsonl start ===" >> "$LOG"
for t in "${TARGETS[@]}"; do
    rotate_one "$t"
done
archive_cleanup
echo "[$TS] === retention-jsonl end ===" >> "$LOG"

exit 0
