# Quick Start: Cluster Guard cl-3e0048f79eb206f9

## 5분 안에 시작하기

### 1. 검증 (30초)

```bash
# 테스트 실행 (모든 기능 검증)
bash ~/.jarvis/lib/test-cluster-guard-cl-3e0048f79eb206f9.sh

# 예상 결과:
# ✓ All tests passed!
```

### 2. 기본 사용 (1분)

**방법 A: ask-claude-safe 사용 (권장)**

```bash
#!/bin/bash
source ~/.jarvis/lib/ask-claude-safe.sh

# 중복 감지 + ask-claude 실행 (원본과 동일 인터페이스)
ask_claude_safe "my-task" "Do something" "Read,Edit" "300"
```

**방법 B: 수동 컨트롤**

```bash
#!/bin/bash
source ~/.jarvis/lib/idempotency-middleware.sh

task_id="my-task"
prompt="Do something"

# 중복 확인
result=$(check_and_protect_duplicate "$task_id" "$prompt")
if [[ $? -ne 0 ]]; then
    echo "중복 명령 또는 진행중입니다"
    exit 1
fi

# ask-claude.sh 실행
your-claude-script.sh "$task_id" "$prompt"

# 완료 기록
mark_command_completed "$task_id" "$prompt" "Success"
```

### 3. 상태 확인 (30초)

```bash
#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

# 진행 중인 명령 확인
list_pending_commands

# 최근 상태 확인
dump_state_db
```

---

## 일반적인 시나리오

### 시나리오: "동일한 명령이 2번 실행되는 상황 방지"

```bash
#!/bin/bash
# task1.sh
source ~/.jarvis/lib/ask-claude-safe.sh

ask_claude_safe "analyze-code" "Analyze this code: $file" "Read"

# 첫 실행: 정상 진행
# 동일 명령 재실행: ⚠️ 경고 + 상태 유지 (재실행 안 됨)
```

### 시나리오: "Cron에서 정기적으로 실행되는 작업 보호"

```bash
#!/bin/bash
# daily-report.sh (crontab에서 호출)

source ~/.jarvis/lib/ask-claude-safe.sh

ask_claude_safe \
  "daily-report-$(date +%Y%m%d)" \
  "Generate daily report" \
  "Read,Bash" \
  "600"

# 매일 새로운 task_id로 실행되므로 중복 안 함
# 같은 날 중복 호출 시 상태 유지
```

### 시나리오: "실행 중인 작업이 완료될 때까지 대기"

```bash
#!/bin/bash
source ~/.jarvis/lib/idempotency-middleware.sh

task="long-running-task"
prompt="Do heavy computation"

# 중복 체크
check_and_protect_duplicate "$task" "$prompt"
case $? in
  0)
    echo "새로운 작업 시작"
    your-script.sh "$task" "$prompt"
    mark_command_completed "$task" "$prompt"
    ;;
  1)
    echo "작업이 진행 중입니다. 완료될 때까지 대기..."
    while true; do
      sleep 5
      if ! check_command_duplicate "$prompt" | grep -q "running"; then
        echo "작업 완료!"
        break
      fi
    done
    ;;
esac
```

---

## 문제 해결

### Q: "명령이 진행 중이라고만 나옴"

**원인:** 이전 실행이 강제 종료되거나 crash하여 상태가 'running'으로 남아있음

**해결:**

```bash
#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

# 상태 확인
get_command_status "command-hash"

# 강제 초기화 (테스트/관리용)
clear_command_state "command-hash"
```

### Q: "SQLite DB 오류"

**원인:** 권한 문제 또는 디스크 부족

**해결:**

```bash
# 권한 확인
ls -la ~/.jarvis/runtime/state/command-state-*.db

# 기존 DB 재생성
rm ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db
bash ~/.jarvis/lib/test-cluster-guard-cl-3e0048f79eb206f9.sh
```

### Q: "성능이 느려짐"

**원인:** 테이블이 너무 커짐 (몇 만 개 이상)

**해결:**

```bash
#!/bin/bash
# 7일 이상 오래된 완료 기록 삭제
sqlite3 ~/.jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db << 'EOF'
DELETE FROM task_state 
WHERE status = 'completed' 
  AND completed_at < (strftime('%s', 'now') - 7*86400);

-- 인덱스 재구축
REINDEX;
EOF
```

---

## API 간단 레퍼런스

### check_and_protect_duplicate

```bash
source ~/.jarvis/lib/idempotency-middleware.sh

check_and_protect_duplicate "task-id" "prompt" ["cluster-id"]

# 반환값:
#   0 = OK (새 명령)
#   1 = 진행중 (차단)
#   2 = 완료됨 (경고, 진행 가능)
#   3 = 실패 (경고, 재시도 가능)
```

### ask_claude_safe

```bash
source ~/.jarvis/lib/ask-claude-safe.sh

ask_claude_safe "task-id" "prompt" [tools] [timeout] [budget] [retention] [model]

# ask-claude.sh와 동일한 인터페이스
# 자동으로 멱등성 체크 수행
```

### list_pending_commands

```bash
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh

list_pending_commands
# 출력: 진행 중인 모든 명령 목록 (해시, 텍스트, 상태, 시간)
```

---

## 더 알아보기

```bash
# 상세 가이드
cat ~/.jarvis/lib/CLUSTER-GUARD-CL-3E0048F79EB206F9-GUIDE.md

# 통합 테스트 보고서
cat ~/.jarvis/lib/CLUSTER-GUARD-CL-3E0048F79EB206F9-INTEGRATION-TEST.md

# 전체 구현 요약
cat ~/.jarvis/lib/CLUSTER-GUARD-CL-3E0048F79EB206F9-IMPLEMENTATION-SUMMARY.md
```

---

## 체크리스트

- [ ] 테스트 실행 (`test-cluster-guard-*.sh`) 완료
- [ ] 기존 스크립트에서 `ask-claude-safe` 사용 시작
- [ ] 진행 중인 명령이 없는지 확인 (`list_pending_commands`)
- [ ] 주간 정리 스크립트 추가 (선택)

---

**상태:** ✅ 프로덕션 준비 완료  
**테스트:** 8/8 통과  
**호환성:** 100% 파괴 없음
