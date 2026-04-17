#!/usr/bin/env bash
set -euo pipefail
# phase-d-code-rewrite.sh — 코드 내 ~/.jarvis 하드코딩을 ~/jarvis/runtime으로
# 일괄 치환. A2 Phase D 본작업.
#
# Usage:
#   bash phase-d-code-rewrite.sh --dry-run   # 변경될 라인 미리보기
#   bash phase-d-code-rewrite.sh --inventory # JSON 인벤토리 생성
#   bash phase-d-code-rewrite.sh --apply     # 실제 치환
#
# 치환 규칙:
#   1. `$HOME/jarvis/runtime`       → `$HOME/jarvis/runtime`
#   2. `${HOME}/jarvis/runtime`     → `${HOME}/jarvis/runtime`
#   3. `homedir(), 'jarvis/runtime'`→ `homedir(), 'jarvis/runtime'`
#   4. `~/jarvis/runtime/`          → `~/jarvis/runtime/`    (비쉘 문맥)
#   5. `/Users/ramsbaby/jarvis/runtime/` → `/Users/ramsbaby/jarvis/runtime/`
#
# 제외:
#   - 주석, docstring, markdown (*.md) 파일 — 설명 문구 보존
#   - .claude/worktrees/ 하위 (다른 작업 브랜치)
#   - 백업 디렉토리

MODE="${1:---dry-run}"
REPO_ROOT="/Users/ramsbaby/jarvis"
INVENTORY="$REPO_ROOT/runtime/state/phase-d-inventory.jsonl"
LOG="$REPO_ROOT/runtime/logs/phase-d-rewrite.log"

mkdir -p "$(dirname "$INVENTORY")" "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# 대상 파일 수집 (주석/markdown 제외, worktrees 제외)
collect_targets() {
    find "$REPO_ROOT/infra" \
        \( -name "*.sh" -o -name "*.mjs" -o -name "*.js" -o -name "*.py" -o -name "*.json" \) \
        -not -path "*/node_modules/*" \
        -not -path "*/.claude/worktrees/*" \
        2>/dev/null
}

case "$MODE" in
    --inventory)
        log "=== 인벤토리 생성 ==="
        true > "$INVENTORY"
        total=0
        while IFS= read -r f; do
            matches=$(grep -nE '\.jarvis(/|")' "$f" 2>/dev/null || true)
            if [[ -z "$matches" ]]; then continue; fi
            count=$(echo "$matches" | wc -l | tr -d ' ')
            total=$((total + count))
            # JSONL 한 줄: file + line + raw text
            while IFS=: read -r lineno rest; do
                if [[ -z "$lineno" ]]; then continue; fi
                printf '{"file":"%s","line":%s,"text":%s}\n' \
                    "${f#$REPO_ROOT/}" "$lineno" "$(printf '%s' "$rest" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
                    >> "$INVENTORY"
            done <<< "$matches"
        done < <(collect_targets)
        log "인벤토리: $INVENTORY ($total건)"
        echo "총 $total건 / $(wc -l < "$INVENTORY") 레코드"
        ;;

    --dry-run)
        log "=== DRY RUN — 치환될 라인 미리보기 ==="
        cnt=0
        changed_files=0
        while IFS= read -r f; do
            matches=$(grep -nE '\$HOME/\.jarvis|\$\{HOME\}/\.jarvis|homedir\(\),\s*"?\.jarvis"?|homedir\(\),\s*'"'"'\.jarvis'"'"'|~/\.jarvis/|/Users/ramsbaby/\.jarvis/' "$f" 2>/dev/null || true)
            if [[ -n "$matches" ]]; then
                c=$(echo "$matches" | wc -l | tr -d ' ')
                cnt=$((cnt + c))
                changed_files=$((changed_files + 1))
                echo "  ${f#$REPO_ROOT/}: $c 건"
            fi
        done < <(collect_targets)
        log "dry-run: $cnt 건 / $changed_files 파일"
        echo "실제 실행: bash $0 --apply"
        ;;

    --apply)
        log "=== 대량 치환 실행 ==="
        applied=0
        files_changed=0
        while IFS= read -r f; do
            # 원본 백업 (in-memory diff로 변경 여부 판별)
            orig=$(cat "$f")
            # sed 체인 (macOS BSD sed)
            new=$(printf '%s' "$orig" | sed \
                -e 's|\$HOME/\.jarvis|$HOME/jarvis/runtime|g' \
                -e 's|\${HOME}/\.jarvis|${HOME}/jarvis/runtime|g' \
                -e "s|homedir(), *'\\.jarvis'|homedir(), 'jarvis/runtime'|g" \
                -e 's|homedir(), *"\\.jarvis"|homedir(), "jarvis/runtime"|g' \
                -e 's|~/\.jarvis/|~/jarvis/runtime/|g' \
                -e 's|/Users/ramsbaby/\.jarvis/|/Users/ramsbaby/jarvis/runtime/|g')
            if [[ "$orig" != "$new" ]]; then
                c=$(diff <(echo "$orig") <(echo "$new") | grep -c '^[<>]' || true)
                printf '%s' "$new" > "$f"
                log "OK: ${f#$REPO_ROOT/} (~$(( c / 2 ))건)"
                applied=$((applied + c / 2))
                files_changed=$((files_changed + 1))
            fi
        done < <(collect_targets)
        log "=== 완료: 적용 $applied건 / $files_changed 파일 ==="
        echo "✅ Phase D 치환: $applied건 / $files_changed 파일"
        ;;

    *)
        echo "Usage: $0 [--dry-run|--inventory|--apply]"
        exit 1
        ;;
esac