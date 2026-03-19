# infra-daily — 인프라 일일 점검 컨텍스트

> 매일 실행되는 인프라 상태 점검 작업의 동작 기준, 감지 항목, 자율 처리 지침을 정의한다.
> SSoT: 이 파일. autonomy-levels.md와 함께 적용한다.

---

## 감지 항목

### 1. RAG 상태
```bash
node ~/.jarvis/lib/rag-manager.mjs status
```
- index 크기, 마지막 업데이트 시간 확인
- 마지막 업데이트 > 2시간: 경고
- index 파일 없거나 0바이트: 오류

### 2. 디스크 사용률
```bash
df -h / | awk 'NR==2 {gsub(/%/,""); print $5}'
```
- >85%: Level1 자율 처리 (cleanup-old-logs.sh 실행)
- >90%: Level2 보고 + dev-queue 적재

### 3. 로그 디렉토리 크기
```bash
du -sh ~/.jarvis/logs/
```
- >500MB: 경고 및 자율 정리 실행

### 4. Lock 파일 점검
```bash
ls -la ~/.jarvis/state/*.lock 2>/dev/null
```
- 24시간+ 이상 된 lock 파일: Level1 자율 삭제 대상

### 5. LaunchAgent (cron) 상태
```bash
launchctl list | grep jarvis
```
- tasks.json에 등록된 cron이 launchd에 없는 경우: 재등록 시도

### 6. 활성 태스크 수 추적
```bash
jq '.tasks | map(select(.disabled != true)) | length' ~/.jarvis/config/tasks.json
```
- 결과를 `~/.jarvis/state/infra-task-count.txt`에 저장
- 전일 대비 변화 감지 (±3개 이상 변화 시 보고)

### 7. Stale lock 파일 목록
```bash
find ~/.jarvis/state -name "*.lock" -mmin +1440 2>/dev/null
```
- 24시간(1440분) 이상 된 lock 파일 목록

---

## 자율 처리 지침

> `autonomy-levels.md` 기준: L1 = 자동 실행(로그만), L2 = 자동 실행 + Discord 보고
> infra-daily는 L2 태스크이므로 실행 결과는 항상 Discord에 보고한다.
> 단, 보고 전에 아래 조건의 자율 처리를 먼저 수행하고 결과를 보고에 포함한다.

### Level1 자율 실행 (즉시 처리, 보고에 결과 포함)

| 조건 | 처리 | 비고 |
|------|------|------|
| RAG 건강 이상 (index 없음 / 2h+ stale) | `node ~/.jarvis/lib/rag-manager.mjs rebuild` 실행 | 30분+ 예상 시 dev-queue 적재 |
| 디스크 >85% | `~/.jarvis/scripts/cleanup-old-logs.sh` 실행 후 결과 확인 | 정리 전후 크기 기록 |
| 로그 디렉토리 >500MB | `~/.jarvis/scripts/cleanup-old-logs.sh` 실행 | 정리 전후 크기 기록 |
| Stale lock 파일 (24h+) | `rm ~/.jarvis/state/*.lock` (안전 확인 후) | 실행 중인 프로세스 없는 경우만 |

**Stale lock 파일 안전 확인 절차:**
```bash
# lock 파일 내 PID 확인 후 프로세스 생존 여부 체크
for f in ~/.jarvis/state/*.lock; do
  pid=$(cat "$f" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "SKIP: $f (PID $pid 살아있음)"
  else
    echo "REMOVE: $f"
    rm -f "$f"
  fi
done
```

### Level2 (dev-queue 적재 후 보고)

| 조건 | 처리 |
|------|------|
| 코드 파일 오류 (syntax error) | dev-queue 적재 + #jarvis-system 보고 |
| LaunchAgent 비정상 (PID 없음, 재등록 실패) | 재등록 시도 → 실패 시 ntfy 알림 + dev-queue 적재 |
| RAG 재빌드 30분+ 예상 | dev-queue 적재 (즉시 실행 불가) |
| 디스크 >90% (cleanup 후에도) | dev-queue 적재 + 긴급 보고 |

### LaunchAgent 재등록 처리
```bash
# tasks.json에 있고 launchd에 없는 cron 재등록
TASK_ID="{id}"
bash ~/.jarvis/scripts/launchd-guardian.sh
# launchd-guardian.sh가 없는 경우 직접:
# launchctl load ~/Library/LaunchAgents/com.jarvis.${TASK_ID}.plist
```

### dev-queue 적재 형식

task-store.mjs는 SQLite 기반이며 CLI는 `addTask` 직접 노출 없음.
infra-daily에서의 적재는 `ensure` 또는 `transition` 커맨드를 사용:

```bash
# 방법 1: ensure (cron 태스크 재활성화)
node ~/.jarvis/lib/task-store.mjs ensure "infra-fix-$(date +%Y%m%d)" "인프라 이슈: {설명}" infra-daily

# 방법 2: 직접 SQLite insert (task-store.mjs addTask export 활용)
node -e "
import('~/.jarvis/lib/task-store.mjs').then(({addTask}) => {
  addTask({
    id: 'infra-fix-$(date +%s)',
    status: 'queued',
    priority: 10,
    name: '인프라 이슈: {설명}',
    source: 'infra-daily',
    prompt: '{상세 내용}',
    allowedTools: 'Bash,Read',
    maxBudget: '0.30',
    timeout: 180,
  });
});
"
```

**참고:** task-store.mjs CLI는 `transition`, `pick`, `field`, `list`, `export`, `ensure`, `cb-status`, `check-deps`, `fsm-summary`, `count-queued`, `force-done`, `get` 커맨드를 지원한다. `enqueue` 커맨드는 없음.

---

## 보고 포맷

Discord #jarvis-system 채널에 보고 시 다음 구조를 사용한다:

```
**🔧 인프라 일일 점검** `{날짜}`

**감지 항목:**
- RAG 상태: {정상 / 이상 내용}
- 디스크: {사용률}% ({전체}/{여유})
- 로그 크기: {크기} ({전일 대비})
- 활성 태스크: {수}개 ({전일 대비 변화})
- Lock 파일: {정상 / 삭제된 파일 목록}
- LaunchAgent: {정상 / 이상 내용}

**자율 처리 결과:**
- ✅ {처리 항목}: {결과}
- ⏳ {dev-queue 적재 항목} → dev-queue 적재 (우선순위: high)
- ❌ 처리 불가 항목: {없음 / 목록}
```

---

## 실행 순서

1. 각 감지 항목 수집 (병렬 가능)
2. Level1 자율 처리 실행 (조건 충족 항목)
3. Level2 dev-queue 적재 (조건 충족 항목)
4. 전체 결과 취합 → Discord 보고

---

## 관련 파일

| 파일 | 용도 |
|------|------|
| `~/.jarvis/config/autonomy-levels.md` | 자율처리 레벨 기준 |
| `~/.jarvis/scripts/cleanup-old-logs.sh` | 로그 정리 스크립트 |
| `~/.jarvis/scripts/disk-alert.sh` | 디스크 사용률 체크 |
| `~/.jarvis/scripts/launchd-guardian.sh` | LaunchAgent 상태 관리 |
| `~/.jarvis/lib/task-store.mjs` | dev-queue SQLite 저장소 |
| `~/.jarvis/lib/rag-manager.mjs` | RAG 인덱스 관리 |
| `~/.jarvis/state/infra-task-count.txt` | 활성 태스크 수 전일 비교용 |
