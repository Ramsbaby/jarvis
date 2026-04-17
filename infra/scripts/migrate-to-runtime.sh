#!/usr/bin/env bash
set -euo pipefail
# migrate-to-runtime.sh — A2 마이그레이션: ~/.jarvis → ~/jarvis/runtime
#
# Phase 1: Dry-run — 뭐가 어디로 옮겨지는지 보고만 (실제 이동 없음)
# Phase 2: Copy — ~/.jarvis의 런타임 데이터를 ~/jarvis/runtime/으로 복사
# Phase 3: Symlink (호환성) — ~/.jarvis 심링크로 ~/jarvis/runtime 가리킴
#            → OSS 사용자(5 fork)가 기존 경로 쓰던 것도 그대로 동작
# Phase 4: Code rewrite — 코드 내 BOT_HOME, ~/.jarvis 하드코딩 전수 수정
#            → 점진 배포 (이번 스크립트 밖)
#
# Usage:
#   bash migrate-to-runtime.sh --dry-run    # 안전 검증
#   bash migrate-to-runtime.sh --copy       # 실제 복사 (idempotent)
#   bash migrate-to-runtime.sh --verify     # 무결성 검증

LEGACY="${HOME}/jarvis/runtime"
RUNTIME="${HOME}/jarvis/runtime"
MODE="${1:---dry-run}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# 런타임으로 옮길 디렉토리 (심링크 아닌 실제 데이터만)
# 2026-04-17 08:59: prompts/rag/ledger/templates/private/configs/adr 누락 후 복구
RUNTIME_DIRS=(
    state logs config configs wiki context docker board results reports
    backup watchdog inbox teams experiments vault-starter tmp data discord
    prompts rag ledger templates private adr
)

# 제외: bin, lib, scripts, infra 는 SSoT 심링크라 옮길 필요 없음
EXCLUDE_DIRS=(bin lib scripts infra)

if [[ ! -d "$LEGACY" ]]; then die "$LEGACY 없음"; fi
if [[ -L "$LEGACY" ]]; then die "$LEGACY 이미 심링크 — 이미 마이그레이션 완료된 듯"; fi

mkdir -p "$RUNTIME"

case "$MODE" in
    --dry-run)
        log "=== DRY RUN (실제 이동 없음) ==="
        log "소스: $LEGACY"
        log "목적지: $RUNTIME"
        echo ""
        log "이동 대상 디렉토리:"
        total_size=0
        for d in "${RUNTIME_DIRS[@]}"; do
            src="$LEGACY/$d"
            if [[ -d "$src" ]] && [[ ! -L "$src" ]]; then
                size_kb=$(du -sk "$src" 2>/dev/null | awk '{print $1}')
                total_size=$((total_size + size_kb))
                printf "  ✓ %-25s → %8s KB\n" "$d" "$size_kb"
            elif [[ -L "$src" ]]; then
                printf "  ↷ %-25s (심링크 — 스킵)\n" "$d"
            else
                printf "  - %-25s (없음)\n" "$d"
            fi
        done
        echo ""
        log "제외 (SSoT 심링크):"
        for d in "${EXCLUDE_DIRS[@]}"; do
            src="$LEGACY/$d"
            if [[ -L "$src" ]]; then
                target=$(readlink "$src")
                printf "  ↷ %-25s → %s\n" "$d" "$target"
            fi
        done
        echo ""
        log "루트 파일 (런타임 전용만 복사; git 레포 메타파일은 스킵):"
        find "$LEGACY" -maxdepth 1 -type f 2>/dev/null | while read -r f; do
            name=$(basename "$f")
            case "$name" in
                .env|.env.test|.env.*|*.pid)
                    printf "  ✓ %s (복사)\n" "$name"
                    ;;
                LICENSE|README*|CLAUDE.md|.gitignore|.gitleaks.toml|.mcp.json|*.md|.opensync.yml|.DS_Store)
                    printf "  ↷ %s (git 레포 메타 또는 무관 — 스킵)\n" "$name"
                    ;;
                *)
                    printf "  ? %s (검토 필요 — 기본 스킵)\n" "$name"
                    ;;
            esac
        done
        echo ""
        log "총 복사 예상 크기: $((total_size / 1024)) MB"
        echo ""
        log "실제 실행: bash $0 --copy"
        ;;

    --copy)
        log "=== COPY MODE ==="
        log "소스: $LEGACY → 목적지: $RUNTIME"
        if [[ -d "$RUNTIME" ]] && [[ -n "$(ls -A "$RUNTIME" 2>/dev/null)" ]]; then
            log "WARN: $RUNTIME 이미 비어있지 않음 — rsync incremental"
        fi
        for d in "${RUNTIME_DIRS[@]}"; do
            src="$LEGACY/$d"
            if [[ -d "$src" ]] && [[ ! -L "$src" ]]; then
                log "Copying $d..."
                rsync -a --delete "$src/" "$RUNTIME/$d/"
            fi
        done
        # 루트 레벨 파일 — .env 계열만 (git 메타파일 제외)
        find "$LEGACY" -maxdepth 1 -type f 2>/dev/null | while read -r f; do
            name=$(basename "$f")
            case "$name" in
                .env|.env.test|.env.*|*.pid)
                    cp -n "$f" "$RUNTIME/" && log "  copied: $name" || true
                    ;;
                *) : ;;  # skip
            esac
        done
        log "Copy 완료. verify 실행: bash $0 --verify"
        ;;

    --verify)
        log "=== VERIFY MODE ==="
        fail=0
        for d in "${RUNTIME_DIRS[@]}"; do
            src="$LEGACY/$d"
            dst="$RUNTIME/$d"
            if [[ -d "$src" ]] && [[ ! -L "$src" ]]; then
                if [[ ! -d "$dst" ]]; then
                    log "MISSING: $dst"
                    fail=$((fail + 1))
                    continue
                fi
                src_count=$(find "$src" -type f 2>/dev/null | wc -l | tr -d ' ')
                dst_count=$(find "$dst" -type f 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$src_count" != "$dst_count" ]]; then
                    log "MISMATCH: $d (src=$src_count, dst=$dst_count)"
                    fail=$((fail + 1))
                else
                    log "OK: $d ($src_count files)"
                fi
            fi
        done
        if [[ "$fail" -gt 0 ]]; then
            die "검증 실패 $fail건 — 재실행 필요"
        fi
        log "전체 검증 통과"
        ;;

    *)
        die "Usage: $0 [--dry-run|--copy|--verify]"
        ;;
esac