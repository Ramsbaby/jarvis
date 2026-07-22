#!/usr/bin/env bash
# learned-mistakes-glob.sh — 오답노트 본체+아카이브 통합 조회 헬퍼 (DRY · SSoT)
#
# 배경(2026-07-22 Step 1-0 감사): learned-mistakes.md(활성본)를 월별 아카이브로 분할하면,
#   전체본을 grep/count하던 감사 스크립트들이 아카이브분을 조용히 누락 → 카운트 급락 →
#   mistake-to-skill-pipeline은 "신규 없음" 영구 침묵. 이 헬퍼로 glob 조회를 단일화한다.
#
# 계약(contract): 아카이브 파일은 `learned-mistakes-YYYY-MM.md`(월별) 또는 `learned-mistakes*.md`로
#   명명하고 **원본 헤더 `## YYYY-MM-DD — 제목`을 유지**한다(형식 변경 금지). 그래야 아래 lm_grep의
#   `^## 2026-` 패턴이 파일 이동과 무관하게 전체를 균일 집계한다.
#
# 사용:
#   source "$HOME/jarvis/infra/lib/learned-mistakes-glob.sh"
#   CURRENT=$(lm_grep "^## 2026-" | wc -l | tr -d ' \n')   # 본체+아카이브 전체 헤더 카운트
#   lm_files                                                # 파일 목록(줄 단위)

# 오답노트 파일 목록(본체 + 아카이브)을 줄 단위로 출력. 없으면 무출력(exit 0).
lm_files() {
    local dir="${1:-${BOT_HOME:-$HOME/jarvis/runtime}/wiki/meta}"
    ls "$dir"/learned-mistakes*.md 2>/dev/null || true
}

# 전체 오답노트 파일에서 패턴 grep(-h: 파일명 접두 제거). 추가 grep 옵션은 뒤에 전달.
# 파일이 0개면 조용히 빈 출력.
lm_grep() {
    local pattern="$1"; shift
    local -a files=()
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(lm_files)
    [ ${#files[@]} -eq 0 ] && return 0
    grep -h "$@" "$pattern" "${files[@]}" 2>/dev/null || true
}
