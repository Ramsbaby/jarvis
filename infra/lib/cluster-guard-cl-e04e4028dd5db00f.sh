#!/usr/bin/env bash
# cluster-guard-cl-e04e4028dd5db00f.sh — 규칙 편차 방지 가드
#
# 클러스터 ID  : cl-e04e4028dd5db00f (최근 7일 재발 12건)
# 대표 시드    : 규칙 편차 — 세트별 예문 개수 불일치 미방지
# 멤버 패턴    : 확정 규칙 미적용 후 완료 선언 / 예외의 표준 미승격 / 이전 규칙으로 회귀
#
# 역할:
#   1. guard_new_set_start <파일유형>  — 새 세트 작업 시작 시 확정 규칙 자동 출력
#   2. guard_validate_set <파일>       — 세트 완료 전 확정 규칙 위반 검사 (exit 0/1)
#   3. rule_promote_exception <규칙ID> <값> [<이유>]  — 예외를 표준으로 승격 (대화형)
#   4. rule_registry_show              — 현재 활성 규칙 목록 출력
#   5. rule_registry_add <이름> <설명> <check_type> [<추가필드...>]  — 새 규칙 등록
#
# 사용:
#   source ~/.jarvis/infra/lib/cluster-guard-cl-e04e4028dd5db00f.sh
#   guard_new_set_start "card_news"
#   guard_validate_set "~/.openclaw-data/runtime/preply-materials/CardNews_BTS.html"
#   rule_promote_exception "rule-예문3개" "4" "보람님이 BTS 세트에 예문 4개 요청"
#
# 통합:
#   preply-student.sh new     → guard_new_set_start 자동 호출
#   preply-student.sh verify  → guard_validate_set 자동 호출
#
# 기존 동작 보호: 가드 FAIL 시 preply-student.sh는 warn만 출력, 차단하지 않음
#   (완전 차단은 preply-student.sh send --force 패턴과 일관성을 맞추기 위해 별도 플래그 필요)

set -o pipefail

# ── 경로 상수 ────────────────────────────────────────────────────────────────

readonly _CL_ID="cl-e04e4028dd5db00f"
readonly _CL_REGISTRY="${HOME}/.openclaw-data/runtime/state/rule-registry-cl-e04e4028dd5db00f.json"
readonly _CL_STUDENTS_JSON="${HOME}/.openclaw-data/runtime/config/preply-students.json"
readonly _CL_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_ID}.log"
readonly _CL_PREFIX="[rule-guard ${_CL_ID}]"

# ── 내부 헬퍼 ────────────────────────────────────────────────────────────────

_cl_now() { date '+%Y-%m-%dT%H:%M:%S'; }

_cl_log() {
    local level="$1"; shift
    local msg="$*"
    mkdir -p "$(dirname "$_CL_LOG")" 2>/dev/null || true
    printf '%s %s [%s] %s\n' "$(_cl_now)" "$_CL_PREFIX" "$level" "$msg" >> "$_CL_LOG" 2>/dev/null || true
}

_cl_say() { echo "${_CL_PREFIX} $*" >&2; }
_cl_warn() { echo "⚠️  ${_CL_PREFIX} [WARN] $*" >&2; }
_cl_fail() { echo "❌ ${_CL_PREFIX} [FAIL] $*" >&2; }
_cl_ok()   { echo "✅ ${_CL_PREFIX} [OK]   $*" >&2; }

# jq가 없으면 python3 폴백
_cl_jq() {
    if command -v jq &>/dev/null; then
        jq "$@"
    else
        python3 -c "
import json, sys
data = json.load(open('${_CL_REGISTRY}'))
print(json.dumps(data, ensure_ascii=False, indent=2))
" 2>/dev/null
    fi
}

# 레지스트리 읽기 (python3로 특정 필드)
_cl_reg_get() {
    local query="$1"
    python3 -c "
import json, sys
try:
    with open('${_CL_REGISTRY}') as f:
        d = json.load(f)
    # query: 'rules[0].id' 형태 지원 필요 없음 — 아래서 직접 처리
    print(json.dumps(d, ensure_ascii=False))
except Exception as e:
    print('{}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# 레지스트리의 활성 규칙만 리스트로 출력 (각 줄 = JSON 객체)
_cl_active_rules() {
    python3 - "$_CL_REGISTRY" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        reg = json.load(f)
    for r in reg.get("rules", []):
        if r.get("active", True):
            print(json.dumps(r, ensure_ascii=False))
except Exception as e:
    sys.exit(0)
PY
}

# ── 공개 API 1: 새 세트 시작 시 규칙 출력 ──────────────────────────────────

# guard_new_set_start [scope]
# scope: "card_news" | "lesson_material" | "" (전체)
guard_new_set_start() {
    local scope="${1:-}"

    if [ ! -f "$_CL_REGISTRY" ]; then
        _cl_warn "규칙 레지스트리 없음: $_CL_REGISTRY — 가드 스킵"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 [rule-guard] 새 세트 시작 — 확정 규칙 체크리스트"
    echo "   클러스터: ${_CL_ID} (규칙 편차 방지)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local count=0
    while IFS= read -r rule_json; do
        local rule_scope rule_name rule_desc
        rule_scope=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('scope',''))" "$rule_json" 2>/dev/null)
        rule_name=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('name',''))" "$rule_json" 2>/dev/null)
        rule_desc=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('description',''))" "$rule_json" 2>/dev/null)

        # scope 필터
        if [ -n "$scope" ] && [ "$rule_scope" != "$scope" ]; then
            continue
        fi

        count=$((count + 1))
        echo "  ${count}. ✔ ${rule_name}"
        echo "     └ ${rule_desc}"
    done < <(_cl_active_rules)

    if [ "$count" -eq 0 ]; then
        echo "  (해당 scope의 활성 규칙 없음)"
    else
        echo ""
        echo "  ⚠️  위 규칙은 '완료 선언' 전에 반드시 지켜야 합니다."
        echo "  세트 완료 후: guard_validate_set <파일경로>"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    _cl_log "INFO" "new_set_start scope=${scope:-all} rules_shown=$count"
    return 0
}

# ── 공개 API 2: 세트 완료 전 규칙 검증 ──────────────────────────────────────

# guard_validate_set <파일경로>
# 반환: 0=통과, 1=위반발견 (기존 동작은 파괴하지 않음 — 호출자가 결정)
guard_validate_set() {
    local file_path="${1:-}"
    [ -n "$file_path" ] || { _cl_warn "파일 경로 필요: guard_validate_set <파일>"; return 0; }

    file_path="${file_path/#\~/$HOME}"
    if [ ! -f "$file_path" ]; then
        _cl_warn "파일 없음: $file_path — 가드 스킵"
        return 0
    fi

    if [ ! -f "$_CL_REGISTRY" ]; then
        _cl_warn "레지스트리 없음 — 가드 스킵"
        return 0
    fi

    local basename_f
    basename_f="$(basename "$file_path")"
    local fail_count=0
    local warn_count=0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔍 [rule-guard] 확정 규칙 검증: $basename_f"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while IFS= read -r rule_json; do
        local rule_id rule_name rule_check rule_pattern
        rule_id=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('id',''))" "$rule_json" 2>/dev/null)
        rule_name=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('name',''))" "$rule_json" 2>/dev/null)
        rule_check=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('check_type',''))" "$rule_json" 2>/dev/null)
        rule_pattern=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('file_pattern',''))" "$rule_json" 2>/dev/null)

        # file_pattern 매칭 검사
        if [ -n "$rule_pattern" ]; then
            if ! echo "$basename_f" | grep -qE "$rule_pattern"; then
                continue
            fi
        fi

        # check_type별 검사 로직
        case "$rule_check" in
            html_element_count_in_section)
                _validate_element_count_in_section "$rule_json" "$file_path" "$rule_name" "$rule_id"
                local rc=$?
                [ "$rc" -ne 0 ] && fail_count=$((fail_count + 1))
                ;;
            html_element_count)
                _validate_element_count "$rule_json" "$file_path" "$rule_name" "$rule_id"
                local rc=$?
                [ "$rc" -ne 0 ] && fail_count=$((fail_count + 1))
                ;;
            companion_files)
                _validate_companion_files "$rule_json" "$file_path" "$rule_name" "$rule_id"
                local rc=$?
                [ "$rc" -ne 0 ] && warn_count=$((warn_count + 1))
                ;;
        esac
    done < <(_cl_active_rules)

    echo ""
    if [ "$fail_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
        _cl_ok "모든 확정 규칙 통과 — 완료 선언 가능"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        _cl_log "INFO" "validate_ok file=$basename_f"
        return 0
    else
        _cl_fail "규칙 위반 ${fail_count}건, 경고 ${warn_count}건 발견"
        echo ""
        echo "  📌 예외 처리 시 rule_promote_exception으로 표준 승격 여부를 결정하세요."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        _cl_log "WARN" "validate_fail file=$basename_f fails=$fail_count warns=$warn_count"
        return 1
    fi
}

# 내부: html_element_count_in_section 검사
_validate_element_count_in_section() {
    local rule_json="$1" file_path="$2" rule_name="$3" rule_id="$4"

    local selector section_sel expected
    selector=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('selector',''))" "$rule_json" 2>/dev/null)
    section_sel=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('section_selector',''))" "$rule_json" 2>/dev/null)
    expected=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('expected_count',0))" "$rule_json" 2>/dev/null)

    # python3로 HTML 파싱 (html.parser 내장)
    local result
    result=$(python3 - "$file_path" "$selector" "$section_sel" "$expected" <<'PY'
import sys
from html.parser import HTMLParser

file_path = sys.argv[1]
target_sel = sys.argv[2]      # e.g. ".g-ex-box"
section_sel = sys.argv[3]     # e.g. ".grammar-slide, #c7"
expected = int(sys.argv[4])

# 단순 클래스/ID 기반 카운터 (full CSS 파서 없음 — 핵심 패턴만 지원)
def sel_to_patterns(sel_str):
    """selector string → [(tag, id, class)] list"""
    patterns = []
    for part in sel_str.split(','):
        part = part.strip()
        tag = None; el_id = None; el_class = None
        if '#' in part:
            tag_part, id_part = part.split('#', 1)
            tag = tag_part or None
            el_id = id_part.split('.')[0]
            if '.' in id_part:
                el_class = id_part.split('.', 1)[1]
        elif '.' in part:
            tag_part, class_part = part.split('.', 1)
            tag = tag_part or None
            el_class = class_part
        else:
            tag = part if part else None
        patterns.append((tag, el_id, el_class))
    return patterns

def matches(tag, attrs_dict, patterns):
    for (p_tag, p_id, p_class) in patterns:
        tag_ok = (p_tag is None) or (p_tag.lower() == tag.lower())
        id_ok = (p_id is None) or (attrs_dict.get('id','') == p_id)
        # class matching: check if p_class is in space-separated class list
        el_classes = attrs_dict.get('class','').split()
        class_ok = (p_class is None) or (p_class in el_classes)
        if tag_ok and id_ok and class_ok:
            return True
    return False

section_patterns = sel_to_patterns(section_sel)
target_patterns = sel_to_patterns(target_sel)

class Counter(HTMLParser):
    def __init__(self):
        super().__init__()
        self.depth = 0
        self.section_depth = 0
        self.in_section = False
        self.count = 0
        self.section_found = False

    def handle_starttag(self, tag, attrs):
        self.depth += 1
        attrs_dict = dict(attrs)
        if matches(tag, attrs_dict, section_patterns):
            self.in_section = True
            self.section_depth = self.depth
            self.section_found = True
        if self.in_section and matches(tag, attrs_dict, target_patterns):
            self.count += 1

    def handle_endtag(self, tag):
        if self.in_section and self.depth == self.section_depth:
            self.in_section = False
        self.depth -= 1

try:
    with open(file_path, encoding='utf-8', errors='replace') as f:
        html = f.read()
    c = Counter()
    c.feed(html)
    if not c.section_found:
        # 섹션 자체가 없으면 카드뉴스 문법 슬라이드 아닌 파일 — 스킵
        print(f"SKIP:section_not_found")
    elif c.count == expected:
        print(f"OK:{c.count}")
    else:
        print(f"FAIL:{c.count}:{expected}")
except Exception as e:
    print(f"ERR:{e}")
PY
    )

    local outcome="${result%%:*}"
    case "$outcome" in
        OK)
            _cl_ok "${rule_name} — ${selector} ${result#OK:}개 (기댓값 ${expected}개 ✓)"
            return 0
            ;;
        SKIP)
            echo "  ⏭  ${rule_name} — 해당 섹션 없음, 스킵 (non-card-news 파일)"
            return 0
            ;;
        FAIL)
            local actual="${result#FAIL:}"; actual="${actual%%:*}"
            _cl_fail "${rule_name} — ${selector} ${actual}개 발견, 기댓값 ${expected}개"
            echo "     └ rule_id: ${rule_id}"
            echo "     └ 예외 승격: rule_promote_exception '${rule_id}' '${actual}' '이유'"
            _cl_log "FAIL" "rule=${rule_id} actual=${actual} expected=${expected} file=$(basename "$file_path")"
            return 1
            ;;
        ERR)
            _cl_warn "${rule_name} — HTML 파싱 오류: ${result#ERR:} (가드 스킵)"
            return 0
            ;;
    esac
}

# 내부: html_element_count 검사 (섹션 무관 전체 카운트)
_validate_element_count() {
    local rule_json="$1" file_path="$2" rule_name="$3" rule_id="$4"

    local selector expected
    selector=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('selector',''))" "$rule_json" 2>/dev/null)
    expected=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get('expected_count',0))" "$rule_json" 2>/dev/null)

    local result
    result=$(python3 - "$file_path" "$selector" "$expected" <<'PY'
import sys
from html.parser import HTMLParser

file_path = sys.argv[1]
target_sel = sys.argv[2]
expected = int(sys.argv[3])

def sel_to_patterns(sel_str):
    patterns = []
    for part in sel_str.split(','):
        part = part.strip()
        tag = None; el_id = None; el_class = None
        if '#' in part:
            tag_part, id_part = part.split('#', 1)
            el_id = id_part.split('.')[0]
        elif '.' in part:
            tag_part, class_part = part.split('.', 1)
            tag = tag_part or None
            el_class = class_part
        else:
            tag = part if part else None
        patterns.append((tag, el_id, el_class))
    return patterns

def matches(tag, attrs_dict, patterns):
    for (p_tag, p_id, p_class) in patterns:
        tag_ok = (p_tag is None) or (p_tag.lower() == tag.lower())
        id_ok = (p_id is None) or (attrs_dict.get('id','') == p_id)
        el_classes = attrs_dict.get('class','').split()
        class_ok = (p_class is None) or (p_class in el_classes)
        if tag_ok and id_ok and class_ok:
            return True
    return False

target_patterns = sel_to_patterns(target_sel)

class Counter(HTMLParser):
    def __init__(self):
        super().__init__()
        self.count = 0
    def handle_starttag(self, tag, attrs):
        if matches(tag, dict(attrs), target_patterns):
            self.count += 1

try:
    with open(file_path, encoding='utf-8', errors='replace') as f:
        html = f.read()
    c = Counter()
    c.feed(html)
    if c.count == expected:
        print(f"OK:{c.count}")
    else:
        print(f"FAIL:{c.count}:{expected}")
except Exception as e:
    print(f"ERR:{e}")
PY
    )

    local outcome="${result%%:*}"
    case "$outcome" in
        OK)
            _cl_ok "${rule_name} — ${selector} ${result#OK:}개 (기댓값 ${expected}개 ✓)"
            return 0
            ;;
        FAIL)
            local actual="${result#FAIL:}"; actual="${actual%%:*}"
            _cl_fail "${rule_name} — ${selector} ${actual}개 발견, 기댓값 ${expected}개"
            echo "     └ rule_id: ${rule_id}"
            echo "     └ 예외 승격: rule_promote_exception '${rule_id}' '${actual}' '이유'"
            _cl_log "FAIL" "rule=${rule_id} actual=${actual} expected=${expected} file=$(basename "$file_path")"
            return 1
            ;;
        ERR)
            _cl_warn "${rule_name} — HTML 파싱 오류 (가드 스킵)"
            return 0
            ;;
    esac
}

# 내부: companion_files 검사 (숙제 3종 세트 등)
_validate_companion_files() {
    local rule_json="$1" file_path="$2" rule_name="$3" rule_id="$4"

    # 파일명 기반 동반 파일 확인
    local base_dir base_name ext missing=()
    base_dir="$(dirname "$file_path")"
    base_name="$(basename "$file_path")"
    ext="${base_name##*.}"

    local suffixes
    suffixes=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(' '.join(r.get('required_suffixes',[])))" "$rule_json" 2>/dev/null)

    local stem="${base_name%_Unit*}"
    local unit_part="${base_name#*_Unit}"
    unit_part="${unit_part%.*}"
    # 2026-07-26 버그 수정: 파일 자체가 이미 _숙제/_정답지/_요약본 등 접미사를 가진 경우
    # (예: 한국어수업_Lucia_Unit1_숙제.html) unit_part에 접미사가 섞여
    # "Unit1_숙제_숙제.pdf" 같은 존재할 수 없는 동반파일을 요구하던 문제 수정.
    # 순수 유닛 번호만 남기고 뒤의 접미사는 잘라낸다.
    unit_part="${unit_part%%_*}"

    local found=0 missing_list=""
    for suffix in $suffixes; do
        if [ -z "$suffix" ]; then
            continue  # 메인 파일 자체는 이미 존재
        fi
        local companion="${base_dir}/${stem}_Unit${unit_part}${suffix}.pdf"
        if [ ! -f "$companion" ]; then
            missing_list="${missing_list} $(basename "$companion")"
        fi
    done

    if [ -z "$missing_list" ]; then
        _cl_ok "${rule_name} — 동반 파일 모두 확인됨"
        return 0
    else
        _cl_warn "${rule_name} — 동반 파일 미확인:${missing_list}"
        echo "     └ rule_id: ${rule_id} (경고 — 전송 전 확인 필요)"
        return 1
    fi
}

# ── 공개 API 3: 예외를 표준으로 승격 (대화형) ───────────────────────────────

# rule_promote_exception <규칙ID> <새값> [<이유>]
rule_promote_exception() {
    local rule_id="${1:-}"
    local new_value="${2:-}"
    local reason="${3:-}"

    [ -n "$rule_id" ] || { _cl_warn "사용법: rule_promote_exception <규칙ID> <새값> [이유]"; return 1; }
    [ -n "$new_value" ] || { _cl_warn "새 값을 지정하세요"; return 1; }

    if [ ! -f "$_CL_REGISTRY" ]; then
        _cl_warn "레지스트리 없음: $_CL_REGISTRY"
        return 1
    fi

    # 현재 규칙 확인
    local current_val
    current_val=$(python3 -c "
import json, sys
with open('${_CL_REGISTRY}') as f:
    reg = json.load(f)
for r in reg.get('rules', []):
    if r.get('id') == '${rule_id}':
        print(r.get('expected_count', r.get('description', '')))
        break
" 2>/dev/null)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔄 [rule-guard] 예외 → 표준 승격 요청"
    echo "   규칙 ID  : $rule_id"
    echo "   현재 값  : $current_val"
    echo "   새 값    : $new_value"
    [ -n "$reason" ] && echo "   이유     : $reason"
    echo ""

    # 대화형 확인 (TTY 없으면 자동 거부)
    local answer="n"
    if [ -t 0 ]; then
        read -r -p "   이 예외를 영구 표준으로 승격합니까? [y/N] " answer
    else
        _cl_warn "TTY 없음 — 자동 승격 거부. 인터랙티브 터미널에서 실행하세요."
        echo "   명령: rule_promote_exception '$rule_id' '$new_value' '$reason'"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi

    if [ "${answer,,}" != "y" ]; then
        echo "   → 승격 취소. 기존 규칙($current_val) 유지."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _cl_log "INFO" "promote_declined rule=${rule_id} new_val=${new_value}"
        return 0
    fi

    # 레지스트리 업데이트
    local ts
    ts="$(_cl_now)"
    python3 - "$_CL_REGISTRY" "$rule_id" "$new_value" "$reason" "$ts" <<'PY'
import json, sys
reg_path, rule_id, new_val, reason, ts = sys.argv[1:]

with open(reg_path) as f:
    reg = json.load(f)

updated = False
for r in reg.get("rules", []):
    if r.get("id") == rule_id:
        old_val = r.get("expected_count")
        r["expected_count"] = int(new_val) if new_val.isdigit() else new_val
        r["promoted_at"] = ts[:10]
        r["promote_reason"] = reason
        updated = True
        break

if not updated:
    print(f"ERROR: 규칙 ID '{rule_id}'를 찾을 수 없습니다.", file=sys.stderr)
    sys.exit(1)

# exceptions_log에 기록
entry = {
    "rule_id": rule_id,
    "old_value": str(old_val) if 'old_val' in dir() else "unknown",
    "new_value": new_val,
    "reason": reason,
    "promoted_at": ts,
    "promoted_to_standard": True
}
reg.setdefault("exceptions_log", []).append(entry)
reg["_meta"]["last_updated"] = ts[:10]

with open(reg_path, "w") as f:
    json.dump(reg, f, ensure_ascii=False, indent=2)

print(f"OK: 규칙 '{rule_id}' 값이 '{old_val}' → '{new_val}'로 업데이트됨")
PY

    local rc=$?
    if [ $rc -eq 0 ]; then
        _cl_ok "규칙 '$rule_id' 표준 승격 완료 ($current_val → $new_value)"
        echo "   ⚠️  preply-students.json permanent_rules 도 함께 업데이트하세요."
        _cl_log "INFO" "promote_ok rule=${rule_id} old=${current_val} new=${new_value} reason=${reason}"
    else
        _cl_fail "레지스트리 업데이트 실패"
        _cl_log "ERROR" "promote_failed rule=${rule_id}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    return $rc
}

# ── 공개 API 4: 현재 활성 규칙 목록 출력 ────────────────────────────────────

rule_registry_show() {
    if [ ! -f "$_CL_REGISTRY" ]; then
        _cl_warn "레지스트리 없음: $_CL_REGISTRY"
        return 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📚 [rule-guard] 활성 확정 규칙 목록"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    python3 - "$_CL_REGISTRY" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    reg = json.load(f)

rules = [r for r in reg.get("rules", []) if r.get("active", True)]
for i, r in enumerate(rules, 1):
    print(f"  {i}. [{r.get('id')}] {r.get('name')}")
    print(f"     설명: {r.get('description','')}")
    scope_val = r.get("expected_count")
    if scope_val is not None:
        print(f"     기댓값: {scope_val}")
    print(f"     적용범위: {r.get('file_pattern','*')}")
    print(f"     확정일: {r.get('promoted_at','')} | {r.get('confirmed_by','')}")
    print()

exc = reg.get("exceptions_log", [])
if exc:
    print(f"  📋 예외 승격 이력 ({len(exc)}건):")
    for e in exc[-3:]:  # 최근 3건만
        print(f"     - {e.get('rule_id')}: {e.get('old_value')} → {e.get('new_value')} ({e.get('promoted_at','')}) — {e.get('reason','')}")
PY

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ── 공개 API 5: 새 규칙 추가 ────────────────────────────────────────────────

# rule_registry_add <id> <이름> <설명> <check_type> [expected_count] [file_pattern] [scope]
rule_registry_add() {
    local rule_id="${1:-}" rule_name="${2:-}" rule_desc="${3:-}" check_type="${4:-}"
    local expected="${5:-}" file_pat="${6:-}"  scope="${7:-}"

    [ -n "$rule_id" ] && [ -n "$rule_name" ] && [ -n "$rule_desc" ] && [ -n "$check_type" ] || {
        echo "사용법: rule_registry_add <id> <이름> <설명> <check_type> [expected_count] [file_pattern] [scope]"
        return 1
    }

    if [ ! -f "$_CL_REGISTRY" ]; then
        _cl_warn "레지스트리 없음: $_CL_REGISTRY"
        return 1
    fi

    local ts; ts="$(_cl_now)"

    python3 - "$_CL_REGISTRY" "$rule_id" "$rule_name" "$rule_desc" "$check_type" \
              "$expected" "$file_pat" "$scope" "$ts" <<'PY'
import json, sys
reg_path, rule_id, rule_name, rule_desc, check_type, expected, file_pat, scope, ts = sys.argv[1:]

with open(reg_path) as f:
    reg = json.load(f)

# 중복 체크
if any(r.get("id") == rule_id for r in reg.get("rules", [])):
    print(f"SKIP: rule_id '{rule_id}' 이미 존재합니다.")
    sys.exit(0)

new_rule = {
    "id": rule_id,
    "name": rule_name,
    "description": rule_desc,
    "check_type": check_type,
    "active": True,
    "promoted_at": ts[:10],
    "confirmed_by": "rule_registry_add"
}
if expected:
    try: new_rule["expected_count"] = int(expected)
    except: new_rule["expected_count"] = expected
if file_pat:
    new_rule["file_pattern"] = file_pat
if scope:
    new_rule["scope"] = scope

reg.setdefault("rules", []).append(new_rule)
reg["_meta"]["last_updated"] = ts[:10]

with open(reg_path, "w") as f:
    json.dump(reg, f, ensure_ascii=False, indent=2)

print(f"OK: 규칙 '{rule_id}' 추가됨")
PY

    local rc=$?
    [ $rc -eq 0 ] && _cl_log "INFO" "rule_add id=${rule_id} name=${rule_name}"
    return $rc
}

# ── 자동 export (source 시 함수 등록) ───────────────────────────────────────

export -f guard_new_set_start 2>/dev/null || true
export -f guard_validate_set 2>/dev/null || true
export -f rule_promote_exception 2>/dev/null || true
export -f rule_registry_show 2>/dev/null || true
export -f rule_registry_add 2>/dev/null || true
