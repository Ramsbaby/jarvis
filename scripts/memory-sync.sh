#!/usr/bin/env bash
# memory-sync.sh — Jarvis 메모리 자동 동기화
# 1. MEMORY.md ADR/구조 섹션을 파일 파싱으로 직접 갱신 (LLM 불필요)
# 2. claude -p + serena MCP로 Serena 프로젝트 메모리 갱신
#
# Usage: memory-sync.sh [--serena] [--memory-md] [--all]
#   --serena     Serena 메모리만 갱신
#   --memory-md  MEMORY.md ADR 섹션만 갱신
#   --all        둘 다 갱신 (기본값)
#
# Cron: 0 4 * * 1  (매주 월 04:00, 주간 코드 리뷰 후)

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
MEMORY_FILE="$HOME/.claude/projects/-Users-ramsbaby/memory/MEMORY.md"
ADR_INDEX="$BOT_HOME/adr/ADR-INDEX.md"
MCP_CONFIG="$HOME/.mcp.json"
LOG="$BOT_HOME/logs/memory-sync.log"

log() { echo "[$(date '+%F %T')] [memory-sync] $1" | tee -a "$LOG"; }

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# --- 인수 파싱 ---
DO_SERENA=true
DO_MEMORY_MD=true
if [[ $# -gt 0 ]]; then
    DO_SERENA=false
    DO_MEMORY_MD=false
    for arg in "$@"; do
        case "$arg" in
            --serena)    DO_SERENA=true ;;
            --memory-md) DO_MEMORY_MD=true ;;
            --all)       DO_SERENA=true; DO_MEMORY_MD=true ;;
        esac
    done
fi

# ─────────────────────────────────────────────────
# 1. MEMORY.md ADR 섹션 갱신 (순수 bash, LLM 불필요)
# ─────────────────────────────────────────────────
if [[ "$DO_MEMORY_MD" == "true" ]]; then
    log "MEMORY.md ADR 섹션 갱신 시작"

    if [[ ! -f "$ADR_INDEX" ]]; then
        log "WARN: ADR-INDEX.md 없음, 스킵"
    else
        # ADR-INDEX.md 테이블에서 항목 파싱
        # | ADR-009 | 제목 | accepted | 2026-03-10 |
        adr_entries=""
        while IFS='|' read -r _ id title status date _; do
            id="$(echo "$id" | xargs)"
            title="$(echo "$title" | xargs)"
            date="$(echo "$date" | xargs)"
            if [[ "$id" == "ADR" || "$id" == "---"* || -z "$id" ]]; then continue; fi
            adr_entries="${adr_entries}- ${id}: ${title} (${date})\n"
        done < "$ADR_INDEX"

        if [[ -n "$adr_entries" ]]; then
            # MEMORY.md의 ADR 항목 블록 교체
            # 대상: "- ADR-001:" 로 시작하는 연속 줄들
            python3 - "$MEMORY_FILE" <<PYEOF
import sys, re

path = sys.argv[1]
content = open(path).read()

new_block = """- ADR-001~005: claude -p 래퍼, 4계층 토큰, 파일 통신, Obsidian RAG, 무상태 크론
$(printf '%b' "${adr_entries}" | grep -v 'ADR-00[1-5]' | sed 's/\\\\n/\n/g')"""

# ADR 항목 블록 교체 (- ADR-로 시작하는 연속 줄)
updated = re.sub(
    r'(- ADR-001~005:.*?)(?=\n[^-]|\n###|\Z)',
    new_block.rstrip(),
    content,
    flags=re.DOTALL
)

open(path, 'w').write(updated)
print("OK")
PYEOF
            log "MEMORY.md ADR 섹션 갱신 완료"
        fi
    fi
fi

# ─────────────────────────────────────────────────
# 2. Serena 메모리 갱신 (claude -p + serena MCP)
# ─────────────────────────────────────────────────
if [[ "$DO_SERENA" == "true" ]]; then
    log "Serena 메모리 갱신 시작 (claude -p + serena MCP)"

    if [[ ! -f "$MCP_CONFIG" ]]; then
        log "ERROR: ~/.mcp.json 없음 — Serena MCP 사용 불가"
        exit 1
    fi

    # 현재 lib/ 구조 수집
    lib_tree="$(find "$BOT_HOME/lib" -maxdepth 3 -name "*.mjs" -o -name "*.sh" 2>/dev/null \
        | sed "s|$BOT_HOME/||" | sort | head -40)"

    # 최근 변경 파일 (7일 이내)
    recent_changes="$(find "$BOT_HOME" \
        \( -name "*.mjs" -o -name "*.sh" -o -name "*.js" \) \
        -newer "$BOT_HOME/adr/ADR-008.md" \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" \
        2>/dev/null | sed "s|$BOT_HOME/||" | sort | head -20)"

    # ADR 목록 수집
    adr_list="$(grep '| ADR-' "$ADR_INDEX" 2>/dev/null | sed 's/|//g' | xargs | tr ',' '\n')"

    prompt="당신은 Jarvis AI 시스템의 메모리 관리자입니다.
아래 최신 코드베이스 정보를 바탕으로 Serena 프로젝트 메모리를 업데이트해주세요.

## 현재 lib/ 파일 구조
${lib_tree}

## 최근 변경된 파일들
${recent_changes}

## ADR 현황
${adr_list}

## 작업 지시
1. mcp__serena__read_memory로 'codebase_structure' 메모리를 읽으세요
2. lib/nexus/ 구조(shared.mjs, exec-gateway.mjs, rag-gateway.mjs, health-gateway.mjs)가
   codebase_structure에 정확히 반영되어 있는지 확인하세요
3. 누락되거나 오래된 내용은 mcp__serena__edit_memory로 업데이트하세요
4. state/board-minutes/, state/decisions/ 경로가 state/ 섹션에 있는지 확인하고 없으면 추가하세요
5. ADR 현황 섹션에 ADR-009, ADR-010이 없으면 추가하세요
6. 완료 후 '메모리 동기화 완료: [업데이트한 항목 수]개 항목 갱신' 형식으로 보고하세요"

    output_file="$(mktemp /tmp/memory-sync-XXXXXX.json)"
    trap 'rm -f "$output_file"' EXIT

    # 중첩 세션 방지 변수 해제 (크론에서는 없지만, 수동 실행 시 필요)
    unset CLAUDECODE

    _claude_cmd=()
    if [[ -n "${_TIMEOUT_CMD:-}" ]]; then _claude_cmd+=("${_TIMEOUT_CMD}" 180); fi
    _claude_cmd+=(claude -p "$prompt")
    if "${_claude_cmd[@]}" \
        --allowedTools "mcp__serena__read_memory,mcp__serena__edit_memory,mcp__serena__write_memory" \
        --mcp-config "$MCP_CONFIG" \
        --output-format json \
        --permission-mode bypassPermissions \
        --strict-mcp-config \
        --setting-sources local \
        > "$output_file" 2>&1; then

        result="$(jq -r '.result // ""' "$output_file" 2>/dev/null || cat "$output_file")"
        log "Serena 메모리 갱신 완료: ${result:0:120}"
    else
        log "ERROR: claude -p 실패 (exit $?)"
        exit 1
    fi
fi

log "memory-sync 완료"
