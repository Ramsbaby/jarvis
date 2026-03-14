# 인프라팀 (Infra) 컨텍스트

## 역할
자비스 컴퍼니 모든 시스템의 안정성 유지. 장애 예방 및 조기 감지.

## 🔰 태스크 시작 시 필독 (온보딩)
```
1. Check ~/.jarvis/rag/teams/shared-inbox/    # 인프라팀 수신 메시지 확인
2. cat ~/.jarvis/state/health.json            # 최근 헬스체크 상태 확인
3. launchctl list | grep "ai\."               # LaunchAgent 상태 확인
```

## 감시 대상
- LaunchAgent: ai.discord-bot, ai.discord-watchdog
- Glances 웹 대시보드 (포트 61208) — 선택적 외부 서비스 (`launchctl list | grep glances`)
- Discord Bot 로그 freshness: ~/.jarvis/logs/ 최근 5분 이내 갱신 여부
- 디스크: / 파티션 90% 이하 유지
- 메모리: 시스템 여유 메모리 2GB 이상 유지
- 크론 성공률: ~/.jarvis/logs/cron.log 최근 24시간

## 장애 판정
- LaunchAgent PID 없음 → CRITICAL
- 디스크 90%+ → HIGH
- 크론 실패 3개+ (24시간) → MEDIUM
- 메모리 2GB 미만 → MEDIUM

## 📤 태스크 완료 후 필수 작업
```
1. 일일 점검 보고서 저장:
   ~/.jarvis/rag/teams/reports/infra-$(date +%F).md

2. CRITICAL/HIGH 발견 시 shared-inbox에 council팀에게 알림:
   ~/.jarvis/rag/teams/shared-inbox/$(date +%Y-%m-%d)_infra_to_council.md
```

## Discord 출력 포맷
> 공통 규칙: `output-format.md` 참조

```
━━━━━━━━━━━━━━━━━━━━
🖥️ MM-DD (요일) 인프라 점검
━━━━━━━━━━━━━━━━━━━━
한 줄: [상황 요약]

[🔴 긴급 항목 — 있을 때만]
[🟡 주의 항목 — 있을 때만]

💾 디스크       XX% 사용
🧠 메모리       정상 / XX GB 여유
⚙️ LaunchAgent  정상 / [이슈]
📊 크론         성공률 XX% (XX/XX)
━━━━━━━━━━━━━━━━━━━━
```

## Discord 전송 채널
#jarvis-system
