---
name: onboarding
description: |
  Jarvis 초기 설치 온보딩 마법사. Discord 봇 토큰·Claude API 키 등 필수 환경변수를 단계별로 수집하고,
  자동/수동 업데이트 정책을 설정하며, 전용 업데이트 알림 채널(🚀jarvis-update)을 생성합니다.
  완료 시 봇이 즉시 기동됩니다.
argument-hint: (no arguments needed — interactive wizard)
---

# 🛸 Jarvis Onboarding 마법사

Jarvis를 처음 설치할 때 실행하는 대화형 설정 도우미입니다.
아래 절차를 **순서대로** 진행하세요.

---

## Step 0: 사전 환경 확인

```bash
node --version   # v18 이상 필요
git --version    # 설치 확인
```

- Node 18 미만이면 사용자에게 업그레이드 안내 후 중단.
- git 없으면 설치 안내 후 중단.

Ollama 상태 확인 (RAG 기능 선택):
```bash
curl -sf http://localhost:11434/api/tags > /dev/null && echo "ollama_ok" || echo "ollama_missing"
```
- Ollama가 없으면 "RAG 기능은 나중에 설정 가능합니다" 안내하고 계속 진행 (중단 아님).

---

## Step 1: 환경 파일 현황 확인

```bash
node .claude/skills/onboarding/scripts/check-setup.mjs
```

출력 예시:
```json
{
  "envPath": "/Users/you/.jarvis/.env",
  "missing": ["DISCORD_TOKEN", "ANTHROPIC_API_KEY", "GUILD_ID"],
  "present": ["BOT_HOME"]
}
```

- missing가 비어 있으면 "이미 설정된 환경입니다. 재설정하시겠습니까?" 물어보기.
- 재설정 거부 시 Step 8(업데이트 정책 확인)로 바로 이동.

---

## Step 2: Discord Bot Token

사용자에게 안내:
```
Discord Developer Portal(https://discord.com/developers/applications) 에서
봇의 TOKEN을 복사해 붙여넣으세요.
```

입력받은 값을 DISCORD_TOKEN 변수에 저장.
유효성 검증 (형식만, API 호출 없이):
- 길이 70자 이상, . 2개 포함 여부 확인.
- 실패 시 "올바른 형식이 아닙니다" 안내 후 재입력 요청.

---

## Step 3: Anthropic API Key

사용자에게 안내:
```
Anthropic Console(https://console.anthropic.com/settings/keys) 에서
API 키를 복사해 붙여넣으세요. (sk-ant-... 형식)
```

입력받은 값을 ANTHROPIC_API_KEY 변수에 저장.
형식 확인: sk-ant- 로 시작하는지 확인.

---

## Step 4: Discord 서버 ID (GUILD_ID)

사용자에게 안내:
```
Discord 앱에서 서버 이름 우클릭 → 서버 ID 복사를 눌러 붙여넣으세요.
(개발자 모드가 꺼져 있다면: 설정 → 고급 → 개발자 모드 활성화 필요)
```

입력받은 값을 GUILD_ID 변수에 저장.
형식 확인: 숫자 17-20자리인지 확인.

---

## Step 5: 오너 정보

두 가지 입력받기:
1. OWNER_DISCORD_ID - 본인 Discord 사용자 ID (프로필 우클릭 → ID 복사)
2. OWNER_NAME - 봇이 부를 이름 (예: 민기)

---

## Step 6: 환경 파일 + 디렉토리 생성

```bash
node .claude/skills/onboarding/scripts/write-env.mjs \
  --discord-token "$DISCORD_TOKEN" \
  --api-key "$ANTHROPIC_API_KEY" \
  --guild-id "$GUILD_ID" \
  --owner-id "$OWNER_DISCORD_ID" \
  --owner-name "$OWNER_NAME"
```

이 스크립트는:
- ~/.jarvis/.env 생성 (primary, 권한 600)
- ~/.local/share/jarvis/.env 생성 (sync)
- BOT_HOME=~/.local/share/jarvis 자동 포함
- 데이터 디렉토리 8개 자동 생성: logs/ state/ context/ inbox/ results/ rag/ data/ config/

출력 예시:
```json
{ "status": "ok", "paths": ["~/.jarvis/.env", "~/.local/share/jarvis/.env"] }
```

---

## Step 7: 의존성 설치 + 설정 템플릿 복사

Discord 봇 Node.js 의존성 설치:
```bash
npm install --prefix infra/discord
```
- node_modules/ 설치 완료 확인. 실패 시 에러 메시지 표시하고 중단.

설정 템플릿 복사 (이미 있으면 스킵):
```bash
node .claude/skills/onboarding/scripts/copy-config-templates.mjs
```

이 스크립트는:
- infra/config/*.example.json 파일을 ~/.local/share/jarvis/config/ 에 복사
- 파일명에서 .example 제거 (예: models.example.json → models.json)
- 이미 존재하는 파일은 덮어쓰지 않음 (스킵)

---

## Step 8: RAG 셋업 (Optional)

Step 0에서 Ollama가 실행 중인 경우에만 이 단계를 진행합니다.

사용자에게 안내:
```
Ollama가 감지됐습니다. RAG(검색 증강 생성) 기능을 지금 설정하시겠습니까?
임베딩 모델 다운로드가 포함됩니다 (~400MB).

  [Y] 지금 설정
  [N] 건너뛰기 (나중에 python scripts/setup_rag.py 로 설정 가능)

입력 (Y/N):
```

**Y 선택 시:**

Python 버전 확인:
```bash
python3 --version
```
- Python 3.8 미만이면 "Python 3.8 이상이 필요합니다" 안내 후 N 처리.

RAG 셋업 실행:
```bash
python3 scripts/setup_rag.py
```

이 스크립트는:
- Ollama에서 임베딩 모델(nomic-embed-text) 다운로드 (~400MB)
- `~/.local/share/jarvis/rag/` 디렉토리에 벡터 DB 초기화
- Jarvis 지식 베이스 최초 인덱싱

완료 확인: 출력에 `RAG setup complete` 또는 에러 없이 종료 확인.

에러 발생 시:
- `Connection refused` → Ollama가 실행 중인지 확인: `ollama serve`
- `model not found` → `ollama pull nomic-embed-text` 수동 실행 안내

**N 선택 시 또는 Ollama 없는 경우:**
```
⚠️  RAG 기능 비활성 — 나중에 설정하려면:
    1. Ollama 설치: https://ollama.ai
    2. ollama serve 실행
    3. 프로젝트 루트에서: python3 scripts/setup_rag.py
```

---

## Step 9: 업데이트 정책 선택

사용자에게 안내:
```
Jarvis 자동 업데이트 정책을 선택해주세요.

  [A] 자동 업데이트 — 새 릴리즈 발견 시 새벽 3시에 자동으로 설치 & 봇 재시작
  [M] 수동 업데이트 — #🚀jarvis-update 채널에 알림만 발송, 직접 업데이트

입력 (A/M):
```

```bash
node .claude/skills/onboarding/scripts/save-update-policy.mjs --mode <auto|manual>
```

저장 위치: ~/.jarvis/config/update-policy.json

---

## Step 10: 업데이트 전용 채널 생성

환경 파일을 로드하여 🚀jarvis-update 채널을 생성합니다.

```bash
export $(grep -v '^#' ~/.jarvis/.env | grep -v '^$' | xargs)
node .claude/skills/onboarding/scripts/create-update-channel.mjs
```

이 스크립트는:
- 🚀jarvis-update 채널 생성 (system 페르소나 자동 등록)
- .env의 CHANNEL_IDS에 새 채널 ID 추가
- infra/discord/personas.json에 시스템 페르소나 등록
- ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist CHANNEL_IDS 업데이트 (macOS)

출력 예시:
```json
{ "channelId": "1234567890123456789", "channelName": "🚀jarvis-update" }
```

---

## Step 11: LaunchAgent / PM2 등록 (플랫폼별)

**macOS:**
```bash
CHANNEL_ID=<Step 9에서 얻은 channelId>
node .claude/skills/onboarding/scripts/install-launch-agents.mjs --channel-id "$CHANNEL_ID"
```

이 스크립트는:
- ai.jarvis.discord-bot.plist 생성 + launchctl load (봇 자동 시작)
- ai.jarvis.release-checker.plist 생성 + launchctl load (매일 03:00 릴리즈 체크)
- ai.jarvis.watchdog.plist (있으면) 생성 + launchctl load

**Linux / WSL2:**
```bash
npm install -g pm2
pm2 start infra/ecosystem.config.cjs
pm2 startup && pm2 save

# 릴리즈 체커는 crontab에 등록
CHANNEL_ID=<channelId> node .claude/skills/onboarding/scripts/install-linux-cron.mjs --channel-id "$CHANNEL_ID"
```

---

## Step 12: 최종 검증

```bash
node .claude/skills/onboarding/scripts/verify-setup.mjs
```

이 스크립트는 다음을 확인합니다:
- node_modules/ 존재 여부 (infra/discord/)
- discord-bot.js 문법 검증 (node --check)
- 데이터 디렉토리 8개 존재 여부
- .env 파일 존재 + 필수 키 5개 확인
- LaunchAgent 로드 상태 (macOS)

출력:
```json
{
  "passed": 5,
  "total": 5,
  "details": { "discordDeps": true, "botSyntax": true, "dataDirs": true, "envFile": true, "launchAgents": true }
}
```

---

## Step 13: 봇 첫 기동 확인

```bash
sleep 5
tail -10 ~/.local/share/jarvis/logs/discord-bot.log
```

로그 확인:
- Logged in as — 봇 토큰 인증 성공
- Channel personas loaded — 채널 설정 완료
- 에러 없음

에러 발생 시:
- Invalid token → Step 2로 돌아가 토큰 재입력 안내
- Missing Permissions → Discord Developer Portal에서 봇 권한 확인 안내
- npm error → Step 7 npm install 재시도 안내

---

## Step 14: 온보딩 완료 보고

사용자에게 다음 내용 안내:

```
✅ Jarvis 온보딩 완료!

  봇 상태     : 온라인
  업데이트    : <자동|수동> 모드
  알림 채널   : #🚀jarvis-update
  릴리즈 체크 : 매일 새벽 03:00
  RAG         : <활성|비활성 — Ollama 필요>

이제 Discord의 아무 채널에 말을 걸어보세요.
```

---

## 주의사항

- .env 파일은 절대 git에 커밋하지 않음 (.gitignore 등록 확인)
- 봇 토큰이 노출되면 즉시 Discord Developer Portal에서 재발급
- ~/Library/LaunchAgents/ plist 오류 시: launchctl unload && load 재시도
- Linux: PM2 설치 후 pm2 startup으로 부팅 자동 실행 등록 필수
