#!/usr/bin/env bash
# dotfiles/claude/install.sh — ~/.claude/ 설정 설치 스크립트
# 용도: Jarvis fork 사용자가 Claude Code CLI 설정을 자동 설치
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

print_ok()   { echo "  ✅ $1"; }
print_skip() { echo "  ⏭️  $1"; }
print_info() { echo "  ℹ️  $1"; }

echo ""
echo "================================================"
echo "  🤖 Jarvis Claude Code 설정 설치"
echo "================================================"
echo ""

# 1. rules/ 설치
echo "📋 Rules (행동 원칙) 설치 중..."
mkdir -p "$CLAUDE_DIR/rules"
for f in "$SCRIPT_DIR/rules/"*.md; do
  name=$(basename "$f")
  dest="$CLAUDE_DIR/rules/$name"
  if [ -f "$dest" ]; then
    print_skip "$name (이미 존재 — 덮어쓰려면 --force 사용)"
  else
    cp "$f" "$dest"
    print_ok "$name"
  fi
done

# --force 옵션 시 덮어쓰기
if [[ "${1:-}" == "--force" ]]; then
  echo "  ⚠️  --force: 기존 파일 덮어쓰기 모드"
  cp "$SCRIPT_DIR/rules/"*.md "$CLAUDE_DIR/rules/"
  print_ok "rules/ 전체 덮어쓰기 완료"
fi

# 2. prompts/ 설치
echo ""
echo "🔍 Prompts (검증 하네스) 설치 중..."
mkdir -p "$CLAUDE_DIR/prompts"
cp "$SCRIPT_DIR/prompts/verify-harness.md" "$CLAUDE_DIR/prompts/"
print_ok "verify-harness.md"

# 3. hooks/ 설치
echo ""
echo "🪝 Hooks 설치 중..."
mkdir -p "$CLAUDE_DIR/hooks"
for f in "$SCRIPT_DIR/hooks/"*.sh; do
  name=$(basename "$f")
  dest="$CLAUDE_DIR/hooks/$name"
  cp "$f" "$dest"
  chmod +x "$dest"
  print_ok "$name"
done

# 3b. settings.memory.json 병합 (auto memory 계약)
#   전체 settings.json 은 개인 절대경로를 담아 저장소에 두지 않는다. auto memory 관련
#   키만 여기서 병합한다. 이 계약이 사라지면 Claude 는 매 세션 임시 디렉터리에 기억을
#   쌓았다 버리고, claude-memory SSoT 로 가는 다리(post-memory-sync.sh)도 헛돈다.
echo ""
echo "🧠 Auto memory 설정 병합 중..."
if python3 - "$SCRIPT_DIR/settings.memory.json" "$CLAUDE_DIR/settings.json" <<'PY'
import json, os, sys

frag_path, dest_path = sys.argv[1], sys.argv[2]
with open(frag_path) as fh:
    frag = {k: v for k, v in json.load(fh).items() if not k.startswith("_")}

dest = {}
if os.path.exists(dest_path):
    try:
        with open(dest_path) as fh:
            dest = json.load(fh)
    except Exception:
        print("  ⚠️  기존 settings.json 을 파싱할 수 없어 병합을 건너뜁니다", file=sys.stderr)
        sys.exit(1)
    # 덮어쓰기는 되돌릴 수 없다 — 손대기 전에 원본을 남긴다
    with open(dest_path + ".bak-premerge", "w") as fh:
        json.dump(dest, fh, ensure_ascii=False, indent=2)

for key, value in frag.items():
    if key == "env" and isinstance(dest.get("env"), dict):
        dest["env"].update(value)      # env 는 깊은 병합 — 기존 변수를 지우지 않는다
    else:
        dest[key] = value

os.makedirs(os.path.dirname(dest_path), exist_ok=True)
tmp = dest_path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(dest, fh, ensure_ascii=False, indent=2)
os.replace(tmp, dest_path)             # atomic — 중단돼도 반쪽 설정이 남지 않는다
os.chmod(dest_path, 0o600)
print("  ✅ autoMemoryDirectory = " + str(frag.get("autoMemoryDirectory")))
PY
then :; else print_info "settings.json 병합 실패 — 수동 확인 필요"; fi

# 4. commands/ (스킬) 설치
echo ""
echo "⚡ Commands (스킬) 설치 중..."
mkdir -p "$CLAUDE_DIR/commands"
for f in "$SCRIPT_DIR/commands/"*.md; do
  name=$(basename "$f")
  cp "$f" "$CLAUDE_DIR/commands/"
  print_ok "$name"
done

echo ""
echo "================================================"
echo "  🎉 설치 완료!"
echo "================================================"
echo ""
echo "  설치된 항목:"
echo "    📋 Rules:    $(ls "$CLAUDE_DIR/rules/"*.md 2>/dev/null | wc -l | tr -d ' ')개"
echo "    🔍 Prompts:  $(ls "$CLAUDE_DIR/prompts/"*.md 2>/dev/null | wc -l | tr -d ' ')개"
echo "    🪝 Hooks:    $(ls "$CLAUDE_DIR/hooks/"*.sh 2>/dev/null | wc -l | tr -d ' ')개"
echo "    ⚡ Commands: $(ls "$CLAUDE_DIR/commands/"*.md 2>/dev/null | wc -l | tr -d ' ')개"
echo ""
echo "  👉 Claude Code CLI를 재시작하면 적용됩니다."
echo ""
