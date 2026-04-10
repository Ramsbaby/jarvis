# Jarvis FAQ

> 자주 묻는 질문과 답변.

---

## 설치 & 설정

### Q. Claude Max 구독 없이 사용할 수 있나요?

**A.** 아니요. Jarvis는 `claude -p` CLI를 사용합니다. `claude -p`는 Claude Code 또는 Claude Max 구독이 필요합니다. API 키만으로는 작동하지 않습니다. (단, `.env`에 `ANTHROPIC_API_KEY`를 설정하면 API 크레딧으로도 동작하지만, 비용이 발생합니다.)

---

### Q. `claude` 명령어를 찾을 수 없다고 나옵니다.

**A.** Claude Code CLI가 설치되지 않은 상태입니다.

```bash
# macOS/Linux
npm install -g @anthropic-ai/claude-code

# 설치 확인
claude --version
```

---

### Q. Discord 봇이 메시지에 응답하지 않습니다.

**A.** 아래 순서로 확인하세요:

1. 봇 프로세스 실행 중인지 확인
   ```bash
   launchctl list | grep com.jarvis.bot
   # 또는
   ps aux | grep discord-bot
   ```

2. 로그 확인
   ```bash
   tail -50 $BOT_HOME/logs/discord-bot.log
   ```

3. `.env` 설정 확인 (`DISCORD_TOKEN`, `GUILD_ID` 올바른지)

4. 봇 재시작
   ```bash
   bash $BOT_HOME/scripts/bot-self-restart.sh "수동 재시작"
   ```

---

### Q. 설치 후 봇이 시작되지 않습니다.

**A.** 공통 원인:

| 원인 | 해결 |
|------|------|
| Node.js 버전 낮음 | `node --version` → 22+ 필요 |
| `discord/node_modules` 없음 | `cd discord && npm ci` |
| `.env` 파일 없음 | `.env.example` 복사 후 값 채우기 |
| LaunchAgent 미등록 | `bash install.sh` 재실행 |

---

## Dev-Runner

### Q. dev-runner 작업이 계속 실패합니다.

**A.** 아래 순서로 디버깅하세요:

```bash
# 1. 로그 확인
tail -30 $BOT_HOME/logs/dev-runner.log

# 2. 태스크 상태 확인
node $BOT_HOME/lib/task-store.mjs get <task-id>

# 3. Circuit Breaker 상태 확인
cat $BOT_HOME/state/circuit-breaker/dev-runner.json

# 4. CB 리셋 (필요 시)
echo '{"consecutive_fails":0,"last_fail_ts":0,"task_id":"dev-runner"}' \
  > $BOT_HOME/state/circuit-breaker/dev-runner.json
```

---

### Q. `유효하지 않은 전이: queued → done` 오류가 납니다.

**A.** FSM이 `queued → running → done` 경로를 요구하는데 중간 단계를 건너뛴 경우입니다. 수동 복구:

```bash
node $BOT_HOME/lib/task-store.mjs transition <id> running bash-manual
node $BOT_HOME/lib/task-store.mjs transition <id> done bash-manual

# 또는 FSM 우회 (긴급 시)
node $BOT_HOME/lib/task-store.mjs force-done <id>
```

---

### Q. dev-runner가 22:55에 실행되는데 내가 추가한 작업이 처리되지 않았습니다.

**A.** 작업 추가 시각이 22:55 이후라면 다음 날 실행됩니다. 즉시 실행하려면:

```bash
bash $BOT_HOME/bin/dev-runner.sh
```

---

## RAG & 메모리

### Q. Jarvis가 이전 대화를 기억하지 못합니다.

**A.** Jarvis는 명시적 참조 키워드 없이는 RAG를 자동 조회하지 않습니다. 아래처럼 명시적으로 참조하세요:

- "저번에 말한 X 기억해?"
- "아까 설정한 Y 어떻게 했지?"
- "이전에 얘기한 Z 다시 알려줘"

---

### Q. RAG 인덱스가 너무 커졌습니다.

**A.** 런타임 디렉토리 정리:

```bash
# RAG 인덱스 크기 확인
du -sh $BOT_HOME/rag/

# 90일 이상 된 파일 삭제 (선택)
find $BOT_HOME/rag/ -name "*.md" -mtime +90 -delete
```

---

## External Calendar

### Q. 캘린더 등록이 실패합니다.

**A.** 순서대로 확인:

```bash
# 1. 토큰 파일 존재 여부
ls $BOT_HOME/config/secrets/calendar.json

# 2. 수동 토큰 갱신 시도

# 3. 로그 확인
```

---

## 오픈소스 공개

### Q. 공개 전에 어떤 파일을 제거해야 하나요?

**A.** `.gitignore`에 이미 등록된 항목들이 자동으로 제외됩니다. 추가로 확인할 것:

- `config/secrets/` — 토큰/API 키 (gitignored ✅)
- `context/owner/` — 개인 컨텍스트 (gitignored ✅)
- `discord/personas.json` — 채널 설정 (gitignored ✅, `personas.example.json` 참조)
- `.env` — 환경 변수 (gitignored ✅, `.env.example` 참조)

---

### Q. 채널 ID와 개인 설정을 어떻게 교체하나요?

**A.** 설치 후 아래 파일들을 생성/수정합니다:

```bash
# 페르소나 설정
cp discord/personas.example.json discord/personas.json
# → Discord 채널 ID로 키 교체, 채널별 시스템 프롬프트 작성

# 환경 변수
cp .env.example .env
# → DISCORD_TOKEN, GUILD_ID, OWNER_DISCORD_ID 등 채우기
```

---

## 기타

### Q. Windows에서 사용할 수 있나요?

**A.** `setup.ps1`으로 Windows 설치를 지원하지만, 일부 bash 스크립트는 WSL2 환경이 필요합니다. WSL2 설치 후 사용을 권장합니다.

---

### Q. 기여하고 싶습니다.

**A.** [CONTRIBUTING.md](../CONTRIBUTING.md)를 참고하세요. 플러그인 기여는 `plugins/` 디렉토리에 `manifest.json`을 포함한 폴더를 추가하는 방식으로 가능합니다.

---

> 더 궁금한 점은 [GitHub Issues](https://github.com/your-username/jarvis/issues)에 등록해주세요.
