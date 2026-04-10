#!/usr/bin/env bash
# gen-gotchas.sh — recovery-learnings.md에서 3회↑ 반복 패턴을 gotchas.md에 자동 승격
# 사용: bash ~/.jarvis/scripts/gen-gotchas.sh
set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
LEARNINGS_FILE="$BOT_HOME/state/recovery-learnings.md"
GOTCHAS_FILE="$BOT_HOME/state/gotchas.md"
MIN_COUNT=3

if [[ ! -f "$LEARNINGS_FILE" ]]; then
  echo "0"
  exit 0
fi

if [[ ! -f "$GOTCHAS_FILE" ]]; then
  echo "0"
  exit 0
fi

# Python3로 파싱 (macOS sed 호환성 이슈 방지)
python3 - <<'PYEOF'
import re
import os
import sys
from collections import Counter

bot_home = os.environ.get("BOT_HOME", os.path.expanduser("~/.jarvis"))
learnings_file = os.path.join(bot_home, "state", "recovery-learnings.md")
gotchas_file   = os.path.join(bot_home, "state", "gotchas.md")
min_count = 3

# 1) recovery-learnings.md에서 "원인:" 줄 파싱
causes = []
with open(learnings_file, "r", encoding="utf-8") as f:
    for line in f:
        m = re.match(r"-\s*원인:\s*(.+)", line.strip())
        if m:
            causes.append(m.group(1).strip())

# 2) 동일 에러 메시지 패턴 카운트 (정확히 동일한 문자열 기준)
counter = Counter(causes)
candidates = [msg for msg, cnt in counter.items() if cnt >= min_count]

if not candidates:
    print("0")
    sys.exit(0)

# 3) gotchas.md에 이미 있는 내용 확인 (중복 방지)
with open(gotchas_file, "r", encoding="utf-8") as f:
    existing_content = f.read()

# 현재 최대 G-번호 추출
existing_nums = re.findall(r"## G-(\d+):", existing_content)
next_num = max((int(n) for n in existing_nums), default=0) + 1

# 4) 신규 패턴만 gotchas.md 끝에 추가
added = 0
append_lines = []
for cause in candidates:
    # 중복 판단: 원인 원문 전체가 이미 gotchas.md에 있으면 skip
    # (G-001처럼 "원인 원문:" 필드로 명시된 경우 포함)
    if cause in existing_content:
        continue
    # 핵심 식별자 추출 (기술적 에러 키워드): 따옴표 안 문자열, CamelCase 토큰 등
    # ActionRowBuilder, ENOENT, SyntaxError 같은 핵심 토큰이 이미 있으면 skip
    import re as _re
    tech_tokens = _re.findall(r'[A-Z][a-zA-Z]{4,}|ENOENT|EACCES|CRASH LOOP', cause)
    is_dup = any(tok in existing_content for tok in tech_tokens[:3])
    if is_dup:
        continue

    tag = f"G-{next_num:03d}"
    # 패턴명: 원인 문자열 앞 50자를 요약으로 사용
    summary = cause[:50].rstrip()
    block = (
        f"\n## {tag}: [자동 승격] {summary}...\n"
        f"- **증상**: (자동 감지 — 수동 보완 필요)\n"
        f"- **원인 원문**: {cause}\n"
        f"- **발생 횟수**: {counter[cause]}회 이상\n"
        f"- **근본원인**: (분석 필요)\n"
        f"- **해결책**: (작성 필요)\n"
    )
    append_lines.append(block)
    next_num += 1
    added += 1

if added > 0:
    with open(gotchas_file, "a", encoding="utf-8") as f:
        for block in append_lines:
            f.write(block)

print(added)
PYEOF
