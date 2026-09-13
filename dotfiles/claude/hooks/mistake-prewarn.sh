#!/usr/bin/env bash
# mistake-prewarn.sh — 작업 착수 전 관련 오답노트 선제 주입
#
# 주인님 발화의 키워드를 learned-mistakes.md 86건 이상의 기존 오답 패턴과
# 매칭해 상위 관련 오답 최대 2건을 system-reminder로 주입한다.
# "같은 실수 방지" 를 기록이 아닌 **작업 착수 시점의 강제 가시화** 로 만든다.
#
# 안전 원칙:
#   - 파싱/매칭 실패해도 exit 0 (세션 차단 금지)
#   - timeout 3초 (settings.json 설정)
#   - 결과가 비어있으면 아무것도 출력 안 함 (signal noise 최소화)
#   - audit log: ~/.jarvis/logs/mistake-prewarn.jsonl

set -uo pipefail

MISTAKES_FILE="${HOME}/.openclaw-data/runtime/wiki/meta/learned-mistakes.md"
LOG_DIR="${HOME}/.openclaw-data/runtime/logs"
LOG_FILE="$LOG_DIR/mistake-prewarn.jsonl"

# 파일 없으면 조용히 종료
if [[ ! -f "$MISTAKES_FILE" ]]; then exit 0; fi

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

# ─── 의도 키워드 → 오답 검색 키워드 매핑 ───
# 각 작업 유형별로 가장 자주 재발하는 오답 카테고리와 연결.
SEARCH_TERMS=""
PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

if echo "$PROMPT_LOWER" | grep -qE "디버깅|근본.?원인|왜.?실패|investigate|장애|failed|broken|원인|진단|왜"; then
  SEARCH_TERMS="근본 원인|단정|실증|가정|추정|미확인|실측 없이|파일 미확인|단일 가설"
elif echo "$PROMPT_LOWER" | grep -qE "검증|verify|재검증|제대로|통과|확인"; then
  SEARCH_TERMS="검증|단정|소멸|실증 없이|권고 수용|감사관|완료 선언|가정 기반"
elif echo "$PROMPT_LOWER" | grep -qE "배포|deploy|push|ship|릴리즈"; then
  SEARCH_TERMS="배포|회귀|검증|재시작|실제 테스트|실증 없이"
elif echo "$PROMPT_LOWER" | grep -qE "수정|고쳐|fix|버그|경로|path"; then
  SEARCH_TERMS="경로|환경 변수|실증|실측|미확인|가정 기반|단일 가설"
elif echo "$PROMPT_LOWER" | grep -qE "크론|cron|launchagent|plist|스케줄"; then
  SEARCH_TERMS="크론|plist|중복|스케줄|enabled|실측"
elif echo "$PROMPT_LOWER" | grep -qE "삭제|지워|rm |remove|정리|cleanup"; then
  SEARCH_TERMS="백업|파괴|rm|비가역|복구|앞뒤 의도"
elif echo "$PROMPT_LOWER" | grep -qE "분석|추론|연구|리서치|판단|생각|리뷰|감사"; then
  SEARCH_TERMS="단일 가설|병렬 가설|반증|편향|확대 해석|실측"
elif echo "$PROMPT_LOWER" | grep -qE "기억|동선|메커니즘|파이프라인|메모리|하이어라키|hierarchy|아키텍처|구조|딥다이브|훑어|점검|검토|이해|어떻게.?동작|어떻게.?작동"; then
  SEARCH_TERMS="실측 없이|코드 grep|단정|구조 단언|시스템 프롬프트|합산본|확증 편향|추측 기반"
fi

# 매칭되는 키워드가 없으면 조용히 종료
if [[ -z "$SEARCH_TERMS" ]]; then exit 0; fi

# ─── 관련 오답 상위 2건 추출 ───
# `## YYYY-MM-DD — 제목` 블록 단위로 파싱해 패턴 라인에 SEARCH_TERMS가 매치되는 것 선별.
RELATED=$(python3 <<PYEOF 2>/dev/null
import re, sys
terms = """$SEARCH_TERMS""".split("|")
try:
    with open("$MISTAKES_FILE", "r", encoding="utf-8") as f:
        content = f.read()
except Exception:
    sys.exit(0)

# 각 오답 블록 추출 (## YYYY-MM-DD 로 시작)
blocks = re.split(r'^(## \d{4}-\d{2}-\d{2} — .+)$', content, flags=re.MULTILINE)
# blocks = ['prefix', 'header1', 'body1', 'header2', 'body2', ...]
matches = []
for i in range(1, len(blocks), 2):
    header = blocks[i].strip()
    body = blocks[i+1] if i+1 < len(blocks) else ""
    # 패턴 라인만 추출
    pattern_match = re.search(r'- \*\*패턴\*\*:\s*(.+)', body)
    response_match = re.search(r'- \*\*대응\*\*:\s*(.+)', body)
    pattern = pattern_match.group(1).strip() if pattern_match else ""
    response = response_match.group(1).strip() if response_match else ""
    # SEARCH_TERMS 중 하나라도 패턴에 포함되면 매치
    if any(t in pattern for t in terms):
        # 대응 필드가 있을 때만 유용 (구조적 가드 있는 것만)
        if response and len(response) > 20:
            matches.append((header, pattern[:160], response[:220]))
    if len(matches) >= 2:
        break

for h, p, r in matches:
    print(f"### {h}")
    print(f"- 패턴: {p}")
    print(f"- 대응: {r}")
    print()
PYEOF
)

# ─── 출력 (매치 있을 때만) ───
if [[ -n "$RELATED" ]]; then
cat <<EOF
📚 관련 과거 오답 자동 검색 — 작업 착수 전 1분 숙지:

$RELATED
---
출처: ~/.openclaw-data/runtime/wiki/meta/learned-mistakes.md (총 86건 중 상위 2건)
원칙: 동일 유형 실수 재발 시 구조적 가드가 없었다는 뜻. 이번 작업에서 위 '대응' 필드를 지키십시오.
EOF

  # Audit log
  mkdir -p "$LOG_DIR" 2>/dev/null
  TS=$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')
  HIT_COUNT=$(echo "$RELATED" | grep -c "^### " || echo 0)
  printf '{"ts":"%s","search_terms":"%s","hits":%s}\n' "$TS" "$SEARCH_TERMS" "$HIT_COUNT" \
    >> "$LOG_FILE" 2>/dev/null || true
fi

exit 0
