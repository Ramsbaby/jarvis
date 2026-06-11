#!/usr/bin/env bash
# career-coding-mode.sh — 커리어 채널 코딩테스트 모드 토글 (2026-06-11)
# 봇 재시작 불필요 — 다음 메시지부터 즉시 적용 (career-coding-mode.js가 매 요청 상태 파일을 읽음).
#
# 사용:
#   career-coding-mode.sh coach   # 생성형AI 프롬프트 전략 코치 (AI 활용형 라이브코딩 대비)
#   career-coding-mode.sh solve   # 자바 직접 풀이 (기존 모드)
#   career-coding-mode.sh off     # 평소 커리어 채널로 복귀
#   career-coding-mode.sh status  # 현재 모드 확인
set -euo pipefail

STATE="$HOME/jarvis/runtime/state/career-coding-mode.json"

case "${1:-status}" in
    coach|solve|off)
        printf '{"mode":"%s","changedAt":"%s"}\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$STATE"
        echo "✅ 코딩테스트 모드 → $1 (재시작 불필요, 커리어 채널 다음 메시지부터 적용)"
        ;;
    status)
        if [ -f "$STATE" ]; then
            cat "$STATE"
        else
            echo '{"mode":"off","note":"상태 파일 없음 — env CAREER_CODING_MODE 폴백"}'
        fi
        ;;
    *)
        echo "사용법: career-coding-mode.sh {coach|solve|off|status}" >&2
        exit 1
        ;;
esac
