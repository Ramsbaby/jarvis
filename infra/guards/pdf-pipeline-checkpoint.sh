#!/usr/bin/env bash
# pdf-pipeline-checkpoint.sh — HTML 검증 통과 ≠ PDF 성공. 두 체크포인트를 분리 기록·강제한다.
#
# 클러스터 ID: cl-8a2b1b50fcd5ba63 (7일 재발 14건)
# 대표 실수:
#   1) HTML 구조 검증만 돌리고 "모든 검증 통과" 선언 → PDF는 실제로 실패
#   2) PDF 생성 실패 후 구체 원인 진단 없이 추상적 재시도
#   3) 편집·렌더 미실시 상태에서 검증 결과를 추정으로 보고
#
# 설계:
#   - 각 산출물(HTML/PDF) 검증 결과를 콘텐츠 해시 키로 저널에 개별 기록한다.
#   - assert-both 는 저널에서 HTML PASS + PDF PASS 두 레코드가 다 있어야 exit 0.
#     → "모든 검증 통과" 선언을 코드가 강제하므로 추정 보고가 물리적으로 불가능.
#   - PDF 실패 시 diagnose 로 원인 카테고리 즉시 반환 (추상적 재시도 차단).
#
# 사용:
#   pdf-pipeline-checkpoint.sh html-checkpoint <file.html>          # HTML 검증 → 저널 기록
#   pdf-pipeline-checkpoint.sh pdf-checkpoint  <file.pdf>           # PDF 검증 → 저널 기록
#   pdf-pipeline-checkpoint.sh pipeline        <file.html>          # 위 둘 + 렌더까지 원샷
#   pdf-pipeline-checkpoint.sh assert-both     <file.html>          # 둘 다 PASS 저널 없으면 exit 1
#   pdf-pipeline-checkpoint.sh diagnose        <file.pdf|err.log>   # 실패 원인 카테고리 반환
#
# 기존 동작 파괴 금지: 기존 preply-html2pdf.mjs / artifact-quality-gate.mjs / preply-render-check.mjs
# 를 호출만 하고, 결과를 저널에 기록·강제하는 오버레이 계층으로만 동작한다.

set -euo pipefail

JARVIS_HOME="${HOME}/.jarvis"
STATE_DIR="${JARVIS_HOME}/runtime/state/pdf-pipeline"
JOURNAL="${STATE_DIR}/checkpoints.jsonl"
CLUSTER_ID="cl-8a2b1b50fcd5ba63"
INFRA="${HOME}/jarvis/infra"

mkdir -p "$STATE_DIR" 2>/dev/null || true

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
_hash() { # 파일이면 내용, 없으면 경로 문자열의 sha256 앞 16자
    local f="$1"
    if [[ -f "$f" ]] && command -v shasum &>/dev/null; then
        shasum -a 256 "$f" | awk '{print substr($1,1,16)}'
    elif command -v shasum &>/dev/null; then
        printf '%s' "$f" | shasum -a 256 | awk '{print substr($1,1,16)}'
    else
        printf '%s' "$f" | cksum | awk '{print $1}'
    fi
}
_record() { # _record <kind> <file> <status> <detail>
    local kind="$1" file="$2" status="$3" detail="${4:-}"
    printf '{"ts":"%s","cluster":"%s","kind":"%s","file":"%s","hash":"%s","status":"%s","detail":"%s"}\n' \
        "$(_ts)" "$CLUSTER_ID" "$kind" "$(_esc "$file")" "$(_hash "$file")" "$status" "$(_esc "$detail")" \
        >> "$JOURNAL"
}

# ── HTML 체크포인트 ─────────────────────────────────────────────
_html_checkpoint() {
    local html="$1"
    [[ -f "$html" ]] || { _record html "$html" FAIL "file_not_found"; echo "❌ HTML 없음: $html" >&2; return 1; }

    local ok=1 detail=""
    # 1) artifact-quality-gate (있으면)
    if [[ -f "$INFRA/lib/artifact-quality-gate.mjs" ]]; then
        if ! node "$INFRA/lib/artifact-quality-gate.mjs" "$html" >/dev/null 2>&1; then
            ok=0; detail="quality-gate-fail"
        fi
    fi
    # 2) preply-render-check (있고 preply 계열 이름이면)
    if [[ $ok -eq 1 && -f "$INFRA/scripts/preply-render-check.mjs" ]]; then
        if node "$INFRA/scripts/preply-render-check.mjs" "$html" >/dev/null 2>&1; then :; else
            local rc=$?
            [[ $rc -eq 2 ]] && { ok=0; detail="render-check-fail"; }
        fi
    fi
    if [[ $ok -eq 1 ]]; then
        _record html "$html" PASS "structure_ok"
        echo "✅ HTML 체크포인트 PASS: $(basename "$html")"
        return 0
    fi
    _record html "$html" FAIL "$detail"
    echo "❌ HTML 체크포인트 FAIL: $(basename "$html") ($detail)" >&2
    return 1
}

# ── PDF 체크포인트 ──────────────────────────────────────────────
_pdf_checkpoint() {
    local pdf="$1" min_pages="${2:-1}"
    if [[ ! -f "$pdf" ]]; then
        _record pdf "$pdf" FAIL "file_not_found"
        echo "❌ PDF 없음 — 생성 자체가 안 됨: $pdf" >&2
        return 1
    fi
    # 1) 크기 (렌더링 실패 시 대개 <10KB)
    local size; size=$(wc -c < "$pdf" | tr -d ' ')
    if [[ $size -lt 10240 ]]; then
        _record pdf "$pdf" FAIL "small_pdf:${size}B"
        echo "❌ PDF 크기 이상: ${size}B (<10KB) — 렌더링 실패 의심" >&2
        return 1
    fi
    # 2) 매직 넘버
    if ! head -c 4 "$pdf" | grep -q '^%PDF'; then
        _record pdf "$pdf" FAIL "bad_magic"
        echo "❌ PDF 손상: 매직 넘버 불일치" >&2
        return 1
    fi
    # 3) 페이지 수 (pdfinfo 있으면)
    local pages=0
    if command -v pdfinfo &>/dev/null; then
        pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/{print $2}')
        pages=${pages:-0}
        if [[ $pages -lt $min_pages ]]; then
            _record pdf "$pdf" FAIL "pages<${min_pages}:${pages}"
            echo "❌ PDF 페이지 부족: ${pages}p (기대≥${min_pages})" >&2
            return 1
        fi
    fi
    # 4) artifact-quality-gate PDF 검사 (있으면 — 클리핑 휴리스틱)
    if [[ -f "$INFRA/lib/artifact-quality-gate.mjs" ]]; then
        node "$INFRA/lib/artifact-quality-gate.mjs" "$pdf" >/dev/null 2>&1 || {
            _record pdf "$pdf" FAIL "quality-gate-fail"
            echo "⚠️  PDF 품질 게이트 실패 (클리핑/기타)" >&2
            return 1
        }
    fi
    _record pdf "$pdf" PASS "size=${size},pages=${pages}"
    echo "✅ PDF 체크포인트 PASS: $(basename "$pdf") (${size}B, ${pages}p)"
    return 0
}

# ── PDF 실패 원인 진단 ─────────────────────────────────────────
# 추상적 재시도 대신 카테고리 라벨을 즉시 반환한다.
_diagnose() {
    local arg="$1"
    local text=""
    if [[ -f "$arg" && "$arg" == *.pdf ]]; then
        local size; size=$(wc -c < "$arg" | tr -d ' ')
        [[ $size -eq 0 ]]     && { echo "EMPTY_PDF: 0바이트 — 렌더러 크래시(playwright/chrome). 로그·모듈 설치 확인."; return; }
        [[ $size -lt 10240 ]] && { echo "SMALL_PDF: ${size}B — 콘텐츠 미로드(외부 이미지/JS 대기 초과) 가능. waitForTimeout 상향 또는 이미지 로컬화."; return; }
        head -c 4 "$arg" | grep -q '^%PDF' || { echo "BAD_MAGIC: PDF 헤더 없음 — 렌더러 예외로 다른 파일이 쓰임. stderr 로그 필수."; return; }
        if command -v pdfinfo &>/dev/null; then
            local p; p=$(pdfinfo "$arg" 2>/dev/null | awk '/^Pages:/{print $2}')
            [[ ${p:-0} -eq 0 ]] && { echo "ZERO_PAGES: 페이지 0 — DOM 렌더 전 pdf() 호출. domcontentloaded 대기 실패."; return; }
            [[ ${p:-0} -gt 40 ]] && { echo "OVERSIZE: ${p}p — Chrome headless 40p 인쇄 한계. html-to-pdf.sh 분할경계 사용."; return; }
        fi
        echo "UNKNOWN_PDF_STATE: 파일은 유효해 보이나 게이트 실패 — quality-gate 상세 로그 확인."
        return
    fi
    # 파일이 로그면 텍스트 매칭
    [[ -f "$arg" ]] && text=$(cat "$arg") || text="$arg"
    case "$text" in
        *"playwright"*"MODULE_NOT_FOUND"*|*"Cannot find module 'playwright'"*)
            echo "MISSING_PLAYWRIGHT: infra/discord 에서 npm i playwright 필요." ;;
        *"Chromium distribution 'chrome' is not found"*|*"Executable doesn't exist"*)
            echo "MISSING_CHROME: Google Chrome 미설치 또는 playwright browsers install 필요." ;;
        *"Printing failed"*|*"Print preview failed"*)
            echo "PRINT_FAILED: 문서 과대(대개 40p+) — html-to-pdf.sh 분할 렌더 사용." ;;
        *"Timeout"*|*"timeout"*"exceeded"*)
            echo "RENDER_TIMEOUT: 이미지/네트워크 대기 초과 — waitUntil=domcontentloaded 및 외부 리소스 최소화." ;;
        *"ENOENT"*|*"no such file"*)
            echo "MISSING_INPUT: 입력 HTML 경로 오타 또는 이전 단계 미생성." ;;
        *"EACCES"*|*"permission denied"*)
            echo "PERMISSION: 출력 경로 권한 없음." ;;
        *)
            echo "UNCLASSIFIED: 아래 로그를 직접 확인. 재시도 전 원인 카테고리 확정 필수.
$text" ;;
    esac
}

# ── 둘 다 PASS 강제 ────────────────────────────────────────────
# HTML 파일 인자 하나로 짝 PDF(같은 경로 .pdf)의 저널을 함께 조회.
_assert_both() {
    local html="$1"
    local base="${html%.html}"; base="${base%.htm}"
    local pdf="${base}.pdf"
    [[ -f "$JOURNAL" ]] || { echo "❌ 저널 없음 — 체크포인트 미실행. 완료 선언 불가." >&2; return 1; }
    local h_hash p_hash html_pass=0 pdf_pass=0
    h_hash=$(_hash "$html"); p_hash=$(_hash "$pdf")
    grep -F "\"hash\":\"$h_hash\"" "$JOURNAL" 2>/dev/null | grep -F '"kind":"html"' | grep -q '"status":"PASS"' && html_pass=1 || true
    grep -F "\"hash\":\"$p_hash\"" "$JOURNAL" 2>/dev/null | grep -F '"kind":"pdf"'  | grep -q '"status":"PASS"' && pdf_pass=1 || true
    if [[ $html_pass -eq 1 && $pdf_pass -eq 1 ]]; then
        echo "✅ 두 체크포인트 모두 PASS — 완료 선언 허용 ($(basename "$html"))"
        return 0
    fi
    echo "❌ 완료 선언 차단: html_pass=$html_pass pdf_pass=$pdf_pass (cluster=$CLUSTER_ID)" >&2
    echo "   HTML 검증 통과만으로 '모든 검증 통과' 선언 금지. pipeline 서브커맨드로 재실행 요망." >&2
    return 1
}

# ── 원샷 파이프라인 ────────────────────────────────────────────
_pipeline() {
    local html="$1"
    local base="${html%.html}"; base="${base%.htm}"
    local pdf="${base}.pdf"
    _html_checkpoint "$html" || return 1
    # 실제 렌더 (기존 preply-html2pdf 재사용 — 파괴 금지)
    if [[ -f "$INFRA/scripts/preply-html2pdf.mjs" ]]; then
        node "$INFRA/scripts/preply-html2pdf.mjs" "$html" 2>&1 | tail -20
    else
        echo "❌ preply-html2pdf.mjs 부재 — PDF 생성 스크립트 확인." >&2
        return 1
    fi
    _pdf_checkpoint "$pdf" || {
        echo "── 원인 진단 ──" >&2
        _diagnose "$pdf" >&2
        return 1
    }
    _assert_both "$html"
}

# ── 셀프테스트 ─────────────────────────────────────────────────
_selftest() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    local html="$d/t.html" bad_pdf="$d/bad.pdf"
    printf '<!doctype html><html><body>t</body></html>\n' > "$html"
    printf 'NOT_A_PDF' > "$bad_pdf"
    # 손상 PDF는 반드시 FAIL
    if _pdf_checkpoint "$bad_pdf" 2>/dev/null; then echo "❌ 셀프테스트 실패: 손상 PDF가 PASS로 통과됨"; return 1; fi
    # 저널에 FAIL 기록됐어야 assert-both 도 차단해야 함
    if _assert_both "$html" 2>/dev/null; then echo "❌ 셀프테스트 실패: 미검증 상태에서 assert-both 통과"; return 1; fi
    # 진단 카테고리 확인
    local cat; cat=$(_diagnose "$bad_pdf")
    case "$cat" in
        SMALL_PDF*|BAD_MAGIC*) : ;;
        *) echo "❌ 셀프테스트 실패: diagnose 카테고리 이상 ($cat)"; return 1 ;;
    esac
    echo "✅ 셀프테스트 통과 (cluster=$CLUSTER_ID)"
    return 0
}

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        html-checkpoint) _html_checkpoint "$@" ;;
        pdf-checkpoint)  _pdf_checkpoint  "$@" ;;
        pipeline)        _pipeline        "$@" ;;
        assert-both)     _assert_both     "$@" ;;
        diagnose)        _diagnose        "$@" ;;
        selftest|test)   _selftest ;;
        *) cat >&2 <<EOF
사용법: $0 <subcommand> <args>
  html-checkpoint <file.html>   HTML 검증 → 저널 기록
  pdf-checkpoint  <file.pdf>    PDF 검증 → 저널 기록
  pipeline        <file.html>   HTML→렌더→PDF 원샷, 두 체크포인트 강제
  assert-both     <file.html>   둘 다 PASS 없으면 exit 1 (완료 선언 게이트)
  diagnose        <arg>         PDF/에러로그 실패 원인 카테고리 반환
  selftest                      가드 자체 회귀 검증
저널: $JOURNAL
EOF
           exit 2 ;;
    esac
}
main "$@"
