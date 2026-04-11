#!/usr/bin/env bash
# cron-auditor.sh — 모든 크론 정상 동작 여부 수집 → stdout으로 리포트 출력

set -euo pipefail
BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
NOW=$(date +%s)
TASKS_TMP=$(mktemp /tmp/cron-audit-tasks-XXXXXX.tsv)
COUNTS_TMP=$(mktemp /tmp/cron-audit-counts-XXXXXX.txt)
trap 'rm -f "$TASKS_TMP" "$COUNTS_TMP"' EXIT
echo "0 0" > "$COUNTS_TMP"   # ok issue

# ── 헬퍼 ─────────────────────────────────────────────────────────────────────

# cron 표현식(문자열 전체) → 인터벌(분) — 언쿼팅 glob 방지를 위해 1인자로 받음
cron_interval_minutes() {
  local min_f hour_f dom_f mon_f dow_f
  read -r min_f hour_f dom_f mon_f dow_f <<< "$1"
  dow_f="${dow_f:-*}"
  if [[ "$dom_f" != "*" && "$dom_f" != *"/"* ]]; then echo 43200; return; fi
  if [[ "$dow_f" != "*" && "$dow_f" != *"/"* ]]; then echo 10080; return; fi
  if [[ "$hour_f" != "*" && "$hour_f" != *"/"* ]]; then echo 1440; return; fi
  if [[ "$min_f" == "0" ]]; then echo 60; return; fi
  if [[ "$min_f" =~ ^\*/([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  echo 60
}

log_mtime() {
  local f="$1"
  if [[ ! -f "$f" ]]; then echo 0; return; fi
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0
}

last_task_ts() {
  local task_id="$1" line ts_str
  line=$(grep "\[$task_id\]" "$BOT_HOME/logs/cron.log" 2>/dev/null | tail -1 || true)
  if [[ -z "$line" ]]; then echo 0; return; fi
  ts_str=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1 || true)
  if [[ -z "$ts_str" ]]; then echo 0; return; fi
  date -j -f "%Y-%m-%d %H:%M:%S" "$ts_str" +%s 2>/dev/null \
    || date -d "$ts_str" +%s 2>/dev/null \
    || echo 0
}

last_task_result() {
  grep "\[$1\]" "$BOT_HOME/logs/cron.log" 2>/dev/null \
    | grep -E 'SUCCESS|FAILED|ERROR|DONE' | tail -1 || true
}

judge() {
  local last_ts="$1" interval_min="$2" last_result="$3"
  local age_min=$(( (NOW - last_ts) / 60 ))
  if [[ "$last_ts" -eq 0 ]]; then echo "DEAD"; return; fi
  # 시계 오류/타임존 불일치로 age_min이 음수가 될 수 있음 → 0으로 클램핑
  if [[ "$age_min" -lt 0 ]]; then age_min=0; fi
  if echo "$last_result" | grep -qE 'FAILED|ERROR'; then echo "FAIL"; return; fi
  if [[ "$age_min" -gt $((interval_min * 5)) ]]; then echo "STALE"; return; fi
  echo "OK"
}

add_count() {   # add_count ok|issue
  read -r ok issue < "$COUNTS_TMP"
  if [[ "$1" == "ok" ]]; then
    echo "$((ok+1)) $issue" > "$COUNTS_TMP"
  else
    echo "$ok $((issue+1))" > "$COUNTS_TMP"
  fi
}

# ── 1. tasks.json 태스크 ──────────────────────────────────────────────────────

python3 - "$BOT_HOME/config/tasks.json" <<'PYEOF' 2>/dev/null > "$TASKS_TMP" || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
tasks = data.get('tasks', []) if isinstance(data, dict) else data
for t in tasks:
    print('\t'.join([
        t.get('id',''),
        t.get('schedule') or '',
        str(t.get('enabled', True))
    ]))
PYEOF

echo "## [tasks.json 태스크]"
while IFS=$'\t' read -r tid sched enabled; do
  if [[ -z "$tid" ]]; then continue; fi
  if [[ "$enabled" == "False" ]]; then
    printf "  %-36s DISABLED\n" "$tid"
    continue
  fi
  if [[ -z "$sched" ]]; then
    printf "  %-36s NO_SCHED\n" "$tid"
    continue
  fi
  interval=$(cron_interval_minutes "$sched" 2>/dev/null || echo 1440)
  last_ts=$(last_task_ts "$tid")
  last_result=$(last_task_result "$tid")
  status=$(judge "$last_ts" "$interval" "$last_result")
  if [[ "$last_ts" -eq 0 ]]; then
    age_str="NEVER"
  else
    age_str="ago=$(( (NOW - last_ts) / 60 ))min"
  fi
  printf "  %-36s %-6s  %-16s  sched=%s\n" "$tid" "$status" "$age_str" "$sched"
  if [[ "$status" == "OK" ]]; then add_count ok; else add_count issue; fi
done < "$TASKS_TMP"

# ── 2. 직접 실행 크론 스크립트 ───────────────────────────────────────────────

echo ""
echo "## [직접 실행 크론 스크립트]"
while IFS= read -r line; do
  sched_fields=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
  interval=$(cron_interval_minutes "$sched_fields" 2>/dev/null || echo 1440)
  # $HOME / ~ 확장 후 추출 ($HOME과 ~는 crontab에 리터럴로 저장되므로 명시적 치환 필요)
  expanded_line=$(echo "$line" | sed "s|\$HOME|$HOME|g; s|~/|$HOME/|g")
  logfile=$(echo "$expanded_line" | grep -oE '>>[[:space:]]*[^[:space:]]+' \
    | head -1 | sed 's/>>[[:space:]]*//' || true)
  script=$(echo "$expanded_line" | grep -oE '/[^[:space:]]+\.sh' | head -1 || true)
  label=$(basename "${script:-unknown}")

  if [[ -n "$script" && ! -f "$script" ]]; then
    printf "  %-40s MISSING  %s\n" "$label" "$script"
    add_count issue
    continue
  fi

  last_ts=0
  if [[ -n "$logfile" && -f "$logfile" ]]; then
    last_ts=$(log_mtime "$logfile")
  fi
  last_result=""
  if [[ -n "$logfile" && -f "$logfile" ]]; then
    last_result=$(tail -20 "$logfile" 2>/dev/null \
      | grep -iE 'error|fail|exit [^0]' | tail -1 || true)
  fi

  status=$(judge "$last_ts" "$interval" "$last_result")
  if [[ "$last_ts" -eq 0 ]]; then
    age_str="NEVER"
  else
    age_str="ago=$(( (NOW - last_ts) / 60 ))min"
  fi
  printf "  %-40s %-6s  %-16s  log=%s\n" \
    "$label" "$status" "$age_str" "$(basename "${logfile:-없음}")"
  if [[ "$status" == "OK" ]]; then add_count ok; else add_count issue; fi
done < <(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' \
  | grep -vE 'bot-cron\.sh|jarvis-cron\.sh' || true)

# ── 3. 최근 48시간 에러 요약 ─────────────────────────────────────────────────

echo ""
echo "## [최근 48시간 cron.log 에러]"
CUTOFF=$(date -v-48H '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
  || date -d '48 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
if [[ -n "$CUTOFF" ]]; then
  grep -E 'FAILED|ERROR' "$BOT_HOME/logs/cron.log" 2>/dev/null \
    | awk -v c="[$CUTOFF" '$0 >= c' \
    | grep -v 'not found in tasks.json' | tail -20 || echo "  (없음)"
else
  grep -E 'FAILED|ERROR' "$BOT_HOME/logs/cron.log" 2>/dev/null | tail -20 || echo "  (없음)"
fi

read -r ok issue < "$COUNTS_TMP"
echo ""
echo "## [요약]"
echo "  OK: ${ok}  /  ISSUE: ${issue}"
echo "  수집 시각: $(date '+%F %T')"
