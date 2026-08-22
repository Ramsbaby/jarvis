#!/usr/bin/env bash
# automation-browser-cleanup.sh — 유휴 자동화 브라우저 자동 회수
# 매시간 (StartInterval 3600)
#
# Why:
#   2026-08-20 job-apply 스킬이 띄운 Chrome(--user-data-dir=~/.jarvis/state/  # ALLOW-DOTJARVIS (사고 당시 실제 경로 — 고치면 사실이 바뀐다)
#   job-apply-chrome-profile)이 13일 3시간 동안 렌더러 18개 · 2.59GB 를 점유했다.
#   16GB 맥미니에서 swap 이 89.5% 까지 차올랐고 WindowServer 가 50.7% 로 밀려
#   주인님 화면 클릭이 먹지 않았다. 오퍼 서명(8/10)으로 job-apply 는 이미 열흘 전
#   용도가 끝나 있었으나 아무도 닫지 않았다.
#
# Existing (DRY 검토 — 기존 가드 3종은 설계상 이 건을 잡을 수 없다):
#   - runaway-process-guard.sh : CPU 폭주만 감시. 이 Chrome 은 CPU 0% 였다.
#   - claude-zombie-cleanup.sh : Claude CLI / remote serve 만 대상.
#   - system-memory-trend.sh   : 시스템 총량 관측·리포트만. 프로세스를 죽이지 않는다.
#   → "장시간 유휴 + 메모리 대량 점유" 를 회수하는 가드가 부재했다. 이 스크립트가 그 공백이다.
#
# 판정 (4중 AND — 보수적):
#   1) Chrome/Chromium 메인 프로세스이고 --user-data-dir 이 jarvis 관리 경로를 가리킨다
#      → 주 브라우저는 기본 프로필을 쓰므로 --user-data-dir 자체가 없어 원천 배제된다
#   2) 가동시간 >= IDLE_HOURS (기본 6h)
#   3) 프로세스 트리 평균 CPU < CPU_IDLE_PCT (기본 5%)
#      → ps %cpu 는 '생애 평균' 이라 장시간 유휴 판정에 오히려 적합하다.
#        (top -l 1 은 macOS 에서 항상 0.0 을 반환한다 — 2026-08-20 runaway-guard 버그 참조)
#   4) 트리 총 RSS >= MIN_RSS_MB (기본 300MB) — 회수 가치가 있을 때만 건드린다
#
# 조치: 메인 PID 에 SIGTERM → 5초 → SIGKILL. 자식 렌더러는 함께 정리된다.
#       자동화 브라우저는 다음 실행 때 새로 뜨므로 가역적이다.
#
# DRYRUN:
#   AUTOMATION_BROWSER_CLEANUP_DRYRUN=1 → 판정만 하고 ledger 기록 (기본값)
#   AUTOMATION_BROWSER_CLEANUP_DRYRUN=0 → 실제 회수

set -uo pipefail

# launchd 는 PATH=/usr/bin:/bin:/usr/sbin:/sbin 최소값으로 실행한다.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
NAME="automation-browser-cleanup"
LOG_FILE="$JARVIS_HOME/runtime/logs/${NAME}.log"
LEDGER="$JARVIS_HOME/runtime/state/${NAME}-ledger.jsonl"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LEDGER")"
# tee 를 쓰지 않는다 — plist StandardOutPath 가 같은 파일이면 이중 기록된다
# (2026-08-20 runaway-process-guard 로그 중복 버그와 동일 원인)
_log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

DRYRUN="${AUTOMATION_BROWSER_CLEANUP_DRYRUN:-1}"
IDLE_HOURS="${AUTOMATION_BROWSER_IDLE_HOURS:-6}"
CPU_IDLE_PCT="${AUTOMATION_BROWSER_CPU_IDLE:-5}"
MIN_RSS_MB="${AUTOMATION_BROWSER_MIN_RSS_MB:-300}"

# jarvis 관리 프로필 경로 (~/.jarvis 는 ~/jarvis/runtime 심링크 — 같은 inode)
PROFILE_PATTERN="${AUTOMATION_BROWSER_PROFILE_PATTERN:-(\.jarvis/|jarvis/runtime/)}"

_log "=== ${NAME} 시작 (DRYRUN=${DRYRUN} · 유휴≥${IDLE_HOURS}h · CPU<${CPU_IDLE_PCT}% · RSS≥${MIN_RSS_MB}MB) ==="

# etime(DD-HH:MM:SS | HH:MM:SS | MM:SS) → 시간(정수)
_etime_hours() {
  local et="$1"
  if [[ "$et" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    echo $(( 10#${BASH_REMATCH[1]} * 24 + 10#${BASH_REMATCH[2]} ))
  elif [[ "$et" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    echo "$(( 10#${BASH_REMATCH[1]} ))"
  else
    echo 0
  fi
}

KILLED=0; FREED_MB=0; SCANNED=0; DETECTED=0
DETAIL=""

# === 1. 수집: --user-data-dir 이 jarvis 경로인 Chrome 메인 프로세스 ===
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
  # 메인 프로세스만 (렌더러/GPU 등 --type= 자식 제외)
  [[ "$cmd" == *"--type="* ]] && continue
  # jarvis 관리 프로필인지
  udd=$(echo "$cmd" | tr ' ' '\n' | grep -m1 '^--user-data-dir=' || true)
  [[ -n "$udd" ]] || continue
  echo "$udd" | grep -qE "$PROFILE_PATTERN" || continue

  SCANNED=$((SCANNED + 1))
  etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  hours=$(_etime_hours "$etime")

  # 트리 전체(자기 + 자식) CPU 합 · RSS 합
  read -r tree_cpu tree_rss_kb < <(
    ps -axo pid,ppid,%cpu,rss | awk -v P="$pid" '$1==P || $2==P {c+=$3; r+=$4} END {printf "%.1f %d", c+0, r+0}'
  )
  tree_rss_mb=$(( tree_rss_kb / 1024 ))
  cpu_int=${tree_cpu%.*}

  profile=$(basename "${udd#--user-data-dir=}")
  _log "SCAN pid=${pid} profile=${profile} 가동=${etime}(${hours}h) cpu=${tree_cpu}% rss=${tree_rss_mb}MB"

  # === 2. 판정 (4중 AND) ===
  if (( hours < IDLE_HOURS )); then
    _log "  SKIP — 가동 ${hours}h < 임계 ${IDLE_HOURS}h"; continue
  fi
  if (( cpu_int >= CPU_IDLE_PCT )); then
    _log "  SKIP — CPU ${tree_cpu}% >= ${CPU_IDLE_PCT}% (사용 중으로 판단)"; continue
  fi
  if (( tree_rss_mb < MIN_RSS_MB )); then
    _log "  SKIP — RSS ${tree_rss_mb}MB < ${MIN_RSS_MB}MB (회수 가치 없음)"; continue
  fi

  DETECTED=$((DETECTED + 1))
  DETAIL="${DETAIL}${profile}(${hours}h·${tree_rss_mb}MB) "

  # === 3. 액션 (DRYRUN 가드) ===
  if [[ "$DRYRUN" == "0" ]]; then
    kill "$pid" 2>/dev/null
    sleep 5
    if ps -p "$pid" >/dev/null 2>&1; then
      kill -9 "$pid" 2>/dev/null
      _log "  ✅ 회수 (SIGKILL) pid=${pid} profile=${profile} ${tree_rss_mb}MB"
    else
      _log "  ✅ 회수 (SIGTERM) pid=${pid} profile=${profile} ${tree_rss_mb}MB"
    fi
    KILLED=$((KILLED + 1)); FREED_MB=$((FREED_MB + tree_rss_mb))
    printf '{"ts":"%s","action":"killed","pid":%s,"profile":"%s","hours":%s,"rss_mb":%s,"cpu":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$pid" "$profile" "$hours" "$tree_rss_mb" "$tree_cpu" >> "$LEDGER"
  else
    _log "  🔵 DRYRUN — 회수 대상이나 미실행 pid=${pid} profile=${profile} ${tree_rss_mb}MB"
    printf '{"ts":"%s","action":"dryrun-detect","pid":%s,"profile":"%s","hours":%s,"rss_mb":%s,"cpu":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$pid" "$profile" "$hours" "$tree_rss_mb" "$tree_cpu" >> "$LEDGER"
  fi
done < <(pgrep -f "Google Chrome|Chromium" 2>/dev/null || true)

_log "완료 — 스캔 ${SCANNED}건 · 대상 ${DETECTED}건 · 회수 ${KILLED}건 (${FREED_MB}MB)"

# === 4. Discord 알림 — 실제 회수했을 때만 (정상 시 무음: jarvis-system 폭격 방지) ===
if (( KILLED > 0 )); then
  # shellcheck source=/dev/null
  source "$JARVIS_HOME/infra/lib/discord-route.sh" 2>/dev/null && \
    discord_route info "유휴 자동화 브라우저 회수" "회수=${KILLED}건,확보=${FREED_MB}MB,대상=${DETAIL% }" 2>/dev/null || true
fi

exit 0
