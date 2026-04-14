#!/usr/bin/env bash
set -euo pipefail
# auto-insight.sh — 에이전트 인사이트 자동 저장
#
# Usage:
#   auto-insight.sh <category> <title> <content>
#
# 저장 위치: ${VAULT_DIR:-$HOME/vault}/03-insights/YYYY-MM-DD-<category>.md
# rag-watcher가 변경 감지 → LanceDB 자동 인덱싱 (자율 진화 루프)

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
source "${BOT_HOME}/lib/compat.sh" 2>/dev/null || {
  IS_MACOS=false; case "$(uname -s)" in Darwin) IS_MACOS=true ;; esac
}
VAULT_INSIGHTS="${VAULT_DIR:-$HOME/vault}/03-insights"
LOCK_DIR="$BOT_HOME/state"

CATEGORY="${1:-general}"
TITLE="${2:-}"
CONTENT="${3:-}"

if [[ -z "$TITLE" || -z "$CONTENT" ]]; then
    echo "Usage: auto-insight.sh <category> <title> <content>" >&2
    exit 1
fi

mkdir -p "$VAULT_INSIGHTS" "$LOCK_DIR"

TODAY=$(date '+%Y-%m-%d')
TIMESTAMP=$(date '+%H:%M')
FILE="$VAULT_INSIGHTS/${TODAY}-${CATEGORY}.md"
LOCK_DIR_PATH="$LOCK_DIR/insight-${CATEGORY}.lock.d"

# mkdir 기반 atomic lock (macOS flock 미지원 대응)
LOCK_ACQUIRED=0
for i in {1..10}; do
    if mkdir "$LOCK_DIR_PATH" 2>/dev/null; then
        LOCK_ACQUIRED=1
        break
    fi
    sleep 0.2
done

if [[ $LOCK_ACQUIRED -eq 0 ]]; then
    echo "[auto-insight] Lock 획득 실패 — 중단" >&2
    exit 1
fi

cleanup() { rmdir "$LOCK_DIR_PATH" 2>/dev/null || true; }
trap cleanup EXIT

# 파일 없으면 frontmatter 포함하여 새로 생성
if [[ ! -f "$FILE" ]]; then
    cat > "$FILE" <<FRONTMATTER
---
title: "Insights — ${CATEGORY} — ${TODAY}"
tags: [area/insights, type/auto, category/${CATEGORY}]
created: ${TODAY}
updated: ${TODAY}
---

# ${TODAY} ${CATEGORY} 인사이트

FRONTMATTER
fi

# frontmatter updated 갱신
if ${IS_MACOS:-false}; then
    sed -i '' "s/^updated: .*/updated: ${TODAY}/" "$FILE" 2>/dev/null || true
else
    sed -i "s/^updated: .*/updated: ${TODAY}/" "$FILE" 2>/dev/null || true
fi

# 인사이트 항목 추가
cat >> "$FILE" <<ENTRY

## ${TIMESTAMP} — ${TITLE}

${CONTENT}

ENTRY

echo "[auto-insight] 저장 완료: $FILE"
