#!/usr/bin/env bash
# export-public.sh — 민감정보 제거 후 공개 레포(origin)에 export
# 사용: bash ~/.jarvis/scripts/export-public.sh
# - private 레포(private)에는 영향 없음
# - 임시 브랜치에서 작업 후 origin/main으로 push, 임시 브랜치 자동 삭제

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
cd "$BOT_HOME"

echo "=== Jarvis Public Export ==="

# origin remote 확인
if ! git remote get-url origin &>/dev/null; then
  echo "❌ 'origin' remote 없음. 먼저 설정하세요."
  exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
TEMP_BRANCH="public-export-$(date +%s)"

echo "▶ 임시 브랜치 생성: $TEMP_BRANCH"
git checkout -b "$TEMP_BRANCH"

# EXIT trap: 어떤 경우에도 원래 브랜치 복귀 + 임시 브랜치 정리
trap '
  echo "▶ 원래 브랜치로 복귀: '"$CURRENT_BRANCH"'"
  git checkout "'"$CURRENT_BRANCH"'" 2>/dev/null || true
  git branch -D "'"$TEMP_BRANCH"'" 2>/dev/null || true
' EXIT

# ── 1. personas.json → personas.example.json (익명화) ──────────────────────
if [[ -f "discord/personas.json" ]]; then
  echo "▶ personas.json 익명화 중..."
  python3 << 'PYEOF'
import json, re, sys

with open("discord/personas.json", encoding="utf-8") as f:
    data = json.load(f)

example = {}
channel_num = 1
for channel_id, persona in data.items():
    placeholder_id = f"YOUR_CHANNEL_ID_{channel_num}"

    cleaned = persona

    # 한국 실명/닉네임 패턴
    cleaned = re.sub(r'송보람|Song Boram|songboram\d*', '[OWNER_NAME]', cleaned, flags=re.IGNORECASE)
    # 보람님 프로필 블록 전체 제거
    cleaned = re.sub(r'보람님 프로필.*?\n\n', '[PERSONAL_PROFILE_REMOVED]\n\n', cleaned, flags=re.DOTALL)
    # 보유 폰, 케이스 등 기기 정보
    cleaned = re.sub(r'- 보유 폰:.*?\n', '- 보유 폰: [DEVICE_INFO]\n', cleaned)
    cleaned = re.sub(r'- 구매 케이스:.*?\n', '', cleaned)
    # 여행 계획 등 일정
    cleaned = re.sub(r'삿포로.*?치앙마이.*?\n', '[TRAVEL_INFO_REMOVED]\n', cleaned, flags=re.DOTALL)
    # Discord 채널 ID 숫자 (18자리)
    cleaned = re.sub(r'\b\d{17,19}\b', 'YOUR_CHANNEL_ID_HERE', cleaned)
    # 이메일 주소
    cleaned = re.sub(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', '[EMAIL_REMOVED]', cleaned)

    example[placeholder_id] = cleaned
    channel_num += 1

with open("discord/personas.example.json", "w", encoding="utf-8") as f:
    json.dump(example, f, indent=2, ensure_ascii=False)

print(f"  personas.example.json 생성 완료: {len(example)}개 채널")
PYEOF
  # 원본 personas.json은 git에서 제거 (워킹트리 파일은 유지)
  git rm --cached "discord/personas.json" 2>/dev/null || true
fi

# ── 2. 개인 context 파일 제거 ────────────────────────────────────────────────
echo "▶ 개인 context 파일 제거..."
git rm -rf "context/owner/" 2>/dev/null && echo "  context/owner/ 제거" || echo "  — context/owner/ 없음"

# ── 3. secrets 디렉토리 제거 ─────────────────────────────────────────────────
echo "▶ config/secrets/ 제거..."
git rm -rf "config/secrets/" 2>/dev/null && echo "  config/secrets/ 제거" || echo "  — config/secrets/ 없음"

# ── 4. 변경사항 스테이징 및 커밋 ─────────────────────────────────────────────
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore(public): export public template — sensitive data removed [$(date '+%Y-%m-%d')]"
  echo "▶ 커밋 완료"
else
  echo "▶ 변경사항 없음 — 기존 상태로 push"
fi

# ── 5. 공개 레포에 push ────────────────────────────────────────────────────
echo "▶ origin(공개 레포)으로 push..."
git push origin "$TEMP_BRANCH:main" --force-with-lease 2>/dev/null || \
  git push origin "$TEMP_BRANCH:main" --force

echo ""
echo "✅ 공개 레포 export 완료"
echo "   origin: https://github.com/Ramsbaby/jarvis"
