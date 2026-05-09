ultrathink

자비스 컴퍼니 인프라팀 일일 점검:
1) ls ~/jarvis/runtime/rag/teams/shared-inbox/ 으로 infra팀 수신 메시지 확인
2) launchctl list | grep -E 'jarvis|jarvis' 으로 LaunchAgent 상태 (ai.jarvis.discord-bot, ai.jarvis.watchdog PID 필수)
3) df -h / 으로 디스크 현황 (90% 초과 시 HIGH)
4) memory_pressure 2>/dev/null | grep 'System-wide memory free percentage' 으로 실제 메모리 여유율 확인 (20% 미만 MEDIUM, 10% 미만 HIGH — vm_stat free pages 방식은 macOS inactive 페이지를 무시해 오탐 발생하므로 사용 금지)
5) tail -50 ~/jarvis/runtime/logs/cron.log | grep -c 'FAILED' 으로 최근 크론 실패 수
모두 정상이면 '✅ 인프라: 정상'. 이상 있으면 항목별 경고 및 council shared-inbox에 알림 작성.
보고서를 ~/jarvis/runtime/rag/teams/reports/infra-$(date +%F).md 에 저장. 이상 항목 발견 시에만 ~/jarvis/runtime/scripts/alert.sh 로 Discord #jarvis-ceo 경고 전송. 모두 정상이면 Discord 전송 없음.

## Loop 연결 (이벤트 발행)
보고서 저장 완료 후, 이상 발견 시 아래 기준으로 이벤트 발행:
- event-bus.sh 존재 여부 먼저 확인: [[ -f ~/jarvis/runtime/lib/event-bus.sh ]] || exit 0
- 디스크 90% 초과: source ~/jarvis/runtime/lib/event-bus.sh && emit_event 'disk.threshold_exceeded' '{"pct":"'$DISK_PCT'"}'
- 최근 크론 FAILED 3건 초과: source ~/jarvis/runtime/lib/event-bus.sh && emit_event 'task.failed' '{"count":"3+"}'
- LaunchAgent(discord-bot/watchdog) PID 없음: source ~/jarvis/runtime/lib/event-bus.sh && emit_event 'system.alert' '{"service":"discord-bot"}'
이상 없으면 이벤트 발행 없음.

## 보고서 품질 루브릭 (감사팀 자동 평가 기준)
보고서 본문 작성 후 아래 4개 항목을 자가 체크하여 보고서 **마지막 줄**에 다음 형식으로 표기할 것:
`루브릭: N/4 | ✅항목1 ❌항목2 ...`

- **[R1]** 점검 항목 5개 모두 수치 또는 명확한 상태값 포함 (예: "디스크 63% — 정상")
- **[R2]** WARN/HIGH 항목은 근본 원인 1줄 이상 명시 (이상 없으면 자동 ✅)
- **[R3]** 액션 포인트 최소 1개 명시 (이상 없으면 "정상 유지" 허용)
- **[R4]** shared-inbox 확인 결과 기재 (메시지 수 또는 "신규 없음")

루브릭 4/4이면 감사팀 자동 평가 A등급. 2/4 이하이면 다음 날 재점검 대상.

## 팀 간 공유 파이프라인
이상 항목 발견 시 아래 명령으로 shared-inbox에도 기록하여 타 팀장이 참조할 수 있게 한다:
```bash
INBOX=~/jarvis/runtime/rag/teams/shared-inbox/infra-alerts.md
echo "## $(date '+%Y-%m-%d %H:%M KST') [infra] 이상 감지" >> "$INBOX"
echo "- 항목: <이상 내용 한 줄>" >> "$INBOX"
echo "" >> "$INBOX"
```
정상이면 shared-inbox 기록 생략.