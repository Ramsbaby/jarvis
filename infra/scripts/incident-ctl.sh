#!/usr/bin/env bash
# incident-ctl.sh — 사고 원장 CLI (SELF-HEAL-PLAN 4a)
#
#   incident-ctl.sh open  --source <src> --key <key> --title "<제목>" [--severity low|med|high]
#                         [--cause "<가설>"] [--fix "<커밋/티켓>"] [--evidence '<json>'] [--by human|auto]
#   incident-ctl.sh close <id|key> --fix "<커밋/티켓>" [--cause "<가설>"] [--by human|auto]
#   incident-ctl.sh update <id|key> [--cause ..] [--fix ..] [--severity ..] [--title ..] [--note ".."]
#   incident-ctl.sh reopen <id|key> [--note ".."]
#   incident-ctl.sh discard <id|key> --reason "<오탐·시험 사유>"
#   incident-ctl.sh list [--open|--closed|--all] [--source <src>] [--json]
#   incident-ctl.sh show <id|key>
#   incident-ctl.sh count [--open|--all]
#   incident-ctl.sh summary
#
# source 관례: runtime-guard · coder-review · coder-merge · integrity · loss · manual · e2e
# 닫힘(close)은 structural_fix 없이는 거부된다 — 원장의 존재 이유가 "구조 수정이 닫혔는가" 이기 때문.
# 사고가 아닌 행(시험 호출·센서 오탐)은 close 가 아니라 discard 로 — 센서 오탐율의 재료가 된다.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BOT_HOME="${BOT_HOME:-$HOME/.openclaw-data/runtime}"
export BOT_HOME
INFRA_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/incident-ledger.sh
source "${INFRA_DIR}/lib/incident-ledger.sh"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1
shift

SOURCE="" KEY="" TITLE="" SEVERITY="" CAUSE="" FIX="" EVIDENCE="" BY="" NOTE="" REASON="" FILTER="" JSON=0
TARGET=""
case "$cmd" in
    close|update|reopen|discard|show) TARGET="${1:-}"; [[ -n "$TARGET" ]] || usage 1; shift ;;
esac
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE="${2:-}"; shift 2 ;;
        --key) KEY="${2:-}"; shift 2 ;;
        --title) TITLE="${2:-}"; shift 2 ;;
        --severity) SEVERITY="${2:-}"; shift 2 ;;
        --cause) CAUSE="${2:-}"; shift 2 ;;
        --fix) FIX="${2:-}"; shift 2 ;;
        --evidence) EVIDENCE="${2:-}"; shift 2 ;;
        --by) BY="${2:-}"; shift 2 ;;
        --note) NOTE="${2:-}"; shift 2 ;;
        --reason) REASON="${2:-}"; shift 2 ;;
        --open|--closed|--all) FILTER="${1#--}"; shift ;;
        --json) JSON=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; usage 1 ;;
    esac
done

case "$cmd" in
    open)
        [[ -n "$SOURCE" && -n "$KEY" && -n "$TITLE" ]] || { echo "open: --source --key --title 필요" >&2; exit 1; }
        rc=0
        id=$(incident_open "$SOURCE" "$KEY" "$TITLE" "${SEVERITY:-med}" "$EVIDENCE" "$CAUSE" "$FIX" "${BY:-human}") || rc=$?
        case "$rc" in
            0) echo "opened $id" ;;
            3) echo "already-open $id" ;;
            4) echo "recurred $id (닫힌 사고의 재발 — reopen 기록)" ;;
            *) exit "$rc" ;;
        esac
        ;;
    close)
        [[ -n "$FIX" ]] || { echo "close: --fix \"<커밋/티켓>\" 없이는 닫지 않습니다" >&2; exit 2; }
        rc=0; id=$(incident_close "$TARGET" "$FIX" "$CAUSE" "${BY:-human}") || rc=$?
        case "$rc" in 0) echo "closed $id" ;; 3) echo "already-closed $id" ;; *) exit "$rc" ;; esac
        ;;
    update)
        patch=$(jq -nc --arg c "$CAUSE" --arg f "$FIX" --arg s "$SEVERITY" --arg t "$TITLE" \
            '{} + (if $c != "" then {cause_hypothesis:$c} else {} end)
                + (if $f != "" then {structural_fix:$f} else {} end)
                + (if $s != "" then {severity:$s} else {} end)
                + (if $t != "" then {title:$t} else {} end)')
        [[ "$patch" != "{}" || -n "$NOTE" ]] || { echo "update: 바꿀 필드가 없습니다" >&2; exit 1; }
        id=$(incident_update "$TARGET" "$patch" "$NOTE"); echo "updated $id"
        ;;
    reopen)
        rc=0; id=$(incident_reopen "$TARGET" "${NOTE:-reopen}") || rc=$?
        case "$rc" in 0) echo "reopened $id" ;; 3) echo "already-open $id" ;; *) exit "$rc" ;; esac
        ;;
    discard)
        [[ -n "$REASON" ]] || { echo "discard: --reason 필요" >&2; exit 2; }
        rc=0; id=$(incident_discard "$TARGET" "$REASON") || rc=$?
        case "$rc" in 0) echo "discarded $id" ;; 3) echo "already-closed $id" ;; *) exit "$rc" ;; esac
        ;;
    show)
        incident_find "$TARGET" | jq .
        ;;
    count)
        if [[ "$FILTER" == "all" ]]; then incident_state | jq 'length'; else incident_open_count; fi
        ;;
    list)
        f="${FILTER:-open}"
        st=$(incident_state | jq -c --arg f "$f" '
            map(select(if $f=="open" then .closed_at==null elif $f=="closed" then .closed_at!=null else true end))')
        [[ -z "$SOURCE" ]] || st=$(jq -c --arg s "$SOURCE" 'map(select(.source==$s))' <<<"$st")
        if (( JSON )); then jq . <<<"$st"; exit 0; fi
        n=$(jq 'length' <<<"$st")
        echo "사고 ${f}: ${n}건"
        jq -r '.[] | "\(.id)  \(.severity | .[0:1] | ascii_upcase)  \(.opened_at[0:10])  [\(.source)]  \(.title)"
                     + (if .discarded then "  ✖ 폐기 \(.closed_at[0:10]) \(.discard_reason)"
                        elif .closed_at then "  ✔ \(.closed_at[0:10]) \(.structural_fix)" else "" end)' <<<"$st"
        ;;
    summary)
        incident_summary
        ;;
    *) usage 1 ;;
esac
