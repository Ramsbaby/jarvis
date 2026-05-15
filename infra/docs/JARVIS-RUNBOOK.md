# 🎩 Jarvis Runbook — 운영 가이드

> 1인 사용자(주인님) 부재 시 다른 사람도 자비스를 운영할 수 있도록 작성한 비상 매뉴얼.
> 대상: 미래의 자비스 운영자 / 비상 대응자 / 다음 세대 자비스 자체

---

## 🚦 자비스가 멈추면 (긴급)

### 1단계 — 봇 부활
```bash
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot
```

### 2단계 — supervisor 재기동
```bash
launchctl kickstart -k gui/$(id -u)/ai.jarvis.supervisor
```

### 3단계 — 로그 확인
```bash
tail -50 ~/jarvis/runtime/logs/discord-bot.log
tail -50 ~/jarvis/runtime/logs/supervisor.log
```

### 4단계 — 모든 cron 일괄 정지 (비상)
```bash
for la in ~/Library/LaunchAgents/ai.jarvis.*.plist; do
    launchctl unload "$la"
done
```

### 5단계 — 일괄 재기동
```bash
for la in ~/Library/LaunchAgents/ai.jarvis.*.plist; do
    launchctl load -w "$la"
done
```

---

## 📋 자비스 자동 시간표 (cron 카탈로그)

→ `~/jarvis/infra/docs/LAUNCHAGENT-CATALOG.md` 자동 생성 (매주 갱신)

자세한 일정은 위 카탈로그 참조.

---

## 🧠 자비스 시스템 구조

### 핵심 컴포넌트
- **Discord 봇** (`infra/discord/`) — 사용자 인터페이스
- **dev-queue** (`infra/lib/task-store.mjs`) — task 라이프사이클 (3 reapers)
- **supervisor** (`infra/supervisor/`) — 5분마다 4-source health monitor
- **RAG** (`rag/`) — LanceDB + Ollama 임베딩 (snowflake-arctic-embed2)

### 데이터 흐름
1. 사용자 메시지 → Discord 봇
2. 봇 → 봇 Claude API 호출 (or RAG 검색)
3. 결정 사항 → wiki / dev-queue / Notion
4. 매일 새벽 → insight-extractor → action-dispatch → dev-queue propose
5. 자비스가 결과 → Discord 알림

---

## 🔧 일반적 문제 해결

### "Discord 봇이 응답 안 함"
1. 봇 프로세스 확인: `pgrep -fl discord-bot`
2. 죽었으면 → 1단계 (봇 부활)
3. 살아있는데 응답 X → `tail -100 ~/jarvis/runtime/logs/discord-bot-stderr.log`

### "AUTH_ERROR 다발"
1. `~/jarvis/runtime/scripts/oauth-refresh.sh` 즉시 실행
2. supervisor가 자동 감지하므로 회복 대기 (5~10분)

### "특정 cron 비활성화하고 싶음"
```bash
launchctl unload ~/Library/LaunchAgents/ai.jarvis.{NAME}.plist
```
→ 다음 부팅까지 비활성. 영구는 plist 파일 이동/삭제.

### "비용 폭주 의심"
1. 매시간 모니터: `tail -20 ~/jarvis/runtime/logs/llm-cost-cap-monitor.log`
2. 즉시 차단 마커: `touch ~/jarvis/runtime/state/llm-daily-cap-exceeded`
   → 다음 cron들이 이 마커 보고 skip (구현된 cron만)

---

## 📚 사전 (자주 쓰는 정보)

자주 묻는 정보는 코드 grep 전에 사전 먼저:
- 크론 × 모델 × 채널: `infra/docs/CRON-MATRIX.md`
- LaunchAgent 일정: `infra/docs/LAUNCHAGENT-CATALOG.md`
- Discord 채널 매핑: `infra/docs/DISCORD-CHANNELS.md`
- 모델 정책: `runtime/context/model-policy.json`

→ 자동 갱신 (매일 04:00 + 매주 월 09:10)

---

## 🚨 비상 연락 / 절차

| 상황 | 1차 대응 | 2차 (1차 실패 시) |
|---|---|---|
| 봇 다운 | watchdog 자동 부활 | 위 1단계 수동 |
| RAG 멈춤 | supervisor 자동 감지 | `~/jarvis/runtime/scripts/rag-restart.sh` |
| Mac 다운 | 재부팅 후 LaunchAgent 자동 시작 | 일괄 재기동 (5단계) |
| 비용 폭주 | cap-monitor 자동 차단 | crontab 일괄 unload |

---

## 🛡️ 자비스를 새로 운영하는 사람에게

1. **읽으세요**: `~/CLAUDE.md` + `~/.claude/rules/jarvis-*.md` (페르소나 / 윤리 / 코어 원칙)
2. **자비스 자체 회고 받으세요**: 매주 일요일 22:00 KST Discord 카드
3. **cron 이해**: 위 "자동 시간표" 사전 참조
4. **문제 시**: 위 "긴급" 5단계
5. **신규 cron 추가 시**: `infra/docs/CRON-INTRODUCTION-CHECKLIST.md` 따라가세요

---

> 작성: 2026-05-08
> 자비스가 자비스를 만드는 시스템이지만, 사람의 운영 인계가 가능해야 합니다.
