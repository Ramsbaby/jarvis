#!/usr/bin/env bash
# shadow-path-guard.sh — 그림자 디렉터리(데이터가 엉뚱한 곳에 쌓이는 현상) 감지
#
# 배경 (2026-06-22 사고 / 2026-07-25 원인 정정):
#   ceo-digest 경영 리포트 ~50개가 정규 경로가 아닌 그림자 폴더에만 쌓여
#   RAG 인덱싱에서 누락됐다. 당시엔 원인을 "~/.jarvis 가 ~/jarvis/runtime 심링크라서"로
#   기록했으나, 2026-07-25 실측 결과 ~/.jarvis 는 심링크가 아니라 독립 실제 디렉터리였다.
#   실제 그림자는 두 경로로 생긴다:
#
#   A형) ~/.jarvis/runtime/...  ← 스크립트에 이 경로가 하드코딩된 경우.  # ALLOW-DOTJARVIS
#        정규 데이터는 ~/jarvis/runtime/ 에 있으므로 여기 쌓이면 RAG·감사에서 누락된다.
#
#   B형) ~/jarvis/runtime/runtime/...  ← 스크립트는 "$JARVIS_HOME/runtime/..." 을 쓰는데
#        JARVIS_HOME(저장소 루트 = ~/jarvis)이 BOT_HOME(한 단계 아래 = ~/jarvis/runtime)으로
#        떨어지면 runtime 이 한 번 더 붙는다. 원인은 "JARVIS_HOME:-${BOT_HOME:-...}" 대체값 연쇄.
#        두 변수는 계층이 다르므로 서로의 대체값이 될 수 없다.
#
# 화이트리스트:
#   같은 줄에 "# ALLOW-DOTJARVIS" 주석이 있으면 의도적 허용으로 통과시킨다.
#
# 종료 코드: 정적 안티패턴 발견 시 1, 없으면 0.
#   (이미 쌓인 그림자 폴더 자체는 경고로만 보고한다 — 실데이터가 들어있어 임의 삭제 금지.)

set -euo pipefail

JARVIS_ROOT="${JARVIS_ROOT:-${HOME}/jarvis}"
# 기준선: 2026-07-25 시점에 이미 존재하던 위반 목록. 여기 있는 항목은 통과시키고
#   "새로 생기는 위반"만 차단한다. 기존 항목은 상태 파일 경로라 이관 계획 없이 바꾸면
#   idempotency(중복 실행 방지) 기록을 잃고 작업이 재실행될 수 있어 일괄 수정하지 않는다.
#   이관 완료 시 해당 줄을 기준선에서 지우면 다시 감시 대상이 된다.
BASELINE="${JARVIS_ROOT}/infra/config/shadow-path-baseline.txt"

shopt -s nullglob
# 설정·프롬프트 (기존 범위)
TARGETS=(
  "$JARVIS_ROOT"/runtime/config/*.md
  "$JARVIS_ROOT"/runtime/config/*.json
  "$JARVIS_ROOT"/infra/agents/*.md
  "$JARVIS_ROOT"/infra/prompts/*.md
)
# 실행 코드 (2026-07-25 추가 — A형 하드코딩이 셸 라이브러리에 숨어 가드를 빠져나갔다)
CODE_TARGETS=(
  "$JARVIS_ROOT"/infra/lib/*.sh
  "$JARVIS_ROOT"/infra/scripts/*.sh
  "$JARVIS_ROOT"/infra/bin/*.sh
)

hits=0
baselined=0

# 기준선에 등록된 위반인가? (파일명 + 줄 내용으로 식별 — 줄번호 이동에 견딤)
_is_baselined() {
  [ -f "$BASELINE" ] || return 1
  grep -Fqx "$1" "$BASELINE" 2>/dev/null
}

# --- A형: ~/.jarvis/runtime/ 하드코딩 ---  # ALLOW-DOTJARVIS
for f in "${TARGETS[@]}" "${CODE_TARGETS[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in *shadow-path-guard.sh) continue ;; esac
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$line" | grep -q "ALLOW-DOTJARVIS" && continue
    key="$(basename "$f")|${line#*:}"
    if _is_baselined "$key"; then baselined=$((baselined + 1)); continue; fi
    printf '  ⚠️  [A형] %s: %s\n' "$(basename "$f")" "$line"
    hits=$((hits + 1))
  done < <(grep -nE '(~|\$\{?HOME\}?)/\.jarvis/runtime/' "$f" 2>/dev/null || true)
done

# --- B형: JARVIS_HOME 이 BOT_HOME 으로 떨어지는 대체값 연쇄 ---
for f in "${CODE_TARGETS[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in *shadow-path-guard.sh) continue ;; esac
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$line" | grep -q "ALLOW-DOTJARVIS" && continue
    key="$(basename "$f")|${line#*:}"
    if _is_baselined "$key"; then baselined=$((baselined + 1)); continue; fi
    printf '  ⚠️  [B형] %s: %s\n' "$(basename "$f")" "$line"
    hits=$((hits + 1))
  done < <(grep -n 'JARVIS_HOME:-\${\?BOT_HOME' "$f" 2>/dev/null || true)
done

# --- 이미 쌓인 그림자 폴더 현황 (경고만 — 실데이터 포함, 임의 삭제 금지) ---
for shadow in "$JARVIS_ROOT/runtime/runtime" "${HOME}/.jarvis/runtime"; do  # ALLOW-DOTJARVIS
  if [ -d "$shadow" ]; then
    n=$(find "$shadow" -type f 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && printf 'ℹ️  그림자 폴더 잔존: %s (%s개 파일) — 실데이터 포함 가능, 이관 계획 후 정리할 것\n' "$shadow" "$n"
  fi
done

if [ "$hits" -gt 0 ]; then
  printf '🚨 그림자 경로 안티패턴 %d건 발견\n' "$hits"
  printf '   A형 수정: "~/.jarvis/runtime/" → "~/jarvis/runtime/"\n'  # ALLOW-DOTJARVIS
  printf '   B형 수정: "JARVIS_HOME:-${BOT_HOME:-...}" → "JARVIS_HOME:-$HOME/jarvis" (계층이 다른 변수를 대체값으로 쓰지 말 것)\n'
  printf '   의도적이면 같은 줄에 "# ALLOW-DOTJARVIS" 주석\n'
  exit 1
fi

if [ "$baselined" -gt 0 ]; then
  printf '✅ 신규 그림자 안티패턴 0건 (기존 %d건은 기준선 등록 — 이관 계획 대상)\n' "$baselined"
else
  printf '✅ 그림자 경로 안티패턴 0건\n'
fi
exit 0
