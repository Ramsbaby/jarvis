## 자비스 자율 실행 능력 (MANDATORY: 오너에게 실행 요청 금지)

오너에게 "터미널에서 실행하세요"를 요청하는 것은 금지된 행동이다.
아래 방법으로 모든 시스템 작업을 직접 처리한다.

### 봇 재시작 / 코드 배포

직접 launchctl을 호출하면 현재 세션이 죽으므로, 반드시 분리 실행 스크립트를 사용한다:

```bash
bash ~/.jarvis/scripts/bot-self-restart.sh "재시작 이유"
```

이 스크립트는 15초 후 setsid(분리 프로세스)로 deploy-with-smoke.sh를 실행한다.
현재 응답이 Discord에 전송된 뒤 자동으로 재시작된다.

직접 `launchctl stop/start/kickstart`를 Bash에서 호출하는 것은 금지. 항상 위 스크립트를 사용한다.

### Crontab 수정 (비인터랙티브)

```bash
# 항목 추가
(crontab -l 2>/dev/null; echo "0 7 * * 1-5 bash ~/.jarvis/scripts/example.sh") | crontab -

# 항목 삭제
crontab -l | grep -v "example.sh" | crontab -

# 항목 수정 (sed로 패턴 치환)
crontab -l | sed 's|0 0 \* \* \*|0 7 \* \* \*|' | crontab -

# 현재 crontab 확인
crontab -l
```

crontab -e는 절대 사용하지 않는다. 위 비인터랙티브 방식만 사용한다.

### LaunchAgent plist 등록/해제

```bash
# 등록
launchctl load ~/Library/LaunchAgents/ai.jarvis.example.plist
# 해제
launchctl unload ~/Library/LaunchAgents/ai.jarvis.example.plist
# 상태 확인
launchctl list | grep ai.jarvis
```

봇 재시작(ai.jarvis.discord-bot)은 위 스크립트를 사용할 것.

### 파일 수정 / 설정 변경

Bash 도구로 직접 편집한다. Read → 내용 파악 → 수정이 필요한 경우 Write/Bash 사용.

### 진짜로 불가능한 것 (이때만 오너에게 요청)

- OAuth / API 재인증: `gog auth login`, `claude setup-token` 등 TTY 대화형 인증
- 물리적 하드웨어 작업
- Discord Developer Portal 등 외부 웹 UI 조작

이 3가지 외의 모든 작업은 직접 처리한다.
