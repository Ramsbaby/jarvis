#!/usr/bin/env bash
# install-skill-optimization.sh — Claude Code CLI 스킬 최적화 1회 설치
#
# 목적:
#   1) 저빈도/미호출 스킬 6개를 archive 로 이동 → 매 턴 로드 토큰 절감
#   2) UserPromptSubmit 훅에 슬래시 호출 로깅 블록 병합 → 실측 누적
#
# 왜 이 스크립트가 필요한가:
#   Claude 에이전트의 Bash/Edit tool 은 ~/.claude/ 를 센서티브 구역으로
#   자동 차단. 따라서 이 최적화는 오너 터미널에서 직접 실행해야 함.
#
# 실행: bash ~/.jarvis/scripts/install-skill-optimization.sh
#
# 멱등성: 여러 번 실행해도 결과 동일 (이미 이동된 파일/블록 감지 후 skip).
# 안전성: 훅 수정 전 백업 자동 생성 (<file>.bak-<YYYYMMDDHHMMSS>).

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────────────────────
CLAUDE_DIR="${HOME}/.claude"
CMD_DIR="${CLAUDE_DIR}/commands"
ARCHIVE_DIR="${CLAUDE_DIR}/commands-archive"
HOOK_FILE="${CLAUDE_DIR}/hooks/sensor-prompt.sh"
LEDGER_DIR="${HOME}/.jarvis/state"
TS=$(date +%Y%m%d%H%M%S)

# archive 대상: skill-creator (36% 부하) + all-time 0건 5개
TARGETS=(
  "skill-creator"         # 디렉토리, 70KB
  "cycling-log.md"
  "logs.md"
  "brief.md"
  "standup.md"
  "compact-ctx.md"
)

echo "=== Claude Code CLI 스킬 최적화 설치 ==="
echo "시각: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 1. 아카이브 디렉토리 준비
# ─────────────────────────────────────────────────────────────
if [[ ! -d "$ARCHIVE_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  echo "✅ archive 디렉토리 생성: $ARCHIVE_DIR"
else
  echo "ℹ️  archive 디렉토리 이미 존재: $ARCHIVE_DIR"
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Step 2. 스킬 6개 이동 (idempotent)
# ─────────────────────────────────────────────────────────────
MOVED=0
SKIPPED=0
MISSING=0
for name in "${TARGETS[@]}"; do
  src="$CMD_DIR/$name"
  dst="$ARCHIVE_DIR/$name"
  if [[ -e "$dst" ]]; then
    echo "  ⏭️  skip (이미 아카이브됨): $name"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if [[ ! -e "$src" ]]; then
    echo "  ⚠️  missing (원본 없음): $name"
    MISSING=$((MISSING + 1))
    continue
  fi
  mv "$src" "$dst"
  echo "  📦 moved: $name"
  MOVED=$((MOVED + 1))
done
echo ""
echo "요약: 이동 ${MOVED} / 스킵 ${SKIPPED} / 누락 ${MISSING}"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 3. sensor-prompt.sh 에 슬래시 로깅 블록 병합
# ─────────────────────────────────────────────────────────────
MARKER="# (0) 슬래시 커맨드 호출 로깅 — Phase-SKO"

if [[ ! -f "$HOOK_FILE" ]]; then
  echo "❌ 훅 파일 없음: $HOOK_FILE — 병합 건너뜀"
elif grep -q "$MARKER" "$HOOK_FILE" 2>/dev/null; then
  echo "ℹ️  슬래시 로깅 블록 이미 병합됨 — 중복 삽입 방지"
else
  # 백업 생성
  BACKUP="$HOOK_FILE.bak-$TS"
  cp "$HOOK_FILE" "$BACKUP"
  echo "💾 백업: $BACKUP"

  # 삽입 지점: `if [[ -z "$PROMPT" ]]; then exit 0; fi` 바로 다음
  # Python으로 원자적 치환 (sed 멀티라인 이식성 한계 회피)
  python3 <<'PY'
import os, re, sys

hook = os.path.expanduser("~/.claude/hooks/sensor-prompt.sh")
with open(hook, 'r') as f:
    content = f.read()

anchor = 'if [[ -z "$PROMPT" ]]; then exit 0; fi'
if anchor not in content:
    print("❌ anchor 찾기 실패 — 수동 병합 필요", file=sys.stderr)
    sys.exit(1)

block = '''
# ─────────────────────────────────────────────────────────────
# (0) 슬래시 커맨드 호출 로깅 — Phase-SKO (Skill Kit Optimization)
#     프롬프트 선두가 `/skill-name ...` 패턴이면 skill-usage.jsonl 기록.
#     실측 누적 후 선별 주입 전략(on-demand vs always-load) 판단 근거.
#     비매칭이면 즉시 다음 단계로 (성능 영향 최소).
# ─────────────────────────────────────────────────────────────
SKILL_NAME=$(printf '%s' "$PROMPT" | python3 -c "
import sys, re
p = sys.stdin.read().strip()
m = re.match(r'^/([a-zA-Z][a-zA-Z0-9_-]{1,})(?:\\s|$)', p)
print(m.group(1) if m else '')
" 2>/dev/null || echo "")
if [[ -n "$SKILL_NAME" ]]; then
  SKILL_TS=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  ARGS_HEAD=$(printf '%s' "$PROMPT" | python3 -c "
import sys, json, re
p = sys.stdin.read().strip()
m = re.match(r'^/[a-zA-Z][a-zA-Z0-9_-]+\\s+(.*)$', p)
print(json.dumps((m.group(1)[:60] if m else '')))
" 2>/dev/null || echo '""')
  printf '{"ts":"%s","sessionId":"%s","skill":"%s","args_head":%s}\\n' \\
    "$SKILL_TS" "${SESSION_ID:-}" "$SKILL_NAME" "$ARGS_HEAD" \\
    >> "$STATE_DIR/skill-usage.jsonl" 2>/dev/null || true
fi
'''

new_content = content.replace(anchor, anchor + block, 1)
with open(hook, 'w') as f:
    f.write(new_content)

print("✅ sensor-prompt.sh 에 슬래시 로깅 블록 병합 완료")
PY

  # 구문 체크
  if bash -n "$HOOK_FILE"; then
    echo "✅ bash 구문 검증 통과"
  else
    echo "❌ bash 구문 오류 — 백업에서 복구: cp $BACKUP $HOOK_FILE"
    cp "$BACKUP" "$HOOK_FILE"
    exit 1
  fi
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Step 4. 로그 디렉토리 준비
# ─────────────────────────────────────────────────────────────
mkdir -p "$LEDGER_DIR"
touch "$LEDGER_DIR/skill-usage.jsonl"
echo "✅ 원장 준비: $LEDGER_DIR/skill-usage.jsonl"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 5. 결과 요약
# ─────────────────────────────────────────────────────────────
CMD_SIZE=$(du -sk "$CMD_DIR" 2>/dev/null | cut -f1)
ARC_SIZE=$(du -sk "$ARCHIVE_DIR" 2>/dev/null | cut -f1)

echo "=== 설치 완료 ==="
echo "  commands/         : ${CMD_SIZE} KB"
echo "  commands-archive/ : ${ARC_SIZE} KB"
echo ""
echo "→ 다음 Claude Code CLI 세션부터 아카이브된 스킬 로드 제외"
echo "→ 슬래시 호출 시 $LEDGER_DIR/skill-usage.jsonl 에 기록 시작"
echo ""
echo "복구 방법 (특정 스킬만):"
echo "  mv $ARCHIVE_DIR/<name> $CMD_DIR/<name>"
echo ""
echo "전체 롤백:"
echo "  mv $ARCHIVE_DIR/* $CMD_DIR/ && rm -rf $ARCHIVE_DIR"
echo "  cp $HOOK_FILE.bak-* $HOOK_FILE   # 훅만 복구 시 (가장 최신 백업 선택)"
