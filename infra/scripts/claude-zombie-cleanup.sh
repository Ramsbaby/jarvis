#!/bin/bash
# claude-zombie-cleanup.sh — Claude CLI 좀비 세션 자동 정리
# 2026-04-27 주인님 OOM 사고 (938MB cap 800MB) 근본 처방.
#
# 배경:
#   3개월 운영 중 Claude CLI 세션이 누적 (1~2일 uptime + idle), swap 압박 → 봇 GC 지연 → OOM.
#   Mac Mini 16GB 메모리 / swap 5GB. 좀비 4~5개 누적 시 swap 75% 사용, 시스템 압박.
#
# 정책 (보수적):
#   - 대상 ①: Claude CLI 프로세스 (~/.claude/remote/ccd-cli/* 또는 ~/.local/bin/claude)
#   - 대상 ②: 웹 브리지 serve 고아 (~/.claude/remote/srv/* server --serve) — 2026-05-29 추가
#   - 좀비 판정: uptime > 12시간 AND CPU 사용률 < 1% (idle)
#   - 회피: 현재 활성 세션 (active-session 파일에 기록된 PID / 최신 serve)
#   - SIGTERM (graceful) → 5초 대기 → SIGKILL (강제)
#
# 실행 빈도: 4시간마다 (00·04·08·12·16·20시 KST) — LaunchAgent ai.jarvis.claude-zombie-cleanup

set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/claude-zombie-cleanup.log"
mkdir -p "$(dirname "$LOG")"

NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$NOW] === Claude zombie cleanup 시작 ===" >> "$LOG"

# etime(DD-HH:MM:SS 또는 HH:MM:SS) → 시간(정수) 변환 헬퍼
etime_to_hours() {
  local et="$1"
  if [[ "$et" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    echo $(( 10#${BASH_REMATCH[1]} * 24 + 10#${BASH_REMATCH[2]} ))
  elif [[ "$et" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    echo "$(( 10#${BASH_REMATCH[1]} ))"
  else
    echo 0  # MM:SS 형식 = 1시간 미만
  fi
}

# ============================================================
# [2026-05-29 추가] remote serve 고아 정리
#   배경: claude.ai/code 웹 브리지의 'server --serve' 프로세스가 세션 종료 후 잔존.
#         재연결이 죽은 세션에 붙어 "bridged Claude Code process stopped responding
#         mid-turn" 에러 반복. 2026-05-29 주인님 웹 세션 반복 멈춤 → 고아 2개(하루+)
#         수동 정리 후 구조적 가드로 등재. 기존 CLI 좀비 필터(ccd-cli)는 serve를
#         못 잡던 사각지대였음 (blast radius 누락 보강).
#   식별(보수적 3중 AND): 가동시간 ≥ 12h  AND  rpc.sock 활성연결 없음(lsof fd<2)
#                          AND  최신 serve 아님(현재 활성 세션 무조건 보존)
#   DRYRUN: SERVE_CLEANUP_DRYRUN=1 (기본) — 1주 관찰 후 0으로 전환
# ============================================================
SERVE_DRYRUN="${SERVE_CLEANUP_DRYRUN:-1}"
SERVE_KILLED=0
SERVE_FREED=0
SERVE_PIDS=()
while IFS= read -r _sp; do
  [[ -n "$_sp" ]] && SERVE_PIDS+=("$_sp")
done < <(pgrep -f "remote/srv/.*server --serve" || true)

if (( ${#SERVE_PIDS[@]} > 1 )); then
  # 최신 serve(가동시간 최소) = 현재 활성 → 무조건 보존
  NEWEST_PID=""; NEWEST_H=999999
  for sp in "${SERVE_PIDS[@]}"; do
    h=$(etime_to_hours "$(ps -o etime= -p "$sp" 2>/dev/null | tr -d ' ')")
    if (( h < NEWEST_H )); then NEWEST_H=$h; NEWEST_PID="$sp"; fi
  done
  echo "[$NOW] serve ${#SERVE_PIDS[@]}개 발견, 최신 PID=$NEWEST_PID(${NEWEST_H}h) 보존 / DRYRUN=$SERVE_DRYRUN" >> "$LOG"

  for sp in "${SERVE_PIDS[@]}"; do
    [[ "$sp" == "$NEWEST_PID" ]] && continue
    h=$(etime_to_hours "$(ps -o etime= -p "$sp" 2>/dev/null | tr -d ' ')")
    if (( h < 12 )); then
      echo "[$NOW] serve SKIP PID=$sp (${h}h < 12h)" >> "$LOG"; continue
    fi
    sockfd=$(lsof -p "$sp" 2>/dev/null | grep -c "rpc.sock" || echo 0)
    if (( sockfd >= 2 )); then
      echo "[$NOW] serve SKIP PID=$sp (${h}h, 활성연결 ${sockfd}fd)" >> "$LOG"; continue
    fi
    rundir=$(lsof -p "$sp" 2>/dev/null | grep -oE "/[^ ]+/remote/run/[a-f0-9]+" | head -1)
    rss=$(ps -o rss= -p "$sp" 2>/dev/null | tr -d ' '); rss=$(( ${rss:-0} / 1024 ))
    if [[ "$SERVE_DRYRUN" == "1" ]]; then
      echo "[$NOW] [DRYRUN] serve 고아 PID=$sp (${h}h, ${sockfd}fd, ${rss}MB) rundir=${rundir:-?} → 종료 대상(미실행)" >> "$LOG"
    else
      echo "[$NOW] serve 고아 종료 PID=$sp (${h}h, ${sockfd}fd, ${rss}MB)" >> "$LOG"
      kill -TERM "$sp" 2>/dev/null || true
      sleep 2
      kill -0 "$sp" 2>/dev/null && kill -KILL "$sp" 2>/dev/null || true
      # run dir 제거 — 반드시 .../remote/run/<id> 형태일 때만 (안전 가드)
      if [[ -n "$rundir" && -d "$rundir" && "$rundir" == *"/remote/run/"* ]]; then
        rm -r "$rundir" 2>/dev/null || true
        echo "[$NOW]   run dir 제거: $rundir" >> "$LOG"
      fi
      SERVE_KILLED=$(( SERVE_KILLED + 1 ))
      SERVE_FREED=$(( SERVE_FREED + rss ))
    fi
  done
else
  echo "[$NOW] serve ${#SERVE_PIDS[@]}개 — 고아 정리 불필요" >> "$LOG"
fi

# serve 고아 Discord 알림 (실제 종료 시만 — info 레벨)
if (( SERVE_KILLED > 0 )); then
  WH_FILE="${HOME}/jarvis/runtime/config/monitoring.json"
  if [[ -f "$WH_FILE" ]]; then
    WH=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$WH_FILE','utf8')).webhooks?.['jarvis-system']||'')}catch{}" 2>/dev/null)
    [[ -n "$WH" ]] && curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"content\":\"🌉 **웹 브리지 고아 정리** — serve ${SERVE_KILLED}개 종료, 약 ${SERVE_FREED}MB 회수 (mid-turn 멈춤 재발 방지)\"}" \
      "$WH" >/dev/null 2>&1 || true
  fi
fi

# 활성 세션 PID (정리 대상에서 제외)
ACTIVE_PID=""
if [[ -f "${HOME}/jarvis/runtime/state/active-session" ]]; then
  # active-session 파일에는 timestamp만 있음. 활성 세션 보호는 ppid 추적으로
  ACTIVE_PID=$(pgrep -f "claude.*--allowedTools" | head -1 || echo "")
fi

ZOMBIES=()
TOTAL_FREED=0

# Claude CLI 프로세스 전수 검사
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  PID=$(echo "$line" | awk '{print $1}')
  ETIME=$(echo "$line" | awk '{print $2}')
  CPU=$(echo "$line" | awk '{print $3}')
  RSS_KB=$(echo "$line" | awk '{print $4}')

  # 현재 활성 세션 보호
  if [[ -n "$ACTIVE_PID" && "$PID" == "$ACTIVE_PID" ]]; then
    continue
  fi

  # uptime 12시간+ 판정 (etime 형식: DD-HH:MM:SS 또는 HH:MM:SS)
  if [[ "$ETIME" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    DAYS="${BASH_REMATCH[1]}"
    HOURS=$((DAYS * 24 + BASH_REMATCH[2]))
  elif [[ "$ETIME" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    HOURS="${BASH_REMATCH[1]}"
  else
    continue  # 12시간 미만은 정상
  fi

  if (( HOURS < 12 )); then
    continue
  fi

  # CPU 사용률 < 1.0% = idle 판정
  if [[ "$(echo "$CPU < 1.0" | bc -l 2>/dev/null || echo 0)" != "1" ]]; then
    # [2026-05-31 구멍2 수정] 활성(CPU≥1%)이라도 hard cap(16h) 넘으면 강제 종료.
    # 근거: OAuth 토큰 만료 주기 8h. 16h+ 인터랙티브 세션은 시작 시점의 옛 토큰을
    #       메모리에 들고 SDK가 30분마다 credentials.json을 그 옛 토큰으로 덮어 401 유발
    #       (2026-05-31 PID 98132 18h 좀비 사고). 기존엔 CPU 활성이면 무조건 SKIP →
    #       SDK 동기화 CPU 때문에 영구히 안 죽던 사각지대였음 (어제 18h까지 생존).
    if (( HOURS >= 16 )); then
      echo "[$NOW] HARD-CAP PID=$PID etime=$ETIME cpu=$CPU% (활성이나 ${HOURS}h≥16h — 토큰 역동기화 위험, 강제 종료)" >> "$LOG"
    else
      echo "[$NOW] SKIP PID=$PID etime=$ETIME cpu=$CPU% (활성 추정, ${HOURS}h<16h)" >> "$LOG"
      continue
    fi
  fi

  ZOMBIES+=("$PID")
  TOTAL_FREED=$((TOTAL_FREED + RSS_KB / 1024))
  echo "[$NOW] ZOMBIE PID=$PID etime=$ETIME cpu=$CPU% rss=$((RSS_KB/1024))MB" >> "$LOG"
done < <(ps -eo pid,etime,%cpu,rss,command | grep -E "ccd-cli|/.local/bin/claude " | grep -v grep)

if (( ${#ZOMBIES[@]} == 0 )); then
  echo "[$NOW] ✅ 좀비 0건 — cleanup 불필요" >> "$LOG"
  exit 0
fi

echo "[$NOW] 좀비 ${#ZOMBIES[@]}개 발견 (회수 예상 ${TOTAL_FREED}MB)" >> "$LOG"

# SIGTERM → 5초 대기 → SIGKILL
for PID in "${ZOMBIES[@]}"; do
  echo "[$NOW]   SIGTERM PID=$PID" >> "$LOG"
  kill -TERM "$PID" 2>/dev/null || true
done

sleep 5

# 잔존 강제 종료
for PID in "${ZOMBIES[@]}"; do
  if kill -0 "$PID" 2>/dev/null; then
    echo "[$NOW]   SIGKILL PID=$PID (SIGTERM 무시)" >> "$LOG"
    kill -KILL "$PID" 2>/dev/null || true
  fi
done

echo "[$NOW] ✅ 정리 완료 — ${#ZOMBIES[@]}개 좀비, 약 ${TOTAL_FREED}MB 회수" >> "$LOG"

# Discord 알림 (선택 — webhooks 설정 시)
WEBHOOK_FILE="${HOME}/jarvis/runtime/config/monitoring.json"
if [[ -f "$WEBHOOK_FILE" ]]; then
  WEBHOOK=$(node -e "try { console.log(JSON.parse(require('fs').readFileSync('$WEBHOOK_FILE','utf-8')).webhooks?.['jarvis-system']||'') } catch{}" 2>/dev/null)
  if [[ -n "$WEBHOOK" ]]; then
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"content\":\"🧹 **Claude 좀비 정리** — ${#ZOMBIES[@]}개 종료, 약 ${TOTAL_FREED}MB 회수\"}" \
      "$WEBHOOK" >/dev/null 2>&1 || true
  fi
fi
