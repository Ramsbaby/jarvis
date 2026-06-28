#!/usr/bin/env bash
set -euo pipefail

# preply-student.sh — 보람님(Preply 한국어 강사) 학생별 맞춤 교재 작업 헬퍼.
# 목적: 매번 반복되던 통증을 구조로 차단한다.
#   - "미쉘 파일 다시 보내줘" → 어느 게 최신인지 헷갈림        → latest
#   - 신규 학생 교재를 100KB 인라인 재생성하다 API 오류로 파일 손상 → new (골드스탠다드 복사 후 수정)
#   - 캐서린처럼 퀴즈가 유실됐는데 모르고 학생에게 전송          → verify
#   - 엉뚱한 채널(#jarvis-boram)로 업로드                       → send (채널 고정)
#
# 사용:
#   preply-student.sh list                      # 학생 + 최신 파일 목록
#   preply-student.sh latest <학생>             # 학생의 최신 교재 파일 경로
#   preply-student.sh new <학생> [파일명]        # 골드스탠다드 복사 → 새 작업 파일
#   preply-student.sh verify <파일>             # 퀴즈 유실·정답 노출·타학생 잔존 검사
#   preply-student.sh pdf <파일> [추가파일...]   # 학생 전송용 PDF 변환
#   preply-student.sh send <메시지> <파일...>    # jarvis-preply-tutor 채널에 첨부 업로드

JARVIS="${HOME}/jarvis"
REGISTRY="${JARVIS}/runtime/config/preply-students.json"
MATERIAL_DIR="${PREPLY_MATERIAL_DIR:-${HOME}/jarvis/runtime/preply-materials}"
DISCORD_DIR="${JARVIS}/infra/discord"
PDF_SCRIPT="${JARVIS}/infra/scripts/preply-html2pdf.mjs"
UPLOAD_SCRIPT="${JARVIS}/infra/scripts/preply-upload.mjs"

err() { echo "❌ $*" >&2; exit 1; }
[ -f "$REGISTRY" ] || err "레지스트리 없음: $REGISTRY"

# 레지스트리에서 한 학생의 필드 읽기 (python3)
reg_field() { # <name> <field>
  python3 - "$REGISTRY" "$1" "$2" <<'PY'
import json,sys
reg=json.load(open(sys.argv[1])); name=sys.argv[2]; field=sys.argv[3]
for s in reg["students"]:
    names=[s.get("name_ko"),s.get("name_en"),*s.get("alt_names",[])]
    if name in [n for n in names if n]:
        v=s.get(field); print(v if v is not None else ""); break
PY
}

gold_standard() {
  python3 - "$REGISTRY" <<'PY'
import json,sys,os
reg=json.load(open(sys.argv[1]))
p=reg["_meta"]["gold_standard_file"].replace("~",os.path.expanduser("~"))
print(p)
PY
}

# 학생의 모든 한글/영문/별칭 이름을 공백구분으로
all_names() { # <name>
  python3 - "$REGISTRY" "$1" <<'PY'
import json,sys
reg=json.load(open(sys.argv[1])); name=sys.argv[2]
for s in reg["students"]:
    names=[n for n in [s.get("name_ko"),s.get("name_en"),*s.get("alt_names",[])] if n]
    if name in names: print(" ".join(names)); break
PY
}

# 교재 폴더에서 학생 한글명이 들어간 최신 html
resolve_latest() { # <korean-name>
  local kn="$1"
  ls -t "$MATERIAL_DIR"/*"$kn"*.html 2>/dev/null | head -1 || true
}

cmd_list() {
  echo "📚 보람님 학생 교재 현황"
  echo "─────────────────────────────"
  python3 - "$REGISTRY" "$MATERIAL_DIR" <<'PY'
import json,sys,glob,os
reg=json.load(open(sys.argv[1])); desk=sys.argv[2]
gs=reg["_meta"]["gold_standard_file"].replace("~",os.path.expanduser("~"))
for s in reg["students"]:
    kn=s["name_ko"]; en=s.get("name_en","")
    files=sorted(glob.glob(f"{desk}/*{kn}*.html"), key=os.path.getmtime, reverse=True)
    latest=os.path.basename(files[0]) if files else "(파일 없음)"
    star=" ⭐골드" if s.get("is_gold_standard") else ""
    flag={"수리필요":" 🔧","미착수":" ⏳"}.get(s.get("status",""),"")
    print(f"- {kn} ({en}){star}{flag} · {s.get('status','?')}")
    print(f"    테마: {s.get('theme','미확인')} / 유닛 {s.get('units','?')}")
    print(f"    최신: {latest}")
PY
}

cmd_latest() {
  local name="${1:-}"; [ -n "$name" ] || err "학생 이름 필요: preply-student.sh latest <학생>"
  local kn; kn="$(reg_field "$name" name_ko)"; kn="${kn:-$name}"
  local f; f="$(resolve_latest "$kn")"
  [ -n "$f" ] || err "$kn 의 교재 파일을 교재 폴더에서 찾지 못함"
  echo "$f"
}

cmd_new() {
  local name="${1:-}"; [ -n "$name" ] || err "학생 이름 필요: preply-student.sh new <학생> [파일명]"
  local kn; kn="$(reg_field "$name" name_ko)"; kn="${kn:-$name}"
  local units; units="$(reg_field "$name" units)"; units="${units:-1-4}"
  local fname="${2:-한국어수업_${kn}_Unit${units}.html}"
  local dest="$MATERIAL_DIR/$fname"
  local gs; gs="$(gold_standard)"
  [ -f "$gs" ] || err "골드스탠다드 파일 없음: $gs"
  [ -e "$dest" ] && err "이미 존재함: $dest (덮어쓰지 않음 — 다른 이름 지정)"
  cp "$gs" "$dest"
  echo "✅ 골드스탠다드 복사 완료 → $dest"
  echo "   원본: $(basename "$gs")"
  echo "   ⚠️ 이제 인라인 재생성(100KB 통째 출력) 금지. 이 파일을 디스크에서 섹션별로 수정하세요."
  echo "   재구성 후: preply-student.sh verify \"$dest\""
}

cmd_verify() {
  local f="${1:-}"; [ -n "$f" ] || err "파일 필요: preply-student.sh verify <파일>"
  f="${f/#\~/$HOME}"
  [ -f "$f" ] || err "파일 없음: $f"
  echo "🔍 교재 검증: $(basename "$f")"
  echo "─────────────────────────────"
  local fail=0 warn=0

  # 유닛 수 파싱 (파일명 Unit{start}-{end} → 유닛 수). 실패 시 4 기본.
  local units_n=4 _ur
  _ur=$(basename "$f" | sed -nE 's/.*Unit([0-9]+)-([0-9]+).*/\1 \2/p')
  if [ -n "$_ur" ]; then
    local _s="${_ur% *}" _e="${_ur#* }"
    units_n=$(( _e - _s + 1 )); [ "$units_n" -ge 1 ] || units_n=4
  fi

  # 교재 유형 감지 (2026-06-28): 가사줄(lyric-line)이 다수면 노래 가사 기반 교재.
  # 노래 교재는 퀴즈/compare-note 대신 가사줄+숨은뜻(meaning-box/context-box)이 핵심 학습 요소.
  # 케이리(WOODZ Busted) 교재가 일반 규칙으로 오탐 FAIL→전송 차단되던 문제 해소.
  local is_song=0 lyric_n
  lyric_n=$( { grep -o 'class="lyric-line' "$f" || true; } | wc -l | tr -d ' ')
  [ "$lyric_n" -ge 5 ] && { is_song=1; echo "🎵 노래 가사 교재 감지 (가사줄 ${lyric_n}개) — 퀴즈 대신 가사·숨은뜻 기준 검증"; }

  # quiz-opt/quiz-q 는 class 정확 매칭으로 센다 (CSS 규칙·quiz-options 등 오탐 제거).
  # pipefail 환경에서 grep 무매칭(exit 1)이 스크립트를 죽이지 않도록 { ... || true; } 가드.
  local quizopt ansreveal quizq
  quizopt=$( { grep -o 'class="quiz-opt"' "$f" || true; } | wc -l | tr -d ' ')
  quizq=$(   { grep -o 'class="quiz-q"'   "$f" || true; } | wc -l | tr -d ' ')
  ansreveal=$(grep -co 'ans-reveal' "$f" || true)
  echo "퀴즈 보기(quiz-opt): $quizopt · 문항(quiz-q): $quizq · 정답클릭공개(ans-reveal): $ansreveal"
  if [ "$quizopt" -eq 0 ]; then
    if [ "$is_song" -eq 1 ]; then
      local mbox cbox
      mbox=$( { grep -o 'class="meaning-box"' "$f" || true; } | wc -l | tr -d ' ')
      cbox=$( { grep -o 'class="context-box"' "$f" || true; } | wc -l | tr -d ' ')
      echo "  🎵 노래 교재 — 퀴즈 대신 가사줄 ${lyric_n}개 · 숨은뜻(meaning-box ${mbox}/context-box ${cbox})"
      if [ "$lyric_n" -lt 5 ]; then
        echo "  ❌ FAIL: 노래 교재인데 가사줄 ${lyric_n}개 — 가사 구조 유실 의심"
        fail=$((fail+1))
      fi
    else
      echo "  ❌ FAIL: 퀴즈 보기(class=\"quiz-opt\") 0개 — 퀴즈 통째 유실 (캐서린 패턴: API 오류로 누락)"
      fail=$((fail+1))
    fi
  elif [ "$ansreveal" -eq 0 ]; then
    echo "  ❌ FAIL: 퀴즈는 있는데 정답공개(ans-reveal) 0개 — 정답 메커니즘 유실"
    fail=$((fail+1))
  elif [ "$quizopt" -lt $((units_n * 20)) ]; then
    echo "  ⚠️ WARN: 퀴즈 보기 ${quizopt}개 — ${units_n}유닛 교재 기준 최소 $((units_n * 20))개 권장 (유실 의심)"
    warn=$((warn+1))
  fi

  # 정답 정적 노출 검사 (PDF로 뽑아도 보이면 안 됨). ✓ 마커 + 정답 텍스트 직접 노출 모두.
  local exposed exposed2
  exposed=$( { grep -oE '<li[^>]*>[^<]*✓' "$f" || true; } | wc -l | tr -d ' ')
  exposed2=$( { grep -oE '<strong>[^<]*(정답|[Aa]nswer)|\(정답\)|（정답|정답[:：]' "$f" || true; } | wc -l | tr -d ' ')
  if [ "$exposed" -gt 0 ] || [ "$exposed2" -gt 0 ]; then
    echo "  ❌ FAIL: 정답 정적 노출 — 옵션 내 ✓ ${exposed}개 / 정답 텍스트(strong·괄호·정답:) ${exposed2}개 (PDF에서 노출됨)"
    fail=$((fail+1))
  else
    echo "정답 정적 노출(✓·정답텍스트): 0 ✅"
  fi

  # 인쇄 안전 CSS
  if grep -q 'break-inside' "$f"; then
    echo "인쇄 안전 CSS(break-inside): 있음 ✅"
  else
    echo "  ⚠️ WARN: break-inside 없음 — PDF에서 카드가 페이지 경계에서 잘릴 수 있음"
    warn=$((warn+1))
  fi

  # 동적 렌더링 감지 (규칙5: 정적 HTML). flip-card·JS 동적 렌더는 PDF에서 유닛 1개만 나옴.
  local dyn
  dyn=$( { grep -oE 'class="[^"]*flip-card|renderTab|\.innerHTML[[:space:]]*=|UNITS[[:space:]]*=[[:space:]]*\[|renderUnit' "$f" || true; } | wc -l | tr -d ' ')
  if [ "$dyn" -gt 0 ]; then
    echo "  ❌ FAIL: 동적 렌더링 구조 ${dyn}건(flip-card·JS 렌더) — PDF로 뽑으면 유닛 1개만 나옴 (규칙5 위반, 캐서린 패턴)"
    fail=$((fail+1))
  else
    echo "정적 HTML(동적 렌더 없음): ✅"
  fi

  # 문화비교(compare-note) 존재·영어 분량 — 보람님이 반복 지적한 항목.
  local cnote cnote_avgen
  cnote=$( { grep -o 'compare-note' "$f" || true; } | wc -l | tr -d ' ')
  if [ "$cnote" -eq 0 ]; then
    if [ "$is_song" -eq 1 ] && grep -qE '문화|[Cc]ulture|싱가|[Ss]ingapore' "$f"; then
      echo "문화 섹션(노래 교재 형식): 있음 ✅ (compare-note 외 구조)"
    else
      echo "  ❌ FAIL: 문화비교(compare-note) 0개 — 보람님 반복 지적 항목 (캐서린 패턴)"
      fail=$((fail+1))
    fi
  else
    cnote_avgen=$(python3 -c "
import re
html=open('$f').read()
notes=re.findall(r'class=\"[^\"]*compare-note[^\"]*\"[^>]*>(.*?)</', html, re.S)
ens=[len(re.findall(r'[A-Za-z]{3,}', re.sub('<[^>]+>',' ',n))) for n in notes]
print(round(sum(ens)/len(ens),1) if ens else 0)
" 2>/dev/null || echo 0)
    echo "문화비교(compare-note): ${cnote}개 · 블록당 영어 평균 ${cnote_avgen}단어"
    if [ "$cnote" -lt "$units_n" ]; then
      echo "  ⚠️ WARN: 문화비교 ${cnote}개 < 유닛 ${units_n}개 — 유닛마다 1개 이상 권장"
      warn=$((warn+1))
    fi
    if python3 -c "import sys; sys.exit(0 if float('$cnote_avgen') < 15 else 1)" 2>/dev/null; then
      echo "  ⚠️ WARN: 문화비교 영어 설명 부족 (블록당 평균 ${cnote_avgen}단어 < 15) — 영어 3~4문장으로 보강"
      warn=$((warn+1))
    fi
  fi

  # 타 학생/타 테마 잔존 검사 (복사 후 재구성 누락 탐지)
  # 대상 학생 본인의 모든 이름(한글·영문·별칭)은 제외 — 본인 이름은 잔존이 아님.
  local target_kn; target_kn="$(basename "$f" | sed -E 's/한국어수업_([^_]+)_.*/\1/')"
  local target_names; target_names=" $(all_names "$target_kn") $target_kn "
  local leaks=""
  while IFS= read -r other; do
    [ -z "$other" ] && continue
    case "$target_names" in *" $other "*) continue;; esac
    local cnt; cnt=$(grep -co "$other" "$f" || true)
    [ "$cnt" -gt 0 ] && leaks="$leaks $other($cnt)"
  done < <(python3 -c "
import json,os
reg=json.load(open('$REGISTRY'))
out=set()
for s in reg['students']:
    for n in [s.get('name_ko'),s.get('name_en'),*s.get('alt_names',[])]:
        if n: out.add(n)
print('\n'.join(out))
")
  # 골드스탠다드 테마(현진/SKZ 등) 잔존 — 대상이 미쉘이 아니면 누출
  if [ "$target_kn" != "미쉘" ]; then
    for kw in 현진 SKZ "Stray Kids" ATEEZ; do
      local c; c=$(grep -co "$kw" "$f" || true)
      [ "$c" -gt 0 ] && leaks="$leaks ${kw}($c)"
    done
  fi
  if [ -n "$leaks" ]; then
    echo "  ⚠️ WARN: 타 학생/타 테마 잔존 →$leaks  (복사 후 재구성 누락 의심)"
    warn=$((warn+1))
  else
    echo "타 학생/테마 잔존: 없음 ✅"
  fi

  # ── 보람님 영구 선호 규칙 (2026-06-27 사흘치 반복 지적 → 영구 게이트화) ──
  # 1) 기울어진 글씨(italic) — "단어 예문 누워있는 글씨 싫어. 다 똑바르게 바꿔"
  local italic_n
  italic_n=$( { grep -oiE 'font-style: ?italic' "$f" || true; } | wc -l | tr -d ' ')
  if [ "$italic_n" -gt 0 ]; then
    echo "  ❌ FAIL: 기울어진 글씨(italic) ${italic_n}곳 — 보람님 '누워있는 글씨 싫어'. font-style:normal 로 교체."
    fail=$((fail+1))
  else
    echo "기울어진 글씨(italic): 0 ✅"
  fi

  # 2) 노란 발광 hover — "어휘·표현 마우스 대면 노란 테두리 발광, 앞으로 모든 교재에 적용"
  local glow_n
  glow_n=$( { grep -oE 'rgba\(251,191,36|border-color:#FBBF24' "$f" || true; } | wc -l | tr -d ' ')
  if [ "$glow_n" -eq 0 ]; then
    echo "  ⚠️ WARN: 노란 발광 hover 없음 — 보람님 '모든 교재에 노란 테두리 발광' 반복 요청. 골드스탠다드에서 제대로 복사됐는지 확인."
    warn=$((warn+1))
  else
    echo "노란 발광 hover: 있음 ✅"
  fi

  # 3) 어두운 표지/배너 — "이런 어두운 분위기 싫다고!" (밝은 배경 강제, 이미지 fallback 제외)
  local dark_hit
  dark_hit=$(python3 -c "
import re
html=open('$f').read()
hits=0
for m in re.finditer(r'(\.cover|\.skz-banner|\.unit-banner-overlay|\.hero|header)[^{]*\{([^}]*)\}', html):
    body=m.group(2)
    if 'onerror' in body or '<img' in body: continue
    for hx in re.findall(r'#([0-9a-fA-F]{6})', body):
        r,g,b=int(hx[0:2],16),int(hx[2:4],16),int(hx[4:6],16)
        if (0.299*r+0.587*g+0.114*b) < 70: hits+=1
print(hits)
" 2>/dev/null || echo 0)
  if [ "${dark_hit:-0}" -gt 0 ]; then
    echo "  ⚠️ WARN: 어두운 표지/배너 배경 ${dark_hit}곳 — 보람님 '어두운 분위기 싫어'. 밝은 색으로 교체 권장."
    warn=$((warn+1))
  else
    echo "어두운 표지/배너: 없음 ✅"
  fi

  # 구조 요약
  local imgs body
  imgs=$(grep -co '<img' "$f" || true)
  body=$(python3 -c "import re;print(len(re.sub('<[^>]+>','',open('$f').read())))")
  echo "이미지: ${imgs}개 · 본문 글자수: $body"

  # ── 직전 버전 대비 섹션 소실 감지 (2026-06-28 신설) ──
  # 사고: 케이리 교재가 통째 재작성되며 가사 '숨은 뜻'(context-box 31개)이 0개로 소실됐는데
  # 단일파일 검사로는 못 잡았다. 같은 학생의 이전 verify 스냅샷(클래스 카운트)과 비교해,
  # 직전에 다수 있던 섹션이 사라지면 FAIL. send 게이트가 학생 전송을 자동 차단한다.
  local loss_out loss_fail loss_warn
  loss_out=$(python3 - "$f" <<'PYEOF'
import re, json, os, sys, time
f = sys.argv[1]
LEDGER = os.path.expanduser('~/jarvis/runtime/state/preply-verify-ledger.jsonl')
html = open(f).read()
classes = {}
for m in re.findall(r'class="([^"]+)"', html):
    for c in m.split():
        classes[c] = classes.get(c, 0) + 1
base = os.path.basename(f)
mk = re.search(r'한국어수업_([^_]+)_', base)
key = mk.group(1) if mk else re.sub(r'\.(html|bak.*)$', '', base).split('_')[0]
prev = None
if os.path.exists(LEDGER):
    for line in open(LEDGER):
        try: d = json.loads(line)
        except: continue
        if d.get('key') == key:
            prev = d  # 같은 학생의 가장 최근 스냅샷
fail = warn = 0
msgs = []
if prev:
    for c, n in prev.get('classes', {}).items():
        if n >= 5:
            cur = classes.get(c, 0)
            if cur == 0:
                msgs.append(f'FAIL|섹션 통째 소실: class="{c}" {n}개→0개 (직전 버전엔 있었음 — 재작성 중 유실)')
                fail += 1
            elif cur < n * 0.5:
                msgs.append(f'WARN|섹션 대폭 감소: class="{c}" {n}개→{cur}개')
                warn += 1
rec = {'ts': time.strftime('%Y-%m-%dT%H:%M:%S'), 'key': key, 'file': base, 'classes': classes}
with open(LEDGER, 'a') as w:
    w.write(json.dumps(rec, ensure_ascii=False) + '\n')
print(f'{fail} {warn}')
for m in msgs: print(m)
PYEOF
)
  read -r loss_fail loss_warn <<< "$(echo "$loss_out" | head -1)"
  if [ "${loss_fail:-0}" -gt 0 ] || [ "${loss_warn:-0}" -gt 0 ]; then
    echo "$loss_out" | tail -n +2 | while IFS='|' read -r lvl msg; do
      [ "$lvl" = "FAIL" ] && echo "  ❌ FAIL: $msg" || echo "  ⚠️ WARN: $msg"
    done
    fail=$((fail + ${loss_fail:-0}))
    warn=$((warn + ${loss_warn:-0}))
  else
    echo "직전 버전 대비 섹션 소실: 없음 ✅"
  fi

  echo "─────────────────────────────"
  if [ "$fail" -gt 0 ]; then
    echo "결과: ❌ FAIL ${fail}건 · WARN ${warn}건 — 전송 전 수정 필요"
    return 1
  elif [ "$warn" -gt 0 ]; then
    echo "결과: ⚠️ WARN ${warn}건 — 검토 권장 (유닛 수 적으면 정상일 수 있음)"
  else
    echo "결과: ✅ 통과"
  fi
}

cmd_pdf() {
  [ "$#" -ge 1 ] || err "파일 필요: preply-student.sh pdf <파일> [추가파일...]"
  [ -f "$PDF_SCRIPT" ] || err "PDF 변환기 없음: $PDF_SCRIPT"
  ( cd "$DISCORD_DIR" && node "$PDF_SCRIPT" "$@" )
}

cmd_send() {
  # --force: 검증 실패해도 강제 전송 (정말 필요할 때만)
  local force=0
  if [ "${1:-}" = "--force" ]; then force=1; shift; fi
  [ "$#" -ge 2 ] || err "사용법: preply-student.sh send [--force] \"<메시지>\" <파일1> [파일2 ...]"
  [ -f "$UPLOAD_SCRIPT" ] || err "업로더 없음: $UPLOAD_SCRIPT"
  # 전송 전 HTML 자동 검증 게이트 — 손상 파일이 학생에게 가는 것을 구조적으로 차단.
  if [ "$force" -eq 0 ]; then
    local arg _h
    for arg in "$@"; do
      case "$arg" in
        *.html)
          _h="${arg/#\~/$HOME}"
          [ -f "$_h" ] || continue
          if ! cmd_verify "$_h"; then
            echo "" >&2
            err "검증 실패 — 전송 차단. 위 FAIL 항목 수정 후 다시 보내세요. (강제 전송: send --force ...)"
          fi
          ;;
      esac
    done
  fi
  ( cd "$DISCORD_DIR" && node "$UPLOAD_SCRIPT" "$@" )
}

sub="${1:-}"; shift || true
case "$sub" in
  list)   cmd_list "$@" ;;
  latest) cmd_latest "$@" ;;
  new)    cmd_new "$@" ;;
  verify) cmd_verify "$@" ;;
  pdf)    cmd_pdf "$@" ;;
  send)   cmd_send "$@" ;;
  *) cat >&2 <<EOF
preply-student.sh — 보람님 학생별 교재 헬퍼
  list                      학생 + 최신 파일 목록
  latest <학생>             최신 교재 파일 경로 ("다시 보내줘")
  new <학생> [파일명]        골드스탠다드 복사 → 새 작업 파일 (인라인 재생성 금지)
  verify <파일>             퀴즈 유실·정답 노출·타학생 잔존 검사
  pdf <파일> [추가...]       학생 전송용 PDF 변환
  send "<메시지>" <파일...>  jarvis-preply-tutor 채널에 첨부 업로드
EOF
     exit 1 ;;
esac
