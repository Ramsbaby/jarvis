#!/usr/bin/env bash
# export-public.sh — 민감정보 제거 후 공개 레포(origin)에 export
# 사용: bash ~/.jarvis/scripts/export-public.sh
# - private 레포(private)에는 영향 없음
# - origin/main 기점 임시 브랜치 생성 → 안전 diff 적용 → 단일 커밋 push
# - private 커밋(secrets/.env 등)이 public history에 절대 포함되지 않음

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

# branch 전환 전에 personas.json 복사 (전환 후 git이 tracked 파일 삭제하므로)
_PERSONAS_TMP=$(mktemp)
[[ -f "discord/personas.json" ]] && cp "discord/personas.json" "$_PERSONAS_TMP" || true

# origin/main 최신화
echo "▶ origin/main fetch 중..."
git fetch origin main --quiet

echo "▶ 임시 브랜치 생성 (기점: origin/main): $TEMP_BRANCH"
git checkout -b "$TEMP_BRANCH" origin/main

# 브랜치 전환 확인
if [[ "$(git branch --show-current)" != "$TEMP_BRANCH" ]]; then
  echo "❌ 브랜치 전환 실패 — 임시 브랜치 아님. 중단." >&2
  exit 1
fi

# EXIT trap: 어떤 경우에도 원래 브랜치 복귀 + 임시 브랜치 정리
trap '
  echo "▶ 원래 브랜치로 복귀: '"$CURRENT_BRANCH"'"
  git checkout "'"$CURRENT_BRANCH"'" 2>/dev/null || true
  git branch -D "'"$TEMP_BRANCH"'" 2>/dev/null || true
  rm -f "'"$_PERSONAS_TMP"'" 2>/dev/null || true
' EXIT

# ── 1. 로컬 변경사항을 안전 diff로 적용 ────────────────────────────────────
# 민감 파일들을 diff에서 제외 → private 커밋 내용이 temp branch에 유입 차단
echo "▶ 안전 diff 적용 중 (민감 파일 제외)..."
git diff origin/main "$CURRENT_BRANCH" -- \
  ':(exclude)discord/.env' \
  ':(exclude)config/secrets' \
  ':(exclude)config/user_profiles.json' \
  ':(exclude)context/owner' \
  ':(exclude)discord/personas.json' \
  | git apply --allow-empty --whitespace=nowarn 2>/dev/null || true

# ── 2. personas.json → personas.example.json (익명화) ──────────────────────
# branch 전환 전에 복사해둔 임시 파일 사용
if [[ -s "$_PERSONAS_TMP" ]]; then
  echo "▶ personas.json 익명화 중..."
  python3 - "$_PERSONAS_TMP" << 'PYEOF'
import json, re, sys, pathlib

data = json.loads(pathlib.Path(sys.argv[1]).read_text())

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
    # webhook URL
    cleaned = re.sub(r'https://discord\.com/api/webhooks/[^\s\'"]+', 'YOUR_WEBHOOK_URL', cleaned)

    example[placeholder_id] = cleaned
    channel_num += 1

with open("discord/personas.example.json", "w", encoding="utf-8") as f:
    json.dump(example, f, indent=2, ensure_ascii=False)

print(f"  personas.example.json 생성 완료: {len(example)}개 채널")
PYEOF
fi

# ── 3. 혹시라도 남아있는 민감 파일 강제 제거 (2중 방어) ─────────────────────
echo "▶ 민감 파일 2중 제거 검증..."
[[ "$(git branch --show-current)" == "$TEMP_BRANCH" ]] || { echo "❌ 브랜치 불일치. 중단." >&2; exit 1; }
git rm -rf "context/owner/"          2>/dev/null && echo "  context/owner/ 제거" || true
git rm -rf "config/secrets/"         2>/dev/null && echo "  config/secrets/ 제거" || true
git rm -f  "config/user_profiles.json" 2>/dev/null && echo "  user_profiles.json 제거" || true
git rm -f  "discord/.env"            2>/dev/null && echo "  discord/.env 제거" || true
git rm --cached "discord/personas.json" 2>/dev/null || true

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
