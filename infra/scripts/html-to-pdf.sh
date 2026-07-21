#!/usr/bin/env bash
# html-to-pdf.sh — HTML을 PDF로 변환한다.
#
# 왜 이 스크립트가 있는가 (2026-07-14 사고):
#   ① Chrome headless는 문서가 약 40페이지를 넘으면 "Printing failed"로 죽는다.
#      → 그때 매번 즉흥으로 분할 명령을 짜다가, 원인을 좀비 프로세스로 오진하고
#        `pkill -f "Google Chrome"`을 실행해 주인님이 다른 세션에서 쓰던 GUI Chrome을 전부 죽였다.
#   ② 그래서 (a) 격리 프로필로만 실행하고 (b) 분할·병합을 자동화해 재발 경로 자체를 없앤다.
#
# 사용법:
#   html-to-pdf.sh <input.html> <output.pdf> [분할경계_grep패턴...]
#   분할 경계를 주면 그 지점에서 나눠 뽑아 pdfunite로 합친다. (요소 중간이 잘리지 않는 지점을 줄 것)
#   경계를 안 주면 통째로 시도하고, 실패하면 어떻게 해야 하는지 안내한다.
#
# 예:
#   html-to-pdf.sh cram.html ~/Downloads/cram.pdf '<!-- ===== PART 4' '<!-- ===== PART 7'

set -euo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
IN="${1:?사용법: html-to-pdf.sh <input.html> <output.pdf> [분할패턴...]}"
OUT="${2:?출력 PDF 경로가 필요합니다}"
shift 2 || true
PATTERNS=("$@")

[[ -f "$IN" ]] || { echo "❌ 입력 파일 없음: $IN" >&2; exit 1; }
[[ -x "$CHROME" ]] || { echo "❌ Chrome을 찾을 수 없습니다: $CHROME" >&2; exit 1; }

TMP=$(mktemp -d "/tmp/html2pdf.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# 핵심 1: GUI Chrome과 완전히 분리된 프로필로 실행한다. 절대 pkill로 남의 Chrome을 건드리지 않는다.
# 핵심 2: headless Chrome은 PDF를 다 쓰고도 종료되지 않는 경우가 있다(격리 프로필일 때 특히).
#         그래서 timeout으로 감싸 상한을 두고, 성공 여부는 "PDF 파일이 생겼는가"로만 판정한다.
#         timeout이 죽이는 건 내가 방금 띄운 이 프로세스 하나뿐이다 — 다른 Chrome은 영향 없다.
RENDER_TIMEOUT="${RENDER_TIMEOUT:-90}"
PROFILE="$TMP/profile"   # 프로필은 1회만 만들어 재사용 (매번 새로 만들면 초기화가 느리다)

render() {  # render <html> <pdf>
    timeout "$RENDER_TIMEOUT" "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
        --user-data-dir="$PROFILE" \
        --print-to-pdf="$2" "file://$1" >/dev/null 2>&1 || true
    [[ -s "$2" ]]
}

pages() { python3 -c "import re,sys;print(len(re.findall(rb'/Type\s*/Page[^s]',open(sys.argv[1],'rb').read())))" "$1"; }

# --- 분할 경계가 없으면 통째로 시도 ---
if [[ ${#PATTERNS[@]} -eq 0 ]]; then
    if render "$IN" "$OUT"; then
        echo "✅ $OUT ($(pages "$OUT")p)"
        exit 0
    fi
    echo "❌ 인쇄 실패 — 문서가 커서(약 40p 초과) Chrome이 감당하지 못했을 가능성이 높습니다." >&2
    echo "   분할 경계를 인자로 주고 다시 실행하십시오. 예:" >&2
    echo "   html-to-pdf.sh \"$IN\" \"$OUT\" '<!-- ===== PART 4' '<!-- ===== PART 7'" >&2
    echo "   ⚠️ pkill로 Chrome을 죽이지 마십시오 — 원인이 아니고, 주인님의 다른 세션을 파괴합니다." >&2
    exit 1
fi

# --- 분할 렌더 ---
command -v pdfunite >/dev/null || { echo "❌ pdfunite 필요: brew install poppler" >&2; exit 1; }

# <head>~ 스타일 블록(공통 머리)을 몇 줄까지 쓸지: <body> 다음 줄까지
HEAD_END=$(grep -n '<body>' "$IN" | head -1 | cut -d: -f1)
[[ -n "$HEAD_END" ]] || { echo "❌ <body> 태그를 찾지 못했습니다" >&2; exit 1; }

# 경계 줄 번호 수집
BOUNDS=()
for p in "${PATTERNS[@]}"; do
    ln=$(grep -nF "$p" "$IN" | head -1 | cut -d: -f1 || true)
    [[ -n "$ln" ]] || { echo "❌ 분할 패턴을 찾지 못했습니다: $p" >&2; exit 1; }
    BOUNDS+=("$ln")
done

TOTAL=$(wc -l < "$IN")
PARTS=()
START=1
for i in "${!BOUNDS[@]}"; do
    END=$(( BOUNDS[i] - 1 ))
    f="$TMP/part$i.html"
    if [[ $START -eq 1 ]]; then
        head -n "$END" "$IN" > "$f"
    else
        head -n "$HEAD_END" "$IN" > "$f"
        sed -n "${START},${END}p" "$IN" >> "$f"
    fi
    printf '</body>\n</html>\n' >> "$f"
    PARTS+=("$f")
    START=${BOUNDS[i]}
done
# 마지막 조각 (원본의 닫는 태그를 그대로 씀)
f="$TMP/part${#BOUNDS[@]}.html"
head -n "$HEAD_END" "$IN" > "$f"
sed -n "${START},${TOTAL}p" "$IN" >> "$f"
PARTS+=("$f")

PDFS=()
for i in "${!PARTS[@]}"; do
    o="$TMP/part$i.pdf"
    if render "${PARTS[i]}" "$o"; then
        echo "  ✅ 조각 $((i+1))/${#PARTS[@]} ($(pages "$o")p)"
        PDFS+=("$o")
    else
        echo "  ❌ 조각 $((i+1)) 인쇄 실패 — 이 조각이 아직 너무 큽니다. 경계를 더 잘게 주십시오." >&2
        exit 1
    fi
done

pdfunite "${PDFS[@]}" "$OUT"
echo "✅ $OUT (총 $(pages "$OUT")p, ${#PDFS[@]}조각 병합)"
