#!/usr/bin/env bash
# system-doctor.sh — Jarvis 자동 시스템 점검 (비대화형, 매일 06:00)
# 이상 없으면 한 줄 OK, WARN/FAIL 있으면 Discord jarvis-system 알림

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
source "${BOT_HOME}/lib/compat.sh" 2>/dev/null || {
  IS_MACOS=false; IS_LINUX=false
  case "$(uname -s)" in Darwin) IS_MACOS=true ;; Linux) IS_LINUX=true ;; esac
}
LOG="$BOT_HOME/logs/system-doctor.log"
ROUTE="$BOT_HOME/bin/route-result.sh"
TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# ── 결과 저장소 (임시 파일, subshell 안전) ─────────────────────────────────
RESULTS_TMP=$(mktemp "/tmp/sysdr-results-$(date +%s%N)-XXXXXX.tsv")
COUNTS_TMP=$(mktemp "/tmp/sysdr-counts-$(date +%s%N)-XXXXXX.txt")
trap 'rm -f "$RESULTS_TMP" "$COUNTS_TMP"' EXIT
echo "0 0" > "$COUNTS_TMP"   # ok warn_fail

add_result() {
  local item="$1" status="$2" note="$3"
  printf '%s\t%s\t%s\n' "$item" "$status" "$note" >> "$RESULTS_TMP"
  read -r ok wf < "$COUNTS_TMP"
  if [[ "$status" == "OK" ]]; then
    echo "$((ok+1)) $wf" > "$COUNTS_TMP"
  else
    echo "$ok $((wf+1))" > "$COUNTS_TMP"
  fi
}

# ── 1. LaunchAgents / PM2 서비스 ─────────────────────────────────────────────
check_launchagents() {
  if $IS_MACOS; then
    local launchd_out
    launchd_out=$(launchctl list 2>/dev/null || echo "")

    for svc in "ai.jarvis.discord-bot" "ai.jarvis.watchdog"; do
      local line pid
      line=$(echo "$launchd_out" | grep "$svc" || echo "")
      if [[ -z "$line" ]]; then
        add_result "launchd:$svc" "FAIL" "not loaded"
      else
        pid=$(echo "$line" | awk '{print $1}')
        if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]]; then
          add_result "launchd:$svc" "OK" "PID $pid"
        else
          local ec
          ec=$(echo "$line" | awk '{print $2}')
          add_result "launchd:$svc" "FAIL" "not running (exit=$ec)"
        fi
      fi
    done

    # Glances LaunchAgent
    if echo "$launchd_out" | grep -q "ai.jarvis.glances"; then
      add_result "launchd:glances" "OK" "loaded"
    else
      add_result "launchd:glances" "WARN" "not loaded"
    fi

    # plist 스크립트 존재 검증
    local missing_scripts=()
    local la_dir="$HOME/Library/LaunchAgents"
    if [[ -d "$la_dir" ]]; then
      while IFS= read -r plist; do
        local script_path
        script_path=$(python3 -c "
import plistlib, sys
try:
  d = plistlib.load(open('$plist', 'rb'))
  args = d.get('ProgramArguments', [])
  print(args[0] if args else '')
except: print('')
" 2>/dev/null || echo "")
        if [[ -n "$script_path" && ! -f "$script_path" ]]; then
          local svc_name
          svc_name=$(basename "$plist" .plist | sed 's/^ai\.jarvis\.//')
          missing_scripts+=("$svc_name")
        fi
      done < <(find "$la_dir" -maxdepth 1 -name 'ai.jarvis.*.plist' 2>/dev/null)
    fi
    if [[ ${#missing_scripts[@]} -gt 0 ]]; then
      add_result "launchd:config-debt" "WARN" "스크립트 없음: ${missing_scripts[*]}"
    fi
  else
    # Linux/WSL2: PM2 서비스 상태 확인
    if ! command -v pm2 &>/dev/null; then
      add_result "pm2" "FAIL" "pm2 not installed"
      return
    fi
    for svc in "jarvis-bot" "jarvis-watchdog"; do
      local status
      status=$(pm2 jlist 2>/dev/null | python3 -c "
import json,sys
try:
  procs=json.load(sys.stdin)
  match=[p for p in procs if p['name']=='$svc']
  print(match[0]['pm2_env']['status'] if match else 'not_found')
except: print('error')
" 2>/dev/null || echo "error")
      case "$status" in
        online)    add_result "pm2:$svc" "OK" "online" ;;
        not_found) add_result "pm2:$svc" "FAIL" "not registered" ;;
        *)         add_result "pm2:$svc" "FAIL" "status=$status" ;;
      esac
    done
  fi
}

# ── 2. Discord 봇 메모리 ─────────────────────────────────────────────────────
check_discord_bot() {
  local pid mem_mb
  if $IS_MACOS; then
    pid=$(launchctl list 2>/dev/null | awk '/ai\.jarvis\.discord-bot/{print $1}' | grep -E '^[0-9]+$' | head -1 || echo "")
  else
    pid=$(pgrep -f "discord-bot.js" 2>/dev/null | head -1 || echo "")
  fi
  if [[ -z "$pid" ]]; then
    add_result "discord-bot" "FAIL" "no PID"
    return
  fi
  local rss_kb
  rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
  mem_mb=$(( ${rss_kb:-0} / 1024 ))
  if [[ "$mem_mb" -gt 500 ]]; then
    add_result "discord-bot" "WARN" "PID=$pid RSS=${mem_mb}MB (high)"
  else
    add_result "discord-bot" "OK" "PID=$pid RSS=${mem_mb}MB"
  fi

  # crash count
  local crashes=0
  if [[ -f "$BOT_HOME/watchdog/crash-count" ]]; then
    crashes=$(cat "$BOT_HOME/watchdog/crash-count" 2>/dev/null || echo "0")
  fi
  if [[ "$crashes" -gt 3 ]]; then
    add_result "crash-count" "WARN" "${crashes}회"
  fi
}

# ── 3. RAG / LanceDB ─────────────────────────────────────────────────────────
check_rag() {
  local node_out
  # BOT_HOME을 env var로 전달 — 하드코딩 경로 제거
  local node_script='
const { createRequire } = await import("module");
const require = createRequire("file:///");
const BOT_HOME = process.env.BOT_HOME || (process.env.HOME + "/jarvis/runtime");
const ldb = require(BOT_HOME + "/discord/node_modules/@lancedb/lancedb/dist/index.js");
const db = await ldb.connect(BOT_HOME + "/rag/lancedb");
try {
  const t = await db.openTable("documents");
  const n = await t.countRows();
  console.log("chunks:" + n);
} catch(e) { console.log("ERROR:" + e.message.slice(0,60)); }
'
  if [[ -n "$TIMEOUT_CMD" ]]; then
    node_out=$(NODE_PATH="$BOT_HOME/discord/node_modules" \
      $TIMEOUT_CMD 20 node --input-type=module <<< "$node_script" 2>/dev/null || echo "ERROR:timeout")
  else
    node_out=$(NODE_PATH="$BOT_HOME/discord/node_modules" \
      node --input-type=module <<< "$node_script" 2>/dev/null || echo "ERROR:node_failed")
  fi

  if echo "$node_out" | grep -q "^ERROR"; then
    add_result "rag-lancedb" "FAIL" "$node_out"
  else
    local chunks
    chunks=$(echo "$node_out" | grep -oE 'chunks:[0-9]+' | grep -oE '[0-9]+' || echo "0")
    if [[ "${chunks:-0}" -eq 0 ]]; then
      add_result "rag-lancedb" "FAIL" "0 chunks"
    elif [[ "${chunks:-0}" -lt 500 ]]; then
      add_result "rag-lancedb" "WARN" "${chunks} chunks (낮음)"
    else
      add_result "rag-lancedb" "OK" "${chunks} chunks"
    fi
  fi

  # 최근 인덱싱 시간
  if [[ -f "$BOT_HOME/logs/rag-index.log" ]]; then
    local last_idx
    last_idx=$(tail -3 "$BOT_HOME/logs/rag-index.log" 2>/dev/null | tail -1 || echo "")
    log "RAG 최근 인덱싱: $last_idx"
  fi
}

# ── 4. 크론 에러 (최근 24시간) ───────────────────────────────────────────────
# task_XXXXXX_ 패턴: dev-task-daemon이 생성하는 임시 태스크 ID.
# 구조적 크론 스크립트 오류가 아니므로 집계에서 제외한다.
check_cron_errors() {
  if [[ ! -f "$BOT_HOME/logs/cron.log" ]]; then
    add_result "cron-errors" "OK" "로그 없음"
    return
  fi
  local cutoff
  cutoff=$(date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

  local err_count task_count
  if [[ -n "$cutoff" ]]; then
    err_count=$(grep -E 'FAILED|ERROR|CRITICAL' "$BOT_HOME/logs/cron.log" 2>/dev/null \
      | grep -vE 'task_[0-9]+_' \
      | awk -v c="[$cutoff" '$0 >= c' | wc -l) || err_count=0
    task_count=$(grep -E 'FAILED|ERROR|CRITICAL' "$BOT_HOME/logs/cron.log" 2>/dev/null \
      | grep -E 'task_[0-9]+_' \
      | awk -v c="[$cutoff" '$0 >= c' | wc -l) || task_count=0
  else
    err_count=$(grep -E 'FAILED|ERROR|CRITICAL' "$BOT_HOME/logs/cron.log" 2>/dev/null \
      | grep -vE 'task_[0-9]+_' | wc -l) || err_count=0
    task_count=$(grep -E 'FAILED|ERROR|CRITICAL' "$BOT_HOME/logs/cron.log" 2>/dev/null \
      | grep -E 'task_[0-9]+_' | wc -l) || task_count=0
  fi
  err_count=$((${err_count:-0}))
  task_count=$((${task_count:-0}))

  local task_note=""
  [[ "$task_count" -gt 0 ]] && task_note=" (+task ${task_count}건 제외)"

  if (( err_count > 10 )); then
    add_result "cron-errors" "FAIL" "24h ${err_count}건${task_note}"
  elif (( err_count > 0 )); then
    add_result "cron-errors" "WARN" "24h ${err_count}건${task_note}"
  else
    add_result "cron-errors" "OK" "에러 없음${task_note}"
  fi
}

# ── 5. E2E 테스트 결과 ───────────────────────────────────────────────────────
check_e2e() {
  if [[ ! -f "$BOT_HOME/logs/e2e-cron.log" ]]; then
    add_result "e2e" "WARN" "아직 미실행"
    return
  fi
  local pass fail total
  pass=$(grep -c 'PASS' "$BOT_HOME/logs/e2e-cron.log" 2>/dev/null) || pass=0
  fail=$(grep -c 'FAIL' "$BOT_HOME/logs/e2e-cron.log" 2>/dev/null) || fail=0
  total=$(( pass + fail ))
  if (( fail >= 3 )); then
    add_result "e2e" "FAIL" "${fail}개 실패 / 전체 ${total}"
  elif (( fail > 0 )); then
    add_result "e2e" "WARN" "${fail}개 실패 / 전체 ${total}"
  else
    add_result "e2e" "OK" "${pass}/${total} 통과"
  fi
}

# ── 6. Glances API ──────────────────────────────────────────────────────────
check_glances() {
  local cpu_info
  if [[ -n "$TIMEOUT_CMD" ]]; then
    cpu_info=$($TIMEOUT_CMD 5 curl -sf "http://localhost:61208/api/4/cpu" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'CPU {d[\"total\"]}%')" 2>/dev/null || echo "")
  else
    cpu_info=$(curl -sf --max-time 5 "http://localhost:61208/api/4/cpu" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'CPU {d[\"total\"]}%')" 2>/dev/null || echo "")
  fi
  if [[ -z "$cpu_info" ]]; then
    add_result "glances" "FAIL" "응답없음"
  else
    add_result "glances" "OK" "$cpu_info"
  fi
}

# ── 7. CLI 도구 ──────────────────────────────────────────────────────────────
check_cli_tools() {
  local missing=()
  command -v memo >/dev/null 2>&1 || missing+=("memo")
  command -v gog >/dev/null 2>&1 || missing+=("gog")
  if [[ ${#missing[@]} -gt 0 ]]; then
    add_result "cli-tools" "WARN" "없음: ${missing[*]}"
  else
    add_result "cli-tools" "OK" "memo/gog 정상"
  fi
}

# ── 8. 디스크 ────────────────────────────────────────────────────────────────
check_disk() {
  local pct
  pct=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}' 2>/dev/null || echo "0")
  if [[ "$pct" -gt 90 ]]; then
    add_result "disk" "FAIL" "${pct}% 사용"
  elif [[ "$pct" -gt 80 ]]; then
    add_result "disk" "WARN" "${pct}% 사용"
  else
    add_result "disk" "OK" "${pct}% 사용"
  fi
}

# ── 모든 체크 실행 ────────────────────────────────────────────────────────────
log "system-doctor 시작"

check_launchagents
check_discord_bot
check_rag
check_cron_errors
check_e2e
check_glances
check_cli_tools
check_disk

read -r ok wf < "$COUNTS_TMP"
log "점검 완료 — OK:$ok WARN/FAIL:$wf"

# ── 결과 포맷팅 ───────────────────────────────────────────────────────────────
if [[ "$wf" -eq 0 ]]; then
  log "all OK — silent (이상 없으면 Discord 전송 안 함)"
  exit 0
fi

# WARN/FAIL 있으면 상세 리포트
REPORT="━━━━━━━━━━━━━━━━━━━━
🩺 Jarvis 점검 — $(date '+%m-%d %H:%M')
━━━━━━━━━━━━━━━━━━━━
✅ 정상: ${ok}개  |  ⚠️ 이상: ${wf}개
"

ISSUES=""
OKSUMMARY=""
while IFS=$'\t' read -r item status note; do
  if [[ "$status" == "OK" ]]; then
    OKSUMMARY="${OKSUMMARY}  ✅ ${item}: ${note}\n"
  elif [[ "$status" == "WARN" ]]; then
    ISSUES="${ISSUES}  ⚠️ ${item}: ${note}\n"
  else
    ISSUES="${ISSUES}  ❌ ${item}: ${note}\n"
  fi
done < "$RESULTS_TMP"

if [[ -n "$ISSUES" ]]; then
  REPORT="${REPORT}
[이상 항목]
$(printf '%b' "$ISSUES")"
fi

if [[ -n "$OKSUMMARY" ]]; then
  REPORT="${REPORT}
[정상 항목]
$(printf '%b' "$OKSUMMARY")"
fi

REPORT="${REPORT}━━━━━━━━━━━━━━━━━━━━"

log "Discord 전송 (이상 ${wf}건)"

# 시각화 카드 전송 (TSV → JSON → discord-visual.mjs)
VISUAL_SCRIPT="$BOT_HOME/scripts/discord-visual.mjs"
if command -v node >/dev/null 2>&1 && [[ -f "$VISUAL_SCRIPT" ]]; then
  ITEMS_JSON=$(python3 -c "
import sys, json
rows = []
for line in open('${RESULTS_TMP}'):
    parts = line.rstrip('\n').split('\t')
    if len(parts) >= 3:
        rows.append({'item': parts[0], 'status': parts[1], 'note': parts[2]})
print(json.dumps({'items': rows, 'ok': ${ok}, 'warn': ${wf}, 'timestamp': '$(date '+%Y-%m-%d %H:%M')'}))
" 2>/dev/null || echo "")
  if [[ -n "$ITEMS_JSON" ]]; then
    node "$VISUAL_SCRIPT" --type system-doctor --data "$ITEMS_JSON" --channel jarvis-system \
      2>>"$LOG" || true
  else
    [[ -f "$ROUTE" ]] && "$ROUTE" discord system-doctor "$REPORT" jarvis-system 2>/dev/null || true
  fi
else
  [[ -f "$ROUTE" ]] && "$ROUTE" discord system-doctor "$REPORT" jarvis-system 2>/dev/null || true
fi