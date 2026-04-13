#!/usr/bin/env bash
set -euo pipefail

# token-ledger-query.sh — Tier 0 원장 조회/집계 CLI
# Usage:
#   token-ledger-query.sh today          # 오늘 총 지출
#   token-ledger-query.sh top [N]        # 태스크별 24h 비용 Top N (기본 10)
#   token-ledger-query.sh dedup [N]      # 결과 해시 중복 N회 이상 (기본 3)
#   token-ledger-query.sh budget         # maxBudget 대비 소비율 (24h)
#   token-ledger-query.sh task <task>    # 특정 태스크 최근 20건
#   token-ledger-query.sh stats          # 전체 요약 (태스크 수, 총 지출, 평균)

LEDGER="${BOT_HOME:-${HOME}/.jarvis}/state/token-ledger.jsonl"

if [[ ! -f "$LEDGER" ]]; then
    echo "[ERROR] ledger 파일 없음: $LEDGER" >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq 필요" >&2; exit 2; }

cmd="${1:-stats}"

case "$cmd" in
    today)
        today="$(date -u +%Y-%m-%d)"
        total=$(jq -s --arg d "$today" \
            'map(select(.ts | startswith($d))) | map(.cost_usd // 0) | add // 0' \
            "$LEDGER")
        runs=$(jq -s --arg d "$today" \
            'map(select(.ts | startswith($d))) | length' \
            "$LEDGER")
        printf 'Today UTC=%s: %d runs, $%s\n' "$today" "$runs" "$total"
        ;;

    top)
        n="${2:-10}"
        jq -s --argjson n "$n" \
            'map(select(.ts > (now - 86400 | strftime("%Y-%m-%dT%H:%M:%SZ"))))
             | group_by(.task)
             | map({
                 task: .[0].task,
                 runs: length,
                 cost: (map(.cost_usd // 0) | add),
                 input: (map(.input // 0) | add),
                 output: (map(.output // 0) | add),
                 unique_hashes: ([.[].result_hash] | unique | length)
               })
             | sort_by(-.cost)
             | .[0:$n]
             | .[]
             | "\(.task | .[0:28] | . + (" " * (30 - length))) cost=$\(.cost) runs=\(.runs) uniq=\(.unique_hashes)/\(.runs)"' \
            -r "$LEDGER"
        ;;

    dedup)
        threshold="${2:-3}"
        jq -s --argjson t "$threshold" \
            'group_by(.result_hash)
             | map(select(length >= $t))
             | map({hash: .[0].result_hash, task: .[0].task, count: length})
             | sort_by(-.count)
             | .[]
             | "\(.task | .[0:28] | . + (" " * (30 - length))) hash=\(.hash) dup=\(.count)"' \
            -r "$LEDGER"
        ;;

    budget)
        jq -s \
            'map(select(.ts > (now - 86400 | strftime("%Y-%m-%dT%H:%M:%SZ")) and (.max_budget_usd // 0) > 0))
             | group_by(.task)
             | map({
                 task: .[0].task,
                 max_budget: .[0].max_budget_usd,
                 spent: (map(.cost_usd // 0) | add),
                 pct: ((map(.cost_usd // 0) | add) / .[0].max_budget_usd * 100 | floor)
               })
             | sort_by(-.pct)
             | .[]
             | "\(.task | .[0:28] | . + (" " * (30 - length))) $\(.spent)/$\(.max_budget) = \(.pct)%"' \
            -r "$LEDGER"
        ;;

    task)
        t="${2:?task id required}"
        jq -s --arg t "$t" \
            'map(select(.task == $t))
             | sort_by(.ts)
             | .[-20:]
             | .[]
             | "\(.ts) cost=$\(.cost_usd) in=\(.input) out=\(.output) bytes=\(.result_bytes) hash=\(.result_hash)"' \
            -r "$LEDGER"
        ;;

    stats)
        jq -s \
            '{
               total_entries: length,
               earliest: (map(.ts) | min // "없음"),
               latest: (map(.ts) | max // "없음"),
               total_cost_all_time: (map(.cost_usd // 0) | add // 0),
               unique_tasks: ([.[].task] | unique | length)
             }' \
            "$LEDGER"
        ;;

    *)
        echo "Usage: $(basename "$0") [today|top N|dedup N|budget|task ID|stats]" >&2
        exit 2
        ;;
esac
