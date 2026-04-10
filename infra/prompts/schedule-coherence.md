ultrathink

## 일정 정합성 자율 점검

다음 절차로 Owner의 일정 설정이 실제 생활 패턴과 맞는지 점검하고, 어긋난 항목이 있으면 즉시 Discord로 개선 제안을 보내라.

**1단계: 기준 로드**
- `cat $BOT_HOME/config/user-schedule.json` 으로 출근/기상/귀가 시간 확인
- 특히 `departure_time`(출근 시간)과 `briefing_deadline`(브리핑 수신 마감) 확인

**2단계: 현재 설정 스캔**
- `crontab -l` 로 morning-standup, news-briefing, pre-cron-auth-check 시간 확인
- `cat ~/Library/LaunchAgents/com.jarvis.morning-standup.plist` 로 launchd 시간 확인

**3단계: 정합성 판단**
브리핑 수신 마감(briefing_deadline) 이후에 실행되는 아침 태스크가 있으면 → 문제로 분류
또한 다음도 체크:
- 같은 태스크가 crontab + launchd 양쪽에 중복 설정된 경우
- 불필요하게 이른 시간(wake_time 1시간 이전)에 실행되는 사용자 대면 태스크
- 귀가 시간(return_time) 이후에 설정된 긴급/중요 알람

**4단계: 결과 보고**
- 문제 없으면: 짧게 '✅ 일정 정합성 점검 완료 — 이상 없음' 메시지만 Discord 전송
- 문제 발견 시: '🕐 일정 조율 제안' 형식으로 각 문제와 구체적 수정 방안을 Discord에 전송
  예: '모닝 스탠드업(07:30)이 출근 시간(06:30) 이후입니다 → 06:10 권장. 수정할까요?'

**주의**: 직접 수정하지 말고 반드시 제안 메시지만 보낼 것. Owner가 승인한 후 수정.