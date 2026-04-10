#!/usr/bin/env bash
# stop-changelog.sh — 세션 종료 시 변경 파일 기록 + Discord 알림
# LLM 없음. bash만. 즉시 실행.
# Stop hook (async, 10s timeout)

BOT_HOME="${HOME}/.jarvis"
SESSION_TS="${BOT_HOME}/state/.claude-session-start"
CHANGELOG="${BOT_HOME}/docs/session-changelog.md"  # rag-index.mjs가 docs/ 인덱싱
LOG="${BOT_HOME}/logs/session-changelog.log"
WEBHOOK_URL="$(python3 -c "import json; d=json.load(open('${BOT_HOME}/config/monitoring.json')); print(d.get('webhooks',{}).get('jarvis-system',''))" 2>/dev/null)"

log() { echo "[$(date '+%F %T')] [stop-changelog] $1" >> "$LOG"; }

if [[ ! -f "$SESSION_TS" ]]; then log "No session timestamp — skip"; exit 0; fi

# 변경 파일 수집 (코드/설정/문서만, 크론 결과물 제외)
changed_files=$(find \
    "$BOT_HOME/lib" "$BOT_HOME/bin" "$BOT_HOME/scripts" \
    "$BOT_HOME/discord" "$BOT_HOME/adr" "$BOT_HOME/docs" \
    "$BOT_HOME/config" "$BOT_HOME/context" \
    "$HOME/.claude/hooks" "$HOME/.claude/settings.json" \
    "$HOME/.claude/projects/-Users-$(whoami)/memory" \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/rag/lancedb/*" \
    -not -path "*/logs/*" \
    -not -path "*/.claude-session-start" \
    -not -path "*/session-changelog.md" \
    -not -path "*/cache/*" \
    \( -name "*.md" -o -name "*.mjs" -o -name "*.js" -o -name "*.sh" -o -name "*.json" \) \
    -newer "$SESSION_TS" 2>/dev/null \
    | sed "s|${HOME}/||" | sort)

if [[ -z "$changed_files" ]]; then
    log "No files changed — skip"
    touch "$SESSION_TS"
    exit 0
fi

file_count=$(echo "$changed_files" | wc -l | tr -d ' ')
today=$(date '+%Y-%m-%d')
now=$(date '+%Y-%m-%d %H:%M')

# 카테고리 분류 (bash, LLM 불필요)
cat_nexus=$(echo   "$changed_files" | grep -E "lib/nexus|lib/mcp-nexus"  || true)
cat_discord=$(echo "$changed_files" | grep -E "discord/"                  || true)
cat_scripts=$(echo "$changed_files" | grep -E "scripts/|bin/"             || true)
cat_adr=$(echo     "$changed_files" | grep -E "adr/"                     || true)
cat_hooks=$(echo   "$changed_files" | grep -E "\.claude/hooks|settings"  || true)
cat_config=$(echo  "$changed_files" | grep -E "config/|MEMORY"           || true)
cat_lib=$(echo     "$changed_files" | grep -E "\.jarvis/lib/" | grep -Ev "nexus|mcp-nexus" || true)
# 위 카테고리에 속하지 않는 나머지 (context/, docs/ 등)
cat_other=$(echo   "$changed_files" | grep -Ev "lib/nexus|lib/mcp-nexus|discord/|scripts/|bin/|adr/|\.claude/hooks|settings|config/|MEMORY|\.jarvis/lib/" || true)

# session-changelog.md 작성
{
    echo "# Jarvis 세션 변경 이력"
    echo ""
    echo "## ${today} 세션 (${now}) — ${file_count}개 파일"
    echo ""
    if [[ -n "$cat_nexus" ]];   then echo "### Nexus MCP";       echo "$cat_nexus"   | sed 's/^/- /'; echo ""; fi
    if [[ -n "$cat_discord" ]]; then echo "### Discord 봇";      echo "$cat_discord" | sed 's/^/- /'; echo ""; fi
    if [[ -n "$cat_lib" ]];     then echo "### 라이브러리";      echo "$cat_lib"     | sed 's/^/- /'; echo ""; fi
    if [[ -n "$cat_scripts" ]]; then echo "### 스크립트";        echo "$cat_scripts" | sed 's/^/- /'; echo ""; fi
    if [[ -n "$cat_adr" ]];     then echo "### ADR";             echo "$cat_adr"     | sed 's/^/- /'; echo ""; fi
    if [[ -n "$cat_hooks" ]];   then echo "### Claude Code 훅";  echo "$cat_hooks"   | sed 's/^/- /'; echo ""; fi
    if [[ -n "$cat_config" ]];  then echo "### 설정/메모리";     echo "$cat_config"  | sed 's/^/- /'; echo ""; fi
    if [[ -n "$cat_other" ]];   then echo "### 기타";            echo "$cat_other"   | sed 's/^/- /'; echo ""; fi
    echo "---"
    echo ""
    # 기존 이력: 최근 4개 세션만 유지 (## YYYY-MM-DD 헤더 기준으로 자름)
    if [[ -f "$CHANGELOG" ]]; then
        python3 - "$CHANGELOG" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# '## YYYY-MM-DD' 기준으로 세션 블록 분리
blocks = re.split(r'(?=^## \d{4}-\d{2}-\d{2})', content, flags=re.MULTILINE)
# 헤더(# Jarvis ...) 및 빈 블록 제외, 최근 4개만
sessions = [b for b in blocks if b.strip() and not b.startswith('#')]
for s in sessions[:4]:
    print(s, end='')
PYEOF
    fi
} > "${CHANGELOG}.tmp" && mv "${CHANGELOG}.tmp" "$CHANGELOG"

log "Changelog saved: ${file_count}개 파일"

# 변경된 코드 파일 문법검사 (md 제외)
lint_errors=""
while IFS= read -r rel_path; do
    full_path="${HOME}/${rel_path}"
    [[ -f "$full_path" ]] || continue
    ext="${rel_path##*.}"
    case "$ext" in
        sh)
            if grep -qE '^[[:space:]]*set -[a-zA-Z]*e' "$full_path" 2>/dev/null; then
                bad=$(grep -nE '\[\[.*\]\]\s*&&\s*[^|]' "$full_path" 2>/dev/null \
                    | grep -v '^[0-9]*:[[:space:]]*#' \
                    | grep -v '^[0-9]*:[[:space:]]*if ' \
                    | grep -v '^[0-9]*:[[:space:]]*elif ' \
                    | grep -v '||[[:space:]]*true' | head -3 || true)
                [[ -n "$bad" ]] && lint_errors+="⚠️ set-e 안티패턴: ${rel_path}\n"
            fi
            ;;
        json)
            if ! node -e "JSON.parse(require('fs').readFileSync(0,'utf8'))" < "$full_path" 2>/dev/null; then
                lint_errors+="❌ JSON 오류: ${rel_path}\n"
            fi
            ;;
        js|mjs|cjs)
            if ! node --check "$full_path" 2>/dev/null; then
                lint_errors+="❌ JS 구문 오류: ${rel_path}\n"
            fi
            ;;
        py)
            if command -v ruff &>/dev/null; then
                if ! ruff check "$full_path" 2>/dev/null; then
                    lint_errors+="⚠️ Python lint: ${rel_path}\n"
                fi
            fi
            ;;
    esac
done <<< "$changed_files"

if [[ -n "$lint_errors" ]]; then
    log "Lint errors found:\n$lint_errors"
    # 다음 세션 시작 시 자동수정을 위해 pending 파일 저장
    PENDING_LINT="${BOT_HOME}/state/pending-lint-fixes.txt"
    printf '%s' "$lint_errors" > "$PENDING_LINT"
    log "Pending lint fixes saved: $PENDING_LINT"
fi

# Discord 세션 종료 알림 — 비활성 (노이즈 감소 목적으로 제거)
log "세션 종료 changelog 기록 완료 (Discord 전송 비활성)"

# 타임스탬프 갱신
touch "$SESSION_TS"

# Auditor 자동 실행 (세션 종료 시마다)
AUDITOR="${BOT_HOME}/scripts/jarvis-auditor.sh"
if [[ -x "$AUDITOR" ]]; then
    log "Running jarvis-auditor..."
    bash "$AUDITOR" --incremental >> "$LOG" 2>&1 &
fi

exit 0
