#!/usr/bin/env bash
# answer-english-hint-guard.sh — 정답 선택지 영어 힌트 노출 방어 가드
#
# 클러스터 ID: cl-33ab3e59820bd8c8 (최근 7일 재발 14건)
# 문제: 교재 HTML/JSON의 정답 선택지(correct answer option)에 영어 번역/힌트가
#       포함되어 학생이 한국어를 판단하기 전에 답을 알게 되는 설계 오류.
#       문법 문제(선택지가 한국어여야 함)와 단어 문제(선택지가 영어일 수도 있음) 미구분.
#
# 동작 원리:
#   HTML 교재: quiz-opts[data-answer="X"] 에서 정답 인덱스를 읽고,
#              해당 qopt 버튼의 텍스트에 영어가 포함되면 FAIL.
#   JSON 교재: quiz 배열에서 correct_index 또는 answer 필드로 정답 옵션을 특정,
#              해당 옵션 텍스트에 영어가 포함되면 FAIL.
#
#   단, 문법 문제(q-type=grammar 또는 q-text에 "문법·particle·form·grammar" 포함)는
#   선택지가 한국어여야 하므로 영어 포함 시 FAIL.
#   단어/뜻 문제(q-text에 "뜻·mean·meaning·번역" 포함)는 선택지가 영어일 수 있으므로
#   정답 선택지 영어 포함 시 WARN (차단하지 않음 — 의미 선택 문제).
#
# 사용법:
#   answer-english-hint-guard.sh <파일.html|파일.json> [--strict]
#   --strict: 단어/뜻 문제의 WARN도 FAIL로 처리
#
# Exit codes:
#   0: 정답 선택지 영어 힌트 없음 (업로드 진행 가능)
#   1: 정답 선택지에 영어 힌트 발견 (업로드 차단)
#   2: 파일 미지정 또는 지원하지 않는 형식

set -euo pipefail

CLUSTER_ID="cl-33ab3e59820bd8c8"
JARVIS_HOME="${HOME}/jarvis"
LOG_FILE="${JARVIS_HOME}/runtime/logs/answer-english-hint-guard.jsonl"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$(dirname "$LOG_FILE")"

# ── 색상 코드 ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

err()  { echo -e "${RED}❌ $*${NC}" >&2; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
info() { echo -e "${CYAN}ℹ  $*${NC}"; }

# ── 인자 파싱 ─────────────────────────────────────────────────────────────
FILE="${1:-}"
STRICT=0
for arg in "$@"; do
  [ "$arg" = "--strict" ] && STRICT=1
done

if [ -z "$FILE" ]; then
  err "파일 경로 필요: answer-english-hint-guard.sh <file.html|file.json> [--strict]"
  exit 2
fi

FILE="${FILE/#\~/$HOME}"
if [ ! -f "$FILE" ]; then
  err "파일 없음: $FILE"
  exit 2
fi

echo "🔍 정답 영어 힌트 검사: $(basename "$FILE")"
echo "──────────────────────────────────────────"

FAIL=0
WARN_COUNT=0
FINDINGS=""

# ── 영어 포함 여부 판단 함수 ───────────────────────────────────────────────
# 텍스트에 연속 3자 이상 영문이 2단어 이상 있으면 "영어 힌트"로 판정.
# 단순 a/b/c 레이블, 단일 알파벳 조사(예: "-에서") 등 오탐 방지.
has_english_hint() {
  local text="$1"
  # 3자 이상 영문 단어 수 카운트
  local cnt
  cnt=$(echo "$text" | python3 -c "
import sys, re
text = sys.stdin.read()
words = re.findall(r'[A-Za-z]{3,}', text)
print(len(words))
" 2>/dev/null || echo 0)
  [ "$cnt" -ge 2 ]
}

# ── HTML 파일 처리 ─────────────────────────────────────────────────────────
check_html() {
  local f="$1"
  info "HTML 교재 분석 중..."

  # python3로 HTML 파싱 — quiz-opts[data-answer] + qopt 버튼 텍스트 추출
  local result
  result=$(python3 - "$f" "$STRICT" "$CLUSTER_ID" "$TIMESTAMP" <<'PYEOF'
import sys, re, json

f       = sys.argv[1]
strict  = sys.argv[2] == "1"
cluster = sys.argv[3]
ts      = sys.argv[4]

html = open(f, encoding="utf-8", errors="replace").read()

findings = []
fail     = 0
warn     = 0

# quiz-opts 블록 전체 추출 (data-answer 포함)
# 패턴: <ul class="quiz-opts" data-answer="X">...</ul>
quiz_blocks = re.findall(
    r'<ul[^>]+class="[^"]*quiz-opts[^"]*"[^>]+data-answer="([a-z])"[^>]*>(.*?)</ul>',
    html, re.S | re.I
)

if not quiz_blocks:
    print(json.dumps({"status": "skip", "reason": "quiz-opts 블록 없음 (검사 대상 아님)"}))
    sys.exit(0)

# 각 quiz-q 블록에서 q-text도 추출 (문법 vs 단어 구분용)
# quiz-q 단위로 묶어서 처리
quiz_q_blocks = re.findall(
    r'<div[^>]+class="[^"]*quiz-q[^"]*"[^>]*>(.*?)</div\s*>\s*(?=<div[^>]+class="[^"]*quiz-q|</div\s*>\s*</div|\Z)',
    html, re.S | re.I
)

# 더 안정적인 방법: quiz-opts와 바로 앞 q-text를 함께 추출
# 전체 HTML을 라인 단위로 순차 분석
lines = html.split('\n')
full_text = html

# quiz-opts 블록별 처리
for idx, (answer_letter, block_html) in enumerate(quiz_blocks):
    # 정답 인덱스 (a=0, b=1, c=2, ...)
    answer_idx = ord(answer_letter.lower()) - ord('a')

    # qopt 버튼 텍스트 추출
    opts = re.findall(r'<button[^>]+class="[^"]*qopt[^"]*"[^>]*>(.*?)</button>', block_html, re.S | re.I)
    if not opts:
        # li 내부 텍스트로 폴백
        opts = re.findall(r'<li[^>]*>(.*?)</li>', block_html, re.S | re.I)

    # HTML 태그 제거
    opts_text = [re.sub(r'<[^>]+>', '', o).strip() for o in opts]

    if answer_idx >= len(opts_text):
        continue  # 인덱스 초과 — 스킵

    correct_text = opts_text[answer_idx]
    if not correct_text:
        continue

    # 영문 단어 3자 이상 2개 이상이면 영어 힌트 판정
    en_words = re.findall(r'[A-Za-z]{3,}', correct_text)

    if len(en_words) < 2:
        continue  # 영어 힌트 없음

    # 이 quiz-opts 바로 앞의 q-text 찾기 (문법 vs 단어 구분)
    # ul 블록 이전 200자에서 q-text 검색
    ul_pat = re.escape(f'data-answer="{answer_letter}"')
    ul_match = re.search(ul_pat, full_text)
    context = full_text[max(0, ul_match.start()-400):ul_match.start()] if ul_match else ""
    q_text_match = re.findall(r'<div[^>]+class="[^"]*q-text[^"]*"[^>]*>(.*?)</div>', context, re.S | re.I)
    q_text = re.sub(r'<[^>]+>', '', q_text_match[-1]).strip() if q_text_match else ""

    # 문법 문제 판정: q-text에 문법 관련 키워드 포함
    grammar_keywords = r'문법|particle|form|grammar|conjugat|어미|조사|활용|Choose the correct'
    is_grammar = bool(re.search(grammar_keywords, q_text, re.I)) or \
                 bool(re.search(grammar_keywords, context, re.I))

    # 단어/뜻 문제 판정
    meaning_keywords = r'뜻|mean|meaning|번역|translate|what does|의미'
    is_meaning = bool(re.search(meaning_keywords, q_text, re.I))

    severity = "FAIL"
    reason   = "문법 문제 정답 선택지에 영어 힌트"
    if not is_grammar and is_meaning:
        severity = "WARN" if not strict else "FAIL"
        reason   = "단어/뜻 문제 정답 선택지에 영어 포함 (의미 선택 문제일 수 있음)"

    finding = {
        "q_index"       : idx + 1,
        "answer_letter" : answer_letter,
        "correct_text"  : correct_text,
        "english_words" : en_words,
        "q_text_snippet": q_text[:80],
        "is_grammar"    : is_grammar,
        "is_meaning"    : is_meaning,
        "severity"      : severity,
        "reason"        : reason,
    }
    findings.append(finding)

    if severity == "FAIL":
        fail += 1
    else:
        warn += 1

output = {
    "status"      : "fail" if fail > 0 else ("warn" if warn > 0 else "pass"),
    "fail_count"  : fail,
    "warn_count"  : warn,
    "total_quizzes": len(quiz_blocks),
    "findings"    : findings,
    "cluster_id"  : cluster,
    "timestamp"   : ts,
    "file"        : f,
}
print(json.dumps(output, ensure_ascii=False))
PYEOF
  )

  # JSON 파싱하여 결과 출력
  local status fail_count warn_count total
  status=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "error")
  fail_count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fail_count',0))" 2>/dev/null || echo "0")
  warn_count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('warn_count',0))" 2>/dev/null || echo "0")
  total=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_quizzes',0))" 2>/dev/null || echo "0")

  # 개별 findings 출력
  echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
findings = d.get('findings', [])
if not findings:
    pass
for fn in findings:
    sev = fn['severity']
    q   = fn['q_index']
    ans = fn['answer_letter']
    txt = fn['correct_text']
    reason = fn['reason']
    print(f\"  {'❌ FAIL' if sev=='FAIL' else '⚠️  WARN'}: Q{q}(정답={ans}) '{txt}' — {reason}\")
" 2>/dev/null || true

  echo "총 퀴즈 블록: ${total}개 | FAIL: ${fail_count}건 | WARN: ${warn_count}건"

  # JSONL 로그 기록
  echo "$result" >> "$LOG_FILE"

  if [ "$fail_count" -gt 0 ]; then
    FAIL=1
    FINDINGS="HTML: 정답 선택지 영어 힌트 ${fail_count}건 FAIL"
  fi
  if [ "$warn_count" -gt 0 ]; then
    WARN_COUNT=$warn_count
  fi
}

# ── JSON 파일 처리 ─────────────────────────────────────────────────────────
check_json() {
  local f="$1"
  info "JSON 교재 분석 중..."

  local result
  result=$(python3 - "$f" "$STRICT" "$CLUSTER_ID" "$TIMESTAMP" <<'PYEOF'
import sys, re, json

f       = sys.argv[1]
strict  = sys.argv[2] == "1"
cluster = sys.argv[3]
ts      = sys.argv[4]

try:
    data = json.load(open(f, encoding="utf-8"))
except Exception as e:
    print(json.dumps({"status": "skip", "reason": f"JSON 파싱 실패: {e}"}))
    sys.exit(0)

findings = []
fail     = 0
warn     = 0

def strip_tags(t):
    return re.sub(r'<[^>]+>', '', str(t)).strip()

def en_word_count(t):
    return len(re.findall(r'[A-Za-z]{3,}', strip_tags(t)))

# quiz 배열 탐색 (다양한 구조 지원)
def iter_quizzes(obj, depth=0):
    if depth > 5:
        return
    if isinstance(obj, dict):
        # quiz 배열 키
        for key in ('quiz', 'quizzes', 'questions', 'items'):
            if key in obj and isinstance(obj[key], list):
                for q in obj[key]:
                    yield q
        # 재귀
        for v in obj.values():
            if isinstance(v, (dict, list)):
                yield from iter_quizzes(v, depth+1)
    elif isinstance(obj, list):
        for item in obj:
            yield from iter_quizzes(item, depth+1)

for idx, q in enumerate(iter_quizzes(data)):
    if not isinstance(q, dict):
        continue

    # 정답 인덱스 파악
    answer_idx = None
    options = q.get('options') or q.get('choices') or q.get('opts') or []

    # correct_index 필드
    if 'correct_index' in q:
        answer_idx = int(q['correct_index'])
    # answer 필드가 인덱스인 경우
    elif 'answer' in q:
        a = q['answer']
        if isinstance(a, int):
            answer_idx = a
        elif isinstance(a, str) and len(a) == 1 and a.isalpha():
            answer_idx = ord(a.lower()) - ord('a')
        elif isinstance(a, str) and options:
            # 정답 텍스트와 일치하는 옵션 찾기
            for i, opt in enumerate(options):
                if strip_tags(str(opt)) == strip_tags(a):
                    answer_idx = i
                    break
    # correct 필드
    elif 'correct' in q:
        c = q['correct']
        if isinstance(c, int):
            answer_idx = c
        elif isinstance(c, str) and options:
            for i, opt in enumerate(options):
                if strip_tags(str(opt)) == strip_tags(c):
                    answer_idx = i
                    break

    if answer_idx is None or not options or answer_idx >= len(options):
        continue

    correct_text = strip_tags(str(options[answer_idx]))
    en_cnt = en_word_count(correct_text)
    if en_cnt < 2:
        continue

    # 문법 vs 단어 구분
    q_text = strip_tags(str(q.get('question') or q.get('text') or q.get('q') or ''))
    q_type = str(q.get('type') or q.get('q_type') or '')

    grammar_kw = r'문법|particle|form|grammar|conjugat|어미|조사|활용'
    is_grammar = bool(re.search(grammar_kw, q_text + q_type, re.I))
    meaning_kw = r'뜻|mean|meaning|번역|translate|what does|의미'
    is_meaning = bool(re.search(meaning_kw, q_text + q_type, re.I))

    severity = "FAIL"
    reason   = "문법 문제 정답 선택지에 영어 힌트"
    if not is_grammar and is_meaning:
        severity = "WARN" if not strict else "FAIL"
        reason   = "단어/뜻 문제 정답 선택지에 영어 포함"

    findings.append({
        "q_index"        : idx + 1,
        "correct_text"   : correct_text,
        "english_word_cnt": en_cnt,
        "q_text_snippet" : q_text[:80],
        "severity"       : severity,
        "reason"         : reason,
    })
    if severity == "FAIL":
        fail += 1
    else:
        warn += 1

output = {
    "status"    : "fail" if fail > 0 else ("warn" if warn > 0 else "pass"),
    "fail_count": fail,
    "warn_count": warn,
    "findings"  : findings,
    "cluster_id": cluster,
    "timestamp" : ts,
    "file"      : f,
}
print(json.dumps(output, ensure_ascii=False))
PYEOF
  )

  local status fail_count warn_count
  status=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "error")
  fail_count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fail_count',0))" 2>/dev/null || echo "0")
  warn_count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('warn_count',0))" 2>/dev/null || echo "0")

  echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for fn in d.get('findings', []):
    sev = fn['severity']
    q   = fn['q_index']
    txt = fn['correct_text']
    reason = fn['reason']
    print(f\"  {'❌ FAIL' if sev=='FAIL' else '⚠️  WARN'}: Q{q} '{txt[:60]}' — {reason}\")
" 2>/dev/null || true

  echo "JSON 퀴즈 검사 | FAIL: ${fail_count}건 | WARN: ${warn_count}건"

  echo "$result" >> "$LOG_FILE"

  if [ "$fail_count" -gt 0 ]; then
    FAIL=1
    FINDINGS="JSON: 정답 선택지 영어 힌트 ${fail_count}건 FAIL"
  fi
  if [ "$warn_count" -gt 0 ]; then
    WARN_COUNT=$warn_count
  fi
}

# ── 파일 형식 분기 ─────────────────────────────────────────────────────────
ext="${FILE##*.}"
ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

case "$ext_lower" in
  html|htm)
    check_html "$FILE"
    ;;
  json)
    check_json "$FILE"
    ;;
  *)
    err "지원하지 않는 파일 형식: $ext (html, json만 지원)"
    exit 2
    ;;
esac

echo "──────────────────────────────────────────"

# ── 최종 판정 ─────────────────────────────────────────────────────────────
if [ "$FAIL" -eq 1 ]; then
  err "FAIL: 정답 선택지 영어 힌트 발견 — 업로드 전 수정 필요 (cl-${CLUSTER_ID})"
  echo ""
  echo "수정 방법:"
  echo "  - 문법 문제 정답 선택지는 한국어 표현만 사용"
  echo "  - 영어 번역이 필요하면 q-text(문제) 또는 힌트 박스에만 포함"
  echo "  - 단어/뜻 문제라면 q-text에 '뜻'/'mean' 키워드 명시 후 --strict 없이 재실행"
  exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
  warn "WARN: 단어/뜻 문제 정답에 영어 포함 ${WARN_COUNT}건 (의도된 설계인지 확인)"
  echo "  → 의도된 설계라면 통과. 의심스러우면 --strict 옵션으로 재실행."
  ok "PASS (WARN ${WARN_COUNT}건 — 업로드 진행 가능, 확인 권장)"
  exit 0
else
  ok "PASS: 정답 선택지 영어 힌트 없음 (cl-${CLUSTER_ID})"
  exit 0
fi
