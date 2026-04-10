#!/usr/bin/env bash
set -euo pipefail

# config-snapshot.sh — 설정 파일 자동 스냅샷 + 롤백
# OpenJarvis AgentConfigEvolver의 .history/ 패턴 차용
#
# Usage:
#   config-snapshot.sh save [label]     — 현재 설정 스냅샷 저장
#   config-snapshot.sh list             — 스냅샷 목록
#   config-snapshot.sh diff [id]        — 최신 vs 지정 스냅샷 diff
#   config-snapshot.sh rollback <id>    — 지정 스냅샷으로 롤백
#   config-snapshot.sh prune [keep]     — 오래된 스냅샷 정리 (기본 20개 유지)

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HISTORY_DIR="${BOT_HOME}/data/config-history"

# 스냅샷 대상 파일들
WATCHED_FILES=(
    "config/tasks.json"
    "config/goals.json"
    "config/monitoring.json"
    "config/team-budget.json"
    "agents/ceo.md"
    "agents/infra-chief.md"
    "agents/record-keeper.md"
    "agents/strategy-advisor.md"
)

# --- save: 현재 설정 스냅샷 ---
cmd_save() {
    local label="${1:-auto}"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local snap_dir="${HISTORY_DIR}/${ts}_${label}"

    mkdir -p "$snap_dir"

    local saved=0
    for rel in "${WATCHED_FILES[@]}"; do
        local src="${BOT_HOME}/${rel}"
        if [[ -f "$src" ]]; then
            local dest_dir
            dest_dir=$(dirname "${snap_dir}/${rel}")
            mkdir -p "$dest_dir"
            cp "$src" "${snap_dir}/${rel}"
            saved=$((saved + 1))
        fi
    done

    # 메타데이터 기록
    printf '{"ts":"%s","label":"%s","files":%d,"git_sha":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$label" "$saved" \
        "$(cd "$BOT_HOME" && git rev-parse --short HEAD 2>/dev/null || echo 'none')" \
        > "${snap_dir}/.meta.json"

    echo "Snapshot saved: ${ts}_${label} (${saved} files)"
}

# --- list: 스냅샷 목록 ---
cmd_list() {
    if [[ ! -d "$HISTORY_DIR" ]]; then
        echo "No snapshots yet."
        return 0
    fi

    echo "ID                         Label    Files  Git SHA"
    echo "-------------------------  -------  -----  -------"
    for d in $(ls -d "${HISTORY_DIR}"/*/ 2>/dev/null | sort -r); do
        local name
        name=$(basename "$d")
        if [[ -f "${d}/.meta.json" ]]; then
            python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
print(f'{sys.argv[2]:<27s}  {m.get(\"label\",\"?\"):<7s}  {m.get(\"files\",0):<5d}  {m.get(\"git_sha\",\"?\")}')
" "${d}/.meta.json" "$name" 2>/dev/null || echo "$name  ?  ?  ?"
        else
            echo "$name  (no meta)"
        fi
    done
}

# --- diff: 현재 vs 스냅샷 ---
cmd_diff() {
    local snap_id="${1:-}"

    if [[ -z "$snap_id" ]]; then
        # 최신 스냅샷 자동 선택
        snap_id=$(ls -d "${HISTORY_DIR}"/*/ 2>/dev/null | sort -r | head -1 | xargs basename 2>/dev/null || echo "")
        if [[ -z "$snap_id" ]]; then
            echo "No snapshots to diff against."
            return 1
        fi
    fi

    local snap_dir="${HISTORY_DIR}/${snap_id}"
    if [[ ! -d "$snap_dir" ]]; then
        echo "Snapshot not found: $snap_id"
        return 1
    fi

    echo "=== Diff: current vs ${snap_id} ==="
    local has_diff=false
    for rel in "${WATCHED_FILES[@]}"; do
        local current="${BOT_HOME}/${rel}"
        local snapshot="${snap_dir}/${rel}"
        if [[ -f "$current" && -f "$snapshot" ]]; then
            if ! diff -q "$current" "$snapshot" >/dev/null 2>&1; then
                echo ""
                echo "--- ${rel} ---"
                diff --unified=3 "$snapshot" "$current" 2>/dev/null | head -30 || true
                has_diff=true
            fi
        elif [[ -f "$current" && ! -f "$snapshot" ]]; then
            echo "  NEW: ${rel}"
            has_diff=true
        elif [[ ! -f "$current" && -f "$snapshot" ]]; then
            echo "  DELETED: ${rel}"
            has_diff=true
        fi
    done

    if [[ "$has_diff" == "false" ]]; then
        echo "  No changes detected."
    fi
}

# --- rollback: 스냅샷으로 복원 ---
cmd_rollback() {
    local snap_id="${1:?Usage: config-snapshot.sh rollback <snapshot-id>}"
    local snap_dir="${HISTORY_DIR}/${snap_id}"

    if [[ ! -d "$snap_dir" ]]; then
        echo "Snapshot not found: $snap_id"
        return 1
    fi

    # 롤백 전 현재 상태를 자동 백업
    cmd_save "pre-rollback"

    local restored=0
    for rel in "${WATCHED_FILES[@]}"; do
        local snapshot="${snap_dir}/${rel}"
        local target="${BOT_HOME}/${rel}"
        if [[ -f "$snapshot" ]]; then
            mkdir -p "$(dirname "$target")"
            cp "$snapshot" "$target"
            restored=$((restored + 1))
        fi
    done

    echo "Rolled back to ${snap_id} (${restored} files restored)"
    echo "Pre-rollback snapshot saved automatically."
}

# --- prune: 오래된 스냅샷 정리 ---
cmd_prune() {
    local keep="${1:-20}"
    if [[ ! -d "$HISTORY_DIR" ]]; then
        return 0
    fi

    local all
    all=$(ls -d "${HISTORY_DIR}"/*/ 2>/dev/null | sort -r)
    local count
    count=$(echo "$all" | wc -l | tr -d ' ')

    if [[ "$count" -le "$keep" ]]; then
        echo "Nothing to prune (${count}/${keep} snapshots)"
        return 0
    fi

    local to_remove
    to_remove=$(echo "$all" | tail -n +"$((keep + 1))")
    local removed=0
    for d in $to_remove; do
        rm -rf "$d"
        removed=$((removed + 1))
    done

    echo "Pruned ${removed} old snapshots (kept ${keep})"
}

# --- Main ---
mkdir -p "$HISTORY_DIR"

case "${1:-help}" in
    save)     cmd_save "${2:-auto}" ;;
    list)     cmd_list ;;
    diff)     cmd_diff "${2:-}" ;;
    rollback) cmd_rollback "${2:-}" ;;
    prune)    cmd_prune "${2:-20}" ;;
    help|*)
        echo "Usage: config-snapshot.sh {save [label]|list|diff [id]|rollback <id>|prune [keep]}"
        ;;
esac
