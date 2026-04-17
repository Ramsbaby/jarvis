#!/usr/bin/env bash
set -euo pipefail
# context-diagnostics.sh — Context Assembly Pipeline 진단 도구
#
# 현재 조립되는 시스템 프롬프트의 구조와 크기를 분석한다.
# - 총 크기 (바이트 + 추정 토큰)
# - STABLE / SEMI / DYNAMIC 비율
# - 가장 큰 동적 섹션 TOP 3
#
# Usage:
#   context-diagnostics.sh [TASK_ID] [PROMPT]
#   context-diagnostics.sh                      # 기본값으로 진단
#   context-diagnostics.sh tqqq-monitor "test"   # 특정 태스크 진단
#
# Exit: 0 = 정상, 1 = 에러

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TASK_ID="${1:-_diagnostics}"
# shellcheck disable=SC2034  # PROMPT, CONTEXT_FILE, RESULTS_DIR are used by sourced context-loader.sh
PROMPT="${2:-diagnostics health check}"
CONTEXT_FILE="${BOT_HOME}/context/${TASK_ID}.md"
RESULTS_DIR="${BOT_HOME}/results/${TASK_ID}"

# --- Load context assembly pipeline ---
CONTEXT_LOADER="${BOT_HOME}/infra/lib/context-loader.sh"
if [[ ! -f "$CONTEXT_LOADER" ]]; then
    # Fallback: legacy path
    CONTEXT_LOADER="${BOT_HOME}/lib/context-loader.sh"
fi
if [[ ! -f "$CONTEXT_LOADER" ]]; then
    echo "❌ context-loader.sh 를 찾을 수 없음" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONTEXT_LOADER"
load_context

# --- Token estimation (rough: ~4 chars/token for mixed Korean/English) ---
CHARS_PER_TOKEN=4
total_bytes=${#SYSTEM_PROMPT}
total_tokens=$(( total_bytes / CHARS_PER_TOKEN ))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Context Assembly Pipeline — 진단 결과"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎯 태스크: ${TASK_ID}"
printf "📏 총 크기: %s bytes (~%s tokens)\n" "$total_bytes" "$total_tokens"
echo ""

# --- Parse CTX_SECTION_SIZES ---
stable_bytes=0
semi_bytes=0
dynamic_bytes=0

# Collect sections for sorting
declare -a section_names=()
declare -a section_stabilities=()
declare -a section_sizes=()
idx=0

while IFS=: read -r name stability size; do
    [[ -n "$name" ]] || continue
    section_names[$idx]="$name"
    section_stabilities[$idx]="$stability"
    section_sizes[$idx]="$size"

    case "$stability" in
        STABLE)  stable_bytes=$(( stable_bytes + size )) ;;
        SEMI)    semi_bytes=$(( semi_bytes + size )) ;;
        DYNAMIC) dynamic_bytes=$(( dynamic_bytes + size )) ;;
    esac
    idx=$(( idx + 1 ))
done <<< "${CTX_SECTION_SIZES:-}"

section_count=$idx

echo "📋 섹션 목록 (${section_count}개):"
echo "┌─────────────────────┬───────────┬───────────┬────────────┐"
printf "│ %-19s │ %-9s │ %9s │ %10s │\n" "섹션" "안정성" "바이트" "추정 토큰"
echo "├─────────────────────┼───────────┼───────────┼────────────┤"

for (( i=0; i<section_count; i++ )); do
    est_tok=$(( section_sizes[i] / CHARS_PER_TOKEN ))
    # Stability emoji
    case "${section_stabilities[i]}" in
        STABLE)  stab_icon="🟢 STABLE " ;;
        SEMI)    stab_icon="🟡 SEMI   " ;;
        DYNAMIC) stab_icon="🔴 DYNAMIC" ;;
        *)       stab_icon="⚪ ???    " ;;
    esac
    printf "│ %-19s │ %s │ %9s │ %10s │\n" \
        "${section_names[i]}" "$stab_icon" "${section_sizes[i]}" "$est_tok"
done

echo "└─────────────────────┴───────────┴───────────┴────────────┘"
echo ""

# --- Stability ratio ---
echo "📊 안정성 비율:"
if (( total_bytes > 0 )); then
    stable_pct=$(( stable_bytes * 100 / total_bytes ))
    semi_pct=$(( semi_bytes * 100 / total_bytes ))
    dynamic_pct=$(( dynamic_bytes * 100 / total_bytes ))
else
    stable_pct=0; semi_pct=0; dynamic_pct=0
fi

printf "  🟢 STABLE  : %5d bytes (%2d%%)\n" "$stable_bytes" "$stable_pct"
printf "  🟡 SEMI    : %5d bytes (%2d%%)\n" "$semi_bytes" "$semi_pct"
printf "  🔴 DYNAMIC : %5d bytes (%2d%%)\n" "$dynamic_bytes" "$dynamic_pct"
echo ""

# --- Top 3 largest DYNAMIC sections ---
echo "🔝 가장 큰 동적(DYNAMIC+SEMI) 섹션 TOP 3:"

# Build sortable list of non-STABLE sections
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

for (( i=0; i<section_count; i++ )); do
    if [[ "${section_stabilities[i]}" != "STABLE" ]]; then
        printf '%d\t%s\t%s\n' "${section_sizes[i]}" "${section_names[i]}" "${section_stabilities[i]}" >> "$tmpfile"
    fi
done

rank=1
while IFS=$'\t' read -r size name stability; do
    [[ -n "$name" ]] || continue
    est_tok=$(( size / CHARS_PER_TOKEN ))
    printf "  %d. %-20s %6d bytes (~%d tokens) [%s]\n" "$rank" "$name" "$size" "$est_tok" "$stability"
    rank=$(( rank + 1 ))
    (( rank > 3 )) && break
done < <(sort -t$'\t' -k1 -rn "$tmpfile")

if (( rank == 1 )); then
    echo "  (동적 섹션 없음)"
fi

echo ""

# --- KV-cache optimization hint ---
cacheable_bytes=$(( stable_bytes + semi_bytes ))
if (( total_bytes > 0 )); then
    cacheable_pct=$(( cacheable_bytes * 100 / total_bytes ))
else
    cacheable_pct=0
fi

echo "💡 KV-cache 힌트:"
printf "  캐시 가능 접두어 (STABLE+SEMI): %d bytes (%d%%)\n" "$cacheable_bytes" "$cacheable_pct"
printf "  캐시 미스 접미어 (DYNAMIC):     %d bytes (%d%%)\n" "$dynamic_bytes" "$dynamic_pct"

if (( cacheable_pct >= 50 )); then
    echo "  ✅ 접두어 비율 양호 — 캐시 효율 기대 가능"
elif (( cacheable_pct >= 25 )); then
    echo "  ⚠️  접두어 비율 보통 — 안정 컨텍스트 추가 시 개선 여지"
else
    echo "  🔻 접두어 비율 낮음 — 동적 섹션이 지배적 (캐시 효과 제한적)"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"