#!/usr/bin/env bash
set -euo pipefail

# vault-auto-link.sh — 새/수정된 노트에 관련 노트 링크 자동 추가
# Usage: crontab에서 매일 실행 (또는 수동: vault-auto-link.sh [HOURS])
#
# 규칙:
#   1. 같은 팀 보고서끼리는 링크하지 않음 (노이즈 방지)
#   2. 팀 보고서(team-YYYY-*)는 링크 타겟에서 제외 (고유 키워드 없음)
#   3. 최소 6글자 이상 키워드만 매칭 (오탐 방지)
#   4. _index, Home, 템플릿은 처리 대상에서 제외

VAULT="${HOME}/Jarvis-Vault"
LOG_TAG="vault-auto-link"
HOURS_AGO="${1:-24}"

# Ensure HOURS_AGO is set (defensive against unbound variable errors)
if [[ -z "${HOURS_AGO}" ]]; then
    HOURS_AGO=24
fi

log() { echo "[$(date '+%F %T')] [${LOG_TAG}] $1"; }

if [[ ! -d "$VAULT" ]]; then
    log "ERROR: Vault not found at $VAULT"
    exit 1
fi

# --- 1. 링크 타겟 수집 (의미 있는 문서만) ---
declare -a note_titles=()
declare -a note_paths=()

while IFS= read -r -d '' file; do
    relpath="${file#"$VAULT/"}"
    filename=$(basename "$file" .md)

    # 제외 대상
    case "$relpath" in
        _templates/*|README.md|Home.md) continue ;;
        */_index.md) continue ;;
    esac

    # 팀 보고서(team-YYYY-*) 제외 — 이것들은 타겟이 되면 노이즈만 만듦
    if echo "$filename" | grep -qE '^[a-z]+-[0-9]{4}'; then continue; fi

    # 날짜만 있는 파일(YYYY-MM-DD) 제외
    if echo "$filename" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then continue; fi

    # 제목이 6글자 이상만 (너무 짧으면 오탐)
    if [[ ${#filename} -ge 6 ]]; then
        note_titles+=("$filename")
        note_paths+=("${relpath%.md}")
    fi
done < <(find "$VAULT" -name "*.md" -not -path "*/.obsidian/*" -not -path "*/.git/*" -print0)

log "Collected ${#note_titles[@]} linkable targets"

# --- 2. 최근 수정 파일에서 관련 노트 발견 ---
linked=0

while IFS= read -r -d '' file; do
    relpath="${file#"$VAULT/"}"
    filename=$(basename "$file" .md)

    # 메타 파일 스킵
    case "$relpath" in
        _templates/*|README.md|Home.md) continue ;;
        */_index.md) continue ;;
    esac

    content=$(cat "$file")

    # 이미 "자동 발견 링크" 섹션이 있으면 스킵
    if echo "$content" | grep -q "## 자동 발견 링크" 2>/dev/null; then continue; fi

    found_links=""
    found_count=0

    for i in "${!note_titles[@]}"; do
        title="${note_titles[$i]}"
        path="${note_paths[$i]}"

        # 자기 자신은 스킵
        if [[ "${relpath%.md}" == "$path" ]]; then continue; fi

        # 이미 링크되어 있으면 스킵
        if echo "$content" | grep -q "\[\[.*${title}.*\]\]" 2>/dev/null; then continue; fi

        # 본문에서 키워드 검색 (frontmatter 제외)
        body=$(echo "$content" | awk '/^---$/{c++;next}c>=2' 2>/dev/null || echo "$content")

        # 대소문자 무시하되 단어 단위로 매칭
        if echo "$body" | grep -qiw "$title" 2>/dev/null; then
            found_links="${found_links}[[${path}|${title}]], "
            found_count=$((found_count + 1))
            # 최대 3개
            if [[ "$found_count" -ge 3 ]]; then break; fi
        fi
    done

    # 1개 이상 발견 시 추가
    if [[ "$found_count" -gt 0 ]]; then
        # Remove trailing ", " from found_links
        trimmed="$(echo "$found_links" | sed 's/, $//')"

        echo "" >> "$file"
        echo "## 자동 발견 링크" >> "$file"
        echo "" >> "$file"
        echo "$trimmed" >> "$file"

        linked=$((linked + 1))
        log "  Added $found_count links to: $relpath"
    fi
done < <(find "$VAULT" -name "*.md" -not -path "*/.obsidian/*" -not -path "*/.git/*" -mmin "-$((HOURS_AGO * 60))" -print0)

log "Auto-link complete: $linked files updated"
