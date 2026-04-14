# Jarvis — Task Completion Checklist

작업 완료 전 반드시 확인할 것.

## 모든 코드 변경 시 (공통)

### 1. 문법 검증
```bash
# Shell
bash -n <changed-file.sh>

# JS/TS (jarvis-board)
cd ~/jarvis-board && npx tsc --noEmit
```

### 2. 안티패턴 검사 (post-edit-lint.sh hook가 자동 실행하지만 수동 확인)
```bash
# set -e + [[ ]] && cmd 패턴 금지
grep -nE '\[\[.*\]\]\s*&&\s*[^|]' <file.sh> | grep -v '#' | grep -v 'if ' | grep -v '|| true'

# claude -p timeout 누락 금지
grep -nE '[^a-z_]claude -p' <file.sh> | grep -v 'timeout' | grep -v '_safe_claude'
```

### 3. 큰 틀 자문 (CLAUDE.md 최상위 규칙)
- [ ] **Root cause**: 증상이 아닌 원인을 찾았는가?
- [ ] **Blast radius**: 같은 원인으로 영향받는 다른 곳은?
- [ ] **Recurrence guard**: 재발 방지 구조(테스트/원장/감사)가 있는가?

### 4. 1회용 스크립트 금지
- 작성한 코드가 **재사용 가능한 패턴**인가? 1회용이면 구조화 가능 여부 먼저 검토.

## tasks.json 변경 시

### 필수 후속 단계
```bash
# 1. JSON 유효성
jq '.' ~/.jarvis/config/tasks.json

# 2. effective-tasks.json 재생성
BOT_HOME=~/.jarvis ~/jarvis/infra/bin/plugin-loader.sh

# 3. 변경된 태스크가 cron에도 등록돼 있는지
crontab -l | grep "<task-id>"
# 없으면 crontab에도 추가해야 함 (자동 동기화 없음)

# 4. 백업
cp ~/.jarvis/config/tasks.json ~/.jarvis/config/tasks.json.bak.$(date +%Y%m%d-%H%M%S)
```

## ask-claude.sh / lib/ 변경 시

### 문서 동기화 hook 자동 트리거
- `infra/docs/OPERATIONS.md` 도 함께 수정 필요 (post-tool hook가 강제)

### Tier 0 ledger 영향 확인
- 새 필드 추가 시: 기존 ledger entries와 호환되는가?
- token-ledger-query.sh / token-ledger-audit.sh 의 jq 쿼리 영향 확인

## 신규 cron 태스크 추가 시

### 2-step 등록 (잊기 쉬움)
```bash
# Step 1: tasks.json에 task 정의 추가 (script 또는 prompt)
# Step 2: crontab에 line 추가
crontab -l > /tmp/crontab.bak
new_line="30 8 * * 0 /bin/bash \$HOME/.jarvis/bin/bot-cron.sh <task-id> >> \$HOME/.jarvis/logs/cron.log 2>&1"
(crontab -l 2>/dev/null; echo "$new_line") | crontab -

# Step 3: plugin-loader 재생성
BOT_HOME=~/.jarvis ~/jarvis/infra/bin/plugin-loader.sh

# Step 4: 수동 한 번 실행해서 START/SUCCESS/DONE 확인
~/.jarvis/bin/bot-cron.sh <task-id>
tail -5 ~/.jarvis/logs/cron.log
```

## 커밋 전

### 변경 범위 확인 (다른 세션 작업 혼입 주의)
```bash
git status -s
git diff --stat HEAD

# 내 작업만 stage (다른 세션 미커밋 변경 보호)
git add <specific-file>      # NOT git add -A 또는 -p 사용
```

### 커밋 메시지 포맷
- conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`
- 본문에 root cause / blast radius / recurrence guard 포함
- Co-Authored-By 줄 마지막에

### Push
```bash
git push origin main
# rebase 필요한 경우:
git stash push -m "unrelated" && git pull --rebase origin main && git push && git stash pop
```

## Discord/봇 변경 시

```bash
# 봇 코드 수정 후 재시작 필요
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot

# 로그 확인
tail -30 ~/.jarvis/logs/discord-bot.log
```

## RAG 변경 시

```bash
# 절대 lancedb 디렉토리 수동 삭제 금지
# 정상 절차:
cd ~/jarvis/rag
npm run stats         # 변경 전 baseline
# (변경 작업)
npm run stats         # diff 확인
npm run repair        # 손상 의심 시
```

## 시각적 검증 (UI 변경 시)
- jarvis-board 변경: 로컬 dev server 띄워서 브라우저 확인 권장
- Type check + build 만으로는 UX regression 검증 불가

## 메모리 (이 디렉토리) 갱신
- 큰 구조 변경 후 `codebase_structure` 메모리 업데이트
- 새 필수 명령어 발견 시 `suggested_commands` 갱신
- 코딩 규칙 변경 시 `style_and_conventions` 갱신
