#!/usr/bin/env bash
set -euo pipefail

# vault-sync.sh — Jarvis 데이터를 Obsidian Vault로 미러링
# Usage: vault-sync.sh (crontab에서 6시간마다 실행)
#
# 미러링 매핑:
#   ~/.jarvis/rag/teams/reports/{team}-*.md  → ~/Jarvis-Vault/03-teams/{team}/
#   ~/.jarvis/docs/*.md                      → ~/Jarvis-Vault/06-knowledge/architecture/
#   ~/.jarvis/rag/teams/proposals-tracker.md → ~/Jarvis-Vault/03-teams/

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
VAULT_BASE="$HOME/Jarvis-Vault"
MAX_REPORTS=7  # 각 팀 폴더에 최신 N개 보고서만 유지

log() {
    echo "[$(date '+%F %T')] [vault-sync] $1"
}

# Frontmatter + Wikilink 헤더/푸터를 추가하여 Vault에 복사
# Usage: copy_with_frontmatter <src> <dest> <team_name>
copy_with_frontmatter() {
    local src="$1"
    local dest="$2"
    local team_name="${3:-}"
    local filename
    filename="$(basename "$src" .md)"
    local today
    today="$(date '+%Y-%m-%d')"
    local header='> 팀: [[03-teams/_index|팀 목록]]'
    local footer=$'---\n관련: [[Home]] | [[03-teams/_index|팀 목록]]'

    {
        echo "---"
        echo "title: \"${team_name} 보고 — ${filename#*-}\""
        echo "tags: [area/teams, type/report, team/${team_name}]"
        echo "created: ${today}"
        echo "updated: ${today}"
        echo "team: ${team_name}"
        echo "---"
        echo ""
        echo "$header"
        echo ""
        # 원본에 이미 frontmatter가 있으면 스킵
        if head -1 "$src" | grep -q '^---$'; then
            # frontmatter 이후의 내용만 복사
            sed '1,/^---$/d' "$src" | sed '1{/^$/d;}'
        else
            cat "$src"
        fi
        echo ""
        echo "$footer"
    } > "$dest"
}

# Vault 디렉토리 존재 확인
if [[ ! -d "$VAULT_BASE" ]]; then
    log "ERROR: Vault not found at $VAULT_BASE"
    exit 1
fi

synced=0
pruned=0

# --- 1. 팀 보고서 → Vault/03-teams/{team}/ ---
REPORTS_DIR="$BOT_HOME/rag/teams/reports"
if [[ -d "$REPORTS_DIR" ]]; then
    for report_file in "$REPORTS_DIR"/*.md; do
        if [[ ! -f "$report_file" ]]; then continue; fi
        if [[ ! -s "$report_file" ]]; then continue; fi  # 빈 파일 스킵
        filename="$(basename "$report_file")"
        # 파일명에서 팀 이름 추출: {team}-{date}.md 또는 {team}-{year}-W{week}.md
        team_name="${filename%%-*}"
        team_dir="$VAULT_BASE/03-teams/$team_name"
        mkdir -p "$team_dir"
        if copy_with_frontmatter "$report_file" "$team_dir/$filename" "$team_name" 2>/dev/null; then
            synced=$((synced + 1))
        fi
    done

    # Retention: 각 팀 폴더에 최신 MAX_REPORTS개만 유지
    for team_dir in "$VAULT_BASE/03-teams"/*/; do
        if [[ ! -d "$team_dir" ]]; then continue; fi
        file_count=$(find "$team_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$file_count" -gt "$MAX_REPORTS" ]]; then
            excess=$((file_count - MAX_REPORTS))
            # 이름순 정렬 (날짜 기반 파일명이므로 오래된 것이 먼저)
            # head -z 는 macOS BSD head 미지원 → POSIX 호환 방식
            find "$team_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null \
                | sort \
                | head -n "$excess" \
                | while IFS= read -r _old; do rm -f "$_old"; done
            pruned=$((pruned + excess))
        fi
    done
fi

# --- 2. 프로젝트 문서 → Vault/06-knowledge/architecture/ ---
DOCS_DIR="$BOT_HOME/docs"
ARCH_VAULT="$VAULT_BASE/06-knowledge/architecture"
if [[ -d "$DOCS_DIR" ]]; then
    mkdir -p "$ARCH_VAULT"
    for doc_file in "$DOCS_DIR"/*.md; do
        if [[ ! -f "$doc_file" ]]; then continue; fi
        filename="$(basename "$doc_file")"
        if cp "$doc_file" "$ARCH_VAULT/$filename" 2>/dev/null; then
            synced=$((synced + 1))
        fi
    done
fi

# --- 3. standup → Vault/02-daily/standup/ (최신 결과만) ---
STANDUP_DIR="$BOT_HOME/results/morning-standup"
STANDUP_VAULT="$VAULT_BASE/02-daily/standup"
if [[ -d "$STANDUP_DIR" ]]; then
    mkdir -p "$STANDUP_VAULT"
    # 최근 7일 파일만
    find "$STANDUP_DIR" -name "*.md" -type f -mtime -7 2>/dev/null | while read -r src; do
        # 파일명: YYYY-MM-DD_HHMMSS.md → YYYY-MM-DD.md
        src_name="$(basename "$src")"
        date_part="${src_name%%_*}"
        dest="$STANDUP_VAULT/${date_part}.md"
        # 이미 존재하면 스킵 (덮어쓰기 방지)
        if [[ -f "$dest" ]]; then continue; fi
        today="$(date '+%Y-%m-%d')"
        {
            echo "---"
            echo "title: \"스탠드업 — ${date_part}\""
            echo "tags: [area/daily, type/standup]"
            echo "created: ${date_part}"
            echo "updated: ${today}"
            echo "---"
            echo ""
            cat "$src"
        } > "$dest"
        synced=$((synced + 1))
    done
fi

# --- 4. proposals-tracker → Vault/03-teams/ (frontmatter 포함) ---
TRACKER="$BOT_HOME/rag/teams/proposals-tracker.md"
if [[ -f "$TRACKER" ]]; then
    TRACKER_DEST="$VAULT_BASE/03-teams/proposals-tracker.md"
    today="$(date '+%Y-%m-%d')"
    {
        echo "---"
        echo 'title: "팀 제안 트래커"'
        echo "tags: [area/teams, type/reference]"
        echo "created: 2026-03-02"
        echo "updated: ${today}"
        echo "---"
        echo ""
        if head -1 "$TRACKER" | grep -q '^---$'; then
            sed '1,/^---$/d' "$TRACKER" | sed '1{/^$/d;}'
        else
            cat "$TRACKER"
        fi
    } > "$TRACKER_DEST" 2>/dev/null && synced=$((synced + 1))
fi

# --- 5. Discord 대화 기록 → Vault/02-daily/discord/ (최근 7일) ---
DISCORD_HISTORY="$BOT_HOME/context/discord-history"
DISCORD_VAULT="$VAULT_BASE/02-daily/discord"
if [[ -d "$DISCORD_HISTORY" ]]; then
    mkdir -p "$DISCORD_VAULT"
    find "$DISCORD_HISTORY" -name "*.md" -type f -mtime -7 2>/dev/null | while read -r src; do
        src_name="$(basename "$src")"
        dest="$DISCORD_VAULT/$src_name"
        if [[ -f "$dest" ]] && [[ "$dest" -nt "$src" ]]; then continue; fi
        today="$(date '+%Y-%m-%d')"
        date_part="${src_name%.md}"
        {
            echo "---"
            echo "title: \"Discord 대화 — ${date_part}\""
            echo "tags: [area/daily, type/conversation]"
            echo "created: ${date_part}"
            echo "updated: ${today}"
            echo "---"
            echo ""
            if head -1 "$src" | grep -q '^---$'; then
                sed '1,/^---$/d' "$src" | sed '1{/^$/d;}'
            else
                cat "$src"
            fi
        } > "$dest"
        synced=$((synced + 1))
    done
fi

# --- 6. ADR → Vault/06-knowledge/adr/ ---
ADR_DIR="$BOT_HOME/adr"
ADR_VAULT="$VAULT_BASE/06-knowledge/adr"
if [[ -d "$ADR_DIR" ]]; then
    mkdir -p "$ADR_VAULT"
    for adr_file in "$ADR_DIR"/*.md; do
        if [[ ! -f "$adr_file" ]]; then continue; fi
        filename="$(basename "$adr_file")"
        if cp "$adr_file" "$ADR_VAULT/$filename" 2>/dev/null; then
            synced=$((synced + 1))
        fi
    done
fi

# --- 7. board-minutes → Vault/03-teams/board-minutes/ (최근 30일) ---
BOARD_DIR="$BOT_HOME/state/board-minutes"
BOARD_VAULT="$VAULT_BASE/03-teams/board-minutes"
if [[ -d "$BOARD_DIR" ]]; then
    mkdir -p "$BOARD_VAULT"
    find "$BOARD_DIR" -name "*.md" -type f -mtime -30 2>/dev/null | while IFS= read -r src; do
        src_name="$(basename "$src")"
        dest="$BOARD_VAULT/$src_name"
        if [[ -f "$dest" ]] && [[ "$dest" -nt "$src" ]]; then continue; fi
        today="$(date '+%Y-%m-%d')"
        date_part="${src_name%.md}"
        {
            echo "---"
            echo "title: \"이사회 회의록 — ${date_part}\""
            echo "tags: [area/teams, type/board-meeting]"
            echo "created: ${date_part}"
            echo "updated: ${today}"
            echo "---"
            echo ""
            if head -1 "$src" | grep -q '^---$'; then
                sed '1,/^---$/d' "$src" | sed '1{/^$/d;}'
            else
                cat "$src"
            fi
        } > "$dest"
        synced=$((synced + 1))
    done
fi

# --- 8. decisions (JSONL) → Vault/03-teams/decisions/ (최근 30일) ---
DECISIONS_DIR="$BOT_HOME/state/decisions"
DECISIONS_VAULT="$VAULT_BASE/03-teams/decisions"
if [[ -d "$DECISIONS_DIR" ]]; then
    mkdir -p "$DECISIONS_VAULT"
    find "$DECISIONS_DIR" -name "*.jsonl" -type f -mtime -30 2>/dev/null | while IFS= read -r src; do
        src_name="$(basename "$src")"
        dest_name="${src_name%.jsonl}.md"
        dest="$DECISIONS_VAULT/$dest_name"
        if [[ -f "$dest" ]] && [[ "$dest" -nt "$src" ]]; then continue; fi
        today="$(date '+%Y-%m-%d')"
        date_part="${src_name%.jsonl}"
        {
            echo "---"
            echo "title: \"의사결정 감사 로그 — ${date_part}\""
            echo "tags: [area/teams, type/decisions]"
            echo "created: ${date_part}"
            echo "updated: ${today}"
            echo "---"
            echo ""
            echo '```json'
            cat "$src"
            echo '```'
        } > "$dest"
        synced=$((synced + 1))
    done
fi


# --- 9. CEO 다이제스트 → Vault/00-ceo/weekly/ ---
CEO_VAULT="$VAULT_BASE/00-ceo/weekly"
mkdir -p "$CEO_VAULT"
for digest_file in "$REPORTS_DIR"/ceo-digest-*.md; do
    if [[ ! -f "$digest_file" ]]; then continue; fi
    if [[ ! -s "$digest_file" ]]; then continue; fi
    filename="$(basename "$digest_file")"
    dest="$CEO_VAULT/$filename"
    if [[ -f "$dest" ]] && [[ "$dest" -nt "$digest_file" ]]; then continue; fi
    if copy_with_frontmatter "$digest_file" "$dest" "ceo-digest" 2>/dev/null; then
        synced=$((synced + 1))
    fi
done

# CHANGELOG → Vault/00-ceo/changelog.md
CHANGELOG_SRC="$BOT_HOME/CHANGELOG.md"
if [[ -f "$CHANGELOG_SRC" ]]; then
    CHANGELOG_DEST="$VAULT_BASE/00-ceo/changelog.md"
    today="$(date '+%Y-%m-%d')"
    {
        echo "---"
        echo 'title: "Jarvis Changelog"'
        echo "tags: [area/ceo, type/reference]"
        echo "created: 2026-03-16"
        echo "updated: ${today}"
        echo "---"
        echo ""
        cat "$CHANGELOG_SRC"
    } > "$CHANGELOG_DEST" 2>/dev/null && synced=$((synced + 1))
fi

log "Sync complete: ${synced} files synced, ${pruned} old reports pruned"

# --- Auto-commit to git (if changes exist) ---
if cd "$VAULT_BASE" && git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    log "Git: no changes to commit"
else
    cd "$VAULT_BASE"
    git add -A
    git commit -m "vault-sync: auto-commit $(date +%F_%H%M)" --no-gpg-sign -q 2>/dev/null || true
    log "Git: auto-committed changes"
fi
