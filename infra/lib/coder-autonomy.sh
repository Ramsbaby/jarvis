#!/usr/bin/env bash
# coder-autonomy.sh — 코더 자율성 정책 (SELF-HEAL-PLAN 3c, 2026-09-04)
# 정책표: infra/config/coder-autonomy.json. coder-merge.sh(3b)·coder-review(3a) 가 source 한다.
#
# 함수:
#   coder_autonomy_config                     → 정책 파일 경로 (JARVIS_CODER_AUTONOMY_CONFIG 로 대체 가능)
#   coder_autonomy_ledger                     → ${BOT_HOME}/ledger/coder-merge.jsonl
#   coder_autonomy_classify_file <path>       → class 이름 (order 순 첫 매치, 없으면 default_class)
#   coder_autonomy_classify_files             → stdin 의 파일 목록을 가장 엄격한 class 하나로 요약
#   coder_autonomy_threshold <class>          → auto_threshold (영구 수동이면 "null")
#   coder_autonomy_streak <class>             → 원장에서 그 class 의 연속 승인(merged) 횟수. 거절(rejected)·되돌림(reverted)이 나오면 0
#                                               (expired 는 아무도 안 본 것이므로 스트릭을 깎지 않는다)
#   coder_autonomy_allows_auto <class>        → 자동 머지 허용이면 0, 아니면 1. stdout 에 사유 한 줄
#
# 패턴 매칭은 bash 의 [[ == ]] glob — '*' 가 '/' 를 넘어간다. 파일 경로는 저장소 루트 기준 상대경로.

_coder_autonomy_infra() {
    if [[ -n "${JARVIS_INFRA_HOME:-}" ]]; then echo "$JARVIS_INFRA_HOME"; return; fi
    local here; here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
    echo "$here"
}

coder_autonomy_config() {
    echo "${JARVIS_CODER_AUTONOMY_CONFIG:-$(_coder_autonomy_infra)/config/coder-autonomy.json}"
}

coder_autonomy_ledger() {
    local rel; rel=$(jq -r '.ledger // "ledger/coder-merge.jsonl"' "$(coder_autonomy_config)" 2>/dev/null || echo "ledger/coder-merge.jsonl")
    echo "${BOT_HOME:?BOT_HOME 미설정}/$rel"
}

coder_autonomy_classify_file() {
    local f="$1" cfg; cfg=$(coder_autonomy_config)
    local cls pat
    # order 순으로 class 를 돌며 paths 패턴에 첫 매치
    while IFS= read -r cls; do
        [[ -n "$cls" ]] || continue
        while IFS= read -r pat; do
            [[ -n "$pat" ]] || continue
            # shellcheck disable=SC2053  # 패턴 변수의 glob 매칭이 의도
            if [[ "$f" == $pat ]]; then echo "$cls"; return 0; fi
        done < <(jq -r --arg c "$cls" '.classes[$c].paths[]? // empty' "$cfg")
    done < <(jq -r '.order[]? // empty' "$cfg")
    jq -r '.default_class // "scripts"' "$cfg"
}

# stdin: 파일 경로 한 줄씩. 가장 엄격한 class 하나를 출력.
# 엄격도: manual_forever(threshold null) > threshold 큰 순.
coder_autonomy_classify_files() {
    local cfg; cfg=$(coder_autonomy_config)
    local f cls best="" best_t=-1 t
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        cls=$(coder_autonomy_classify_file "$f")
        t=$(coder_autonomy_threshold "$cls")
        if [[ "$t" == "null" ]]; then echo "$cls"; return 0; fi
        if (( t > best_t )); then best_t=$t; best=$cls; fi
    done
    if [[ -z "$best" ]]; then jq -r '.default_class // "scripts"' "$cfg"; else echo "$best"; fi
}

coder_autonomy_threshold() {
    local cls="$1"
    jq -r --arg c "$cls" '.classes[$c].auto_threshold // "null"' "$(coder_autonomy_config)" 2>/dev/null || echo null
}

coder_autonomy_streak() {
    local cls="$1" ledger; ledger=$(coder_autonomy_ledger)
    [[ -f "$ledger" ]] || { echo 0; return 0; }
    # merged 는 +1, rejected/reverted 는 0 으로 리셋, 그 외(dry_run/blocked/expired)는 무시
    jq -rs --arg c "$cls" '
        map(select(type=="object" and .class==$c))
        | reduce .[] as $r (0;
            if $r.action=="merged" then .+1
            elif ($r.action=="rejected" or $r.action=="reverted") then 0
            else . end)' "$ledger" 2>/dev/null || echo 0
}

coder_autonomy_allows_auto() {
    local cls="$1" t s
    t=$(coder_autonomy_threshold "$cls")
    if [[ "$t" == "null" ]]; then
        echo "class=${cls} 는 영구 수동 — 사람이 coder-merge.sh 를 직접 호출해야 합니다"
        return 1
    fi
    s=$(coder_autonomy_streak "$cls")
    if (( s >= t )); then
        echo "class=${cls} 연속 승인 ${s}/${t} — 자동 머지 허용"
        return 0
    fi
    echo "class=${cls} 연속 승인 ${s}/${t} — 문턱 미달, 사람 승인 필요"
    return 1
}
