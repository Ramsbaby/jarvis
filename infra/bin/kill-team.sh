#!/usr/bin/env bash
# kill-team.sh — Claude 팀 에이전트 및 자식 프로세스 강제 정리
# 사용법: kill-team.sh <team-name>
#   예시: kill-team.sh abundant-orbiting-island
#         kill-team.sh --all   (모든 팀 잔여 에이전트 정리)
#
# 동작:
#   1. team-name 인수 포함 claude 프로세스 탐지
#   2. SIGTERM → 3초 대기 → 잔여 시 SIGKILL
#   3. 결과 출력

set -euo pipefail

TEAM="${1:-}"

if [[ -z "$TEAM" ]]; then
    echo "사용법: $0 <team-name> | --all"
    exit 1
fi

# ============================================================
# 대상 PID 수집
# ============================================================
if [[ "$TEAM" == "--all" ]]; then
    PIDS=$(pgrep -f 'team-name ' || true)
    LABEL="모든 팀 에이전트"
else
    PIDS=$(pgrep -f "team-name $TEAM" || true)
    LABEL="팀: $TEAM"
fi

if [[ -z "$PIDS" ]]; then
    echo "[kill-team] $LABEL — 실행 중인 에이전트 없음. 종료."
    exit 0
fi

COUNT=$(echo "$PIDS" | wc -l | tr -d ' ')
echo "[kill-team] $LABEL — ${COUNT}개 에이전트 발견: $(echo "$PIDS" | tr '\n' ' ')"

# ============================================================
# SIGTERM (정상 종료 요청)
# ============================================================
echo "$PIDS" | xargs kill -TERM 2>/dev/null || true
echo "[kill-team] SIGTERM 전송 → 3초 대기..."
sleep 3

# ============================================================
# 잔여 확인 → SIGKILL
# ============================================================
if [[ "$TEAM" == "--all" ]]; then
    REMAINING=$(pgrep -f 'team-name ' || true)
else
    REMAINING=$(pgrep -f "team-name $TEAM" || true)
fi

if [[ -n "$REMAINING" ]]; then
    R_COUNT=$(echo "$REMAINING" | wc -l | tr -d ' ')
    echo "[kill-team] ${R_COUNT}개 잔여 → SIGKILL 강제 종료"
    echo "$REMAINING" | xargs kill -KILL 2>/dev/null || true
    sleep 1
fi

# ============================================================
# 최종 확인
# ============================================================
if [[ "$TEAM" == "--all" ]]; then
    FINAL=$(pgrep -f 'team-name ' || true)
else
    FINAL=$(pgrep -f "team-name $TEAM" || true)
fi

if [[ -z "$FINAL" ]]; then
    echo "[kill-team] ✅ $LABEL 정리 완료"
else
    echo "[kill-team] ⚠️  일부 프로세스 잔여: $(echo "$FINAL" | tr '\n' ' ')"
    exit 1
fi
