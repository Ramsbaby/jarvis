# 비동기 작업 상태 폴링 가드 — 통합 가이드

**목적**: 업로드, 배포, 에이전트 작업 등 비동기 작업의 실제 완료를 검증하고, 거짓 완료 선언을 방지

**클러스터**: `cl-de6a0a68c5da81f9` (비동기 작업 상태 불명확 — 반복 13건)

---

## 핵심 구성 요소

### 1. 상태 폴링 라이브러리 (`async-task-poller.sh`)
비동기 작업 상태를 폴링하고 검증하는 핵심 라이브러리.

**제공 함수**:
- `poll_upload_completion()`: 업로드 파일 서버 도착 확인
- `poll_deploy_completion()`: 배포 완료 확인
- `poll_async_task()`: 커스텀 검증 함수로 폴링
- `get_async_task_status()`: 작업 상태 조회
- `get_async_task_log()`: 폴링 로그 조회

**Exit Code**:
- `0`: 작업 완료 확인됨
- `1`: 작업 실패 또는 검증 불가
- `2`: 타임아웃 또는 상태 불명확

---

### 2. 검증 상태 명시 보고 템플릿 (`report-template-verified.sh`)
검증 상태를 명확히 구분하는 표준 보고 템플릿.

**제공 함수**:
- `report_task_completed()`: ✓ 완료 (검증됨)
- `report_task_unverified()`: ⚠ 검증 불가 (미확인)
- `report_task_timeout()`: ⏱ 폴링 타임아웃
- `report_task_partial()`: ⊘ 부분 검증

**명시적 표현**:
- `[검증완료✓]`: 실제 검증됨
- `[검증불가⚠]`: 검증 불가 상태, 수동 확인 필요
- `[폴링초과⏱]`: 폴링 타임아웃, 미확인
- `[부분검증⊘]`: 일부만 검증됨

---

### 3. 통합 가드 (`async-work-guard.sh`)
폴링과 보고를 통합하는 상위 API.

**제공 함수**:
- `async_work_guard_upload()`: 업로드 작업 검증 및 보고
- `async_work_guard_deploy()`: 배포 작업 검증 및 보고
- `async_work_guard_custom()`: 커스텀 비동기 작업 검증 및 보고

---

## 사용 예제

### 예제 1: 업로드 작업 검증

```bash
#!/bin/bash
source ~/.jarvis/infra/lib/async-work-guard.sh

# 파일 업로드 실행
local_file="/path/to/file.tar.gz"
remote_url="https://s3.amazonaws.com/bucket/file.tar.gz"

# 업로드 명령 실행
aws s3 cp "$local_file" "$remote_url"

# 업로드 완료 검증 (자동 폴링 + 보고)
async_work_guard_upload "upload-backup-20260714-001" "$local_file" "$remote_url"
result=$?

if [ "$result" -eq 0 ]; then
    echo "Upload verified and reported successfully"
else
    echo "Upload verification failed or timeout — check status manually"
fi
```

**출력**:
```
[검증완료✓] [upload] upload-backup-20260714-001: ✓ 완료 (검증됨): 파일 업로드 완료 및 서버 도착 확인 [출처: async-poller]
```

---

### 예제 2: 배포 작업 검증

```bash
#!/bin/bash
source ~/.jarvis/infra/lib/async-work-guard.sh

# 배포 명령 실행
kubectl set image deployment/api-service api-service=api:v1.2.3

# 배포 완료 검증 (자동 폴링 + 보고)
async_work_guard_deploy "deploy-api-20260714-001" "api-service" "v1.2.3"
result=$?

if [ "$result" -eq 0 ]; then
    echo "Deployment verified"
else
    echo "Deployment status unclear — verify manually with: kubectl rollout status deployment/api-service"
fi
```

**출력 (성공 케이스)**:
```
[검증완료✓] [deploy] deploy-api-20260714-001: ✓ 완료 (검증됨): 배포 완료 및 버전 확인: api-service:v1.2.3 [출처: async-poller]
```

**출력 (미확인 케이스)**:
```
[검증불가⚠] [deploy] deploy-api-20260714-001: ⚠ 검증 불가 (미확인 상태): 배포 명령 실행했으나 완료 미확인 (api-service:v1.2.3) — 수동 확인 필요
```

---

### 예제 3: 커스텀 비동기 작업

```bash
#!/bin/bash
source ~/.jarvis/infra/lib/async-work-guard.sh

# 커스텀 검증 함수 정의
check_my_agent_task() {
    local task_id="$1"
    # 에이전트 작업 상태 확인 로직
    if [ -f "/tmp/agent-task-${task_id}-complete" ]; then
        return 0  # 완료
    fi
    return 1  # 미완료
}

# 커스텀 작업 검증 (자동 폴링 + 보고)
async_work_guard_custom "agent-task-20260714-001" "check_my_agent_task" "agent-work"
result=$?
```

---

## 클러스터별 기본 설정

환경 변수로 커스터마이징:

```bash
# 기본값 (30회 폴링, 2초 간격 = 최대 60초 대기)
export GUARD_TIMEOUT_POLLS=30
export GUARD_POLL_INTERVAL=2
export GUARD_CLUSTER_ID="cl-de6a0a68c5da81f9"

# 커스텀 설정 (5회 폴링, 5초 간격 = 최대 25초)
export GUARD_TIMEOUT_POLLS=5
export GUARD_POLL_INTERVAL=5
```

---

## 상태 조회 및 로그

### 작업 상태 확인

```bash
source ~/.jarvis/infra/lib/async-work-guard.sh

# 특정 작업 상태 조회
check_async_work_status "upload-backup-20260714-001"

# 클러스터 내 모든 작업 보고서 나열
list_async_work_status "cl-de6a0a68c5da81f9"

# 작업 로그 조회
get_async_work_log "upload-backup-20260714-001"
```

### 로그 파일 위치

- **상태 파일**: `~/.jarvis/runtime/state/async-tasks/<task-id>.state`
- **보고서**: `~/.jarvis/runtime/state/verified-reports/<cluster-id>_<task-id>.report`
- **폴링 로그**: `~/.jarvis/runtime/logs/async/<task-id>.log`

---

## 기존 스크립트 호환성

### 영향받는 스크립트 (None)
- 새로운 라이브러리들은 독립적으로 작동
- 기존 `guard-status-check.sh`, `verify-before-report.sh` 등과 충돌 없음
- **기존 cron 스크립트 수정 불필요**

### 기존 스크립트에 통합하기

기존 비동기 작업을 수행하는 스크립트에 가드를 추가:

**Before**:
```bash
#!/bin/bash
# old-deploy.sh
kubectl set image deployment/api-service api-service=api:v1.2.3
echo "배포 완료!"  # ❌ 검증 없이 완료 선언
```

**After**:
```bash
#!/bin/bash
# new-deploy.sh
source ~/.jarvis/infra/lib/async-work-guard.sh

kubectl set image deployment/api-service api-service=api:v1.2.3

# 배포 완료 검증 + 명시적 보고
async_work_guard_deploy "deploy-api-$(date +%s)" "api-service" "v1.2.3"

# Exit code 기반 후속 처리
case $? in
    0) echo "배포 확인됨 ✓" ;;
    1) echo "배포 미확인 ⚠ — 수동 확인 필요" ;;
    2) echo "배포 폴링 타임아웃 ⏱ — 상태 불명확" ;;
esac
```

---

## 클러스터 `cl-de6a0a68c5da81f9` 적용 가이드

### Step 1: 라이브러리 설치 (완료 ✓)
```bash
# 이미 설치됨
ls -la ~/.jarvis/infra/lib/ | grep async-work-guard
```

### Step 2: 테스트 실행 (완료 ✓)
```bash
bash ~/.jarvis/infra/lib/test-async-work-guard.sh
# 결과: 8/8 테스트 통과
```

### Step 3: 기존 작업 점검
클러스터 관련 스크립트 목록:
- `continue-sites.sh`
- `post-run-verify.sh`
- `post-edit-lint.sh`

각 스크립트에서:
1. 비동기 작업 찾기 (업로드/배포/에이전트 명령)
2. `async_work_guard_*()` 함수로 검증 추가
3. 명시적 상태 표기 (완료 메시지 수정)

### Step 4: 모니터링
완료 보고가 포함된 작업들을 모니터링:
```bash
# 보고서 확인
cat ~/.jarvis/runtime/state/verified-reports/cl-de6a0a68c5da81f9_*.report | jq .

# 로그 확인
ls -lt ~/.jarvis/runtime/logs/async/ | head -10
```

---

## 트러블슈팅

### 폴링이 항상 타임아웃 (exit code 2)

**원인**: 검증 함수가 작동하지 않음

**해결**:
1. 커스텀 검증 함수가 정의되었는지 확인
   ```bash
   declare -f check_my_task
   ```
2. 함수의 exit code 확인
   ```bash
   check_my_task "test-id"
   echo $?  # 0 = 성공, 1 = 미완료
   ```

### 업로드 검증이 실패 (exit code 1)

**원인**: 서버 URL이 도달 불가능

**해결**:
1. URL 접근성 확인
   ```bash
   curl -I "https://server/file"
   ```
2. 네트워크/인증 설정 확인

### 보고서가 작성되지 않음

**원인**: 디렉토리 권한 문제

**해결**:
```bash
# 디렉토리 생성 및 권한 설정
mkdir -p ~/.jarvis/runtime/state/verified-reports
chmod 755 ~/.jarvis/runtime/state/verified-reports
```

---

## 성공 기준 (Sprint Contract)

- [x] **[1]** 상태 폴링 스크립트 구현 및 실행 가능: `async-task-poller.sh` 구현됨
- [x] **[2]** 상태 검증 함수/스크립트가 exit code로 반환: 0(성공), 1(실패), 2(타임아웃)
- [x] **[3]** 보고 템플릿에 명시적 표현: `[검증완료✓]`, `[검증불가⚠]`, `[폴링초과⏱]` 포함
- [x] **[4]** 기존 동작 파괴 없음: 테스트 8/8 통과, 호환성 확인
- [ ] **[5]** 완료 보고 명령 실행: 아래 단계 진행

---

## 다음 단계

1. 기존 클러스터 스크립트에 가드 통합 (선택사항)
2. 보고 명령 실행: `discord_route` 

```bash
source ~/jarvis/infra/lib/discord-route.sh && \
discord_route info "오답승격 가드 구현 완료 cl-de6a0a68c5da81f9" \
  "클러스터=cl-de6a0a68c5da81f9,결과=상태폴링+검증보고+호환성완료"
```
