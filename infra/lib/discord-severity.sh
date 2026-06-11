#!/usr/bin/env bash
# discord-severity.sh — 심각도→색상 단일 정의 (SSoT, 2026-06-11 신설)
#
# 배경: alert-send.sh와 task-result-route.sh가 같은 심각도에 서로 다른 RGB를 써서
# 동일 등급의 카드가 채널마다 다른 색으로 보이던 문제 (템플릿 감사 2026-06-11 적발).
# 송출기를 새로 만들면 반드시 이 파일을 source하고 severity_color를 사용할 것.
#
# 사용:
#   source ~/jarvis/infra/lib/discord-severity.sh
#   color=$(severity_color critical)   # Discord embed color 필드용 10진수

severity_color() {
    case "${1:-}" in
        critical|error) echo "15158332" ;;  # 빨강
        warning|warn)   echo "16776960" ;;  # 노랑
        info)           echo "3447003"  ;;  # 파랑
        success|ok)     echo "3066993"  ;;  # 초록
        *)              echo "9807270"  ;;  # 회색 (미지정)
    esac
}
