# 장기 기억

> 마지막 업데이트: 2026-03-03
> `/remember` 명령 또는 "기억해" 키워드로 추가됩니다.
> **역할 분리**: 사용자 프로필(이름, 직업, 기술스택)은 `~/.jarvis/context/user-profile.md` 참조.
> 이 파일은 대화 중 발견한 선호/패턴/설정만 기록.

## 중요 설정 정보
- MacBook + Mac Mini + Galaxy 환경
- gog tasks 사용 (Galaxy 동기화)
- Discord를 주 인터페이스로 사용

## 🏗️ 아키텍처 팩트 (확정)

### Jarvis와 OpenClaw의 관계
**Jarvis는 OpenClaw와 완전 독립입니다.**

| 컴포넌트 | OpenClaw 의존 여부 | 실행 방식 |
|----------|-------------------|-----------|
| Discord 봇 (discord-bot.js) | ❌ 독립 | launchd → Node.js |
| 크론 태스크 전체 (ask-claude.sh) | ❌ 독립 | crontab → claude -p |
| 자비스 컴퍼니 팀들 (council/academy/infra 등) | ❌ 독립 | tasks.json → ask-claude.sh |
| RAG 엔진 (LanceDB) | ❌ 독립 | ~/.jarvis/lib/rag-engine.mjs |
| 자가복구/watchdog | ❌ 독립 | launchd ai.jarvis.watchdog |

**OpenClaw 게이트웨이(포트 18789)는 Jarvis 코드 어디에도 참조되지 않습니다.**
OpenClaw LaunchAgents는 비활성화 상태 (*.plist.disabled). Jarvis 동작에 영향 없음.

### 경로 기준
- Jarvis 홈: `~/.jarvis/`
- 구 경로 `~/claude-discord-bridge/`는 완전 이전 완료됨. 더 이상 사용 안 함.

### 알림 웹훅 표시 이름
- monitoring.json의 Discord 웹훅이 Discord에 "OpenClaw Agents"로 표시되는 이슈 있음.
- 원인: 웹훅 등록 당시 OpenClaw 관련 이름으로 설정됨.
- 실제로 웹훅은 Jarvis watchdog이 전송하는 것. OpenClaw 동작 불필요.
