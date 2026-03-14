#!/usr/bin/env bash
set -euo pipefail

# vault-daily-digest.sh — 일일 다이제스트 자동 생성
# Usage: crontab에서 매일 23:50 실행
# 로직: 오늘 수정/생성된 노트를 수집하여 claude -p로 요약 → digest 노트 생성

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
VAULT="${HOME}/Jarvis-Vault"
LOG_TAG="vault-daily-digest"
TODAY=$(date '+%Y-%m-%d')
DIGEST_DIR="$VAULT/02-daily/digest"
DIGEST_FILE="$DIGEST_DIR/${TODAY}.md"

log() { echo "[$(date '+%F %T')] [${LOG_TAG}] $1"; }

if [[ ! -d "$VAULT" ]]; then
    log "ERROR: Vault not found at $VAULT"
    exit 1
fi

mkdir -p "$DIGEST_DIR"

# 이미 생성된 경우 스킵
if [[ -f "$DIGEST_FILE" ]]; then
    log "Digest already exists for $TODAY, skipping"
    exit 0
fi

# --- 1. 오늘 수정된 파일 수집 ---
changed_files=""
changed_count=0

while IFS= read -r -d '' file; do
    relpath="${file#"$VAULT/"}"

    # 메타 파일 스킵
    case "$relpath" in
        _templates/*|README.md|.obsidian/*) continue ;;
        02-daily/digest/*) continue ;;  # 다이제스트 자신은 스킵
    esac

    # frontmatter의 title 추출
    title=$(grep -m1 '^title:' "$file" 2>/dev/null | sed 's/^title: *"*//;s/"*$//' || basename "$file" .md)

    # 본문 미리보기 (frontmatter 제외, 첫 200자)
    preview=$(sed '1,/^---$/d' "$file" 2>/dev/null | sed '1{/^$/d;}' | head -5 | tr '\n' ' ' | cut -c1-200)

    changed_files="${changed_files}
## [[${relpath%.md}|${title}]]
${preview}
"
    changed_count=$((changed_count + 1))
done < <(find "$VAULT" -name "*.md" -not -path "*/.obsidian/*" -not -path "*/.git/*" -mtime 0 -print0 2>/dev/null)

if [[ "$changed_count" -eq 0 ]]; then
    log "No changes today, creating minimal digest"
    cat > "$DIGEST_FILE" << EOF
---
title: "일일 다이제스트 — ${TODAY}"
tags: [area/daily, type/digest]
created: ${TODAY}
updated: ${TODAY}
---

# 일일 다이제스트 — ${TODAY}

오늘 변경된 노트가 없습니다.

---
관련: [[Home]] | [[02-daily/_index|데일리]]
EOF
    log "Minimal digest created"
    exit 0
fi

# --- 2. claude -p로 요약 생성 ---
PROMPT="다음은 오늘(${TODAY}) Jarvis Vault에서 변경된 ${changed_count}개 노트의 내용입니다.

${changed_files}

위 내용을 바탕으로 일일 다이제스트를 작성해주세요:
1. **오늘의 핵심** (1-3줄 요약)
2. **변경 목록** (각 노트의 핵심 변경 사항 1줄씩)
3. **주목할 점** (중요한 인사이트나 연결이 있으면)

마크다운으로 작성하되 frontmatter는 제외하세요. 간결하게."

# ask-claude.sh 사용
STDERR_LOG="$BOT_HOME/logs/claude-stderr-vault-digest.log"
SUMMARY=$("$BOT_HOME/bin/ask-claude.sh" "vault-digest" "$PROMPT" "Read" "120" "0.50" "1" 2>>"$STDERR_LOG" || echo "요약 생성 실패. 수동 확인 필요.")

# 결과 파일에서 내용 추출 (ask-claude.sh는 results/ 에 저장)
RESULT_DIR="$BOT_HOME/results/vault-digest"
if [[ -d "$RESULT_DIR" ]]; then
    LATEST_RESULT=$(find "$RESULT_DIR" -name "*.md" -type f 2>/dev/null | sort -r | head -1)
    if [[ -n "$LATEST_RESULT" && -s "$LATEST_RESULT" ]]; then
        SUMMARY=$(cat "$LATEST_RESULT")
    fi
fi

# --- 3. 다이제스트 파일 생성 ---
cat > "$DIGEST_FILE" << EOF
---
title: "일일 다이제스트 — ${TODAY}"
tags: [area/daily, type/digest]
created: ${TODAY}
updated: ${TODAY}
changes: ${changed_count}
---

# 일일 다이제스트 — ${TODAY}

> 변경된 노트: ${changed_count}개 | Auto-generated

${SUMMARY}

---
관련: [[Home]] | [[02-daily/_index|데일리]]
EOF

log "Digest created: $DIGEST_FILE ($changed_count changes summarized)"
