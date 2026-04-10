# Jarvis — Usage Examples

> Real-world examples for common Jarvis workflows.

---

## 1. Discord에서 캘린더 이벤트 등록

Jarvis가 자연어 요청을 받아 Google Calendar에 이벤트를 등록합니다.

**Discord 대화:**
```
User:  26년 5월 10일에 "휴대폰요금제프로모션종료" 캘린더 등록해줘
Jarvis: ✅ 캘린더 등록 완료
        - 제목: 휴대폰요금제프로모션종료
        - 날짜: 2026-05-10 (종일)
```

**내부 동작:**
```bash
bash scripts/calendar-add.sh "2026-05-10" "휴대폰요금제프로모션종료"
# → config/secrets/calendar.json에서 access_token 로드
# → 만료 시 token-refresh.sh 자동 실행
# → Calendar API 호출
```

---

## 2. Dev-Runner에 자율 개발 작업 투입

Jarvis의 dev-runner가 밤마다 자동으로 코드 작업을 처리합니다.

**작업 등록:**
```js
import { addTask } from './lib/task-store.mjs';

addTask({
  id: 'fix-import-paths',
  status: 'queued',
  priority: 2,
  name: 'ESM import 경로 .js 확장자 추가',
  prompt: `discord/lib/ 하위 모든 .mjs 파일에서
    import './foo' → import './foo.js' 형식으로 수정.
    node --check로 문법 검증 후 보고.`,
  completionCheck: "node --check ~/.jarvis/discord/lib/handlers.mjs",
  maxBudget: '0.20',
  timeout: 120,
  allowedTools: 'Bash,Read,Write',
  maxRetries: 2,
  createdAt: new Date().toISOString(),
});
```

**실행 흐름:**
```
22:55 KST — dev-runner.sh 실행
  → getReadyTasks() → fix-import-paths 선택
  → completionCheck 실행 → 미통과
  → git snapshot 생성
  → claude -p "ESM import 경로..." 실행
  → 파일 수정 완료
  → completionCheck 재실행 → 통과
  → queued → running → done
  → GitHub 커밋 + 푸시
  → Discord 보고: "fix-import-paths 완료"
```

---

## 3. 크론 작업 추가 (tasks.json)

매일 오전 9시 날씨 체크 크론 추가 예시.

**`config/tasks.json` 수정:**
```json
{
  "id": "weather-check",
  "schedule": "0 9 * * *",
  "enabled": true,
  "timeout": 60,
  "discordChannel": "jarvis",
  "description": "오늘 날씨 확인 및 알림",
  "script": "/Users/yourname/.jarvis/scripts/weather-check.sh"
}
```

**`scripts/weather-check.sh` 생성:**
```bash
#!/usr/bin/env bash
set -euo pipefail

CITY="Seoul"
WEATHER=$(curl -s "wttr.in/${CITY}?format=3")

curl -s -X POST "$DISCORD_WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"🌤️ 오늘 날씨: ${WEATHER}\"}"
```

---

## 4. 플러그인 개발

`plugins/` 디렉토리에 새 플러그인을 추가합니다.

**`plugins/my-plugin/manifest.json`:**
```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "GitHub PR 알림 플러그인",
  "hooks": {
    "onMessage": "handlers/on-message.js",
    "onCron": "cron/daily.sh"
  },
  "config": {
    "github_repo": "owner/repo"
  }
}
```

**`plugins/my-plugin/handlers/on-message.js`:**
```js
export async function onMessage({ message, discord, config }) {
  if (!message.content.includes('PR')) return;

  const prs = await fetchOpenPRs(config.github_repo);
  await discord.reply(`열린 PR: ${prs.length}개`);
}
```

---

## 5. RAG 메모리에 정보 저장 후 검색

Jarvis가 이전 대화 내용을 기억하고 참조합니다.

**저장 (Serena MCP 사용):**
```
mcp__serena__write_memory({
  memory_name: "global/integrations/calendar",
  content: "# Calendar Integration\n- Token location: config/secrets/calendar.json\n..."
})
```

**검색:**
```
mcp__nexus__rag_search({ query: "calendar token location" })
→ [{ content: "# Calendar Integration\n...", score: 0.92 }]
```

**자연어 트리거:**
```
Discord: "저번에 캘린더 연동 어떻게 했지?"
Jarvis: → rag_search → 이전 기록 참조 → 답변
```

---

## 6. Circuit Breaker 수동 리셋

dev-runner가 3회 연속 실패해 쿨다운에 진입했을 때.

```bash
# 상태 확인
cat $BOT_HOME/state/circuit-breaker/dev-runner.json

# 수동 리셋
echo '{"consecutive_fails":0,"last_fail_ts":0,"task_id":"dev-runner"}' \
  > $BOT_HOME/state/circuit-breaker/dev-runner.json

# 문제 태스크 상태 확인
node $BOT_HOME/lib/task-store.mjs get <task-id>

# 수동 상태 전이 (queued → done 우회 필요 시)
node $BOT_HOME/lib/task-store.mjs force-done <task-id>
```

---

## 7. 채널별 페르소나 설정

`discord/personas.json` (gitignored — `personas.example.json` 참조):

```json
{
  "YOUR_CHANNEL_ID": "--- Channel: my-channel ---\n이 채널의 Jarvis 동작 방식 설명.\n\n【역할】\n특정 도메인 전문가로 동작.",
  "ANOTHER_CHANNEL_ID": "--- Channel: another ---\n간결 모드. 3줄 이내 응답."
}
```

채널 ID는 Discord 개발자 모드에서 채널 우클릭 → "ID 복사"로 확인합니다.
