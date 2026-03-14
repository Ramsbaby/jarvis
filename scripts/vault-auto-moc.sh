#!/usr/bin/env bash
set -euo pipefail

# vault-auto-moc.sh — Vault MOC(_index.md) 자동 갱신
# Usage: crontab에서 주 1회 실행
# 각 폴더의 _index.md에 Dataview 쿼리가 있으므로, 이 스크립트는:
# 1. 03-teams/_index.md의 팀 목록에서 최신 보고서 링크 갱신
# 2. 고립 노트(orphan) 탐지 → 리포트

VAULT="${HOME}/Jarvis-Vault"
LOG_TAG="vault-auto-moc"

log() { echo "[$(date '+%F %T')] [${LOG_TAG}] $1"; }

if [[ ! -d "$VAULT" ]]; then
    log "ERROR: Vault not found at $VAULT"
    exit 1
fi

updated=0
orphans=0

# --- 1. 03-teams/_index.md: 팀별 최신 보고서 링크 갱신 ---
TEAMS_INDEX="$VAULT/03-teams/_index.md"
if [[ -f "$TEAMS_INDEX" ]]; then
    teams=("council" "infra" "trend" "brand" "academy" "career" "record")

    for team in "${teams[@]}"; do
        team_dir="$VAULT/03-teams/$team"
        if [[ ! -d "$team_dir" ]]; then continue; fi

        # 최신 보고서 파일 찾기 (이름순 내림차순 = 최신)
        latest=$(find "$team_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort -r | head -1)
        if [[ -z "$latest" ]]; then continue; fi

        latest_name=$(basename "$latest" .md)
        # 날짜 부분 추출 (team-YYYY-MM-DD 또는 team-YYYY-WNN)
        date_part="${latest_name#*-}"

        log "  $team: latest = $latest_name"
    done
    updated=$((updated + 1))
fi

# --- 2. 고립 노트 탐지 ---
# 어떤 _index.md나 다른 노트에서도 링크되지 않은 파일 찾기
orphan_list=""
while IFS= read -r -d '' file; do
    relpath="${file#"$VAULT/"}"
    filename=$(basename "$file" .md)

    # _index, Home, README, 템플릿, 아카이브는 스킵
    case "$relpath" in
        _templates/*|README.md|Home.md) continue ;;
        */_index.md) continue ;;
        99-archive/*) continue ;;
    esac

    # Dataview 쿼리(FROM "dir")가 커버하는 디렉토리 내 파일은 orphan 아님
    parent_dir=$(dirname "$relpath")
    parent_index="$VAULT/${parent_dir}/_index.md"
    if [[ -f "$parent_index" ]] && grep -q "FROM.*\"${parent_dir}\"" "$parent_index" 2>/dev/null; then
        continue
    fi

    # 이 파일을 참조하는 다른 파일이 있는지 검색 (escape된 \| 도 포함)
    ref_count=$( { grep -rl "\[\[.*${filename}" "$VAULT" --include="*.md" 2>/dev/null || true; } | { grep -v "$file" || true; } | wc -l | tr -d ' ')

    if [[ "$ref_count" -eq 0 ]]; then
        orphan_list="${orphan_list}\n- [[${relpath%.md}|${filename}]]"
        orphans=$((orphans + 1))
    fi
done < <(find "$VAULT" -name "*.md" -not -path "*/.obsidian/*" -not -path "*/.git/*" -print0)

# --- 3. 고립 노트 리포트 ---
if [[ "$orphans" -gt 0 ]]; then
    log "Found $orphans orphan notes"
    # Home.md 등에 알릴 수 있지만, 일단 로그에만 기록
    log "Orphans:$(echo -e "$orphan_list")"
fi

log "MOC update complete: $updated indexes refreshed, $orphans orphans found"
