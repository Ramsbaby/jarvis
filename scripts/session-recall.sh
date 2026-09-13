#!/usr/bin/env bash
# session-recall.sh — Claude Code 원본 대화(.jsonl) 전문 검색
#
# 왜 필요한가 (2026-08-04 신설):
#   세션 요약 .md와 RAG 인덱스는 메시지를 2,000자에서 자른다. 통화 녹취·메일 원문처럼
#   긴 붙여넣기는 대부분이 그 경로에서 사라진다. 온전한 원문은 ~/.claude/projects/*.jsonl
#   에만 남는데 이를 검색하는 도구가 없어, 자비스가 "기록에 없다"고 오판한 사고가 있었다.
#   (처우협상 통화 19,803자 중 17,803자 소실 → 근거 없는 재구성 → 오답 3회)
#
# 사용법:
#   session-recall.sh <키워드...> [-n 결과수] [-C 문맥줄] [-d 날짜접두사] [--since 날짜] [--full] [--json]
#
# 예:
#   session-recall.sh 배포실패
#   session-recall.sh 타임아웃 -C 10
#   session-recall.sh 재색인 --full            # 매칭 메시지 전문 출력
#   session-recall.sh 롤백 -d 2026-08          # 8월 대화만
#
# 주의: 사용 예시에 실명·처우 용어를 쓰지 않는다. 이 저장소는 PUBLIC 이다(2026-09-13).

set -euo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

if [[ $# -eq 0 ]]; then usage 1; fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage 0; fi

LIMIT=20
CONTEXT=3
DATE_PREFIX=""
SINCE_DATE=""
FULL=0
JSON=0
MAXCHARS=0
KEYWORDS=()

# 비플래그 인자는 전부 키워드로 본다 (OR 검색). 훅이 여러 키워드를 한 번의 파일 순회로
# 훑을 수 있어야 한다 — 키워드마다 790MB를 다시 읽으면 훅 예산을 넘긴다.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) LIMIT="$2"; shift 2 ;;
    -C) CONTEXT="$2"; shift 2 ;;
    -d) DATE_PREFIX="$2"; shift 2 ;;
    --since) SINCE_DATE="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --json) JSON=1; shift ;;
    --max-chars) MAXCHARS="$2"; shift 2 ;;
    -*) echo "알 수 없는 옵션: $1" >&2; usage 1 ;;
    *) KEYWORDS+=("$1"); shift ;;
  esac
done

if [[ ${#KEYWORDS[@]} -eq 0 ]]; then usage 1; fi
KEYWORD=$(printf '%s\n' "${KEYWORDS[@]}" | paste -sd $'\x1f' -)

if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "원본 대화 디렉터리 없음: $PROJECTS_DIR" >&2
  exit 1
fi

export JR_KEYWORD="$KEYWORD" JR_LIMIT="$LIMIT" JR_CONTEXT="$CONTEXT" \
       JR_DATE="$DATE_PREFIX" JR_SINCE="$SINCE_DATE" JR_FULL="$FULL" JR_DIR="$PROJECTS_DIR" \
       JR_JSON="$JSON" JR_MAXCHARS="$MAXCHARS"

python3 <<'PYEOF'
import json, os, sys, glob

kws     = [k for k in os.environ['JR_KEYWORD'].split('\x1f') if k]
kw      = kws[0]
limit   = int(os.environ['JR_LIMIT'])
ctx     = int(os.environ['JR_CONTEXT'])
datepfx = os.environ['JR_DATE']
since   = os.environ.get('JR_SINCE', '')
full    = os.environ['JR_FULL'] == '1'
root    = os.environ['JR_DIR']
as_json = os.environ['JR_JSON'] == '1'
maxch   = int(os.environ['JR_MAXCHARS'])

def text_of(msg):
    """message.content(문자열 또는 블록 배열) → 평문"""
    c = msg.get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return ' '.join(b.get('text', '') for b in c
                        if isinstance(b, dict) and b.get('type') == 'text')
    return ''

kwbs = [k.encode('utf-8') for k in kws]

def any_hit(s):
    """키워드 중 하나라도 들어 있으면 True (OR 검색)"""
    return any(k in s for k in kws)

# [2026-08-04] 790MB·2,385파일 전수 스캔이 5.18초 걸려 2단 사전 필터를 넣는다.
#   1단 mtime: -d 를 주면 그 날짜 이전에 마지막으로 쓰인 파일은 열지도 않는다.
#   2단 바이트: 파일 전체를 바이트로 한 번에 읽어 키워드 부재를 먼저 판정한다.
#               대부분의 파일은 여기서 걸러져 줄 단위 순회 자체를 건너뛴다.
def _floor(d):
    try:
        from datetime import datetime as _dt
        pad = d + '-01-01'[len(d) - 4:] if len(d) < 10 else d
        return _dt.strptime(pad, '%Y-%m-%d').timestamp()
    except Exception:
        return 0.0

# -d 는 "그 접두사와 일치하는 기간"(2026-08 = 8월), --since 는 "그 날짜 이후 전부".
# 훅처럼 120일 창을 쓸 때 -d 에 full date 를 주면 하루만 검색된다 — 그래서 둘을 나눈다.
mtime_floor = max(_floor(datepfx) if datepfx else 0.0,
                  _floor(since) if since else 0.0)

paths = glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True)
scanned = skipped = 0

hits = []
for path in paths:
    try:
        if mtime_floor and os.path.getmtime(path) < mtime_floor:
            skipped += 1
            continue
        with open(path, 'rb') as bf:
            raw = bf.read()
        if not any(kb in raw for kb in kwbs):
            skipped += 1
            continue
        scanned += 1
        text_lines = raw.decode('utf-8', 'ignore').split('\n')
        del raw
        for line in text_lines:
                if not any_hit(line):      # 빠른 사전 필터
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                msg = obj.get('message')
                if not isinstance(msg, dict):
                    continue
                role = msg.get('role') or obj.get('type')
                if role not in ('user', 'assistant'):
                    continue
                body = text_of(msg)
                if not any_hit(body):
                    continue
                ts = obj.get('timestamp', '') or ''
                if datepfx and not ts.startswith(datepfx):
                    continue
                if since and ts and ts[:10] < since:
                    continue
                hits.append({'ts': ts, 'role': role, 'body': body,
                             'file': os.path.basename(path)})
    except Exception:
        continue

label = ' / '.join(kws)

if not hits:
    if not as_json:
        print(f'"{label}" — 원본 대화에서 찾지 못했습니다.')
    sys.exit(0)

# 중복 제거(같은 메시지가 여러 세션 파일에 재출현) 후 최신순
seen, uniq = set(), []
for h in sorted(hits, key=lambda x: x['ts'], reverse=True):
    key = (h['role'], h['body'][:200])
    if key in seen:
        continue
    seen.add(key)
    uniq.append(h)

def excerpt(h, width=300):
    """키워드가 실제로 등장한 줄 주변만 추려 반환"""
    lines = h['body'].split('\n')
    marks = [i for i, l in enumerate(lines) if any_hit(l)]
    out, shown = [], set()
    for m in marks[:5]:
        for i in range(max(0, m - ctx), min(len(lines), m + ctx + 1)):
            if i in shown:
                continue
            shown.add(i)
            out.append(('▶ ' if any_hit(lines[i]) else '  ') + lines[i][:width])
        out.append('   ⋯')
    return '\n'.join(out)

# ── 주입용 출력 (훅이 소비) ──────────────────────────────────────────────
# 오너 발화를 먼저 싣는다. 자비스 과거 답변이 근거로 둔갑하는 것이 2026-08-04 사고의 기전이다.
if as_json:
    budget = maxch if maxch > 0 else 10_000
    # 여러 키워드를 OR로 묶으면 흔한 단어(협상·연봉)가 희귀한 단어(7436)를 덮는다.
    # → 한 메시지에 몇 개의 서로 다른 키워드가 들어 있는지로 먼저 줄 세운다.
    #   둘 다 담긴 메시지가 곧 오너가 찾는 그 대목이다. 그다음 오너 발화 우선, 그다음 최신순.
    def score(h):
        return sum(1 for k in kws if k in h['body'])
    ordered = sorted(uniq, key=lambda h: (score(h), h['role'] == 'user', h['ts']), reverse=True)
    # 항목당 상한을 둔다. 긴 발췌 하나가 예산을 다 먹으면 나머지 근거가 통째로 잘린다
    # — 그게 바로 2,000자 컷과 같은 실패 모양이다.
    per_item = max(400, budget // 4)
    items, used = [], 0
    for h in ordered[:limit]:
        ex = excerpt(h, 200)
        if len(ex) > per_item:
            ex = ex[:per_item] + '\n   …(발췌 잘림 · 전문은 session-recall.sh --full)'
        if used + len(ex) > budget:
            break
        used += len(ex)
        items.append({'ts': h['ts'][:16].replace('T', ' '),
                      'role': 'owner' if h['role'] == 'user' else 'jarvis',
                      'chars': len(h['body']), 'excerpt': ex})
    print(json.dumps({'keywords': kws, 'total': len(uniq), 'items': items},
                     ensure_ascii=False))
    sys.exit(0)

print(f'"{label}" — 원본 대화 {len(uniq)}건 (중복 제거 후) · 최신순 {min(limit, len(uniq))}건 표시')
print(f'   (파일 {len(paths)}개 중 {scanned}개만 열어봄 · {skipped}개 사전 필터로 건너뜀)\n')

for h in uniq[:limit]:
    who = '주인님' if h['role'] == 'user' else '자비스'
    when = h['ts'][:16].replace('T', ' ') or '시각미상'
    print(f'━━ {when} · {who} · {h["file"][:8]} · {len(h["body"]):,}자')
    print(h['body'] if full else excerpt(h))
    print()

if len(uniq) > limit:
    print(f'… {len(uniq) - limit}건 더 있습니다. -n 으로 늘리십시오.')
PYEOF
