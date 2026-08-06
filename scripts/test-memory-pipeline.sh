#!/usr/bin/env bash
# test-memory-pipeline.sh — 2026-08-04 메모리 파이프라인 수정 회귀 테스트
#
# 검증 대상 (통화 녹취 19,803자 중 17,803자 소실 사고 대응):
#   ① session-recall.sh        원본 전문 검색 (사전 필터가 거짓 음성을 만들지 않는가)
#   ② stop-session-save.sh     세션당 1파일 + 원문 raw 보관
#   ④ claude-cli-rag-sync.mjs  오너 발화 전량 / 자비스 답변 2청크 비대칭
#   ⑤ context-state-inject.sh  커리어 사실 우선 선별
#
# 원칙: "돌아간다"가 아니라 "틀리면 잡힌다"를 본다. 각 테스트는 반증을 목표로 한다.

set -uo pipefail

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
ng()   { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
sk()   { echo "  ⏭️  $1"; SKIP=$((SKIP+1)); }
head2() { echo; echo "── $1"; }

JARVIS="${HOME}/jarvis"
SESS="${JARVIS}/runtime/context/claude-code-sessions"
RAW="${SESS}-raw"
TMP=$(mktemp -d)
TESTPROJ="__pipeline_test__"

# 로컬 픽스처 — ⑤⑥은 오너의 실제 세션 기록을 대상으로 검증하므로 검증 질문
# 자체가 개인정보다. 공개 저장소에 남기지 않으려고 값만 외부 파일로 뺐다.
# 없으면 해당 4개 항목만 SKIP 되고 골격 15개는 그대로 돈다.
# 템플릿: scripts/fixtures/memory-pipeline.example.sh
FIXTURE="${JARVIS}/scripts/fixtures/memory-pipeline.local.sh"
HAVE_FX=0
if [[ -f "$FIXTURE" ]]; then
  # shellcheck source=/dev/null
  . "$FIXTURE"
  HAVE_FX=1
fi
cleanup() {
  rm -rf "$TMP" "${SESS:?}/${TESTPROJ}" "${RAW:?}/${TESTPROJ}"
}
trap cleanup EXIT

echo "════ 메모리 파이프라인 회귀 테스트 ════"

# ─────────────────────────────────────────────────────────────
head2 "① 검색 — 사전 필터가 결과를 누락시키지 않는가"

# 근거값: 사전 필터를 통째로 우회한 순진한 전수 파싱. 결과 "건수"가 다르면 필터가 사실을 삼킨 것이다.
# (파일 개수 비교는 약하다 — 많이 열었다고 다 찾은 게 아니다. 최종 hit 수를 대조한다.)
KW="여보세요"
TRUTH=$(python3 - "$KW" <<'PY'
import json, glob, os, sys
kw = sys.argv[1]
def text_of(m):
    c = m.get('content')
    if isinstance(c, str): return c
    if isinstance(c, list):
        return ' '.join(b.get('text','') for b in c if isinstance(b, dict) and b.get('type')=='text')
    return ''
seen = set()
for p in glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True):
    try:
        for line in open(p, encoding='utf-8', errors='ignore'):   # 사전 필터 없음
            try: o = json.loads(line)
            except Exception: continue
            m = o.get('message')
            if not isinstance(m, dict): continue
            r = m.get('role') or o.get('type')
            if r not in ('user','assistant'): continue
            b = text_of(m)
            if kw in b: seen.add((r, b[:200]))
    except Exception: pass
print(len(seen))
PY
)
GOT=$("${JARVIS}/scripts/session-recall.sh" "$KW" -n 1 2>/dev/null \
      | head -1 | grep -o '대화 [0-9]*건' | grep -o '[0-9]*')
if [[ -n "$GOT" && "$GOT" -eq "$TRUTH" ]]; then
  ok "순진한 전수 파싱 ${TRUTH}건 == 최적화 검색 ${GOT}건 (거짓 음성 0)"
else
  ng "결과 불일치 — 전수 ${TRUTH}건 vs 최적화 ${GOT:-0}건 (사전 필터가 삼킴)"
fi

# 존재하지 않는 키워드 → 0건이어야 하고 죽으면 안 된다
if "${JARVIS}/scripts/session-recall.sh" "존재하지않는키워드XYZ123" >/dev/null 2>&1; then
  ok "무매칭 키워드에도 정상 종료"
else
  ng "무매칭 키워드에서 비정상 종료"
fi

head2 "① 날짜 필터 — 접두사 길이별 경계 파싱"
for d in 2026 2026-08 2026-08-04; do
  OUT=$("${JARVIS}/scripts/session-recall.sh" "$KW" -d "$d" -n 1 2>&1 | head -1)
  if [[ "$OUT" == *"$KW"* ]]; then ok "-d $d 파싱 정상"; else ng "-d $d 실패: $OUT"; fi
done

# 미래 날짜 → 전부 걸러져 0건. 여기서 결과가 나오면 mtime 필터가 안 먹는 것이다.
FUT=$("${JARVIS}/scripts/session-recall.sh" "$KW" -d 2099-01-01 2>&1 | head -1)
if [[ "$FUT" == *"찾지 못했"* ]]; then ok "미래 날짜 → 0건 (mtime 필터 실동작)"; else ng "mtime 필터 미동작: $FUT"; fi

# ─────────────────────────────────────────────────────────────
head2 "② 세션 저장 — 세션당 1파일 · 원문 보존"

mk_transcript() {  # $1=경로 $2=본문
  python3 - "$1" "$2" <<'PY'
import json,sys
p,body=sys.argv[1],sys.argv[2]
rows=[{"type":"user","message":{"role":"user","content":body}},
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"짧은 응답입니다. 열 글자 이상."}]}}]
open(p,'w').write('\n'.join(json.dumps(r,ensure_ascii=False) for r in rows))
PY
}

# 어제 사고와 같은 규모(19,803자)의 붙여넣기를 재현
LONG=$(python3 -c "print('\n'.join(f'통화 원문 {i}번째 줄입니다. 담당자 발언과 숫자가 여기 들어 있습니다.' for i in range(400)))")
echo -n "$LONG" > "$TMP/expected.txt"
LONGLEN=$(python3 -c "print(len(open('$TMP/expected.txt',encoding='utf-8').read()))")

mkdir -p "$TMP/proj"
mk_transcript "$TMP/proj/aaaa1111-2222-3333.jsonl" "$LONG"

run_save() {
  echo "{\"transcript_path\":\"$1\",\"cwd\":\"/tmp/${TESTPROJ}\"}" \
    | bash "${HOME}/.claude/hooks/stop-session-save.sh" >/dev/null 2>&1
}

for _ in 1 2 3 4 5; do run_save "$TMP/proj/aaaa1111-2222-3333.jsonl"; done
N=$(ls "${SESS}/${TESTPROJ}"/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$N" -eq 1 ]]; then ok "5회 저장 → 파일 1개 (종전이면 5개)"; else ng "파일이 ${N}개 생성됨 (기대 1개)"; fi

FNAME=$(basename "$(ls "${SESS}/${TESTPROJ}"/*.md 2>/dev/null | head -1)")
if [[ "$FNAME" == "$(date '+%Y-%m-%d')"* ]]; then
  ok "파일명 날짜 접두사 유지 — context-extractor 호환 ($FNAME)"
else
  ng "날짜 접두사 깨짐: $FNAME"
fi

# 다른 세션은 반드시 다른 파일이어야 한다 (덮어쓰기가 남의 세션을 지우면 대형 사고)
mk_transcript "$TMP/proj/bbbb9999-8888-7777.jsonl" "다른 세션의 짧은 대화입니다. 열 글자 이상 필요합니다."
run_save "$TMP/proj/bbbb9999-8888-7777.jsonl"
N2=$(ls "${SESS}/${TESTPROJ}"/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$N2" -eq 2 ]]; then ok "다른 세션 → 별도 파일 (덮어쓰기 충돌 없음)"; else ng "세션 분리 실패: ${N2}개"; fi

head2 "② 원문 복원 — 어제 사고의 직접 재현"
STASHED=$(grep -o "raw/[a-f0-9]*\.txt" "${SESS}/${TESTPROJ}/${FNAME}" 2>/dev/null | head -1 | cut -d/ -f2)
if [[ -n "$STASHED" && -f "${RAW}/${TESTPROJ}/${STASHED}" ]]; then
  if diff -q "$TMP/expected.txt" "${RAW}/${TESTPROJ}/${STASHED}" >/dev/null 2>&1; then
    ok "${LONGLEN}자 원문이 바이트 단위로 완전 복원됨"
  else
    ng "원문이 변형됨 (크기: $(wc -c < "${RAW}/${TESTPROJ}/${STASHED}"))"
  fi
else
  ng "raw 파일이 생성되지 않음 (링크='${STASHED:-없음}')"
fi

RAWN=$(ls "${RAW}/${TESTPROJ}"/*.txt 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RAWN" -eq 1 ]]; then ok "5회 저장에도 raw는 1개 (내용 해시 중복 제거)"; else ng "raw 중복 ${RAWN}개"; fi

# ─────────────────────────────────────────────────────────────
head2 "④ RAG — 오너 발화 전량 / 자비스 답변 2청크"
node --check "${JARVIS}/infra/scripts/claude-cli-rag-sync.mjs" 2>/dev/null \
  && ok "rag-sync 문법 정상" || ng "rag-sync 문법 오류"

# 코드에 문자열이 있는지가 아니라, 실제로 돌려서 산출물을 본다.
# 합성 세션을 ~/.claude/projects 에 심고 싱크를 돌린 뒤 청크 마커를 센다.
CAPDIR="${HOME}/.claude/projects/-pipeline-test-cap"
CAPOUT="${JARVIS}/runtime/inbox/claude-cli-$(date '+%Y-%m-%d')-captest0.md"
mkdir -p "$CAPDIR"
python3 - "$CAPDIR/captest01.jsonl" <<'PY'
import json, sys
# 고유 줄로 만든다 — 같은 줄 반복은 _stripRepeatedLines 가 지워서 테스트가 무효가 된다
u = '\n'.join(f'오너 원문 {i}번째 줄, 통화 녹취를 흉내낸 고유 문장입니다.' for i in range(300))
a = '\n'.join(f'자비스 답변 {i}번째 줄, 재구성을 흉내낸 고유 문장입니다.' for i in range(300))
rows = [
 {"type":"user","timestamp":"2026-08-04T05:00:00Z","message":{"role":"user","content":u}},
 {"type":"assistant","timestamp":"2026-08-04T05:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":a}]}},
]
open(sys.argv[1],'w').write('\n'.join(json.dumps(r,ensure_ascii=False) for r in rows))
PY
node "${JARVIS}/infra/scripts/claude-cli-rag-sync.mjs" >/dev/null 2>&1
UCH=$(grep -c '^## \*\*\[사용자\]\*\*' "$CAPOUT" 2>/dev/null || echo 0)
ACH=$(grep -c '^## \*\*\[Jarvis CLI\]\*\*' "$CAPOUT" 2>/dev/null || echo 0)
NOTE=$(grep -c "색인 제외" "$CAPOUT" 2>/dev/null || echo 0)
if [[ "$UCH" -eq 6 && "$ACH" -eq 2 && "$NOTE" -eq 1 ]]; then
  ok "실행 검증 — 오너 6청크 전량 / 자비스 2청크 + 제외 표기"
else
  ng "비대칭 미동작 (오너 ${UCH}청크 · 자비스 ${ACH}청크 · 표기 ${NOTE})"
fi
# 테스트 흔적 제거 (state 항목 포함)
rm -rf "$CAPDIR" "$CAPOUT"
python3 - <<'PY'
import json
p='runtime/state/cli-rag-sync.json'
try:
    d=json.load(open(p))
    d['processed']={k:v for k,v in d.get('processed',{}).items() if 'pipeline-test-cap' not in k}
    json.dump(d,open(p,'w'),ensure_ascii=False)
except Exception: pass
PY

# ─────────────────────────────────────────────────────────────
head2 "⑤ 주입 — 커리어 사실 우선 선별"
if [[ "$HAVE_FX" -eq 0 ]]; then
  sk "픽스처 없음 — 커리어 비중 검증 생략 (memory-pipeline.local.sh)"
  sk "픽스처 없음 — STATE 블록 검증 생략"
else
  # session_id 를 매번 새로 만든다 — 훅에 "동일 세션·30분 내 재주입 차단" 게이트가 있어
  # 고정 ID를 쓰면 두 번째 실행부터 정상 차단에 걸려 테스트가 거짓 실패한다.
  SID="pipetest$(date +%s)$$"
  INJ=$(echo "{\"prompt\":\"${FX_CAREER_PROMPT}\",\"session_id\":\"${SID}\"}" \
        | bash "${HOME}/.claude/hooks/context-state-inject.sh" 2>/dev/null)
  rm -f "${JARVIS}/runtime/state/csi-gate/${SID}" 2>/dev/null
  BLOCK=$(echo "$INJ" | sed -n '/^【② /,/^【③ /p')
  TOTAL=$(echo "$BLOCK" | grep -c "^- \[")
  CAREER=$(echo "$BLOCK" | grep -cE "$FX_CAREER_PATTERN")
  if [[ "$TOTAL" -gt 0 && "$CAREER" -ge $((TOTAL * 7 / 10)) ]]; then
    ok "주입 ${TOTAL}건 중 커리어 ${CAREER}건 (70% 이상)"
  else
    ng "커리어 비중 미달: ${CAREER}/${TOTAL}"
  fi

  if echo "$INJ" | grep -q "【① "; then ok "STATE 블록 정상 주입"; else ng "STATE 블록 누락"; fi
fi

# ─────────────────────────────────────────────────────────────
head2 "⑥ 원본 강제 주입 — 검색을 모델 재량에서 뺐는가"
RHOOK="${HOME}/.claude/hooks/context-recall-inject.sh"

# (a) 무관한 질문에 침묵하는가 — 오발하면 매 프롬프트가 오염된다
FP=0
for q in "오늘 날씨 어때" "이 함수 리팩터링해줘" "동남아 여행 추천좀" "파이썬 리스트 정렬 방법"; do
  L=$(echo "{\"prompt\":\"$q\",\"session_id\":\"t$RANDOM\"}" | timeout 15 bash "$RHOOK" 2>&1 | wc -c | tr -d ' ')
  [[ "$L" -gt 1 ]] && FP=$((FP+1))
done
if [[ "$FP" -eq 0 ]]; then ok "무관 질문 4종 전부 침묵 (오발 0)"; else ng "오발 ${FP}건"; fi

# (b) 원문 대조가 필요한 질문에 발화하는가 — 미발화가 곧 8/4 사고다
# (c) 핵심 — 그날 실패한 그 질문에 통화 원문이 실제로 딸려오는가
# 둘 다 오너의 실제 대화 내용을 질문으로 써야 성립한다 → 픽스처 필요
if [[ "$HAVE_FX" -eq 0 ]]; then
  sk "픽스처 없음 — 대조 필요 질문 발화 검증 생략"
  sk "픽스처 없음 — 핵심 원문 주입 검증 생략"
else
  FN=0
  for q in "${FX_RECALL_QUERIES[@]}"; do
    # 출력을 변수로 먼저 받는다. `... | grep -q` 로 바로 물리면 grep 이 매치 즉시 종료하며
    # 상류에 SIGPIPE(141)를 보내고, pipefail 때문에 파이프라인이 실패로 잡혀 거짓 실패가 난다.
    RO=$(echo "{\"prompt\":\"$q\",\"session_id\":\"t$RANDOM\"}" | timeout 15 bash "$RHOOK" 2>&1)
    case "$RO" in *"검색어:"*) ;; *) FN=$((FN+1)) ;; esac
  done
  if [[ "$FN" -eq 0 ]]; then
    ok "대조 필요 질문 ${#FX_RECALL_QUERIES[@]}종 전부 발화 (미발화 0)"
  else
    ng "미발화 ${FN}건"
  fi

  CORE=$(echo "{\"prompt\":\"${FX_CORE_QUERY}\",\"session_id\":\"t$RANDOM\"}" \
         | timeout 15 bash "$RHOOK" 2>&1)
  if echo "$CORE" | grep -q "$FX_CORE_EXPECT" && echo "$CORE" | grep -q "\[오너\]"; then
    ok "과거 실패 질문 → 원문이 오너 발화로 주입됨"
  else
    ng "핵심 원문 미주입 — 이 훅의 존재 이유가 재현되지 않음"
  fi
fi

# (d) 잡음 키워드 방지 — 2글자 토큰의 공백 삽입 오매칭
NOISE=$(echo "{\"prompt\":\"어제 통화에서 복지포인트 얘기 뭐였지\",\"session_id\":\"t$RANDOM\"}" \
        | timeout 15 bash "$RHOOK" 2>&1 | grep -o "검색어: [^·]*" | head -1)
if [[ "$NOISE" != *"어 제"* ]]; then ok "2글자 오매칭 없음 (${NOISE:-검색어없음})"; else ng "잡음 키워드: $NOISE"; fi

# ─────────────────────────────────────────────────────────────
echo
if [[ "$SKIP" -gt 0 ]]; then
  echo "════ 결과: 통과 ${PASS} · 실패 ${FAIL} · 생략 ${SKIP} ════"
  echo "  ℹ️  생략분은 로컬 픽스처가 있어야 검증된다."
  echo "     cp scripts/fixtures/memory-pipeline.example.sh \\"
  echo "        scripts/fixtures/memory-pipeline.local.sh"
else
  echo "════ 결과: 통과 ${PASS} · 실패 ${FAIL} ════"
fi
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
