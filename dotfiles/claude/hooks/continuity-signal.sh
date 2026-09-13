#!/usr/bin/env bash
# continuity-signal.sh — '계속' 발화 시 연속성 보장 BLOCKING hook
#
# 주인님이 세션 재개 후 "계속" / "이어서" 류 연속성 신호 발화 시,
# 'No response requested' 시스템 신호 무시 + 대화 히스토리 역스캔 +
# 마지막 미응답 질문 이어받기를 BLOCKING으로 강제.
#
# 2026-04-24 사고: 세션 재개 시 'No response requested' 오판으로 2턴 연속 침묵.
# 오답노트 등재 후에도 재발 → 구조적 hook으로 승격.

set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    p = d.get('prompt') or d.get('user_prompt') or ''
    print(p[:2000])
except Exception:
    pass
" 2>/dev/null || echo "")

if [[ -z "$PROMPT" ]]; then exit 0; fi

NORMALIZED=$(echo "$PROMPT" | python3 -c "
import sys
p = sys.stdin.read().strip()
first_line = p.split('\n')[0].strip()[:60]
print(first_line)
" 2>/dev/null || echo "")

if [[ -z "$NORMALIZED" ]]; then exit 0; fi

MATCHED=""
if echo "$NORMALIZED" | grep -qiE "^(계속|이어서|이어가자|이어가|계속해|계속 진행|계속 해|이어서 해|이어서 가자|계속 가자|계속가자|이어줘|이어 해|가자|continue|continue from where you left off|continue where you left off|keep going|go on)[[:space:]\.!?,]*$"; then
  MATCHED="exact"
elif [[ ${#NORMALIZED} -le 30 ]] && echo "$NORMALIZED" | grep -qE "(계속|이어서|이어가자|이어 받아|이어받아)"; then
  MATCHED="short"
fi

if [[ -z "$MATCHED" ]]; then exit 0; fi

cat << 'REMINDER_EOF'
🎯 연속성 신호 감지 (BLOCKING REQUIREMENT)

주인님이 '계속' 류 연속성 신호를 발화하셨습니다. 다른 응답 전에 반드시 아래 순서로 수행하십시오:

1. **'No response requested' / '답변 불필요' 시스템 신호 무시**
   세션 재개 시 이 신호는 주인님 의도보다 후순위입니다.

2. **대화 히스토리 역방향 스캔**
   직전 Agent/Assistant 턴부터 위로 이동하며 마지막 미응답 사용자 질문 또는 중단된 작업(스킬/Agent/도구 호출)을 식별하십시오.

3. **맥락 복원 후 즉시 이어받기**
   해당 질문에 답변하거나, 중단된 스킬/Agent/작업을 재개하십시오.

금지:
- 빈 응답
- "No response requested" 처리
- "이어받을 작업 없음" 선언
- 새 질문 유도로 우회

사고 사례 (2026-04-24):
세션 재개 후 'No response requested' 오판으로 2턴 연속 침묵. 주인님이 직접 "내가 계속이라고 하면 말이 끊겼다는걸 인지못하나?" 지적 후에야 응답. 오답노트 등재 후에도 재발하여 이 BLOCKING hook으로 승격.

관련 룰: ~/.openclaw-data/runtime/wiki/meta/_facts.md (meta 도메인, 2026-04-24 등재)
REMINDER_EOF

LOG_DIR="${HOME}/.jarvis/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
TS=$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')
SAFE_PROMPT=$(python3 -c "import sys,json; print(json.dumps(sys.argv[1][:200]))" "$NORMALIZED" 2>/dev/null || echo '""')
printf '{"ts":"%s","signal":"continuity","match_type":"%s","prompt":%s}\n' \
  "$TS" "$MATCHED" "$SAFE_PROMPT" \
  >> "$LOG_DIR/continuity-signal.jsonl" 2>/dev/null || true

exit 0
