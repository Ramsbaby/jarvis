#!/usr/bin/env bash
set -euo pipefail

# claude-idle-session-cleanup.sh v2 — 유휴 6시간 이상 Claude 세션 정리 (CPU 활동 추적)
#
# 왜 v2인가 (v1 파일-mtime 방식 폐기):
#   메모리를 점유하는 오래된 프로세스는 일반 대화창이 아니라 원격/코드 세션(cse_)·
#   agent-teams 실험 세션이었다. 이들은 대화기록 .jsonl 위치가 일반 세션과 달라
#   "파일 수정시각" 매핑이 불가. 또 같은 폴더에서 열린 다중 세션을 구분 못 함.
#   → 세션 형식·기록 위치와 무관한 "누적 CPU 시간 스냅샷 비교"로 전환.
#
# 원리:
#   매 실행마다 각 claude 프로세스의 누적 CPU 초를 상태파일에 기록한다.
#   다음 실행 때 CPU가 (거의) 안 늘었으면 그 사이 일을 안 한 것 = 유휴로 간주하고
#   최초 유휴 시점(last_active)을 유지한다. now - last_active 가 IDLE_THRESHOLD를
#   넘으면 SIGTERM으로 정리. → 반드시 크론으로 주기 실행(예: 매시간)해야 누적됨.
#
# 안전장치:
#   1. dry-run 기본 — 실제 종료는 --kill 인자 필수.
#   2. 현재 세션 보호 — 이 스크립트 조상 프로세스 체인의 claude PID 제외.
#   3. SIGTERM(graceful)만 — SIGKILL 안 함.
#   4. 첫 관측 프로세스는 baseline만 기록하고 절대 종료 안 함(무조건 1주기 유예).
#   5. CPU가 줄어든 프로세스(PID 재사용)는 새 프로세스로 보고 타이머 리셋.
#
# 사용법:
#   bash claude-idle-session-cleanup.sh            # dry-run (목록만, 스냅샷 갱신)
#   bash claude-idle-session-cleanup.sh --kill     # 실제 종료
#   CLAUDE_IDLE_THRESHOLD=10800 bash ... --kill    # 임계 3시간으로 조정
#
# 종료 코드: 항상 0 (자동화 비차단).

# crontab 환경 PATH 보험 (lsof=/usr/sbin, pgrep/ps/stat=/usr/bin) — cron은 PATH가 최소라 명시.
export PATH="/usr/sbin:/usr/bin:/bin:/opt/homebrew/bin:${PATH:-}"

IDLE_THRESHOLD="${CLAUDE_IDLE_THRESHOLD:-21600}"   # 유휴 임계(초). 기본 6시간.
CPU_TOLERANCE="${CLAUDE_IDLE_CPU_TOLERANCE:-3}"    # 이 실행 간 CPU 증가가 이 값 이하면 '일 안 함'
DRY_RUN=1
[ "${1:-}" = "--kill" ] && DRY_RUN=0

LOG="${HOME}/.jarvis/logs/claude-idle-cleanup.log"
LEDGER="${HOME}/.jarvis/state/claude-idle-cleanup.jsonl"
SNAP="${HOME}/.jarvis/state/claude-idle-cpu-snapshot.tsv"
mkdir -p "$(dirname "$LOG")" "$(dirname "$LEDGER")"

TMP_SNAP=$(mktemp "${SNAP}.XXXXXX")
trap 'rm -f "$TMP_SNAP"' EXIT

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

# ── 누적 CPU 문자열([[HH:]MM:]SS[.ss])을 정수 초로 변환 ──────────────────────
cpu_to_sec() {
  local t="${1%%.*}" a b c
  IFS=: read -r a b c <<EOF
$t
EOF
  if [ -n "${c:-}" ]; then
    echo $((10#${a:-0} * 3600 + 10#${b:-0} * 60 + 10#${c:-0}))
  elif [ -n "${b:-}" ]; then
    echo $((10#${a:-0} * 60 + 10#${b:-0}))
  else
    echo $((10#${a:-0}))
  fi
}

# ── 현재 세션 보호: 조상 프로세스 체인의 claude PID 수집 ─────────────────────
PROTECTED=" "
p=$$
for _ in 1 2 3 4 5 6 7 8; do
  [ "$p" -le 1 ] && break
  comm=$(ps -o comm= -p "$p" 2>/dev/null || true)
  case "$comm" in
    *claude*) PROTECTED="${PROTECTED}${p} " ;;
  esac
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || echo 1)
  [ -z "$p" ] && break
done

now=$(date +%s)
reaped=0; kept=0; baseline=0; protected_cnt=0

# ── claude 세션 프로세스 열거 ────────────────────────────────────────────────
pids=$(pgrep -f "\.local/share/claude/versions|\.local/bin/claude" 2>/dev/null || true)

for pid in $pids; do
  cpu_now=$(cpu_to_sec "$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)")

  # 이전 스냅샷 조회 (key = pid)
  prev_line=$(grep -E "^${pid}	" "$SNAP" 2>/dev/null | head -1 || true)
  prev_cpu=$(printf '%s' "$prev_line" | cut -f2)
  prev_active=$(printf '%s' "$prev_line" | cut -f3)

  # last_active(최초 유휴 관측 시점) 결정
  if [ -n "$prev_cpu" ] && [ "$cpu_now" -ge "$prev_cpu" ] \
       && [ "$cpu_now" -le "$((prev_cpu + CPU_TOLERANCE))" ]; then
    last_active="$prev_active"          # CPU 거의 안 늘음 → 유휴 지속, 시점 유지
    first_seen=0
  else
    last_active="$now"                  # 활동했거나 신규/PID재사용 → 타이머 리셋
    first_seen=1
  fi
  printf '%s\t%s\t%s\n' "$pid" "$cpu_now" "$last_active" >> "$TMP_SNAP"

  # (1) 현재 세션 보호
  case "$PROTECTED" in
    *" $pid "*) log "PROTECT(current-session): PID $pid"; protected_cnt=$((protected_cnt + 1)); continue ;;
  esac

  # (1b) claude rc(원격 제어)·원격 코드 세션(cse_)·원격 브리지 서버 무조건 보호.
  #      회사 등 외부에서 맥미니 자비스에 접속하는 통로 — 유휴여도 절대 종료 금지.
  #      식별: 원격 세션은 커맨드라인에 code/sessions/(cse_) / "claude rc" / .claude/remote/ 포함.
  cmdline=$(ps ww -o command= -p "$pid" 2>/dev/null || true)
  case "$cmdline" in
    *code/sessions/*|*"claude rc"*|*.claude/remote/*)
      log "PROTECT(remote/rc-session): PID $pid"; protected_cnt=$((protected_cnt + 1)); continue ;;
  esac

  # (2) 첫 관측이면 baseline만 (이번엔 종료 안 함)
  if [ "$first_seen" = "1" ] && [ -z "$prev_cpu" ]; then
    log "BASELINE(first-seen): PID $pid cpu=${cpu_now}s (다음 주기부터 유휴 측정)"
    baseline=$((baseline + 1)); continue
  fi

  idle=$((now - last_active))
  idle_h=$((idle / 3600))

  # (3) 유휴 판정
  if [ "$idle" -lt "$IDLE_THRESHOLD" ]; then
    log "KEEP(idle=${idle_h}h cpu=${cpu_now}s): PID $pid"; kept=$((kept + 1)); continue
  fi

  # (4) 유휴 임계 초과 → 정리
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN would reap: PID $pid idle=${idle_h}h cpu=${cpu_now}s"
    reaped=$((reaped + 1))
  else
    if kill -TERM "$pid" 2>/dev/null; then
      log "REAPED(SIGTERM idle=${idle_h}h): PID $pid"
      reaped=$((reaped + 1))
    else
      log "FAIL-kill: PID $pid (already gone?)"
    fi
  fi
done

# 스냅샷 원자적 교체
mv -f "$TMP_SNAP" "$SNAP"
trap - EXIT

# ── 원장 append ──────────────────────────────────────────────────────────────
mode=$([ "$DRY_RUN" = "1" ] && echo "dry-run" || echo "kill")
printf '{"ts":"%s","mode":"%s","reaped":%d,"kept":%d,"baseline":%d,"protected":%d,"threshold_s":%d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" "$reaped" "$kept" "$baseline" "$protected_cnt" "$IDLE_THRESHOLD" \
  >> "$LEDGER" 2>/dev/null || true

log "DONE mode=$mode reaped=$reaped kept=$kept baseline=$baseline protected=$protected_cnt"
exit 0
