#!/usr/bin/env bash
# irreversible-bypass-guard.sh — 비가역 작업 차단/우회 감사 원장 (cl-602875a5289bba26)
#
# 클러스터 ID  : cl-602875a5289bba26 (최근 7일 재발 6건)
# 대표 시드    : 비가역 작업 사전 여의 규칙 위반
# 멤버 패턴    :
#   - 비가역 작업 사전 여의 규칙 위반
#   - 비가역 작업(`claude update`) 미상의
#   - 승인 없이 비가역 명령 집행
#   - 비가역 작업 사전 여쭤보기 미이행 후 사후 보고
#   - 여쭤보지 않고 비가역 작업 수행
#
# 목적: precheck-dangerous.sh가 차단하거나(우회 env var 없이) 우회한(env var로 통과시킨)
#       모든 비가역 명령 시도를 append-only 원장에 남긴다. 지금까지는 차단 메시지가
#       stderr에만 찍히고 사라져 "재발 6건"인지 확인할 방법이 없었다 — 이 원장이 그 증거다.
#       특히 "우회"는 env var를 사전에 세팅해야만 가능하므로, 우회 이력 자체가
#       "정말 주인님이 미리 승인했는가"를 주간 검토에서 되짚을 근거가 된다.
#
# 공개 API:
#   log_irreversible_event <pattern_id> <action: blocked|bypassed> [cmd] [tool] [cwd]
#       원장에 1줄 append. 실패해도 호출자(훅)의 차단 판정에 영향 없음 — 항상 성공 취급.
#   generate_bypass_audit_report [days=7]
#       세션 컨텍스트 주입용 마크다운 테이블 stdout 출력. 최근 N일 이벤트 없으면 빈 문자열.
#   irreversible_bypass_guard_status
#       가드 자체 상태 요약 (디버그용).
#
# 사용 (훅에서):
#   source ~/projects/jarvis/infra/lib/irreversible-bypass-guard.sh 2>/dev/null || true
#   log_irreversible_event "claude_cli_selfupdate" "blocked" "$CMD" "$TOOL" "$PWD"
#
# 기존 동작 보호:
#   - set -e 환경에서도 안전하게 source 되도록 설계 (본 파일 자체는 set -e를 걸지 않음)
#   - 로깅 실패(디렉터리 없음, 쓰기 권한 없음 등)는 전부 삼키고 0을 반환 — 훅의 차단/통과
#     판정 로직에는 그 어떤 경우에도 영향을 주지 않는다.

# NOTE: 이 파일은 source 되어 호출되므로 set -e를 남기지 않는다.

readonly _CL_6028_ID="cl-602875a5289bba26"
readonly _CL_6028_LEDGER="${HOME}/.openclaw-data/runtime/ledger/irreversible-bypass-audit.jsonl"
readonly _CL_6028_PREFIX="[irreversible-bypass-guard ${_CL_6028_ID}]"

_6028_now_iso() { TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date +%Y-%m-%dT%H:%M:%S; }

_6028_ensure_dir() {
    mkdir -p "$(dirname "$_CL_6028_LEDGER")" 2>/dev/null || true
}

# ── 공개 API ──────────────────────────────────────────────────────────────────

# log_irreversible_event <pattern_id> <action> [cmd] [tool] [cwd]
# action은 "blocked"(사전 승인 없이 차단됨) 또는 "bypassed"(env var로 사전 승인되어 통과됨)만 사용.
log_irreversible_event() {
    local pattern="${1:-unknown}" action="${2:-unknown}" cmd="${3:-}" tool="${4:-}" cwd="${5:-${PWD:-}}"
    _6028_ensure_dir
    local ts esc_cmd
    ts="$(_6028_now_iso)"
    # 명령 300자 절단 + JSON escape (python3 실패 시 조용히 빈 문자열)
    esc_cmd="$(printf '%s' "$cmd" | head -c 300 | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" 2>/dev/null)"
    [[ -n "$esc_cmd" ]] || esc_cmd='""'
    printf '{"ts":"%s","cluster":"%s","pattern":"%s","action":"%s","tool":"%s","cwd":"%s","cmd":%s}\n' \
        "$ts" "$_CL_6028_ID" "$pattern" "$action" "$tool" "$cwd" "$esc_cmd" \
        >> "$_CL_6028_LEDGER" 2>/dev/null
    return 0
}

# 세션 컨텍스트 주입용 마크다운 리포트. 최근 days일 이벤트가 없으면 빈 문자열(호출자가 skip).
generate_bypass_audit_report() {
    local days="${1:-7}"
    [[ -f "$_CL_6028_LEDGER" ]] || return 0

    REPORT_DAYS="$days" REPORT_LEDGER="$_CL_6028_LEDGER" python3 <<'PYEOF' 2>/dev/null
import json, os, re
from collections import defaultdict
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))
now = datetime.now(KST)
days = int(os.environ.get("REPORT_DAYS", "7"))
cutoff = now - timedelta(days=days)
ledger = os.environ["REPORT_LEDGER"]

def parse_ts(s):
    try:
        s2 = re.sub(r'([+-]\d{2}):?(\d{2})$', r'\1\2', s)
        s2 = re.sub(r'\.\d+', '', s2)
        return datetime.strptime(s2, '%Y-%m-%dT%H:%M:%S%z')
    except Exception:
        return None

rows = defaultdict(lambda: {"blocked": 0, "bypassed": 0, "last": ""})
total_bypassed = 0
try:
    with open(ledger, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            ts = parse_ts(rec.get("ts", ""))
            if ts is None or ts < cutoff:
                continue
            pattern = rec.get("pattern", "unknown")
            action = rec.get("action", "unknown")
            if action not in ("blocked", "bypassed"):
                continue
            rows[pattern][action] += 1
            if rec.get("ts", "") > rows[pattern]["last"]:
                rows[pattern]["last"] = rec.get("ts", "")
            if action == "bypassed":
                total_bypassed += 1
except FileNotFoundError:
    pass

if not rows:
    print("")
else:
    out = []
    out.append(f"## 🚨 비가역 작업 차단/우회 감사 (cl-602875a5289bba26)")
    out.append("")
    out.append(f"_최근 {days}일 집계, 검사 시각: {now.strftime('%Y-%m-%dT%H:%M:%S%z')}_")
    out.append("")
    out.append("| 패턴 | 차단 | 우회 | 최근 발생 |")
    out.append("|---|---:|---:|---|")
    for pattern in sorted(rows.keys()):
        v = rows[pattern]
        out.append(f"| {pattern} | {v['blocked']} | {v['bypassed']} | {v['last']} |")
    out.append("")
    if total_bypassed > 0:
        out.append(f"**주의**: 최근 {days}일 우회(bypassed) {total_bypassed}건. env var(JARVIS_*_OK=1)는 사전 설정이 있어야만 통과되므로, 각 건이 주인님의 실제 사전 승인이었는지 확인하세요.")
    else:
        out.append(f"우회 이력 없음 — 차단된 시도만 존재(정상: 사전 승인 없이는 통과되지 않음).")
    print("\n".join(out))
PYEOF
}

# 가드 자체 상태 요약
irreversible_bypass_guard_status() {
    printf "%s Guard Status\n" "$_CL_6028_PREFIX"
    printf "  ID     : %s\n" "$_CL_6028_ID"
    printf "  Ledger : %s\n" "$_CL_6028_LEDGER"
    if [[ -f "$_CL_6028_LEDGER" ]]; then
        printf "  Lines  : %s\n" "$(wc -l < "$_CL_6028_LEDGER" | tr -d ' ')"
    else
        printf "  Lines  : 0 (파일 없음, 아직 이벤트 없음)\n"
    fi
}

# ── 자동 초기화 ────────────────────────────────────────────────────────────────

_6028_ensure_dir
