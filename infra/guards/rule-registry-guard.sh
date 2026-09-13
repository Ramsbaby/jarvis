#!/usr/bin/env bash
# rule-registry-guard.sh — 확정 규칙 레지스트리 & 세트 시작 체크리스트 가드
#
# 클러스터 ID: cl-e04e4028dd5db00f (최근 7일 재발 12건)
# 문제:
#   1. 세트별 예문 개수 규칙(예문 3개 고정)이 다음 세트에 미적용됨
#   2. 확정 규칙이 이후 문서에서 이전 규칙으로 회귀
#   3. 예외 처리를 영구 표준으로 상향 미실시
#
# 목적:
#   1. 확정 규칙을 파일 기반 룰 레지스트리에 기록·유지
#   2. 새 세트 작업 시작 시 규칙 자동 로드·체크리스트 출력
#   3. HTML 교재의 gram-box당 gram-example 수를 레지스트리 규칙과 대조
#   4. 예외 처리 시 '표준 승격' 인터랙티브 단계 제공
#
# 사용법:
#   rule-registry-guard.sh show-rules
#       현재 확정 규칙 전체 출력
#
#   rule-registry-guard.sh pre-set-checklist [학생명] [유닛번호]
#       새 세트 작업 시작 전 체크리스트 출력 (규칙 자동 로드)
#
#   rule-registry-guard.sh check <파일.html>
#       교재 HTML의 gram-box당 gram-example 수 검증
#
#   rule-registry-guard.sh add-rule <key> <value> <description>
#       규칙 추가 또는 업데이트
#       예: add-rule examples_per_grammar_set 3 "문법 세트당 예문 3개 고정"
#
#   rule-registry-guard.sh promote-exception <key> <new_value> [reason]
#       예외 처리를 표준으로 승격 (인터랙티브 확인)
#
# Exit codes:
#   0: 검증 통과 / 작업 성공
#   1: 규칙 위반 발견 (예문 개수 불일치 등)
#   2: 인수 오류 / 파일 미지정

set -euo pipefail

CLUSTER_ID="cl-e04e4028dd5db00f"
JARVIS_HOME="${HOME}/.jarvis"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
REGISTRY="${JARVIS_HOME}/data/rule-registry/${CLUSTER_ID}.json"
LOG_FILE="${JARVIS_RUNTIME}/logs/rule-registry-guard.jsonl"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HOSTNAME_VAL="$(hostname 2>/dev/null || echo 'unknown')"

# ── 색상 코드 ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── 디렉토리 초기화 ────────────────────────────────────────────────────────
_ensure_dirs() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    mkdir -p "$(dirname "$REGISTRY")" 2>/dev/null || true
}
_ensure_dirs

# ── JSON 안전 이스케이프 ───────────────────────────────────────────────────
_esc() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── JSONL 감사 로그 ────────────────────────────────────────────────────────
_log() {
    local event="$1" detail="$2" exit_code="${3:-0}"
    printf '{"ts":"%s","cluster":"%s","event":"%s","detail":"%s","exit":%s,"host":"%s"}\n' \
        "$TIMESTAMP" "$CLUSTER_ID" "$(_esc "$event")" "$(_esc "$detail")" \
        "$exit_code" "$HOSTNAME_VAL" >> "$LOG_FILE" 2>/dev/null || true
}

# ── 레지스트리 로드 헬퍼 ──────────────────────────────────────────────────
_registry_exists() {
    [[ -f "$REGISTRY" ]]
}

_get_rule_value() {
    local key="$1"
    python3 -c "
import json,sys
try:
    r=json.load(open('$REGISTRY'))
    v=r['rules'].get('$key',{}).get('value')
    print(v if v is not None else '')
except: print('')
" 2>/dev/null
}

_get_rule_description() {
    local key="$1"
    python3 -c "
import json,sys
try:
    r=json.load(open('$REGISTRY'))
    print(r['rules'].get('$key',{}).get('description',''))
except: print('')
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════
# CMD: show-rules — 현재 확정 규칙 전체 출력
# ══════════════════════════════════════════════════════════════════════════
cmd_show_rules() {
    if ! _registry_exists; then
        echo -e "${RED}[ERROR]${RESET} 규칙 레지스트리 없음: $REGISTRY"
        exit 2
    fi

    echo -e "${BOLD}${CYAN}══ 확정 규칙 레지스트리 ══${RESET}"
    echo -e "  클러스터: ${CLUSTER_ID}"
    echo ""

    python3 - "$REGISTRY" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
rules = data.get('rules', {})
if not rules:
    print("  (규칙 없음)")
else:
    for key, rule in rules.items():
        print(f"  ┌─ {key}")
        print(f"  │  값: {rule.get('value')}")
        print(f"  │  설명: {rule.get('description','')}")
        print(f"  │  확정일: {rule.get('confirmed_at','unknown')}")
        print(f"  └─ 출처: {rule.get('source','unknown')}")
        print()

pending = data.get('pending_promotions', [])
if pending:
    print("  ── 승격 대기 예외 ──")
    for p in pending:
        print(f"  * [{p.get('key')}] {p.get('exception_value')} ← {p.get('reason','')}")
PYEOF

    _log "show-rules" "규칙 목록 조회" 0
}

# ══════════════════════════════════════════════════════════════════════════
# CMD: pre-set-checklist — 새 세트 작업 시작 전 체크리스트
# ══════════════════════════════════════════════════════════════════════════
cmd_pre_set_checklist() {
    local student="${1:-}" unit="${2:-}"
    local label=""
    [[ -n "$student" ]] && label=" (${student}"
    [[ -n "$unit" ]] && label="${label} Unit${unit}"
    [[ -n "$label" ]] && label="${label})"

    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║   세트 제작 시작 체크리스트${label}  ${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
    echo ""

    if ! _registry_exists; then
        echo -e "${YELLOW}[WARN]${RESET} 레지스트리 없음 — 기본 규칙으로 진행"
        echo -e "  □ 예문 개수: 기본 3개/세트 (레지스트리 미확인)"
    else
        echo -e "${BOLD}📋 적용할 확정 규칙:${RESET}"
        echo ""
        python3 - "$REGISTRY" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
rules = data.get('rules', {})
if not rules:
    print("  (등록된 규칙 없음 — 수동 확인 필요)")
else:
    for key, rule in rules.items():
        val = rule.get('value')
        desc = rule.get('description', '')
        print(f"  ✅ [{key}] = {val}")
        print(f"      → {desc}")
        print()

pending = data.get('pending_promotions', [])
if pending:
    print("  ⚠️  승격 대기 예외:")
    for p in pending:
        print(f"  → [{p.get('key')}] 예외값 {p.get('exception_value')} 표준 미승격")
        print(f"     사유: {p.get('reason','')}")
        print(f"     ※ 승격: rule-registry-guard.sh promote-exception {p.get('key')} {p.get('exception_value')}")
PYEOF
    fi

    echo ""
    echo -e "${BOLD}📝 작업 시작 전 확인사항:${RESET}"
    echo "  □ 위 규칙을 이번 세트에 적용했는가?"
    echo "  □ 이전 세트의 예외 처리가 있었다면 표준 승격 여부를 결정했는가?"
    echo "  □ 완료 선언 전 completion-validation-guard.sh 실행 예정인가?"
    echo ""
    echo -e "${YELLOW}※ 규칙 변경 시: rule-registry-guard.sh add-rule <key> <값> <설명>${RESET}"
    echo -e "${YELLOW}※ 예외 표준 승격: rule-registry-guard.sh promote-exception <key> <새값> [사유]${RESET}"
    echo ""

    _log "pre-set-checklist" "학생=${student} 유닛=${unit}" 0
}

# ══════════════════════════════════════════════════════════════════════════
# CMD: check <파일.html> — gram-box당 gram-example 수 검증
# ══════════════════════════════════════════════════════════════════════════
cmd_check() {
    local file="${1:-}"
    if [[ -z "$file" ]]; then
        echo -e "${RED}[ERROR]${RESET} 파일 경로 필요: rule-registry-guard.sh check <파일.html>"
        exit 2
    fi
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}[ERROR]${RESET} 파일 없음: $file"
        exit 2
    fi

    local expected_count
    expected_count=$(_get_rule_value "examples_per_grammar_set")
    if [[ -z "$expected_count" ]]; then
        expected_count=3
        echo -e "${YELLOW}[WARN]${RESET} 레지스트리 미조회 — 기본값 3 사용"
    fi

    echo -e "${BOLD}${CYAN}── 규칙 검증: $(basename "$file") ──${RESET}"
    echo -e "  대상 규칙: examples_per_grammar_set = ${BOLD}${expected_count}${RESET}"
    echo ""

    local result
    result=$(python3 - "$file" "$expected_count" <<'PYEOF'
import sys, re

filepath = sys.argv[1]
expected = int(sys.argv[2])
html = open(filepath, encoding='utf-8').read()

# gram-box 블록을 추출해 그 안의 gram-example 개수를 카운트
# gram-box는 중첩 없이 단일 레벨이므로 간단한 슬라이싱으로 처리
violations = []
warns = []

# gram-box 시작/끝 위치 탐색
box_starts = [m.start() for m in re.finditer(r'<div[^>]+class="[^"]*gram-box[^"]*"', html)]

for i, start in enumerate(box_starts):
    # 다음 gram-box 시작 또는 EOF까지가 현재 gram-box 범위
    end = box_starts[i+1] if i+1 < len(box_starts) else len(html)
    segment = html[start:end]

    # gram-box 제목 추출 (h3)
    h3_match = re.search(r'<h3[^>]*>(.*?)</h3>', segment, re.DOTALL)
    title = re.sub(r'<[^>]+>', '', h3_match.group(1)).strip() if h3_match else f"세트#{i+1}"

    # gram-example 개수
    count = len(re.findall(r'<div[^>]+class="[^"]*gram-example[^"]*"', segment))

    status = "PASS" if count == expected else "FAIL"
    print(f"{status}|{title}|{count}|{expected}")
PYEOF
)

    local fail_count=0
    local pass_count=0
    local total=0

    while IFS='|' read -r status title count expected_val; do
        total=$((total + 1))
        if [[ "$status" == "PASS" ]]; then
            pass_count=$((pass_count + 1))
            echo -e "  ${GREEN}✓ PASS${RESET} [${title}] 예문 ${count}개 (규칙: ${expected_val}개)"
        else
            fail_count=$((fail_count + 1))
            echo -e "  ${RED}✗ FAIL${RESET} [${title}] 예문 ${count}개 ≠ 규칙 ${expected_val}개"
        fi
    done <<< "$result"

    echo ""
    if [[ "$fail_count" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}[OK] 모든 gram-box 검증 통과 (${total}/${total})${RESET}"
        _log "check" "PASS file=$(basename "$file") boxes=${total}" 0
        exit 0
    else
        echo -e "  ${RED}${BOLD}[FAIL] ${fail_count}개 gram-box 규칙 위반 (통과: ${pass_count}/${total})${RESET}"
        echo ""
        echo -e "  ${YELLOW}※ 예외라면 표준 승격을 검토하세요:${RESET}"
        echo -e "     rule-registry-guard.sh promote-exception examples_per_grammar_set <새값> <사유>"
        _log "check" "FAIL file=$(basename "$file") violations=${fail_count}" 1
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# CMD: add-rule <key> <value> <description> — 규칙 추가/업데이트
# ══════════════════════════════════════════════════════════════════════════
cmd_add_rule() {
    local key="${1:-}" value="${2:-}" description="${3:-}"
    if [[ -z "$key" || -z "$value" ]]; then
        echo -e "${RED}[ERROR]${RESET} 사용법: add-rule <key> <value> <description>"
        exit 2
    fi

    if ! _registry_exists; then
        echo -e "${RED}[ERROR]${RESET} 레지스트리 없음: $REGISTRY"
        exit 2
    fi

    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    python3 - "$REGISTRY" "$key" "$value" "$description" "$ts" <<'PYEOF'
import json, sys

registry_path, key, raw_value, description, ts = sys.argv[1:6]
data = json.load(open(registry_path))

# 값 타입 자동 변환 (정수 가능하면 int로)
try:
    value = int(raw_value)
except ValueError:
    value = raw_value

old = data['rules'].get(key)
if old:
    # 히스토리 기록
    data.setdefault('history', []).append({
        "action": "update-rule",
        "key": key,
        "old_value": old.get('value'),
        "new_value": value,
        "ts": ts
    })

data['rules'][key] = {
    "value": value,
    "type": "count" if isinstance(value, int) else "string",
    "target": data['rules'].get(key, {}).get('target', ''),
    "description": description if description else data['rules'].get(key, {}).get('description', ''),
    "confirmed_at": ts,
    "source": data['rules'].get(key, {}).get('source', 'manual add-rule')
}
data['lastUpdated'] = ts

json.dump(data, open(registry_path, 'w'), ensure_ascii=False, indent=2)
print("OK")
PYEOF

    echo -e "${GREEN}[OK]${RESET} 규칙 저장: ${key} = ${value}"
    echo -e "     설명: ${description}"
    _log "add-rule" "key=${key} value=${value}" 0
}

# ══════════════════════════════════════════════════════════════════════════
# CMD: promote-exception <key> <new_value> [reason] — 예외를 표준으로 승격
# ══════════════════════════════════════════════════════════════════════════
cmd_promote_exception() {
    local key="${1:-}" new_value="${2:-}" reason="${3:-}"
    if [[ -z "$key" || -z "$new_value" ]]; then
        echo -e "${RED}[ERROR]${RESET} 사용법: promote-exception <key> <new_value> [reason]"
        exit 2
    fi

    local current_value
    current_value=$(_get_rule_value "$key")
    local current_desc
    current_desc=$(_get_rule_description "$key")

    echo -e "${BOLD}${YELLOW}══ 예외 → 표준 승격 검토 ══${RESET}"
    echo ""
    echo -e "  규칙 키: ${BOLD}${key}${RESET}"
    echo -e "  현재 표준값: ${BOLD}${current_value}${RESET}"
    echo -e "  새 표준값:   ${BOLD}${new_value}${RESET}"
    [[ -n "$reason" ]] && echo -e "  사유: ${reason}"
    echo ""

    if [[ -t 0 ]]; then
        # 인터랙티브 모드
        echo -e "${YELLOW}이 예외를 표준으로 승격하겠습니까? [y/N]:${RESET} "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}[취소]${RESET} 예외를 pending_promotions 에 기록합니다."
            _pend_promotion "$key" "$new_value" "$reason"
            return
        fi
    else
        # 비인터랙티브: pending에 기록하고 메시지 출력
        echo -e "${YELLOW}[비인터랙티브]${RESET} 승격 의도를 pending_promotions에 기록합니다."
        echo -e "  확정하려면 인터랙티브로 실행: rule-registry-guard.sh promote-exception ${key} ${new_value}"
        _pend_promotion "$key" "$new_value" "$reason"
        _log "promote-exception-pending" "key=${key} new=${new_value}" 0
        return
    fi

    # 실제 승격 실행
    cmd_add_rule "$key" "$new_value" "$current_desc (예외→표준 승격: ${reason})"

    # pending_promotions 에서 제거
    python3 - "$REGISTRY" "$key" <<'PYEOF'
import json, sys
rp, key = sys.argv[1:3]
data = json.load(open(rp))
data['pending_promotions'] = [p for p in data.get('pending_promotions', []) if p.get('key') != key]
json.dump(data, open(rp, 'w'), ensure_ascii=False, indent=2)
PYEOF

    echo -e "${GREEN}[OK]${RESET} ${key} 표준 승격 완료: ${current_value} → ${new_value}"
    _log "promote-exception-done" "key=${key} old=${current_value} new=${new_value}" 0
}

_pend_promotion() {
    local key="$1" new_value="$2" reason="${3:-}"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    python3 - "$REGISTRY" "$key" "$new_value" "$reason" "$ts" <<'PYEOF'
import json, sys
rp, key, new_val, reason, ts = sys.argv[1:6]
data = json.load(open(rp))
pending = data.setdefault('pending_promotions', [])
# 기존 동일 key 제거 후 재추가
pending = [p for p in pending if p.get('key') != key]
pending.append({"key": key, "exception_value": new_val, "reason": reason, "recorded_at": ts})
data['pending_promotions'] = pending
data['lastUpdated'] = ts
json.dump(data, open(rp, 'w'), ensure_ascii=False, indent=2)
PYEOF
}

# ══════════════════════════════════════════════════════════════════════════
# 진입점
# ══════════════════════════════════════════════════════════════════════════
CMD="${1:-}"
shift || true

case "$CMD" in
    show-rules)       cmd_show_rules ;;
    pre-set-checklist) cmd_pre_set_checklist "$@" ;;
    check)            cmd_check "$@" ;;
    add-rule)         cmd_add_rule "$@" ;;
    promote-exception) cmd_promote_exception "$@" ;;
    "")
        echo -e "${RED}[ERROR]${RESET} 명령 필요"
        echo ""
        echo "사용법:"
        echo "  rule-registry-guard.sh show-rules"
        echo "  rule-registry-guard.sh pre-set-checklist [학생명] [유닛번호]"
        echo "  rule-registry-guard.sh check <파일.html>"
        echo "  rule-registry-guard.sh add-rule <key> <value> <설명>"
        echo "  rule-registry-guard.sh promote-exception <key> <new_value> [사유]"
        exit 2
        ;;
    *)
        echo -e "${RED}[ERROR]${RESET} 알 수 없는 명령: $CMD"
        exit 2
        ;;
esac
