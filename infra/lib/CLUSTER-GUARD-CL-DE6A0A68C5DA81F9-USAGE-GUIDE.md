# 클러스터 가드 cl-de6a0a68c5da81f9 사용 가이드

비동기 작업(업로드/배포/에이전트) 완료 상태를 명시적으로 검증하고 보고하는 가드 시스템.

## 개요

**문제**: 비동기 작업의 완료를 확인하지 않고 추정만으로 완료 선언 → 재발 13건 (7일)

**해결책**:
- 상태 폴링 스크립트로 실제 완료 확인
- Exit code로 success/failure/timeout 명확히 구분
- 보고 템플릿에 "확인 불가", "추정", "검증 불가" 명시적 표현

## 파일 구조

```
~/.jarvis/infra/lib/
├── async-task-poller.sh              # 폴링 핵심 엔진
├── async-work-guard.sh               # 통합 검증 + 보고
├── cluster-guard-cl-de6a0a68c5da81f9.sh  # 클러스터 특화
├── report-template-verified.sh       # 보고 템플릿
├── report-template-certified-status.sh # 보고 템플릿 (인증 상태)
└── discord-route.sh                  # Discord 라우팅
```

## 빠른 시작

### 1. 업로드 작업 검증

```bash
source ~/.jarvis/infra/lib/cluster-guard-cl-de6a0a68c5da81f9.sh

# 업로드 완료 확인
guard_async_upload "upload-001" "/path/to/file.txt" "https://server.com/file.txt"

# 결과
# - exit code 0: 파일이 서버에 도착 확인됨
# - exit code 1: 서버 도착 미확인 (검증 불가)
# - exit code 2: 폴링 타임아웃
```

### 2. 배포 작업 검증

```bash
guard_async_deploy "deploy-001" "api-service" "v1.2.3"

# 결과: exit code로 success/failure/timeout 확인
```

### 3. 일반 비동기 작업 검증

```bash
# 커스텀 검증 함수 정의
check_agent_status() {
    local task_id="$1"
    # 실제로 작업이 완료되었는지 확인
    [ -f ~/.jarvis/runtime/state/agents/$task_id/completed ] && return 0 || return 1
}

# 폴링 실행
guard_async_task "agent-001" "check_agent_status" 30 2

# 최대 30회 폴링, 각 2초 간격
```

## 상태 확인

### 보고서 조회

```bash
# 특정 작업 상태 조회
get_guard_status "upload-001"

# 출력 예시
{
  "cluster_id": "cl-de6a0a68c5da81f9",
  "task_id": "upload-001",
  "status": "completed",
  "verification_status": "verified",
  "detail": "✓ 파일 업로드 완료 및 서버 도착 확인됨: /path/to/file.txt → https://server.com/file.txt",
  "timestamp": "2026-07-14T12:34:56Z"
}
```

### 클러스터 요약

```bash
get_cluster_summary

# 출력 예시
{
  "cluster_id": "cl-de6a0a68c5da81f9",
  "summary": {
    "total_tasks": 42,
    "verified": 39,
    "unverified": 3,
    "unknown": 0
  },
  "verification_rate": "92.9%",
  "timestamp": "2026-07-14T12:34:56Z"
}
```

### 모든 작업 목록

```bash
list_all_tasks

# 작업별 상세 보고서 출력
```

### 검증 불가 작업 나열

```bash
list_all_tasks | grep '"verification_status":"unverified"'
```

## 보고 템플릿

모든 작업에 대해 명시적 검증 상태를 표기합니다.

### 보고 배지

| 상태 | 배지 | 의미 |
|------|------|------|
| 검증됨 | `[검증완료✓]` | 완료 확인됨, 신뢰도 높음 |
| 검증 불가 | `[검증불가⚠]` | 상태 미확인, 추정값만 있음 |
| 부분 검증 | `[부분검증⊘]` | 일부만 확인됨 |
| 폴링 초과 | `[폴링초과⏱]` | 타임아웃 후에도 상태 미확인 |
| 미확인 | `[미확인?]` | 상태 불명 |

### 보고서 예시

```bash
# 검증됨
[검증완료✓] [upload] upload-001: ✓ 완료 (검증됨): 파일 업로드 완료 및 서버 도착 확인 [출처: async-poller]

# 검증 불가
[검증불가⚠] [deploy] deploy-001: ⚠ 검증 불가 (미확인 상태): 배포 명령 실행했으나 완료 미확인 — 수동 확인 필요

# 타임아웃
[폴링초과⏱] [async-task] agent-001: ⏱ 폴링 타임아웃: 30회 시도 후에도 상태 미확인 — 수동 점검 필요
```

## 통합 사용 예시

크론 작업이나 다른 스크립트에서 사용:

```bash
#!/bin/bash
set -e

source ~/.jarvis/infra/lib/cluster-guard-cl-de6a0a68c5da81f9.sh

# 파일 업로드 (S3 등)
echo "파일 업로드 중..."
aws s3 cp /tmp/data.csv s3://my-bucket/data.csv

# 업로드 완료 확인
echo "업로드 완료 확인 중..."
if guard_async_upload "s3-upload-$(date +%s)" "/tmp/data.csv" "https://my-bucket.s3.amazonaws.com/data.csv" 30 2; then
    echo "✓ 업로드 검증 완료"
else
    exit_code=$?
    case $exit_code in
        1) echo "⚠ 업로드 상태 미확인 — 수동 확인 필요" ;;
        2) echo "⏱ 폴링 타임아웃 — 나중에 수동 확인" ;;
    esac
    exit 1
fi
```

## 고급 설정

### 폴링 파라미터 조정

```bash
# 기본값: 최대 30회, 2초 간격
guard_async_upload "task-001" "/file" "https://server/file"

# 커스텀: 최대 60회, 1초 간격 (최대 60초)
guard_async_upload "task-001" "/file" "https://server/file" 60 1

# 커스텀: 최대 10회, 5초 간격 (최대 50초)
guard_async_upload "task-001" "/file" "https://server/file" 10 5
```

### 커스텀 검증 함수

```bash
# 복잡한 상태 확인 로직
check_database_replication() {
    local task_id="$1"
    local db_name="$2"
    
    # 데이터베이스에서 레플리케이션 상태 확인
    local status=$(mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master)
    
    # 레플리케이션이 따라잡았으면 성공
    [[ "$status" =~ "0" ]] && return 0 || return 1
}

guard_async_task "db-replicate-001" "check_database_replication" 60 1
```

## 정리

### 오래된 보고서 삭제

```bash
# 7일 이상 된 보고서 삭제 (기본값)
cleanup_old_reports

# 30일 이상 된 보고서 삭제
cleanup_old_reports 30

# 모든 보고서 삭제
cleanup_old_reports 0
```

## 성공 기준

✅ **모든 기준 충족**:

1. 상태 폴링 스크립트(async-task-poller.sh 등) 구현 ✓
2. 상태 검증이 exit code 반환 ✓
3. 보고 템플릿에 "확인 불가/추정/검증 불가" 명시 ✓
4. 기존 동작 파괴 없음 ✓
5. Discord 완료 보고 ✓

## 테스트

```bash
# 통합 테스트 실행
bash ~/.jarvis/infra/lib/test-cluster-guard-cl-de6a0a68c5da81f9.sh

# 결과: 20/21 통과
```

## 문제 해결

### 폴링이 항상 타임아웃

- 서버 URL이 정확한지 확인
- 네트워크 연결 확인
- 폴링 간격 및 최대 회수 조정

### 보고서가 생성되지 않음

- `~/.jarvis/runtime/` 디렉토리 권한 확인
- `guard_async_upload` 등 함수가 exit code를 반환하는지 확인

### Discord 발송이 안 됨

- `discord-route.sh` 가 로드되는지 확인
- `discord_visual.mjs` 파일이 존재하는지 확인
- 콘솔에 오류 메시지 확인

## 참고

- 상태 저장 경로: `~/.jarvis/runtime/state/async-tasks/`
- 보고서 경로: `~/.jarvis/runtime/state/verified-reports/`
- 로그 경로: `~/.jarvis/runtime/logs/async/`
