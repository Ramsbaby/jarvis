#!/usr/bin/env bash
# pdf-pipeline-ci-check.sh — CI/pre-flight: HTML 통과 ≠ PDF 성공을 배치 강제.
#
# 클러스터 ID: cl-8a2b1b50fcd5ba63
# 존재 이유:
#   pdf-pipeline-checkpoint.sh 는 파일 하나씩 강제하는 원자 도구.
#   이 스크립트는 산출물 폴더 전체를 훑어 HTML/PDF 짝을 CI 관점에서 감사한다.
#   목적은 하나: "HTML 검증 통과" 만 보고 완료 선언한 사례를 배치에서 실측 탐지.
#
# 동작:
#   1) 대상 폴더의 *.html 을 나열 (기본: ~/Desktop 및 Preply 산출물 캐시)
#   2) 각 HTML 마다 짝 PDF(<name>.pdf) 존재 여부·유효성 확인
#   3) pdf-pipeline-checkpoint.sh 의 pdf-checkpoint 를 호출해 저널에 실측 기록
#   4) 실패 파일 목록을 stderr 로 뽑고 exit 1
#   5) --json 옵션이면 결과를 JSON 배열로 stdout 출력 (CI 파서 친화)
#
# 사용:
#   pdf-pipeline-ci-check.sh                        # 기본 폴더 스캔
#   pdf-pipeline-ci-check.sh --dir <PATH>           # 특정 폴더 스캔
#   pdf-pipeline-ci-check.sh --files a.html b.html  # 명시 파일 스캔
#   pdf-pipeline-ci-check.sh --since 1d --dir DIR   # 24h 내 수정된 HTML만
#   pdf-pipeline-ci-check.sh --json                 # 결과 JSON 출력
#   pdf-pipeline-ci-check.sh --selftest             # 자체 회귀 테스트
#
# 기존 동작 파괴 금지: 파일을 수정하지 않고 관찰·기록만 한다.

set -uo pipefail

JARVIS_HOME="${HOME}/.jarvis"
INFRA="${HOME}/jarvis/infra"
GUARD="${INFRA}/guards/pdf-pipeline-checkpoint.sh"
CI_LOG_DIR="${JARVIS_HOME}/runtime/state/pdf-pipeline"
CI_LOG="${CI_LOG_DIR}/ci-check.jsonl"
CLUSTER_ID="cl-8a2b1b50fcd5ba63"

mkdir -p "$CI_LOG_DIR" 2>/dev/null || true

MODE_JSON=0
SINCE_DAYS=""
DIRS=()
FILES=()
SELFTEST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)     MODE_JSON=1; shift ;;
        --dir)      DIRS+=("$2"); shift 2 ;;
        --files)    shift; while [[ $# -gt 0 && "$1" != --* ]]; do FILES+=("$1"); shift; done ;;
        --since)    SINCE_DAYS="${2%d}"; shift 2 ;;
        --selftest|--test) SELFTEST=1; shift ;;
        -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
        *)          echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
done

# 기본 스캔 경로 — 산출물이 쌓이는 실제 위치들. 없는 폴더는 조용히 건너뜀.
if [[ ${#DIRS[@]} -eq 0 && ${#FILES[@]} -eq 0 && $SELFTEST -eq 0 ]]; then
    for d in "${HOME}/Desktop" "${HOME}/Downloads" "${JARVIS_HOME}/preply/out"; do
        [[ -d "$d" ]] && DIRS+=("$d")
    done
fi

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_log() {
    local status="$1" html="$2" pdf="$3" reason="${4:-}"
    printf '{"ts":"%s","cluster":"%s","html":"%s","pdf":"%s","status":"%s","reason":"%s"}\n' \
        "$(_ts)" "$CLUSTER_ID" "$html" "$pdf" "$status" "$reason" >> "$CI_LOG"
}

# 파일 하나 검사 — pdf-pipeline-checkpoint.sh 를 재사용해 저널까지 갱신
_check_one() {
    local html="$1"
    local base="${html%.html}"; base="${base%.htm}"
    local pdf="${base}.pdf"
    if [[ ! -f "$pdf" ]]; then
        _log MISSING_PDF "$html" "$pdf" "no_pair"
        printf '%s\tMISSING_PDF\t%s\n' "MISS" "$html"
        return 1
    fi
    if bash "$GUARD" pdf-checkpoint "$pdf" >/dev/null 2>&1; then
        _log PASS "$html" "$pdf" ""
        printf '%s\tOK\t%s\n' "PASS" "$html"
        return 0
    fi
    local reason; reason=$(bash "$GUARD" diagnose "$pdf" 2>/dev/null | head -1)
    _log FAIL "$html" "$pdf" "$reason"
    printf '%s\tFAIL\t%s\t%s\n' "FAIL" "$html" "$reason"
    return 1
}

# 폴더에서 HTML 후보 수집 (심볼릭·숨김 제외, --since 로 최근 것만)
_collect() {
    local d="$1"
    local -a args=(-type f \( -iname '*.html' -o -iname '*.htm' \) -not -path '*/node_modules/*' -not -path '*/.git/*')
    if [[ -n "$SINCE_DAYS" ]]; then
        args+=(-mtime "-${SINCE_DAYS}")
    fi
    find "$d" -maxdepth 4 "${args[@]}" 2>/dev/null
}

_run_batch() {
    local total=0 ok=0 fail=0 miss=0
    local -a results=()
    for d in "${DIRS[@]+"${DIRS[@]}"}"; do
        while IFS= read -r html; do
            [[ -z "$html" ]] && continue
            total=$((total+1))
            local line rc
            line=$(_check_one "$html"); rc=$?
            results+=("$line")
            case "$rc" in
                0) ok=$((ok+1)) ;;
                *) if [[ "$line" == MISS* ]]; then miss=$((miss+1)); else fail=$((fail+1)); fi ;;
            esac
        done < <(_collect "$d")
    done
    for html in "${FILES[@]+"${FILES[@]}"}"; do
        [[ -z "$html" ]] && continue
        total=$((total+1))
        local line rc
        line=$(_check_one "$html"); rc=$?
        results+=("$line")
        case "$rc" in
            0) ok=$((ok+1)) ;;
            *) if [[ "$line" == MISS* ]]; then miss=$((miss+1)); else fail=$((fail+1)); fi ;;
        esac
    done

    if [[ $MODE_JSON -eq 1 ]]; then
        printf '{"cluster":"%s","total":%d,"pass":%d,"fail":%d,"missing":%d,"log":"%s","items":[' \
            "$CLUSTER_ID" "$total" "$ok" "$fail" "$miss" "$CI_LOG"
        local first=1
        for r in "${results[@]+"${results[@]}"}"; do
            IFS=$'\t' read -r st _ path reason <<<"$r"
            [[ $first -eq 1 ]] && first=0 || printf ','
            printf '{"status":"%s","file":"%s","reason":"%s"}' \
                "$st" "${path//\"/\\\"}" "${reason//\"/\\\"}"
        done
        printf ']}\n'
    else
        echo "── CI PDF 파이프라인 체크 결과 (cluster=$CLUSTER_ID) ──"
        for r in "${results[@]+"${results[@]}"}"; do echo "  $r"; done
        echo "합계: total=$total pass=$ok fail=$fail missing=$miss"
        echo "저널: $CI_LOG"
    fi
    if [[ $fail -gt 0 || $miss -gt 0 ]]; then
        return 1
    fi
    return 0
}

_selftest() {
    local d; d=$(mktemp -d) || { echo "mktemp 실패" >&2; return 1; }
    trap "rm -rf $d" RETURN
    local html1="$d/ok.html" pdf1="$d/ok.pdf"
    local html2="$d/bad.html" pdf2="$d/bad.pdf"
    local html3="$d/lonely.html"
    printf '<!doctype html><html><body>ok</body></html>' > "$html1"
    printf '<!doctype html><html><body>bad</body></html>' > "$html2"
    printf '<!doctype html><html><body>lonely</body></html>' > "$html3"
    # 유효한 PDF 시늉: 매직 넘버 + 10KB 이상. pdfinfo가 있으면 페이지 0 로 FAIL 되므로
    # 셀프테스트에서는 pdf1 도 FAIL/pass 분기를 checkpoint에 위임하고 결과만 관찰한다.
    { printf '%%PDF-1.4\n'; head -c 20000 /dev/urandom | base64; } > "$pdf1"
    printf 'not a pdf'  > "$pdf2"
    DIRS=()
    FILES=("$html1" "$html2" "$html3")
    MODE_JSON=0
    _run_batch
    local rc=$?
    # 최소한: 셀프테스트 실행이 크래시 없이 결과를 뽑아냈고, 손상/누락 케이스가 exit=1 을 유발했어야 한다.
    if [[ $rc -ne 1 ]]; then
        echo "❌ 셀프테스트: 손상·누락 케이스가 있는데 exit 0 이 나옴" >&2
        return 1
    fi
    echo "✅ CI-check 셀프테스트 통과 (cluster=$CLUSTER_ID)"
    return 0
}

if [[ ! -x "$GUARD" && ! -r "$GUARD" ]]; then
    echo "❌ 의존 가드 부재: $GUARD" >&2
    exit 3
fi

if [[ $SELFTEST -eq 1 ]]; then
    _selftest
    exit $?
fi

_run_batch
exit $?
