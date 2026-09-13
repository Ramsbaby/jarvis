#!/usr/bin/env bash
# cron-auditor.sh — 모든 크론 정상 동작 여부 수집 → stdout으로 리포트 출력
#
# 판정 근거 (SELF-HEAL-PLAN 2a, 2026-09-04): tasks.json 태스크는 cron.log grep 이 아니라
#   ① tasks.db 마지막 종결 전이(done/failed + triggered_by + exitCode/lastError)
#   ② runtime/results/ 결과 파일 존재·나이
#   ③ 마지막 실행 시각(running 전이) 대비 주기×5 경과 여부
# 로 판정하고, 줄마다 `evidence=` 에 무엇을 보고 그렇게 판정했는지 적는다 (공백 없는 한 토큰 —
# cron-failure-tracker 가 `awk '{print $1,$2}'` 로 파싱하므로 앞 두 필드는 id·상태 고정).
# DB 에 기록이 없는 태스크만 예전 cron.log grep 으로 떨어진다. DB 와 cron.log 가 다르면 `mismatch` 를
# 붙이고 요약에 센다 — 이 수가 감사 오탐율의 원천 지표다.

set -euo pipefail
BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
NOW=$(date +%s)
TASKS_TMP=$(mktemp /tmp/cron-audit-tasks-XXXXXX)
COUNTS_TMP=$(mktemp /tmp/cron-audit-counts-XXXXXX)
DB_TMP=$(mktemp /tmp/cron-audit-db-XXXXXX)
trap 'rm -f "$TASKS_TMP" "$COUNTS_TMP" "$DB_TMP"' EXIT
echo "0 0 0" > "$COUNTS_TMP"   # ok issue mismatch

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

line_ts() {   # 로그 한 줄의 "[YYYY-MM-DD HH:MM:SS]" → epoch 초. 없으면 0
  local ts_str
  ts_str=$(echo "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1 || true)
  if [[ -z "$ts_str" ]]; then echo 0; return; fi
  date -j -f "%Y-%m-%d %H:%M:%S" "$ts_str" +%s 2>/dev/null \
    || date -d "$ts_str" +%s 2>/dev/null \
    || echo 0
}

# 예전 판정 — cron.log 한 줄 grep. DB 기록이 없는 태스크(섹션 2 직접 실행 스크립트 포함)에만 쓴다.
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

# ── tasks.db 스냅샷 (한 번에 읽는다 — 태스크마다 node 를 띄우면 80개 × 0.1s) ──────────────
# 열: id  status  term_to  term_by  term_ms  run_ms  exit_code  last_error  result_flag
#   term_* = 마지막 종결 전이(done|failed). run_ms = 마지막 running 전이. 값 없음은 '-'.
#   last_error 는 공백을 '_' 로 바꿔 한 토큰으로 만든다 (evidence 가 공백 없는 필드여야 한다).
snapshot_db() {
  local db="$BOT_HOME/state/tasks.db"
  [[ -f "$db" ]] || return 0
  node --experimental-sqlite --no-warnings - "$db" <<'JSEOF' 2>/dev/null || true
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(process.argv[2], { readOnly: true });
const tok = (v) => { const s = (v === null || v === undefined || v === '') ? '-' : String(v); return s.replace(/[\s\t]+/g, '_').slice(0, 80); };
const rows = db.prepare(`
  SELECT t.id, t.status, t.meta,
    (SELECT to_status||'|'||coalesce(triggered_by,'')||'|'||created_at FROM task_transitions x
       WHERE x.task_id=t.id AND x.to_status IN ('done','failed') ORDER BY created_at DESC, id DESC LIMIT 1) AS term,
    (SELECT max(created_at) FROM task_transitions x WHERE x.task_id=t.id AND x.to_status='running') AS run_ms
  FROM tasks t`).all();
for (const r of rows) {
  let meta = {}; try { meta = JSON.parse(r.meta || '{}'); } catch {}
  const [to, by, ms] = r.term ? r.term.split('|') : ['-', '-', '-'];
  let exit = meta.exitCode ?? '-';
  const err = meta.lastError ?? '';
  if (exit === '-' && to === 'failed') { const m = /exit_code=(\d+)/.exec(err || ''); if (m) exit = m[1]; }
  const resultFlag = (meta.result && String(meta.result).trim()) ? 'y' : '-';
  process.stdout.write([r.id, r.status, to, by || '-', ms, r.run_ms ?? '-', exit, tok(to === 'failed' ? err : ''), resultFlag].map(tok).join('\t') + '\n');
}
JSEOF
}

fmt_ms() {   # epoch ms → MM-DDTHH:MM (로컬)
  local ms="$1"
  [[ "$ms" =~ ^[0-9]+$ ]] || { echo "-"; return; }
  date -r $((ms / 1000)) '+%m-%dT%H:%M' 2>/dev/null || date -d "@$((ms / 1000))" '+%m-%dT%H:%M' 2>/dev/null || echo "-"
}

results_mtime() {   # 태스크 결과 파일 중 가장 최근 mtime (초). 없으면 0
  local tid="$1" newest=0 f m
  for f in "$BOT_HOME/results/task-outcomes/"*"-${tid}.json" "$BOT_HOME/results/${tid}/"*; do
    [[ -f "$f" ]] || continue
    m=$(log_mtime "$f")
    if [[ "$m" -gt "$newest" ]]; then newest=$m; fi
  done
  echo "$newest"
}

# DB 기반 판정. stdout: "<STATUS> <evidence>"  (evidence 는 공백 없는 한 토큰)
#   FAIL    = 마지막 종결 전이가 failed (exit code·lastError·누가 찍었는지 evidence 에)
#   STALE   = 마지막 실행(running 전이)이 주기×5 보다 오래됨
#   DEAD    = 실행 기록 자체가 없음
#   SUSPECT = DB 와 cron.log 가 같은 실행을 두고 반대로 말한다 — 티켓을 내지 않고(tracker 는 FAIL|STALE 만 집는다)
#             요약의 mismatch 로 사람에게 올린다. 모순된 근거로 코더를 보내면 코더가 할 일을 지어낸다.
judge_db() {
  local tid="$1" interval_min="$2" db_row="$3" log_ts="$4" log_result="$5"
  local status term_to term_by term_ms run_ms exit_code last_error _result_flag
  IFS=$'\t' read -r _id status term_to term_by term_ms run_ms exit_code last_error _result_flag <<< "$db_row"
  local res_m; res_m=$(results_mtime "$tid")
  local ev="db:${status}"
  if [[ "$term_to" != "-" ]]; then
    ev="${ev};last:${term_to}@$(fmt_ms "$term_ms")/${term_by}"
    [[ "$exit_code" != "-" ]] && ev="${ev};exit=${exit_code}"
    [[ "$term_to" == "failed" && "$last_error" != "-" ]] && ev="${ev};err=${last_error:0:60}"
  fi
  if [[ "$res_m" -gt 0 ]]; then ev="${ev};results:$(( (NOW - res_m) / 60 ))min"; else ev="${ev};results:none"; fi
  # cron.log 교차 확인 — 결과 줄(SUCCESS/FAILED/ERROR/DONE)의 시각을 따로 잡는다
  local log_tag="none" log_res_ts=0
  if [[ -n "$log_result" ]]; then
    log_tag=$(echo "$log_result" | grep -oE 'SUCCESS|FAILED|ERROR|DONE' | tail -1 || true); log_tag="${log_tag:-run}"
    log_res_ts=$(line_ts "$log_result")
    log_tag="${log_tag}@$(fmt_ms $((log_res_ts * 1000)))"
  elif [[ "$log_ts" -gt 0 ]]; then
    log_tag="run@$(fmt_ms $((log_ts * 1000)))"
  fi
  ev="${ev};log:${log_tag}"
  local mismatch=""
  # 로그 결과 줄이 DB 의 마지막 running 전이보다 뒤에 있어야 같은 실행이다 — 그때 부호가 반대면 한쪽 기록 경로가 틀린 것
  #   (예: 성공했는데 DB 는 stale-watcher 가 failed 로 찍음 — 2026-09-04 bot-cron done 전이 누락 사건).
  #   로그 결과가 running 전이보다 앞이면(= 이번 실행은 결과 줄이 없음, 매달림) DB 를 믿는다.
  #   cron.log 의 성공 표식은 SUCCESS 와 그 뒤의 DONE 두 가지다 (마지막 줄은 보통 DONE)
  local same_run=1
  if [[ "$run_ms" =~ ^[0-9]+$ && "$log_res_ts" -gt 0 && $((log_res_ts * 1000 + 1000)) -lt "$run_ms" ]]; then same_run=0; fi
  if [[ "$same_run" -eq 1 ]]; then
    if [[ "$term_to" == "failed" && ( "$log_tag" == SUCCESS@* || "$log_tag" == DONE@* ) ]] \
       || [[ "$term_to" == "done" && ( "$log_tag" == FAILED@* || "$log_tag" == ERROR@* ) ]]; then
      mismatch="mismatch"
    fi
  fi
  if [[ -n "$mismatch" ]]; then ev="${ev};${mismatch}"; fi

  local verdict last_run_s=0
  if [[ "$run_ms" =~ ^[0-9]+$ ]]; then last_run_s=$((run_ms / 1000)); fi
  if [[ "$term_ms" =~ ^[0-9]+$ && $((term_ms / 1000)) -gt "$last_run_s" ]]; then last_run_s=$((term_ms / 1000)); fi
  if [[ "$last_run_s" -eq 0 && "$log_ts" -gt 0 ]]; then last_run_s=$log_ts; fi
  local age_min=$(( (NOW - last_run_s) / 60 )); [[ "$age_min" -lt 0 ]] && age_min=0
  if [[ "$last_run_s" -eq 0 ]]; then verdict="DEAD"
  elif [[ -n "$mismatch" ]]; then verdict="SUSPECT"
  elif [[ "$term_to" == "failed" ]]; then verdict="FAIL"
  elif [[ "$age_min" -gt $((interval_min * 5)) ]]; then verdict="STALE"
  else verdict="OK"; fi
  echo "$verdict $ev"
}

add_count() {   # add_count ok|issue|mismatch
  read -r ok issue mismatch < "$COUNTS_TMP"
  case "$1" in
    ok)       echo "$((ok+1)) $issue $mismatch" > "$COUNTS_TMP" ;;
    mismatch) echo "$ok $issue $((mismatch+1))" > "$COUNTS_TMP" ;;
    *)        echo "$ok $((issue+1)) $mismatch" > "$COUNTS_TMP" ;;
  esac
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

snapshot_db > "$DB_TMP"

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
  db_row=$(grep -m1 "^${tid}"$'\t' "$DB_TMP" 2>/dev/null || true)
  if [[ -n "$db_row" ]]; then
    read -r status evidence <<< "$(judge_db "$tid" "$interval" "$db_row" "$last_ts" "$last_result")"
    # 나이는 DB 마지막 실행 기준 — evidence 의 last:/log: 와 같은 시계
    db_run_ms=$(cut -f6 <<< "$db_row"); db_term_ms=$(cut -f5 <<< "$db_row")
    ref_ts=0
    [[ "$db_run_ms" =~ ^[0-9]+$ ]] && ref_ts=$((db_run_ms / 1000))
    [[ "$db_term_ms" =~ ^[0-9]+$ && $((db_term_ms / 1000)) -gt "$ref_ts" ]] && ref_ts=$((db_term_ms / 1000))
    [[ "$ref_ts" -eq 0 ]] && ref_ts=$last_ts
    last_ts=$ref_ts
  else
    status=$(judge "$last_ts" "$interval" "$last_result")
    log_tag=$(echo "$last_result" | grep -oE 'SUCCESS|FAILED|ERROR|DONE' | tail -1 || true)
    evidence="db:none;log:${log_tag:-none}"
    if [[ "$last_ts" -gt 0 ]]; then evidence="${evidence}@$(fmt_ms $((last_ts * 1000)))"; fi
  fi
  if [[ "$last_ts" -eq 0 ]]; then
    age_str="NEVER"
  else
    age_str="ago=$(( (NOW - last_ts) / 60 ))min"
  fi
  printf "  %-36s %-7s %-16s  sched=%s  evidence=%s\n" "$tid" "$status" "$age_str" "$sched" "$evidence"
  if [[ "$status" == "OK" ]]; then add_count ok; else add_count issue; fi
  if [[ "$evidence" == *";mismatch"* ]]; then add_count mismatch; fi
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
  # .sh 외 node/python 스크립트도 라벨로 잡는다 — 못 잡으면 "unknown" 으로 뭉쳐 티켓 대상이 사라진다
  script=$(echo "$expanded_line" | grep -oE '/[^[:space:]]+\.(sh|mjs|js|py)' | head -1 || true)
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
  # 직접 실행 스크립트는 DB 기록이 없다 — 근거는 로그 파일 mtime 과 tail 에서 잡힌 줄(공백→_)
  evidence="log_mtime:$([[ "$last_ts" -gt 0 ]] && fmt_ms $((last_ts * 1000)) || echo none)"
  if [[ -n "$last_result" ]]; then evidence="${evidence};tail:$(echo "$last_result" | tr -s '[:space:]' '_' | cut -c1-80)"; fi
  printf "  %-40s %-6s  %-16s  log=%s  evidence=%s\n" \
    "$label" "$status" "$age_str" "$(basename "${logfile:-없음}")" "$evidence"
  if [[ "$status" == "OK" ]]; then add_count ok; else add_count issue; fi
done < <(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' \
  | grep -vE 'bot-cron\.sh|jarvis-cron\.sh|cron-safe-wrapper\.sh' || true)

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

# ── 4. output:['discord'] BYPASS 탐지 (2026-04-20 추가) ──────────────────────
# 2026-04-17 daily-usage-check plist 우회 사건 재발 방지 가드레일.
# tasks.json에 output:discord 설정된 태스크의 LaunchAgent가 bot-cron.sh를 타지
# 않으면서 자체 스크립트에도 webhook 호출이 없으면 "전송 파이프 끊김"으로 경보.

echo ""
echo "## [output:discord BYPASS 의심]"
python3 - "$BOT_HOME/config/tasks.json" "$HOME/Library/LaunchAgents" <<'PYEOF' \
  || echo "  (python 실행 실패)"
import json, os, re, sys
tasks_path, la_dir = sys.argv[1], sys.argv[2]
try:
    with open(tasks_path) as f:
        data = json.load(f)
except Exception as e:
    print(f"  (tasks.json 읽기 실패: {e})")
    sys.exit(0)
tasks = data.get('tasks', []) if isinstance(data, dict) else data
suspect = []
for t in tasks:
    if 'discord' not in (t.get('output') or []):
        continue
    tid = t.get('id')
    plist_path = None
    for prefix in ('com.jarvis.', 'ai.jarvis.'):
        p = os.path.join(la_dir, f"{prefix}{tid}.plist")
        if os.path.exists(p):
            plist_path = p
            break
    if not plist_path:
        continue
    content = open(plist_path).read()
    if 'bot-cron.sh' in content:
        continue
    m = re.search(r'<key>ProgramArguments</key>\s*<array>(.*?)</array>', content, re.S)
    args = re.findall(r'<string>(.*?)</string>', m.group(1)) if m else []
    script = next((a for a in args if a.endswith(('.sh', '.mjs', '.py'))), None)
    if not (script and os.path.exists(script)):
        continue
    body = open(script, errors='ignore').read()
    has_webhook = bool(re.search(r'webhook|curl.*(discord|webhook)|route-result\.sh', body, re.I))
    if not has_webhook:
        suspect.append((tid, script))
if suspect:
    for tid, script in suspect:
        print(f"  {tid:<36}  BYPASS  script={script}")
else:
    print("  (위험 없음)")
PYEOF

read -r ok issue mismatch < "$COUNTS_TMP"
echo ""
echo "## [요약]"
echo "  OK: ${ok}  /  ISSUE: ${issue}"
echo "  DB-로그 불일치(mismatch): ${mismatch}  — 감사 판정 오탐 지표. 0 이 아니면 tasks.db 전이 기록 경로부터 의심한다"
echo "  수집 시각: $(date '+%F %T')"