# Jarvis 설치 가이드

Jarvis는 macOS 네이티브, Linux, Windows(Docker) 환경을 지원합니다.

---

## Windows — 빠른 시작 (5분)

### 사전 준비: 필요한 것들 미리 모으기

설치 전에 아래 4가지를 준비해두면 5분 안에 끝납니다.

**① Discord 봇 토큰**

1. https://discord.com/developers/applications 접속
2. 우측 상단 **New Application** 클릭 → 이름 입력 → Create
3. 좌측 메뉴 **Bot** 클릭
4. **Reset Token** 클릭 → 토큰 복사 (한 번만 표시됨, 안전한 곳에 저장)
5. 같은 페이지 하단 **Privileged Gateway Intents** 에서 **Message Content Intent** 활성화
6. 좌측 메뉴 **OAuth2 → URL Generator** 클릭
7. Scopes: `bot` 체크 → Bot Permissions: `Send Messages`, `Read Message History`, `View Channels` 체크
8. 생성된 URL로 봇을 Discord 서버에 초대

**② Anthropic API 키**

1. https://console.anthropic.com 접속 → 로그인 또는 회원가입
2. 좌측 메뉴 **API Keys** 클릭
3. **Create Key** 클릭 → 키 복사 (한 번만 표시됨)

**③ Discord 서버 ID (Guild ID)**

1. Discord 앱 실행 → **설정(톱니바퀴)** → **고급** → **개발자 모드** 활성화
2. Discord로 돌아와서 봇을 초대한 서버 아이콘 우클릭
3. **서버 ID 복사** 클릭

**④ Discord 채널 ID**

1. 봇이 응답할 채널 이름 우클릭
2. **채널 ID 복사** 클릭
3. 여러 채널이면 쉼표로 구분: `123456789,987654321`

---

### 요구사항

- Windows 10 21H2+ / Windows 11
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (무료)
- Git for Windows (https://git-scm.com/download/win)

### WSL2 활성화 (Docker Desktop 필수 요구사항)

Docker Desktop은 내부적으로 WSL2를 사용합니다. 설치 전에 활성화하세요.

PowerShell을 **관리자 권한**으로 열고 실행:

```powershell
wsl --install
```

설치 후 **재부팅** 필요. 이미 WSL2가 설치된 경우 이 단계를 건너뜁니다.

재부팅 후 WSL2 버전 확인:

```powershell
wsl --status
```

`Default Version: 2` 가 표시되면 정상입니다.

---

### 원클릭 설치 (setup.ps1 권장)

PowerShell을 **관리자 권한**으로 열고:

```powershell
# 1회만 필요: 스크립트 실행 허용
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

git clone https://github.com/Ramsbaby/jarvis $env:USERPROFILE\.jarvis
cd $env:USERPROFILE\.jarvis
.\setup.ps1
```

스크립트가 Docker 확인, .env 생성, 필수 항목 대화형 입력, Claude 경로 자동 설정, 컨테이너 시작을 자동으로 처리합니다.

---

### 수동 설치

**1. Docker Desktop 설치**

https://www.docker.com/products/docker-desktop/ 에서 다운로드 및 설치.
설치 후 Docker Desktop을 실행하고 트레이 아이콘이 초록색인지 확인.

**2. 프로젝트 클론**

PowerShell 또는 Git Bash:

```powershell
git clone https://github.com/Ramsbaby/jarvis $env:USERPROFILE\.jarvis
cd $env:USERPROFILE\.jarvis
```

**3. 환경변수 설정**

```powershell
copy .env.example .env
notepad .env
```

**4. .env 필수 항목 체크리스트**

메모장에서 아래 항목을 채웁니다:

- [ ] `DISCORD_TOKEN` — Discord 봇 토큰 (위 ① 참고)
- [ ] `ANTHROPIC_API_KEY` — Anthropic API 키 (위 ② 참고)
- [ ] `GUILD_ID` — Discord 서버 ID (위 ③ 참고)
- [ ] `CHANNEL_IDS` — 봇이 응답할 채널 ID (위 ④ 참고, 쉼표 구분)
- [ ] `OWNER_DISCORD_ID` — 본인 Discord 사용자 ID (본인 프로필 우클릭 → ID 복사)

선택 항목 (비워도 됨):

- [ ] `BOT_NAME` — 봇 이름 (기본값: `Jarvis`)
- [ ] `OWNER_NAME` — 오너 이름 (기본값: `Owner`)
- [ ] `NTFY_TOPIC` — 모바일 푸시 알림 토픽 (ntfy.sh)
- [ ] `OPENAI_API_KEY` — 음성 메시지 텍스트 변환용

**5. 실행**

```powershell
docker compose up -d
```

**6. 상태 확인**

```powershell
docker logs jarvis --follow
docker compose ps
```

**7. 중지**

```powershell
docker compose down
```

---

## macOS (네이티브) — 권장

### 요구사항

- macOS 12+
- Node.js 22+
- Homebrew
- **Claude Max 구독** — `claude -p` 기반 동작. 구독 없이는 아무것도 동작하지 않음.
- **Claude Code CLI 인증** — `npm install -g @anthropic-ai/claude-code` 후 `claude` 실행 → 브라우저 인증 완료. `claude --version` 으로 확인.
- **`OPENAI_API_KEY`** — RAG 벡터 임베딩 사용 시 필요 (Tier 1 이상). RAG 없이 기본 설치만 할 경우 불필요.

### 설치

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
cp .env.example .env
nano .env  # 토큰 입력
```

### 원클릭 설치 (setup.sh 권장)

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
chmod +x setup.sh
./setup.sh
```

### 환경변수 설정

`.env` 파일에서 필수 항목 입력:

```
DISCORD_TOKEN=your_discord_bot_token
ANTHROPIC_API_KEY=your_anthropic_api_key
GUILD_ID=your_guild_id
CHANNEL_IDS=channel_id1,channel_id2
OWNER_DISCORD_ID=your_discord_user_id
```

### 실행 (launchd — 자동시작)

```bash
cp ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist

# 상태 확인
launchctl list | grep jarvis
```

### 실행 (PM2 — 대안)

```bash
npm install -g pm2
pm2 start ecosystem.config.cjs
pm2 startup && pm2 save
```

---

## Linux (네이티브)

### 요구사항

- Ubuntu 22.04+ / Debian 12+ / RHEL 9+
- Node.js 22+
- PM2

### 설치

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
cp .env.example .env
nano .env  # 토큰 입력
```

### 원클릭 설치 (setup.sh 권장)

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
chmod +x setup.sh
./setup.sh
```

### 실행 (PM2 + systemd)

```bash
npm install -g pm2
cd ~/.jarvis
pm2 start ecosystem.config.cjs
pm2 startup systemd  # 자동시작 등록 명령어 출력됨
pm2 save
```

### 상태 확인

```bash
pm2 list
pm2 logs jarvis-bot --lines 50
```

---

## 공통: 환경변수 레퍼런스

**필수**

- `DISCORD_TOKEN` — Discord 봇 토큰 (discord.com/developers/applications)
- `ANTHROPIC_API_KEY` — Anthropic API 키 (console.anthropic.com)
- `GUILD_ID` — 슬래시 커맨드 등록 대상 서버 ID
- `CHANNEL_IDS` — 봇이 응답할 채널 ID (쉼표 구분)
- `OWNER_DISCORD_ID` — 오너 Discord 사용자 ID

**선택**

- `BOT_NAME` — 봇 이름 (기본: `Jarvis`)
- `BOT_LOCALE` — 응답 로케일 `ko` / `en` (기본: `ko`)
- `OWNER_NAME` — 오너 이름 (기본: `Owner`)
- `OWNER_TITLE` — 오너 직함
- `JARVIS_HOME` — 설치 경로 (기본: `~/.jarvis`)
- `NODE_ENV` — 환경 (기본: `production`)
- `NTFY_TOPIC` — ntfy 모바일 알림 토픽
- `OPENAI_API_KEY` — 음성 메시지 Whisper 변환
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` — Google Calendar 연동

---

## 트러블슈팅

### 봇이 온라인이지만 메시지에 응답하지 않음

- `.env` 의 `CHANNEL_IDS` 에 해당 채널 ID가 포함되어 있는지 확인
- Discord 개발자 모드에서 채널 ID를 다시 복사해서 비교
- 채널 ID가 여러 개면 공백 없이 쉼표로 구분: `123,456` (공백 금지)
- 봇이 해당 채널의 메시지 읽기/쓰기 권한이 있는지 확인

### docker compose up 실패

- Docker Desktop이 실행 중인지 확인 (트레이 아이콘 초록색)
- WSL2가 설치되어 있는지 확인: `wsl --status`
- WSL2 미설치 시: PowerShell 관리자 권한에서 `wsl --install` 후 재부팅
- 포트 충돌 시: `docker ps` 로 기존 컨테이너 확인 후 `docker compose down`

### API 오류 (Anthropic)

- `ANTHROPIC_API_KEY` 값이 `sk-ant-` 로 시작하는지 확인
- https://console.anthropic.com 에서 키가 활성 상태인지 확인
- 크레딧 잔액 확인 (무료 크레딧 소진 시 결제 필요)

### Discord 봇 토큰 오류

- `DISCORD_TOKEN` 값이 정확히 복사됐는지 확인 (앞뒤 공백 제거)
- Discord Developer Portal에서 토큰을 재생성해서 업데이트
- 토큰 재생성 후 반드시 `docker compose down && docker compose up -d` 재시작

### PM2 프로세스 재시작

```bash
pm2 restart jarvis-bot
```

### Docker 컨테이너 재빌드

```bash
docker compose down
docker compose up -d --build
```

### 로그 확인

```bash
pm2 logs jarvis-bot --lines 100     # Linux/macOS PM2
docker logs jarvis --tail 100        # Windows/Docker
```

---

## 지원 OS 매트릭스

- macOS 12+ : launchd 또는 PM2, 자동시작 지원, 공식 지원
- Ubuntu 22.04+ : PM2 + systemd, 자동시작 지원, 공식 지원
- Windows 10/11 : Docker Desktop, 자동시작 지원, 공식 지원
- Windows (WSL2) : PM2, 자동시작 지원, 실험적
