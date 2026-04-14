# Jarvis — Suggested Commands (macOS Darwin)

## 시스템 (macOS 특화)

```bash
# 디스크 사용량
df -h /
du -sh ~/.jarvis/state ~/.jarvis/logs ~/.jarvis/rag

# Apple Silicon CPU/GPU/온도
macmon

# 프로세스 + 메모리
btop

# 프로세스 검색 (Linux의 ps aux 대신)
pgrep -fl discord-bot

# 시간 (KST 기준)
date  # macOS는 시스템 timezone 기본, KST 설정돼 있다고 가정
```

## Git

```bash
cd ~/jarvis
git status -s
git log --oneline -10
git diff --stat HEAD
git push origin main      # main에 직접 push (1인 운영)
```

## Jarvis 핵심 유틸리티

### 태스크 관리
```bash
# tasks.json 직접 편집 후
BOT_HOME=~/.jarvis ~/jarvis/infra/bin/plugin-loader.sh   # effective-tasks.json 재생성

# 특정 태스크 수동 실행
~/.jarvis/bin/bot-cron.sh <task-id>

# 크론 로그 tail
tail -f ~/.jarvis/logs/cron.log
tail -f ~/.jarvis/logs/cron.log | grep "\[task-name\]"

# 특정 태스크 stderr (LLM CLI)
tail -50 ~/.jarvis/logs/claude-stderr-<task-id>-$(date +%F).log
```

### 토큰 원장 (Tier 0 SSoT)
```bash
# 오늘 지출
~/jarvis/infra/scripts/token-ledger-query.sh today

# Top 10 비용
~/jarvis/infra/scripts/token-ledger-query.sh top 10

# Dedup 후보 (5회+ 동일 hash)
~/jarvis/infra/scripts/token-ledger-query.sh dedup 5

# 예산 압박
~/jarvis/infra/scripts/token-ledger-query.sh budget

# 특정 태스크 최근 20건
~/jarvis/infra/scripts/token-ledger-query.sh task github-monitor

# 전체 통계
~/jarvis/infra/scripts/token-ledger-query.sh stats
```

### 주간 감사 수동 실행
```bash
BOT_HOME=~/.jarvis ~/jarvis/infra/scripts/token-ledger-audit.sh
BOT_HOME=~/.jarvis ~/jarvis/infra/scripts/tune-task-params.sh
```

### Evaluator 단독 테스트
```bash
~/jarvis/infra/lib/evaluator.sh github-monitor "GitHub: 알림 없음" "prompt"
# verdict=warn reason=thin_result (3W) 등 출력
```

### Discord 봇
```bash
# 상태 확인
launchctl list | grep discord
pgrep -fl discord-bot

# 재시작 (watchdog 자동, 수동 필요시)
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot

# 로그
tail -50 ~/.jarvis/logs/discord-bot.log
```

### RAG
```bash
cd ~/jarvis/rag
npm run stats              # 인덱스 통계
npm run query "검색어"     # 쿼리
npm run compact            # GC (수동)
npm run repair             # 손상 복구
```

## crontab 관리

```bash
crontab -l                                 # 전체 조회
crontab -l | grep "<task-id>"              # 특정 태스크
crontab -l > /tmp/crontab.bak.YYYYMMDD     # 백업 (편집 전 필수)
```

## launchd

```bash
launchctl list | grep jarvis               # Jarvis 관련 모두
launchctl bootout gui/$(id -u)/<label>     # 언로드
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>  # 로드
launchctl kickstart -k gui/$(id -u)/<label>  # 강제 재시작
```

## Discord 알림 (수동)

```bash
~/.jarvis/scripts/alert.sh warning "제목" "내용"
~/.jarvis/scripts/alert.sh critical "긴급" "메시지"
# 4 levels: critical / warning / info / success
```

## 빌드/검증 (jarvis 레포)

```bash
# 쉘 스크립트 syntax
bash -n <script.sh>

# tasks.json 유효성
jq '.' ~/.jarvis/config/tasks.json

# 쉘 스크립트 안티패턴 검사 (post-edit-lint.sh hook가 자동)
grep -nE '\[\[.*\]\]\s*&&\s*[^|]' <file.sh>
```

## ⚠️ 절대 금지

```bash
# RAG DB 수동 초기화 금지
rm -rf ~/.jarvis/rag/lancedb/    # 절대 하지 말 것 (memory: feedback_rag_never_drop)

# 토큰 원장 임의 삭제 금지 (90일 보존)
# > ~/.jarvis/state/token-ledger.jsonl

# tasks.json 직접 수정 후 plugin-loader 안 돌리기 금지
```
