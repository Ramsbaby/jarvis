#!/usr/bin/env bash
# system-doctor.sh — Jarvis 자동 시스템 점검 (비대화형, 매일 06:00 KST)
# 실행 주체: 오픈클로 잡 `jarvis-system-doctor` (2026-09-19 등록. 그 전엔 crontab 06:00 이었다)
# 이상 없으면 원장·로그만 남기고 침묵, WARN/FAIL 이 있으면 알림 게이트를 거쳐 송출한다.
#
# 2026-09-19 정비 (오픈클로 이관 회차 8 이후 첫 손질) — 매일 거짓 🔴 를 내던 검사를 걷어냈다:
#   - discord-bot.js·watchdog LaunchAgent 는 2026-09-10 은퇴했다. 디스코드는 오픈클로 채널이 맡는다.
#     → check_discord_bot(항상 "no PID" FAIL) 을 check_openclaw(게이트웨이 RSS + 채널 연결)로 교체.
#   - LaunchAgent 이름을 스크립트에 박지 않는다. ~/Library/LaunchAgents 의 plist 를 읽어
#     KeepAlive(상주)면 PID 를 요구하고, 캘린더/주기형은 로드 여부만 본다. 이름이 바뀌어도 오탐이 없다.
#   - check_rag 의 모듈 경로 $BOT_HOME/discord/node_modules 는 이관 뒤 존재하지 않는다 → 후보 순회.
#   - check_e2e 가 로그 "전체"의 PASS/FAIL 줄을 세어 누적 실패(37줄)가 영구 FAIL 을 냈다 → 마지막 RESULT 줄만 본다.
#   - crash-count(레거시 watchdog 산출물, 2026-09-10 이후 10 고정) WARN 제거.
#   - Linux/PM2 분기 제거 — jarvis-bot/jarvis-watchdog 은 은퇴했고 이 잡은 맥미니에서만 돈다.
#   - 원장 스키마: overall/red/yellow 필수. 판정은 FAIL>0 → red, WARN>0 → yellow, 그 외 green.
#   - 송출 경로: 옛 웹훅 카드(discord-visual.mjs)는 2026-09-10 의도적으로 비활성 — 호출해도 파일에만 남았다.
#     alert-send.sh 로 바꿨다. red → critical(오픈클로 디스코드 채널로 즉시), yellow → warning(억제 로그).
#     2026-09-13 주인님 결정("긴급만 살아있는 경로로") 그대로다.
#
# 환경변수:
#   BOT_HOME               런타임 루트 (기본 ~/.openclaw-data/runtime; ~/.jarvis 는 이곳의 심링크)
#   JARVIS_NO_EXTERNAL=1   검증 실행 — 알림 게이트 상태와 외부 송출을 건드리지 않는다. 원장·로그는 남긴다.
#   DOCTOR_LEDGER          원장 경로 재지정 (테스트 격리용)
#   OPENCLAW_BIN           오픈클로 CLI (기본 ~/bin/openclaw 래퍼)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
source "${BOT_HOME}/lib/compat.sh" 2>/dev/null || {
  IS_MACOS=false; IS_LINUX=false
  case "$(uname -s)" in Darwin) IS_MACOS=true ;; Linux) IS_LINUX=true ;; esac
}
LOG="$BOT_HOME/logs/system-doctor.log"
LEDGER="${DOCTOR_LEDGER:-${BOT_HOME}/state/doctor-ledger.jsonl}"
ALERT="${BOT_HOME}/scripts/alert-send.sh"
OPENCLAW_BIN="${OPENCLAW_BIN:-${HOME}/bin/openclaw}"
TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# 게이트웨이 RSS 임계 — 추정치. 실측 2026-09-19: 가동 5일차 979MB. 누수가 아니면 2GB 를 넘지 않는다고 본다.
GATEWAY_RSS_WARN_MB=2048
GATEWAY_RSS_FAIL_MB=4096

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

mkdir -p "$(dirname "$LOG")" "$(dirname "$LEDGER")"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# run_with_timeout <초> <명령...>
run_with_timeout() {
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_CMD" ]]; then "$TIMEOUT_CMD" "$secs" "$@"; else "$@"; fi
}
# "YYYY-mm-dd HH:MM:SS" → epoch (macOS/Linux)
epoch_of() {
  date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null \
    || date -d "$1" +%s 2>/dev/null || echo 0
}
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# ── 결과 저장소 (임시 파일, subshell 안전) ─────────────────────────────────
RESULTS_TMP=$(mktemp "/tmp/sysdr-results-XXXXXX.tsv")
COUNTS_TMP=$(mktemp "/tmp/sysdr-counts-XXXXXX.txt")
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

# ── 1. LaunchAgents ──────────────────────────────────────────────────────────
# plist 가 정본이다. ai.jarvis.* / ai.openclaw.* / com.jarvis.* 를 전부 읽어
#   KeepAlive=true(상주)   → launchctl 에 PID 가 있어야 OK
#   StartInterval/StartCalendarInterval(예약) → 로드만 돼 있으면 OK
# disabled/ 하위 디렉토리는 maxdepth 1 로 자연히 제외된다.
# `launchctl disable` 로 꺼 둔 것은 사람의 의도다 — 죽음으로 세지 않는다 (2026-09-26).
#   interview-verifier 가 09-22 부터 disable 상태인데 이 검사가 나흘 연속 red 를 냈고, 상태가 안 바뀌니
#   "무변화" 억제에 걸려 매일 red 가 기본값이 됐다. 감지기(orchestrator-scan.py)는 09-24 에 같은 수정을 받았다.
check_launchagents() {
  if ! $IS_MACOS; then
    add_result "launchd" "OK" "macOS 아님 — 생략"
    return
  fi
  local la_dir="$HOME/Library/LaunchAgents" launchd_out disabled_out
  launchd_out=$(launchctl list 2>/dev/null || echo "")
  disabled_out=$(launchctl print-disabled "gui/$(id -u)" 2>/dev/null || echo "")

  local plist label mode prog line pid ec
  local total=0 daemons=0 scheduled=0 bad=0 stopped=0
  local missing_scripts=()
  while IFS= read -r plist; do
    [[ -z "$plist" ]] && continue
    label=$(basename "$plist" .plist)
    if [[ "$disabled_out" == *"\"$label\" => disabled"* || "$disabled_out" == *"\"$label\" => true"* ]]; then
      stopped=$((stopped + 1))
      continue
    fi
    IFS=$'\t' read -r mode prog < <(python3 - "$plist" <<'PY'
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    print("unreadable\t"); sys.exit(0)
ka = d.get('KeepAlive')
if ka is True or isinstance(ka, dict):
    mode = 'daemon'
elif d.get('StartInterval') or d.get('StartCalendarInterval'):
    mode = 'scheduled'
else:
    mode = 'oneshot'
args = d.get('ProgramArguments') or []
prog = args[0] if args else (d.get('Program') or '')
print(mode + '\t' + prog)
PY
)
    total=$((total + 1))
    # 3번째 필드(Label) 정확 일치 — 부분 매칭(board vs board-watchdog) 오탐 방지
    line=$(printf '%s\n' "$launchd_out" | awk -v l="$label" '$3 == l')
    if [[ -z "$line" ]]; then
      add_result "launchd:$label" "FAIL" "not loaded"
      bad=$((bad + 1))
    else
      pid=$(awk '{print $1}' <<<"$line")
      ec=$(awk '{print $2}' <<<"$line")
      case "$mode" in
        daemon)
          daemons=$((daemons + 1))
          if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
            add_result "launchd:$label" "FAIL" "not running (exit=$ec)"
            bad=$((bad + 1))
          fi ;;
        scheduled) scheduled=$((scheduled + 1)) ;;
        *) ;;
      esac
    fi
    if [[ -n "$prog" && ! -e "$prog" ]]; then
      missing_scripts+=("$label")
    fi
  done < <(find "$la_dir" -maxdepth 1 \( -name 'ai.jarvis.*.plist' -o -name 'ai.openclaw.*.plist' -o -name 'com.jarvis.*.plist' \) 2>/dev/null | sort)

  if (( total == 0 )); then
    add_result "launchd" "WARN" "ai.jarvis/ai.openclaw/com.jarvis plist 0개"
  elif (( bad == 0 )); then
    add_result "launchd" "OK" "${total}개 로드 (상주 ${daemons} · 예약 ${scheduled} · 의도적 정지 ${stopped})"
  fi
  if (( ${#missing_scripts[@]} > 0 )); then
    add_result "launchd:config-debt" "WARN" "스크립트 없음: ${missing_scripts[*]}"
  fi
}

# ── 2. 오픈클로 게이트웨이 · 디스코드 채널 ───────────────────────────────────
# 옛 check_discord_bot 의 후임. 디스코드 봇은 오픈클로 게이트웨이 안의 채널이다.
check_openclaw() {
  local pid rss_kb mem_mb
  pid=$(launchctl list 2>/dev/null | awk '$3 == "ai.openclaw.gateway" {print $1}' | grep -E '^[0-9]+$' | head -1 || true)
  if [[ -z "$pid" ]]; then
    add_result "openclaw-gateway" "FAIL" "no PID (launchd ai.openclaw.gateway)"
  else
    rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
    mem_mb=$(( ${rss_kb:-0} / 1024 ))
    if (( mem_mb > GATEWAY_RSS_FAIL_MB )); then
      add_result "openclaw-gateway" "FAIL" "PID=$pid RSS=${mem_mb}MB (누수 의심)"
    elif (( mem_mb > GATEWAY_RSS_WARN_MB )); then
      add_result "openclaw-gateway" "WARN" "PID=$pid RSS=${mem_mb}MB (high)"
    else
      add_result "openclaw-gateway" "OK" "PID=$pid RSS=${mem_mb}MB"
    fi
  fi

  if [[ ! -x "$OPENCLAW_BIN" ]]; then
    add_result "openclaw-discord" "WARN" "openclaw CLI 없음: $OPENCLAW_BIN"
    return
  fi
  local st running err reconnects
  st=$(run_with_timeout 30 "$OPENCLAW_BIN" channels status --json 2>/dev/null || echo "")
  if [[ -z "$st" ]]; then
    add_result "openclaw-discord" "FAIL" "channels status 응답없음"
    return
  fi
  running=$(jq -r '.channels.discord.running // false' <<<"$st" 2>/dev/null || echo "false")
  err=$(jq -r '.channels.discord.lastError // empty' <<<"$st" 2>/dev/null || echo "")
  reconnects=$(jq -r '.channelAccounts.discord[0].reconnectAttempts // 0' <<<"$st" 2>/dev/null || echo 0)
  if [[ "$running" == "true" ]]; then
    add_result "openclaw-discord" "OK" "running · 재접속 ${reconnects}회"
  else
    add_result "openclaw-discord" "FAIL" "not running${err:+ — ${err:0:60}}"
  fi
}

# ── 3. RAG / LanceDB ─────────────────────────────────────────────────────────
check_rag() {
  local nm="" cand
  for cand in "$HOME/projects/jarvis/rag/node_modules" \
              "$HOME/projects/jarvis/infra/discord/node_modules" \
              "$BOT_HOME/discord/node_modules"; do
    if [[ -f "$cand/@lancedb/lancedb/package.json" ]]; then nm="$cand"; break; fi
  done
  if [[ -z "$nm" ]]; then
    add_result "rag-lancedb" "FAIL" "@lancedb/lancedb 모듈 없음 (후보 3곳)"
  else
    local node_script='
const { createRequire } = await import("module");
const require = createRequire("file:///");
const ldb = require(process.env.RAG_NODE_MODULES + "/@lancedb/lancedb");
const db = await ldb.connect(process.env.RAG_DB);
try {
  const t = await db.openTable("documents");
  console.log("chunks:" + await t.countRows());
} catch (e) { console.log("ERROR:" + String(e.message).slice(0, 60)); }
'
    local node_out
    node_out=$(RAG_NODE_MODULES="$nm" RAG_DB="$BOT_HOME/rag/lancedb" \
      run_with_timeout 20 node --input-type=module <<< "$node_script" 2>/dev/null || echo "ERROR:node failed/timeout")
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
  fi

  # 인덱싱 신선도 — crontab `30 */4` rag-index 가 유일하게 남은 crontab 줄이다.
  # 2주기(8h) 넘게 로그 갱신이 없으면 그 줄이 죽은 것이다.
  local idx_log="$BOT_HOME/logs/rag-index.log"
  if [[ -f "$idx_log" ]]; then
    local age_h=$(( ( $(date +%s) - $(file_mtime "$idx_log") ) / 3600 ))
    log "RAG 최근 인덱싱: $(tail -1 "$idx_log" 2>/dev/null || echo '?')"
    if (( age_h > 8 )); then
      add_result "rag-index" "WARN" "로그 ${age_h}h 정체 (crontab 30 */4 확인)"
    else
      add_result "rag-index" "OK" "${age_h}h 전 갱신"
    fi
  else
    add_result "rag-index" "WARN" "rag-index.log 없음"
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
  if [[ "$task_count" -gt 0 ]]; then
    task_note=" (+task ${task_count}건 제외)"
  fi

  if (( err_count > 10 )); then
    add_result "cron-errors" "FAIL" "24h ${err_count}건${task_note}"
  elif (( err_count > 0 )); then
    add_result "cron-errors" "WARN" "24h ${err_count}건${task_note}"
  else
    add_result "cron-errors" "OK" "에러 없음${task_note}"
  fi
}

# ── 5. E2E 테스트 결과 ───────────────────────────────────────────────────────
# e2e-cron.sh(오픈클로 잡 jarvis-e2e-cron, 매일 05:00)가 남기는 마지막 RESULT 줄만 본다.
#   "RESULT: 62/90 passed (exit: 0)"  또는  "RESULT: 59/90 passed, 3 FAILED (exit: 1)"
check_e2e() {
  local f="$BOT_HOME/logs/e2e-cron.log"
  if [[ ! -f "$f" ]]; then
    add_result "e2e" "WARN" "아직 미실행"
    return
  fi
  local last ts pass total failed
  last=$(grep 'RESULT:' "$f" 2>/dev/null | tail -1 || true)
  if [[ -z "$last" ]]; then
    add_result "e2e" "WARN" "RESULT 줄 없음"
    return
  fi
  ts=$(sed -E 's/^\[([^]]+)\].*/\1/' <<<"$last")
  pass=$(grep -oE '[0-9]+/[0-9]+ passed' <<<"$last" | cut -d/ -f1 || echo 0)
  total=$(grep -oE '[0-9]+/[0-9]+ passed' <<<"$last" | cut -d/ -f2 | cut -d' ' -f1 || echo 0)
  failed=$(grep -oE '[0-9]+ FAILED' <<<"$last" | grep -oE '[0-9]+' || echo 0)
  pass=$((${pass:-0})); total=$((${total:-0})); failed=$((${failed:-0}))

  local age_h=$(( ( $(date +%s) - $(epoch_of "$ts") ) / 3600 ))
  if (( age_h > 48 )); then
    add_result "e2e" "WARN" "마지막 결과 ${age_h}h 전 (${ts}) — 잡 정체"
  elif (( failed >= 3 )); then
    add_result "e2e" "FAIL" "${failed}개 실패 / ${pass}/${total} 통과"
  elif (( failed > 0 )); then
    add_result "e2e" "WARN" "${failed}개 실패 / ${pass}/${total} 통과"
  else
    add_result "e2e" "OK" "${pass}/${total} 통과"
  fi
}

# ── 6. Glances API ──────────────────────────────────────────────────────────
check_glances() {
  local cpu_info
  cpu_info=$(run_with_timeout 5 curl -sf --max-time 5 "http://localhost:61208/api/4/cpu" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'CPU {d[\"total\"]}%')" 2>/dev/null || echo "")
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
  pct=$(df "$([ -d /System/Volumes/Data ] && echo /System/Volumes/Data || echo /)" | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}' 2>/dev/null || echo "0")
  if [[ "$pct" -gt 90 ]]; then
    add_result "disk" "FAIL" "${pct}% 사용"
  elif [[ "$pct" -gt 80 ]]; then
    add_result "disk" "WARN" "${pct}% 사용"
  else
    add_result "disk" "OK" "${pct}% 사용"
  fi
}

# ── 9. claude 직접 호출 격리 가드 (2026-06-11 신설) ──────────────────────────
# 배치 스크립트가 격리 토큰 없이 claude를 직접 호출하면 대화형 CLI와 토큰 갱신 경쟁
# → 세션 강제 로그아웃 사고 재발 (oauth-incident-ledger cli-login-session-expired-20260611).
# 신규 위반 스크립트가 생기면 WARN으로 적발한다.
check_claude_isolation() {
  local viol=0 names=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -qE "CLAUDE_CODE_OAUTH_TOKEN|llm-gateway|ask-claude" "$f" && continue
    case "$(basename "$f")" in
      # 화이트리스트 (2026-06-11 전수 판정 — 에이전트 2차 분류 + 실측):
      # ① 인증 점검 도구 — 메인 credentials 검사가 본래 목적
      pre-cron-auth-check.sh|boot-auth-check.sh|token-health-check.sh|claude-switch.sh) continue ;;
      # ② bot-cron/게이트웨이 격리 주입 경로 경유 또는 claude 실호출 없음(오탐)
      macro-briefing.sh|coder-functions.sh|extras-gateway.mjs|health-gateway.mjs) continue ;;
      watchdog.sh|health-check.sh|bot-self-restart.sh) continue ;;
      # ③ 대화형 TUI — 메인 credentials 사용이 정당 (배치 아님)
      chat.mjs) continue ;;
    esac
    # 2026-07-27: 격리를 실제로 적용한 파일은 통과시킨다.
    if grep -qE 'isolatedClaudeEnv|CLAUDE_CODE_OAUTH_TOKEN|llm-gateway' "$f" 2>/dev/null; then
      continue
    fi
    viol=$((viol + 1))
    names="${names}$(basename "$f") "
  done < <(
    # 2026-07-27: 주석·안내문구까지 잡아 영구 오탐을 내던 것을 정정.
    # 1차로 파일을 추리고, 주석(#, //)을 제거한 뒤에도 매치가 남는 파일만 위반으로 본다.
    grep -rlE 'spawnSync\(CLAUDE_BIN|\.local/bin/claude.{0,40}(-p|--print)|claude (-p|--print)' \
      "$HOME/projects/jarvis/infra/scripts" "$HOME/projects/jarvis/infra/lib" 2>/dev/null \
      | grep -vE '\.bak|\.LOCKED|node_modules|\.md$|\.disabled' \
      | while read -r _cand; do
          # 주석 제거 + 출력문(echo/printf/문서생성 헬퍼/마크다운 표) 제외 후에도 남으면 실제 호출.
          if sed -e 's/#.*//' -e 's|//.*||' "$_cand" 2>/dev/null \
             | grep -vE '^[[:space:]]*(echo|printf|_r )|^\|' \
             | grep -qE 'spawnSync\(CLAUDE_BIN|\.local/bin/claude.{0,40}(-p|--print)|claude (-p|--print)'; then
            printf '%s\n' "$_cand"
          fi
        done || true)
  if [[ "$viol" -gt 0 ]]; then
    add_result "claude-격리" "WARN" "${viol}건 우회 호출: ${names:0:80}"
  else
    add_result "claude-격리" "OK" "전 배치 격리 토큰 경유"
  fi
}

# ── 10. 학습 소비처 등기소 검사 (2026-06-11 신설) ─────────────────────────────
# 학습 산출물(오답노트·체크리스트·통찰·ralph)이 "생산만 되고 아무도 안 읽는"
# 구조 단절을 적발한다. 등기부(learning-consumer-registry.json) 각 항목에 대해
# ① artifact 존재 ② 소비처 파일 존재 ③ 소비처가 artifact 경로/이름을 참조하는지 grep
# 3중 검사 — 실패 항목은 WARN. optional=true(선등기)는 artifact 미생성 시
# 조용히 통과시켜 영구 오탐을 방지한다 (설계 v2 결함 3 정정).
check_learning_consumers() {
  local REG="$BOT_HOME/config/learning-consumer-registry.json"
  if [[ ! -f "$REG" ]]; then
    add_result "학습-소비처" "WARN" "등기부 부재: learning-consumer-registry.json"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    add_result "학습-소비처" "WARN" "jq 없음 — 검사 불가"
    return
  fi
  if ! jq empty "$REG" 2>/dev/null; then
    add_result "학습-소비처" "WARN" "등기부 JSON 파싱 실패"
    return
  fi

  local total=0 issues=0 notes=""
  local id apath kind optional cfile cref ctype

  # ① artifact 존재 검사 — kind=dir은 디렉토리, 그 외는 파일로 판정.
  #    optional=true는 미생성 허용 (경로만 선등기한 항목).
  while IFS=$'\t' read -r id apath kind optional; do
    [[ -z "$id" ]] && continue
    total=$((total + 1))
    apath="${apath/#\~/$HOME}"
    local a_ok=true
    if [[ "$kind" == "dir" ]]; then
      [[ -d "$apath" ]] || a_ok=false
    else
      [[ -f "$apath" ]] || a_ok=false
    fi
    if ! $a_ok && [[ "$optional" != "true" ]]; then
      issues=$((issues + 1))
      notes="${notes}${id}:산출물없음; "
    fi
  done < <(jq -r '.artifacts[] | [.id, .path, (.kind // "file"), ((.optional // false)|tostring)] | @tsv' "$REG" 2>/dev/null)

  # ② + ③ 소비처 검사 — 파일 존재 + artifact 참조(ref 문자열) grep.
  #    kind=archive는 보관용(소비처 부재가 정상)이라 면제.
  #    optional artifact가 아직 미생성이면 소비처 검사 생략 — 생성 시점부터 발효.
  #    비파일 소비처(type 마커, 예: claude-code-rules-autoload)는 grep 불가 → 통과.
  while IFS=$'\t' read -r id apath kind optional cfile cref ctype; do
    [[ -z "$id" ]] && continue
    [[ "$kind" == "archive" ]] && continue
    apath="${apath/#\~/$HOME}"
    if [[ "$optional" == "true" ]]; then
      if [[ "$kind" == "dir" ]]; then
        [[ -d "$apath" ]] || continue
      else
        [[ -f "$apath" ]] || continue
      fi
    fi
    if [[ -z "$cfile" && -n "$ctype" ]]; then
      continue
    fi
    cfile="${cfile/#\~/$HOME}"
    if [[ ! -f "$cfile" ]]; then
      issues=$((issues + 1))
      notes="${notes}${id}:소비처없음($(basename "$cfile")); "
      continue
    fi
    if [[ -n "$cref" ]] && ! grep -qF -- "$cref" "$cfile" 2>/dev/null; then
      issues=$((issues + 1))
      notes="${notes}${id}:참조누락($(basename "$cfile")); "
    fi
  done < <(jq -r '.artifacts[] | .id as $i | .path as $p | (.kind // "file") as $k | ((.optional // false)|tostring) as $o | (.consumers // [])[]? | [$i, $p, $k, $o, (.file // ""), (.ref // ""), (.type // "")] | @tsv' "$REG" 2>/dev/null)

  if [[ "$issues" -gt 0 ]]; then
    add_result "학습-소비처" "WARN" "${issues}건 단절: ${notes:0:110}"
  else
    add_result "학습-소비처" "OK" "artifact ${total}종 소비 연결 실재"
  fi
}

# ── 모든 체크 실행 ────────────────────────────────────────────────────────────
log "system-doctor 시작"

check_launchagents
check_openclaw
check_rag
check_cron_errors
check_e2e
check_glances
check_cli_tools
check_disk
check_claude_isolation
check_learning_consumers

read -r ok wf < "$COUNTS_TMP"
fail_count=$(awk -F'\t' '$2=="FAIL"' "$RESULTS_TMP" | wc -l | tr -d ' ')
warn_count=$(awk -F'\t' '$2=="WARN"' "$RESULTS_TMP" | wc -l | tr -d ' ')
fail_count=$((${fail_count:-0})); warn_count=$((${warn_count:-0}))
if (( fail_count > 0 )); then overall="red"
elif (( warn_count > 0 )); then overall="yellow"
else overall="green"; fi
log "점검 완료 — ${overall} OK:$ok WARN:$warn_count FAIL:$fail_count"

# ── 원장 적재 (type:"cron-scan") ──────────────────────────────────────────────
# 2026-04-25 verify Agent 적발: cron 실행 결과가 doctor-ledger.jsonl 에 안 적재되어 주간 audit 이 운영 추세를 못 봄.
# 2026-09-19: 슬래시 scan 과 같은 overall/red/yellow 를 필수로 적는다 (red=FAIL 수, yellow=WARN 수).
#   metrics 는 항목→상태("ok"|"warn"|"fail") 맵 — doctor-ledger-audit.sh 가 "fail" 값을 세어
#   7일 중 3회+ 반복 FAIL 영역을 잡는다. ok/warn/fail 정수는 종전 집계 호환용으로 유지.
if command -v jq >/dev/null 2>&1; then
  red_items=$(awk -F'\t' '$2=="FAIL"{print $1}' "$RESULTS_TMP" | jq -R . | jq -sc .)
  yellow_items=$(awk -F'\t' '$2=="WARN"{print $1}' "$RESULTS_TMP" | jq -R . | jq -sc .)
  metrics=$(awk -F'\t' '{print $1 "\t" tolower($2)}' "$RESULTS_TMP" \
    | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')
  if jq -cn \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg overall "$overall" \
       --argjson red "$fail_count" \
       --argjson yellow "$warn_count" \
       --argjson ok "${ok:-0}" \
       --argjson warn "$warn_count" \
       --argjson fail "$fail_count" \
       --argjson red_items "$red_items" \
       --argjson yellow_items "$yellow_items" \
       --argjson metrics "$metrics" \
       '{ts:$ts, type:"cron-scan", runner:"system-doctor.sh", overall:$overall,
         red:$red, yellow:$yellow, ok:$ok, warn:$warn, fail:$fail,
         red_items:$red_items, yellow_items:$yellow_items, metrics:$metrics}' \
       >> "$LEDGER" 2>>"$LOG"; then
    log "ledger appended ($overall red=$fail_count yellow=$warn_count ok=$ok) → $LEDGER"
  else
    log "ledger append FAILED — $LEDGER 권한/경로 확인"
  fi
else
  log "ledger skip — jq not found"
fi

# ── 결과 포맷팅 ───────────────────────────────────────────────────────────────
ISSUES=""
OKSUMMARY=""
while IFS=$'\t' read -r item status note; do
  case "$status" in
    OK)   OKSUMMARY="${OKSUMMARY}  ✅ ${item}: ${note}"$'\n' ;;
    WARN) ISSUES="${ISSUES}  ⚠️ ${item}: ${note}"$'\n' ;;
    *)    ISSUES="${ISSUES}  ❌ ${item}: ${note}"$'\n' ;;
  esac
done < "$RESULTS_TMP"

REPORT="🩺 Jarvis 점검 — $(date '+%m-%d %H:%M') · ${overall}
✅ 정상 ${ok}개 · ⚠️ 경고 ${warn_count}개 · ❌ 실패 ${fail_count}개"
[[ -n "$ISSUES" ]]    && REPORT="${REPORT}

[이상 항목]
${ISSUES}"
[[ -n "$OKSUMMARY" ]] && REPORT="${REPORT}
[정상 항목]
${OKSUMMARY}"

# ── 검증 실행이면 여기서 끝 — 게이트 상태·외부 송출을 건드리지 않는다 ─────────────
if [[ "${JARVIS_NO_EXTERNAL:-0}" == "1" ]]; then
  log "검증 실행(JARVIS_NO_EXTERNAL=1) — 알림 게이트·송출 생략"
  printf '%s\n' "$REPORT"
  exit 0
fi

# ── 알림 게이트 (edge-triggered) ──────────────────────────────────────────────
# 2026-07-27 소음 감축: 이상 구성(시그니처)이 바뀌거나 정상으로 복귀할 때만 보낸다.
# 같은 이상이 이어지면 억제하고 횟수만 센다. 반복 FAIL 은 주간 원장 감사가 잡는다.
_AG="${BOT_HOME}/lib/alert-gate.sh"
# shellcheck source=/dev/null
[[ -f "$_AG" ]] && source "$_AG" 2>/dev/null || true
_sig=$(awk -F'\t' '$2 != "OK" {print $1}' "$RESULTS_TMP" 2>/dev/null | sort | tr '\n' ',')
_was_alerting=0
if declare -F alert_gate_was_alerting >/dev/null 2>&1 && alert_gate_was_alerting "system-doctor"; then
  _was_alerting=1
fi
if declare -F alert_gate >/dev/null 2>&1 && ! alert_gate "system-doctor" "${wf:-0}" "$_sig"; then
  log "송출 억제 — 상태 무변화 (이상 ${wf}건 동일, 누적 $(alert_gate_suppressed system-doctor)회 억제)"
  exit 0
fi

if [[ ! -f "$ALERT" ]]; then
  log "alert-send.sh 없음 — 송출 불가 ($ALERT)"
  exit 0
fi

# ── 송출 ─────────────────────────────────────────────────────────────────────
# alert-send.sh 가 경로를 고른다: critical → 오픈클로 디스코드 채널(monitoring.json l3_channel_id)로 즉시,
# warning/success → 억제 로그(no-external.log). 2026-09-13 주인님 결정.
if (( wf == 0 )); then
  if (( _was_alerting )); then
    log "복구 알림 (이상 → 정상)"
    bash "$ALERT" success "Jarvis 점검 복구 — $(date '+%m-%d %H:%M')" "정상 ${ok}개 · 이상 0개" >>"$LOG" 2>&1 \
      || log "복구 알림 실패 (alert-send rc=$?)"
  else
    log "all OK — silent"
  fi
  exit 0
fi

level="warning"
if (( fail_count > 0 )); then level="critical"; fi
log "송출 (${level}, 이상 ${wf}건: ${_sig})"
bash "$ALERT" "$level" "Jarvis 점검 — 이상 ${wf}건 ($(date '+%m-%d %H:%M'))" "$REPORT" >>"$LOG" 2>&1 \
  || log "송출 실패 (alert-send rc=$?)"
