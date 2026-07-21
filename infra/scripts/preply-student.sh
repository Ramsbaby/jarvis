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
warn() { echo "⚠️ $*" >&2; }
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

# [2026-07-05 가드] 사용 가능한 PDF 변환 스크립트 탐색
available_pdf_scripts() {
  local scripts=()
  local i=1
  # infra/scripts 에서 *html2pdf* 파일 찾기
  for script in "${JARVIS}"/infra/scripts/*html2pdf*; do
    [ -f "$script" ] || continue
    local name desc
    name="$(basename "$script")"
    # 첫 줄 주석에서 설명 추출 (있으면)
    if [[ "$name" == *.mjs ]] || [[ "$name" == *.js ]]; then
      desc=$(sed -n '3,5p' "$script" | grep -E '^\s*(//|/\*)' | head -1 | sed 's/^[[:space:]]*[/*]*[/]*[[:space:]]*//' | sed 's/\*\/$//')
    else
      desc=$(sed -n '2,3p' "$script" | grep '^#' | head -1 | sed 's/^#[[:space:]]*//')
    fi
    desc="${desc:-(설명 없음)}"
    scripts+=("$name|$desc|$script")
    ((i++))
  done

  if [ ${#scripts[@]} -eq 0 ]; then
    echo "❌ PDF 변환 스크립트를 찾을 수 없습니다: ${JARVIS}/infra/scripts/*html2pdf*" >&2
    return 1
  fi

  # 스크립트 목록 출력
  echo "🔧 사용 가능한 PDF 변환 스크립트:"
  local idx=1
  for entry in "${scripts[@]}"; do
    IFS='|' read -r name desc path <<<"$entry"
    echo "  $idx. $name — $desc"
    ((idx++))
  done
  echo ""

  # 선택된 스크립트 경로 반환 (첫 번째 또는 지정된 번호)
  local choice="${1:-1}"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#scripts[@]} ]; then
    echo "❌ 잘못된 선택: $choice (1-${#scripts[@]} 범위)" >&2
    return 1
  fi

  IFS='|' read -r _ _ path <<<"${scripts[$((choice-1))]}"
  echo "$path"
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

  # [2026-07-03] 신규 파일 생성 가드: 프로필이 완성되었는지 확인
  # 학생 프로필(level/goal/theme)이 미확인이면 복사 차단 → 프로필 먼저 입력하도록 강제
  local level; level="$(reg_field "$name" level)"; level="${level:-}"
  local goal; goal="$(reg_field "$name" goal)"; goal="${goal:-}"
  local theme; theme="$(reg_field "$name" theme)"; theme="${theme:-}"

  if [ -z "$level" ] || [ "$level" = "미확인" ] || [ "$level" = "None" ]; then
    err "❌ 신규 파일 생성 차단: $kn 의 프로필(level) 미확인. 먼저 프로필을 완성하세요.

    preply-student.sh upsert '$kn' '{\"level\": \"초급\"}'

    또는 Discord에서 보람님에게 확인 후 레지스트리에 입력하세요."
  fi

  if [ -z "$goal" ] || [ "$goal" = "미확인" ] || [ "$goal" = "None" ]; then
    err "❌ 신규 파일 생성 차단: $kn 의 프로필(goal) 미확인. 먼저 프로필을 완성하세요.

    preply-student.sh upsert '$kn' '{\"goal\": \"travel/culture/hobby\"}'

    또는 Discord에서 보람님에게 확인 후 레지스트리에 입력하세요."
  fi

  if [ -z "$theme" ] || [ "$theme" = "미확인" ] || [ "$theme" = "None" ]; then
    err "❌ 신규 파일 생성 차단: $kn 의 프로필(theme) 미확인. 먼저 프로필을 완성하세요.

    preply-student.sh upsert '$kn' '{\"theme\": \"K-pop/K-drama/business\"}'

    또는 Discord에서 보람님에게 확인 후 레지스트리에 입력하세요."
  fi

  # 프로필 완성 확인 완료 → 파일 복사
  cp "$gs" "$dest"
  echo "✅ 신규 파일 생성 완료 → $dest"
  echo "   프로필: 수준=$level / 목표=$goal / 테마=$theme"
  echo "   원본: $(basename "$gs")"
  echo "   ⚠️ 이제 인라인 재생성(100KB 통째 출력) 금지. 이 파일을 디스크에서 섹션별로 수정하세요."
  echo "   재구성 후: preply-student.sh verify \"$dest\""
  echo "   그리고: preply-profile-verify.sh check '$kn' \"$dest\""
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
  # 정답 공개 메커니즘: ans-reveal / answer-box / answer-reveal 어느 클래스든 인정 (2026-07-06 — 클래스 드리프트로 answer-box 교재가 오탐 FAIL나던 문제 해소).
  ansreveal=$( { grep -coE 'ans-reveal|answer-box|answer-reveal' "$f" || true; } | tr -d ' ')
  echo "퀴즈 보기(quiz-opt): $quizopt · 문항(quiz-q): $quizq · 정답공개(reveal/answer-box): $ansreveal"
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

  # ── 퀴즈 정답 정합성 검사 (2026-07-06 신설 — 보람님 6일 반복 불만 기계 차단) ──
  # 근본원인: 기존 검사는 ans-reveal·<strong>정답 마커만 봐서, 실제 교재가 쓰는
  #   answer-box(display:none로 숨김)·checkAnswer(정답키) 구조의 노출·오류를 통째로 놓쳤다.
  #   → 보람님이 "정답이 보인다/두개다/보기에 영어뜻이 있다"를 6일간 반복 지적(#48~#589).
  local quiz_out quiz_fail quiz_warn
  quiz_out=$(python3 - "$f" <<'PYEOF'
import re, sys
from collections import OrderedDict
html = open(sys.argv[1], encoding="utf-8").read()
fail = warn = 0; msgs = []
# 1) answer-box 상시노출 — display:none 규칙이 없으면 정답 텍스트가 화면·PDF에 그대로 보인다.
if 'answer-box' in html and not re.search(r'\.answer-box[^{]*\{[^}]*display\s*:\s*none', html):
    msgs.append('FAIL|정답 상시노출: answer-box에 display:none 없음 — 정답이 화면·PDF에 그대로 보임'); fail += 1
# 2) checkAnswer 정답키 ↔ 보기 data-val 정합성 (문항별 그룹핑)
opts = re.findall(r'<div class="quiz-opt"\s+data-val="([^"]*)"[^>]*onclick="checkAnswer\(this,\s*[\x27]([^\x27]*)[\x27]\s*,\s*[\x27]([^\x27]*)[\x27]\)"[^>]*>(.*?)</div>', html, re.S)
items = OrderedDict()
for val, key, iid, text in opts:
    t = re.sub('<[^>]+>', '', text).strip()
    items.setdefault(iid, {'keys': set(), 'opts': []})
    items[iid]['keys'].add(key); items[iid]['opts'].append((val, t))
for iid, d in items.items():
    vals = [v for v, _ in d['opts']]
    if len(d['keys']) > 1:
        msgs.append(f'FAIL|정답키 불일치(문항 {iid}): 보기마다 정답 지정이 다름'); fail += 1; continue
    key = next(iter(d['keys'])) if d['keys'] else None
    correct = [t for v, t in d['opts'] if v == key]
    if len(correct) == 0:
        msgs.append(f'FAIL|정답 불일치(문항 {iid}): 정답키 "{key}"에 맞는 보기 0개'); fail += 1
    elif len(correct) > 1:
        msgs.append(f'FAIL|정답 중복(문항 {iid}): 정답 보기 {len(correct)}개 — 보람님 "정답이 두개"'); fail += 1
    if len(set(vals)) < len(vals):
        msgs.append(f'FAIL|보기 data-val 중복(문항 {iid}): {vals}'); fail += 1
    # 2026-07-07 신설: 보기 텍스트 중복 (data-val은 다른데 텍스트가 같은 경우 — 말고 Unit2 Q2 사고).
    # data-val 검사(위)는 "키가 같은가"만 보고, 서로 다른 보기가 같은 문장인 경우는 못 잡는다.
    texts = [t for _, t in d['opts']]
    if len(set(texts)) < len(texts):
        dupes = sorted({t for t in texts if texts.count(t) > 1})
        msgs.append(f'FAIL|보기 텍스트 중복(문항 {iid}): {dupes} — 서로 다른 보기인데 문장이 같음'); fail += 1
    for v, t in d['opts']:
        if re.search(r'[A-Za-z]{3,}', t):
            msgs.append(f'WARN|보기에 영어 병기(문항 {iid}): "{t[:24]}" — 답 유추(보람님 "보기 영어뜻")'); warn += 1; break
print(f'{fail} {warn}')
for m in msgs: print(m)
PYEOF
)
  read -r quiz_fail quiz_warn <<< "$(echo "$quiz_out" | head -1)"
  if [ "${quiz_fail:-0}" -gt 0 ] || [ "${quiz_warn:-0}" -gt 0 ]; then
    echo "$quiz_out" | tail -n +2 | while IFS='|' read -r lvl msg; do
      [ "$lvl" = "FAIL" ] && echo "  ❌ FAIL: $msg" || echo "  ⚠️ WARN: $msg"
    done
    fail=$((fail + ${quiz_fail:-0})); warn=$((warn + ${quiz_warn:-0}))
  else
    echo "퀴즈 정답 정합성(노출·중복·영어병기): 0 ✅"
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
    # 2026-07-07 신설: 줄 단위 한영 병기 누락 검사 — 기존 "블록당 평균 15단어"는 집계라
    # 한 블록 안에서 특정 줄 몇 개가 통째로 번역 누락돼도 평균만 맞으면 통과했다(말고 Unit2, 7곳 누락 사고).
    # 휴리스틱: 블록을 li/p/br 단위 줄로 쪼개, 한글 3글자+ 있는데 영문 3글자+ 단어가 0개인 줄을 누락으로 본다.
    cnote_lines=$(python3 -c "
import re
html=open('$f').read()
notes=re.findall(r'class=\"[^\"]*compare-note[^\"]*\"[^>]*>(.*?)</div>', html, re.S)
missing=0
for n in notes:
    lines=re.split(r'<li[^>]*>|</li>|<br\s*/?>|<p[^>]*>|</p>', n)
    for line in lines:
        text=re.sub('<[^>]+>',' ',line).strip()
        if not text: continue
        has_kr=len(re.findall(r'[가-힣]', text)) >= 3
        has_en=len(re.findall(r'[A-Za-z]{3,}', text)) >= 1
        if has_kr and not has_en:
            missing+=1
print(missing)
" 2>/dev/null || echo 0)
    if [ "${cnote_lines:-0}" -gt 0 ]; then
      echo "  ⚠️ WARN: 문화비교 줄 단위 한영 병기 누락 ${cnote_lines}곳 — 블록 평균은 통과해도 개별 줄이 번역 누락일 수 있음(말고 Unit2 패턴)"
      warn=$((warn+1))
    else
      echo "문화비교 줄 단위 한영 병기: 누락 없음 ✅"
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

  # ── 학생 정식 이름 표기 검사 (2026-07-06 — 프로필오타 반복 불만 흡수) ──
  # 보람님이 "루스가 아니라 루즈/나오미가 아니라 야다이"를 반복 지적. 레지스트리 정식명이 교재에 없으면 오타 의심.
  local reg_ko
  reg_ko=$(python3 -c "
import json
reg=json.load(open('$REGISTRY'))
for s in reg['students']:
    names=[n for n in [s.get('name_ko'),s.get('name_en'),*s.get('alt_names',[])] if n]
    if '$target_kn' in names:
        print(s.get('name_ko','')); break
" 2>/dev/null || true)
  if [ -n "$reg_ko" ] && ! grep -qF "$reg_ko" "$f"; then
    echo "  ⚠️ WARN: 학생 정식 이름 '$reg_ko' 이 교재 본문에 없음 — 오타/다른 이름 의심 (보람님 '○가 아니라 △로 기록' 반복)"
    warn=$((warn+1))
  elif [ -n "$reg_ko" ]; then
    echo "학생 정식 이름 표기('$reg_ko'): 있음 ✅"
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
  # [2026-07-05 가드] PDF 생성 명시적 스크립트 선택 + 검증
  local script_choice="" script_path=""

  # 옵션 파싱: --script-choice=<번호>
  local files=()
  for arg in "$@"; do
    case "$arg" in
      --script-choice=*)
        script_choice="${arg#--script-choice=}"
        ;;
      *)
        files+=("$arg")
        ;;
    esac
  done

  [ "${#files[@]}" -ge 1 ] || err "파일 필요: preply-student.sh pdf [--script-choice=N] <파일> [추가파일...]"

  # 스크립트 선택
  if [ -z "$script_choice" ]; then
    # 대화형 선택 (사용자 입력 필요)
    if [ -t 0 ]; then  # stdin이 터미널이면
      available_pdf_scripts || err "스크립트 선택 실패"
      read -p "선택하세요 (기본값: 1): " script_choice
      script_choice="${script_choice:-1}"
    else
      # 비대화형 모드 (cron/배치) → 기본값 사용
      script_choice="1"
    fi
  fi

  # 선택 스크립트 경로 획득
  script_path=$(available_pdf_scripts "$script_choice" 2>&1 | tail -1) || \
    err "스크립트 선택 실패: --script-choice=$script_choice"

  echo "📋 선택됨: $(basename "$script_path")"
  echo ""

  # [2026-07-05] cl-33ab3e59820bd8c8 가드: PDF 변환 전 정답 영어 힌트 사전 검사
  local _eng_guard="${JARVIS}/infra/guards/answer-english-hint-guard.sh"
  if [ -f "$_eng_guard" ]; then
    local _pdf_fail=0
    for _pf in "${files[@]}"; do
      case "$_pf" in
        *.html)
          local _pfh="${_pf/#\~/$HOME}"
          [ -f "$_pfh" ] || continue
          if ! bash "$_eng_guard" "$_pfh"; then
            _pdf_fail=1
          fi
          ;;
      esac
    done
    if [ "$_pdf_fail" -eq 1 ]; then
      err "PDF 변환 차단 — 정답 선택지 영어 힌트 발견. 수정 후 다시 실행하세요."
    fi
  fi

  # PDF 변환 실행 + 결과 검증
  local _conv_out _conv_fail=0
  _conv_out=$( cd "$DISCORD_DIR" && node "$script_path" "${files[@]}" 2>&1 ) || _conv_fail=$?
  echo "$_conv_out"

  # 변환 실패 시 오류 발생 (Iron Law 6: 거짓 성공 보고 금지)
  if [ $_conv_fail -ne 0 ]; then
    err "PDF 변환 실패 (종료 코드: $_conv_fail). HTML 대체 업로드는 차단됩니다."
  fi

  # 생성된 PDF 파일 추적 기록 (cmd_send에서 검증용)
  local _pdf_manifest="${BOT_HOME}/.pdf-manifest"
  mkdir -p "$(dirname "$_pdf_manifest")"
  for _pf in "${files[@]}"; do
    case "$_pf" in
      *.html)
        local _pfh="${_pf/#\~/$HOME}"
        local _pdf_f="${_pfh%.*}.pdf"
        [ -f "$_pdf_f" ] && echo "$_pfh|$_pdf_f|$(date +%s)" >> "$_pdf_manifest"
        ;;
    esac
  done
}


cmd_send() {
  # --force: 검증 실패해도 강제 전송 (정말 필요할 때만)
  local force=0
  if [ "${1:-}" = "--force" ]; then force=1; shift; fi
  [ "$#" -ge 2 ] || err "사용법: preply-student.sh send [--force] \"<메시지>\" <파일1> [파일2 ...]"
  [ -f "$UPLOAD_SCRIPT" ] || err "업로더 없음: $UPLOAD_SCRIPT"

  # ── [2026-07-13] 생성 중단 감지 — --force로도 우회 불가한 최소 무결성 게이트 ──
  # 교재 생성(claude Write)이 API 오류/중단으로 끊기면 HTML이 닫는 태그 없이 잘린다(질리안 Unit2 미완성·
  # 캐서린 퀴즈 유실 패턴). </html> 종료 여부는 템플릿과 무관한 객관 신호라 오탐 0.
  # style 오탐 회피용 --force와 달리, '생성이 잘렸다'는 신호는 어떤 경우에도 전송하면 안 되므로 force 이전에 검사.
  local _cg_arg _cg_h
  for _cg_arg in "$@"; do
    case "$_cg_arg" in
      *.html)
        _cg_h="${_cg_arg/#\~/$HOME}"
        [ -f "$_cg_h" ] || continue
        if ! tail -c 600 "$_cg_h" | grep -qi "</html>"; then
          err "🚫 생성 중단 감지: $(basename "$_cg_h") 가 </html>로 끝나지 않습니다 — 교재 생성이 중간에 끊긴 것으로 보입니다(불완전 파일). 재생성 후 전송하세요. ⚠️ 이 검사는 --force로도 우회할 수 없습니다."
        fi
        ;;
    esac
  done

  # [2026-07-05 가드] HTML 대체 업로드 차단: HTML은 대응 PDF와 함께만 업로드 가능
  # Iron Law 6 준수: PDF 생성이 성공했는지 확인하고, 없으면 HTML 업로드 거절
  local _pdf_manifest="${BOT_HOME}/.pdf-manifest"
  if [ "$force" -eq 0 ]; then
    local arg _h _pdf_path
    for arg in "$@"; do
      case "$arg" in
        *.html)
          _h="${arg/#\~/$HOME}"
          [ -f "$_h" ] || continue

          # HTML을 보내려는데, 대응하는 PDF 생성 기록이 있는지 확인
          _pdf_path="${_h%.*}.pdf"
          local _pdf_found=0

          # 1. manifest 파일에서 확인 (최근 PDF 생성 기록)
          if [ -f "$_pdf_manifest" ] && grep -q "^${_h}|" "$_pdf_manifest"; then
            _pdf_found=1
          fi

          # 2. 또는 .pdf 파일이 .html 파일과 같은 시간대에 생성되었는지 확인
          if [ "$_pdf_found" -eq 0 ] && [ -f "$_pdf_path" ]; then
            local _html_mtime _pdf_mtime _time_diff
            _html_mtime=$(stat -f %m "$_h" 2>/dev/null || echo 0)
            _pdf_mtime=$(stat -f %m "$_pdf_path" 2>/dev/null || echo 0)
            _time_diff=$(((_html_mtime - _pdf_mtime) * 1))
            # HTML이 PDF보다 최근이 아니면 (±60초 허용) → PDF가 이미 있음
            if [ "$_time_diff" -le 60 ] && [ "$_time_diff" -ge -60 ]; then
              _pdf_found=1
            fi
          fi

          # 3. 아무 기록도 없으면 → HTML만 업로드하려는 시도 → 차단!
          if [ "$_pdf_found" -eq 0 ]; then
            echo "" >&2
            echo "🚫 HTML 대체 업로드 차단 (Iron Law 6 준수)" >&2
            err "❌ $(basename "$_h") 에 대한 유효한 PDF 변환 기록이 없습니다.

이유: PDF 생성이 성공하지 않았거나, 이전에 생성되었습니다.
       (데이터 손상/렌더링 실패 위험)

해결:
1. 먼저 PDF를 생성하세요:
   preply-student.sh pdf $(basename "$_h")

2. 생성 후에 다시 전송하세요:
   preply-student.sh send \"메시지\" $(basename "$_h") ${_pdf_path##*/}

3. 정말 필요하면 강제 전송 (위험):
   preply-student.sh send --force \"메시지\" $(basename "$_h")"
          fi
          ;;
      esac
    done
  fi

  # 전송 전 HTML 자동 검증 게이트 — 손상 파일이 학생에게 가는 것을 구조적으로 차단.
  if [ "$force" -eq 0 ]; then
    local arg _h _kn
    for arg in "$@"; do
      case "$arg" in
        *.html)
          _h="${arg/#\~/$HOME}"
          [ -f "$_h" ] || continue
          # [2026-07-06] 파일 형식 규칙 (파일전송 반복 불만 흡수: "요약본·숙제는 PDF로 올려")
          case "$(basename "$_h")" in
            *요약본*|*숙제*|*정답지*)
              warn "⚠️ '$(basename "$_h")'를 HTML로 전송 — 요약본·숙제·정답지는 PDF로 보내는 게 원칙입니다(보람님 반복 요청). PDF를 함께/대신 올리세요." ;;
          esac
          # [2026-07-11 cl-ab0cc1b121a99f4d] QA 검사: 필수 요소(단어 탭, 한영병기, 정답 노출) 확인
          local _qa_script="${JARVIS}/scripts/qa-materials.sh"
          if [ -f "$_qa_script" ]; then
            echo "🔍 QA 검사 (필수 요소: 단어 탭, 한영병기, 정답 노출)..."
            if bash "$_qa_script" "$_h" 2>/dev/null; then
              echo "📋 QA 검사 통과 ✅"
            else
              echo "" >&2
              err "QA 검사 FAIL — 필수 요소 미충족. 위 항목을 수정 후 전송하세요.

   필수 요소:
   - 단어 탭: word-card 요소 3개 이상
   - 한영병기: word-en 요소 80% 이상 적용
   - 정답 노출: 정답/답안지 파일 아님

   강제 전송: send --force ..."
            fi
          fi
          if ! cmd_verify "$_h"; then
            echo "" >&2
            err "검증 실패 — 전송 차단. 위 FAIL 항목 수정 후 다시 보내세요. (강제 전송: send --force ...)"
          fi
          # [2026-07-05] cl-33ab3e59820bd8c8 가드: 정답 선택지 영어 힌트 검사
          # 문법 문제 정답에 영어 번역이 노출되면 학생이 한국어를 판단하기 전에 답을 알게 됨.
          local _eng_guard="${JARVIS}/infra/guards/answer-english-hint-guard.sh"
          if [ -f "$_eng_guard" ]; then
            if ! bash "$_eng_guard" "$_h"; then
              echo "" >&2
              err "영어 힌트 가드 FAIL — 정답 선택지에 영어 번역 노출. 수정 후 전송하세요. (강제: send --force ...)"
            fi
          fi
          # [2026-07-06] 렌더 아이 게이트 — 소스 grep이 아닌 "실제 렌더 화면"으로 정답 노출·A4·글씨 판정.
          #   정답 클래스명이 answer-box/ans-reveal/answer-reveal로 제각각이라 소스 검사가 6일간 뚫린 것을,
          #   렌더 상태(클릭 전 화면에 정답이 보이는가)로 근본 차단한다. 새 구조가 나와도 화면에 보이면 걸린다.
          local _render="${JARVIS}/infra/scripts/preply-render-check.mjs" _rout _rc
          if [ -f "$_render" ]; then
            echo "👁️  렌더 아이 검사 (보람님이 볼 실제 화면)..."
            set +e; _rout=$(cd "$DISCORD_DIR" && node "$_render" "$_h" 2>/dev/null); _rc=$?; set -e
            if [ "$_rc" -eq 2 ]; then
              echo "$_rout" | python3 -c "import json,sys; d=json.load(sys.stdin); [print('  ❌ FAIL:',i['msg']) for i in d['issues'] if i['level']=='FAIL']" 2>/dev/null >&2 || true
              err "렌더 아이 FAIL — 화면에 정답이 보이거나 레이아웃 문제. 수정 후 전송하세요. (강제: send --force ...)"
            elif [ "$_rc" -eq 0 ]; then
              echo "$_rout" | python3 -c "import json,sys; d=json.load(sys.stdin); [print('  ⚠️ ',i['msg']) for i in d['issues'] if i['level']=='WARN']" 2>/dev/null || true
              echo "👁️  렌더 아이 통과 ✅"
            fi
            # _rc==1(렌더 자체 오류)은 비차단 — 가용성 우선(검사 실패가 전송을 막지 않음)
          fi
          # [2026-07-06] 렌더 아이 2층 — 스크린샷을 "보람 눈"(LLM 비전)으로 검토.
          #   1층(DOM 상태)이 못 잡는 주관적 품질(레이아웃·질문/정답 중복·전반 완성도)을 전송 전 포착.
          #   API 실패·rate limit·토큰 문제 시 비차단(1층+verify가 이미 방어) — verdict=FAIL일 때만 차단.
          local _vision="${JARVIS}/infra/scripts/preply-vision-check.mjs" _vout _vrc
          if [ -f "$_vision" ]; then
            echo "👁️‍🗨️  보람 눈 검토 (비전)..."
            set +e; _vout=$(cd "$DISCORD_DIR" && node "$_vision" "$_h" 2>/dev/null); _vrc=$?; set -e
            if [ "$_vrc" -eq 2 ]; then
              echo "$_vout" | python3 -c "import json,sys; d=json.load(sys.stdin); [print('  ❌ FAIL:',i['msg']) for i in d['issues'] if i.get('level')=='FAIL']" 2>/dev/null >&2 || true
              err "보람 눈(비전) 검토 FAIL — 위 문제 수정 후 전송하세요. (강제: send --force ...)"
            elif [ "$_vrc" -eq 0 ]; then
              echo "👁️‍🗨️  보람 눈 검토 통과 ✅"
            else
              echo "   (비전 검토 건너뜀 — rate limit/불가. 1층 렌더 검사로 방어됨)"
            fi
          fi
          # [2026-07-03] 프로필 검증 단계 추가 — 교재가 학생 프로필을 반영했는지 확인
          _kn="$(basename "$_h" | sed -E 's/한국어수업_([^_]+)_.*/\1/')"
          if [ -n "$_kn" ] && [ "$_kn" != "$(basename "$_h")" ]; then
            local profile_verify_script="${JARVIS}/infra/scripts/preply-profile-verify.sh"
            if [ -f "$profile_verify_script" ]; then
              echo "📋 프로필 반영 검증 중..."
              if ! bash "$profile_verify_script" check "$_kn" "$_h"; then
                echo "" >&2
                warn "⚠️ 교재가 학생 프로필을 충분히 반영하지 않을 수 있습니다."
                warn "   위 경고를 검토 후 필요시 강제 전송: send --force ..."
              fi
            fi
          fi
          ;;
      esac
    done
    # [2026-07-07 신설] 규칙128의 반대 방향 누락 검사: "교재 본체는 HTML(+PDF)"인데
    # 기존 게이트(위)는 "HTML만 보내는 것"만 막았지, "PDF만 보내고 HTML을 빠뜨리는 것"은
    # 안 잡았다(말고 Unit2 사고 — 교재본체 PDF만 전송 → 보람님 "왜 PDF만 보내" 재지적).
    local _arg2 _p _base _stem _sib_html_found=0 _pdf_body_seen=0
    for _arg2 in "$@"; do
      case "$_arg2" in
        *.pdf)
          _p="${_arg2/#\~/$HOME}"
          _base="$(basename "$_p")"
          case "$_base" in
            *요약본*|*숙제*|*정답지*) continue ;;  # 이 3종은 PDF가 원칙 — 대상 아님
          esac
          _pdf_body_seen=1
          _stem="${_p%.pdf}"
          for _arg3 in "$@"; do
            case "$_arg3" in
              *.html)
                [ "${_arg3/#\~/$HOME}" = "${_stem}.html" ] && _sib_html_found=1 ;;
            esac
          done
          ;;
      esac
    done
    if [ "$_pdf_body_seen" -eq 1 ] && [ "$_sib_html_found" -eq 0 ]; then
      warn "⚠️ 교재 본체(수업교재)를 PDF만 전송 — 규칙: '교재 본체는 HTML(+PDF)' 동시 배포가 원칙입니다(보람님 반복 지적). HTML도 같이 첨부하세요."
    fi
  fi
  ( cd "$DISCORD_DIR" && node "$UPLOAD_SCRIPT" "$@" )

  # [2026-06-28] 전송 성공 후 latest_file 자동 갱신 (행동 의존 없는 레지스트리 최신화).
  # 봇이 레지스트리 갱신을 잊어도 send가 자동으로 학생의 최신 교재 경로를 기록 → stale 방지.
  local _arg _hf _kn
  for _arg in "$@"; do
    case "$_arg" in
      *.html)
        _hf="${_arg/#\~/$HOME}"
        [ -f "$_hf" ] || continue
        _kn="$(basename "$_hf" | sed -E 's/한국어수업_([^_]+)_.*/\1/')"
        if [ -n "$_kn" ] && [ "$_kn" != "$(basename "$_hf")" ]; then
          python3 - "$REGISTRY" "$_kn" "$_hf" <<'PY' || true
import json, sys, os
reg_path, kn, fp = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    reg = json.load(open(reg_path))
except Exception:
    sys.exit(0)
short = fp.replace(os.path.expanduser('~'), '~')
for s in reg['students']:
    names = [n for n in [s.get('name_ko'), s.get('name_en'), *s.get('alt_names', [])] if n]
    if kn in names:
        s['latest_file'] = short
        json.dump(reg, open(reg_path, 'w'), ensure_ascii=False, indent=2)
        print(f'  📝 레지스트리 자동 갱신: {kn} 최신파일 → {os.path.basename(fp)}', file=sys.stderr)
        break
PY
        fi
        ;;
    esac
  done
}

# upsert <학생한글명> '<JSON필드>' — 멱등 등록/갱신. 봇이 새 학생 정보를 받으면 즉시 호출.
# 사고: 보람님이 케이리 정보를 줬는데 봇이 "저장"이라 말만 하고 레지스트리에 안 넣어 다음에 또 물음.
cmd_upsert() {
  local name="${1:-}"; [ -n "$name" ] || err "사용법: preply-student.sh upsert <학생명> '<JSON필드>'"
  local fields="${2:-}"; [ -n "$fields" ] || fields='{}'  # ${2:-{}} 는 bash가 오파싱(끝에 } 추가)하므로 분리
  python3 - "$REGISTRY" "$name" "$fields" <<'PY'
import json, sys
reg_path, name, fields_json = sys.argv[1], sys.argv[2], sys.argv[3]
reg = json.load(open(reg_path))
try:
    fields = json.loads(fields_json)
    if not isinstance(fields, dict): fields = {}
except Exception:
    fields = {}
found = None
for s in reg['students']:
    names = [n for n in [s.get('name_ko'), s.get('name_en'), *s.get('alt_names', [])] if n]
    if name in names:
        found = s; break
if found:
    for k, v in fields.items():
        if v is not None: found[k] = v
    action = '갱신'
else:
    new = {'name_ko': name, 'name_en': fields.get('name_en', ''), 'theme': '미확인',
           'interests': [], 'is_trial': False, 'needs_homework_pdf': False,
           'is_gold_standard': False, 'status': '수업진행중'}
    new.update(fields)
    reg['students'].append(new)
    action = '신규 등록'
json.dump(reg, open(reg_path, 'w'), ensure_ascii=False, indent=2)
print(f'✅ {name} {action} 완료 (총 {len(reg["students"])}명)')
PY
}

# [2026-07-07 신설] 학생 종료 — 기본은 아카이브(되돌릴 수 있음). "--permanent"면 진짜 삭제.
# 보람님(선생님)이 그 채널 안에서 학생 데이터에 대해 갖는 전권 — 재확인 없이 즉시 실행.
cmd_archive() {
  local name="${1:-}"; [ -n "$name" ] || err "사용법: preply-student.sh archive <학생명>"
  local archive_dir="${MATERIAL_DIR}/archive"
  mkdir -p "$archive_dir"
  python3 - "$REGISTRY" "$name" <<'PY'
import json, sys
reg_path, name = sys.argv[1], sys.argv[2]
reg = json.load(open(reg_path))
found = None
for s in reg['students']:
    names = [n for n in [s.get('name_ko'), s.get('name_en'), *s.get('alt_names', [])] if n]
    if name in names:
        found = s; break
if not found:
    print(f'❌ 학생 없음: {name}'); sys.exit(1)
found['status'] = '종료(아카이브)'
found['archived_at'] = __import__('time').strftime('%Y-%m-%dT%H:%M:%S')
json.dump(reg, open(reg_path, 'w'), ensure_ascii=False, indent=2)
print(f'✅ {name} 아카이브 완료 (레지스트리 status=종료, 파일은 이동 진행)')
PY
  # 해당 학생 파일들을 archive 폴더로 이동 (삭제 아님 — 되돌릴 수 있음)
  local moved=0
  shopt -s nullglob
  for f in "${MATERIAL_DIR}"/*"${name}"*; do
    [ -f "$f" ] || continue
    mv "$f" "$archive_dir/"
    moved=$((moved+1))
  done
  shopt -u nullglob
  echo "📦 파일 ${moved}개 → $archive_dir 로 이동 (필요하면 되돌릴 수 있음)"
}

cmd_delete() {
  local name="${1:-}"; [ -n "$name" ] || err "사용법: preply-student.sh delete <학생명> --permanent"
  local flag="${2:-}"
  if [ "$flag" != "--permanent" ]; then
    err "영구삭제는 명시적으로 --permanent 플래그가 필요합니다: preply-student.sh delete <학생명> --permanent
(되돌릴 수 있는 종료 처리만 원하면: preply-student.sh archive <학생명>)"
  fi
  python3 - "$REGISTRY" "$name" <<'PY'
import json, sys
reg_path, name = sys.argv[1], sys.argv[2]
reg = json.load(open(reg_path))
before = len(reg['students'])
reg['students'] = [s for s in reg['students']
                    if name not in [n for n in [s.get('name_ko'), s.get('name_en'), *s.get('alt_names', [])] if n]]
after = len(reg['students'])
if before == after:
    print(f'❌ 학생 없음: {name}'); sys.exit(1)
json.dump(reg, open(reg_path, 'w'), ensure_ascii=False, indent=2)
print(f'✅ {name} 레지스트리에서 영구 삭제 완료')
PY
  local removed=0
  shopt -s nullglob
  for f in "${MATERIAL_DIR}"/*"${name}"* "${MATERIAL_DIR}/archive"/*"${name}"*; do
    [ -f "$f" ] || continue
    rm -f "$f"
    removed=$((removed+1))
  done
  shopt -u nullglob
  echo "🗑️  파일 ${removed}개 영구 삭제 완료 (복구 불가)"
}

sub="${1:-}"; shift || true
case "$sub" in
  list)   cmd_list "$@" ;;
  latest) cmd_latest "$@" ;;
  new)    cmd_new "$@" ;;
  verify) cmd_verify "$@" ;;
  pdf)    cmd_pdf "$@" ;;
  send)   cmd_send "$@" ;;
  upsert) cmd_upsert "$@" ;;
  archive) cmd_archive "$@" ;;
  delete)  cmd_delete "$@" ;;
  *) cat >&2 <<EOF
preply-student.sh — 보람님 학생별 교재 헬퍼
  list                      학생 + 최신 파일 목록
  latest <학생>             최신 교재 파일 경로 ("다시 보내줘")
  new <학생> [파일명]        골드스탠다드 복사 → 새 작업 파일 (인라인 재생성 금지)
  verify <파일>             퀴즈 유실·정답 노출·타학생 잔존 검사
  pdf <파일> [추가...]       학생 전송용 PDF 변환
  send "<메시지>" <파일...>  jarvis-preply-tutor 채널에 첨부 업로드
  upsert <학생> '<JSON>'    학생 프로필 멱등 등록/갱신 (새 정보 받으면 즉시)
  archive <학생>            학생 종료 — 되돌릴 수 있음(레지스트리 status·파일 archive 폴더 이동)
  delete <학생> --permanent 학생 영구 삭제 — 복구 불가(레지스트리 제거·파일 rm)
EOF
     exit 1 ;;
esac
