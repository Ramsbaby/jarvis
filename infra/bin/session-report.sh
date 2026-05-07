#!/usr/bin/env bash
# session-report.sh — 토큰 사용 분석 HTML 리포트 (P3)
#
# 영상 벤치마킹 (Session Report 패턴):
#   token-ledger.jsonl을 분석해 비용 명세 HTML 리포트 생성.
#   - 기간: 7d (default) / 30d / 90d (env: SESSION_REPORT_DAYS)
#   - top 10 비싼 task / 모델별 분포 / 캐시 hit rate / 일별 추이
#
# 매주 일요일 23:50 cron 또는 수동 실행 (--days 30).
# 결과: ~/jarvis/runtime/state/session-report-YYYYMMDD.html

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER="${BOT_HOME}/state/token-ledger.jsonl"
LOG_FILE="${BOT_HOME}/logs/session-report.log"
DAYS="${SESSION_REPORT_DAYS:-7}"
OUT_HTML="${BOT_HOME}/state/session-report-$(date +%Y%m%d).html"
OUT_JSON="${BOT_HOME}/state/session-report.json"

mkdir -p "$(dirname "$LOG_FILE")"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [session-report] $*" | tee -a "$LOG_FILE"; }

[[ -f "$LEDGER" ]] || { log "FATAL: ledger 없음 ($LEDGER)"; exit 1; }

log "=== Session Report start (days=$DAYS) ==="

CUTOFF=$(date -v-"${DAYS}"d '+%Y-%m-%d' 2>/dev/null || date -d "${DAYS} days ago" '+%Y-%m-%d')

# 기간 필터링 + 분석 (jq stream)
DATA=$(awk -v c="$CUTOFF" '$0 >= "{\"ts\":\""c {print}' "$LEDGER" 2>/dev/null \
  | jq -s '
    map(select(.task and (.cost_usd != null))) as $rows |
    {
      total_rows: ($rows | length),
      total_cost: ($rows | map(.cost_usd // 0) | add // 0),
      total_input: ($rows | map(.input // 0) | add // 0),
      total_output: ($rows | map(.output // 0) | add // 0),
      total_cache_read: ($rows | map(.cache_read // 0) | add // 0),
      cache_hit_rate: (
        ($rows | map(.cache_read // 0) | add // 0) /
        (($rows | map((.cache_read // 0) + (.input // 0)) | add // 1))
      ),
      top_tasks: ($rows | group_by(.task) | map({
        task: .[0].task,
        runs: length,
        cost: (map(.cost_usd // 0) | add),
        input: (map(.input // 0) | add),
        output: (map(.output // 0) | add)
      }) | sort_by(-.cost) | .[0:10]),
      by_model: ($rows | group_by(.model // "default") | map({
        model: (.[0].model // "default"),
        runs: length,
        cost: (map(.cost_usd // 0) | add)
      }) | sort_by(-.cost)),
      daily: ($rows | group_by(.ts[0:10]) | map({
        date: .[0].ts[0:10],
        cost: (map(.cost_usd // 0) | add),
        runs: length
      }) | sort_by(.date))
    }
  ')

echo "$DATA" > "$OUT_JSON"

TOTAL_COST=$(echo "$DATA" | jq -r '.total_cost | tostring | .[0:8]')
TOTAL_ROWS=$(echo "$DATA" | jq -r '.total_rows')
CACHE_RATE=$(echo "$DATA" | jq -r '(.cache_hit_rate * 100) | tostring | .[0:5]')

# HTML 생성 (크림/세리프/테라코타 — Opus 4.7 디자인 정책)
{
cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="ko"><head><meta charset="utf-8">
<title>Jarvis Session Report</title>
<style>
  body { font-family: Georgia, "Fraunces", serif; background: #F4F1EA; color: #2A2622; max-width: 980px; margin: 40px auto; padding: 20px; line-height: 1.7; }
  h1 { font-family: -apple-system, "Helvetica Neue", sans-serif; color: #D4622A; border-bottom: 3px solid #D4622A; padding-bottom: 8px; letter-spacing: -0.5px; }
  h2 { font-family: -apple-system, sans-serif; color: #8B4513; margin-top: 32px; border-left: 4px solid #D4622A; padding-left: 12px; }
  table { border-collapse: collapse; width: 100%; margin: 16px 0; background: white; border-radius: 4px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  th { background: #D4622A; color: white; text-align: left; padding: 10px 14px; font-family: sans-serif; font-size: 13px; }
  td { padding: 10px 14px; border-bottom: 1px solid #EAE5DC; }
  tr:hover td { background: #FAF6EE; }
  .num { font-variant-numeric: tabular-nums; text-align: right; font-family: -apple-system, monospace; }
  .pill { display: inline-block; padding: 2px 8px; border-radius: 10px; background: #FAF6EE; font-size: 12px; font-family: monospace; }
  .total { font-size: 24px; color: #D4622A; font-weight: bold; }
  .meta { color: #8B7B6E; font-size: 13px; }
</style>
</head><body>
HTML_HEAD

cat <<HTML_BODY
<h1>📊 Jarvis Session Report</h1>
<p class="meta">기간: 최근 ${DAYS}일 ($(echo "$CUTOFF") ~ $(date '+%Y-%m-%d')) · 생성: $(date '+%Y-%m-%d %H:%M KST')</p>

<h2>요약</h2>
<table>
  <tr><th>총 비용 (추정)</th><td class="num"><span class="total">\$${TOTAL_COST}</span></td></tr>
  <tr><th>총 호출</th><td class="num">${TOTAL_ROWS} 회</td></tr>
  <tr><th>캐시 hit rate</th><td class="num">${CACHE_RATE}%</td></tr>
  <tr><th>총 input 토큰</th><td class="num">$(echo "$DATA" | jq -r '.total_input | tostring')</td></tr>
  <tr><th>총 output 토큰</th><td class="num">$(echo "$DATA" | jq -r '.total_output | tostring')</td></tr>
</table>

<h2>비싼 Task TOP 10</h2>
<table>
  <tr><th>#</th><th>Task</th><th>호출 수</th><th>비용 (USD)</th><th>Input</th><th>Output</th></tr>
HTML_BODY

echo "$DATA" | jq -r '.top_tasks | to_entries[] | "  <tr><td>\(.key + 1)</td><td><span class=\"pill\">\(.value.task)</span></td><td class=\"num\">\(.value.runs)</td><td class=\"num\">$\(.value.cost | . * 10000 | floor / 10000)</td><td class=\"num\">\(.value.input)</td><td class=\"num\">\(.value.output)</td></tr>"'

cat <<HTML_MID
</table>

<h2>모델별 분포</h2>
<table>
  <tr><th>모델</th><th>호출</th><th>비용</th></tr>
HTML_MID

echo "$DATA" | jq -r '.by_model[] | "  <tr><td>\(.model)</td><td class=\"num\">\(.runs)</td><td class=\"num\">$\(.cost | . * 10000 | floor / 10000)</td></tr>"'

cat <<HTML_DAILY
</table>

<h2>일별 추이</h2>
<table>
  <tr><th>날짜</th><th>호출</th><th>비용</th></tr>
HTML_DAILY

echo "$DATA" | jq -r '.daily[] | "  <tr><td>\(.date)</td><td class=\"num\">\(.runs)</td><td class=\"num\">$\(.cost | . * 10000 | floor / 10000)</td></tr>"'

cat <<'HTML_FOOT'
</table>

<p class="meta">⚙️ 생성: <code>~/jarvis/infra/bin/session-report.sh</code> · 데이터: <code>~/jarvis/runtime/state/token-ledger.jsonl</code></p>
<p class="meta">⚠️ 주의: cost_usd는 토큰×rate 추정값. Claude Max 정액제 실제 청구와 다를 수 있음.</p>

</body></html>
HTML_FOOT
} > "$OUT_HTML"

log "HTML: $OUT_HTML / 총 비용 \$${TOTAL_COST} / 호출 ${TOTAL_ROWS}회 / 캐시 ${CACHE_RATE}%"
log "=== Session Report end ==="
exit 0
