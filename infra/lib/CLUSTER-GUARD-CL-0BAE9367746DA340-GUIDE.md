# 슬랭/신조어 검증 가드 (cl-0bae9367746da340)

## 문제 정의

**클러스터 ID**: cl-0bae9367746da340  
**재발 빈도**: 12건/7일 (높음)  
**전형적 오류**:
- 존재하지 않는 슬랭 의미 조합 후 카드뉴스 제작
- 실존하지 않은 슬랭을 조사 없이 사용 후 오류 인정
- 할루시네이션된 한국 슬랭 정의 — 존재하지 않는 의미 제시
- 실제 의미 모르는 슬랭을 임의 조합·추가
- 검증 없이 슬랭·표현을 창작해 사실처럼 제시

## 솔루션 개요

**핵심**: 슬랭/신조어 포함 콘텐츠 생성 시 WebSearch 기반 검증을 **강제**합니다.

### 아키텍처

```
콘텐츠 생성 파이프라인
  ↓
[검증 게이트] — 슬랭 감지 및 WebSearch 검증
  ↓
  ├─ PASSED: 콘텐츠 발행 진행
  └─ FAILED: 작업 중단 + [UNVERIFIED_SLANG] 마크
```

### 주요 컴포넌트

1. **slang-validator.mjs** (Node.js)
   - Claude API를 사용한 슬랭 추출
   - WebSearch 기반 검증 로직
   - 캐시 저장소 (반복 검증 최소화)

2. **cluster-guard-cl-0bae9367746da340.sh** (Bash)
   - 검증 게이트 인터페이스
   - 상태 관리 및 로깅
   - CLI 제공

---

## 설치 & 초기화

### 1단계: 의존성 확인

```bash
# Node.js & npm 확인
node --version  # v16+ 권장
npm list @anthropic-ai/sdk

# npm에서 의존성 설치되지 않았으면
npm install @anthropic-ai/sdk
```

### 2단계: 가드 초기화

```bash
# 상태 초기화
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh init

# 또는 직접 sourcing
source ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh
get_guard_status
```

---

## 사용 방법

### 기본 검증 (CLI)

```bash
# 콘텐츠 검증
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh validate \
  "이건 완전 꿀잼인데, 진짜 대박이야! 요즘 트렌드는 '핑크팬더 무드'가 뜨고있어."

# 결과 예시 (PASSED)
{
  "status": "PASSED",
  "unverifiedTerms": [],
  "verifications": [
    {
      "term": "꿀잼",
      "isValid": true,
      "verdict": "VERIFIED",
      "confidence": 0.95
    }
  ]
}

# 결과 예시 (FAILED)
{
  "status": "FAILED",
  "unverifiedTerms": [
    {
      "term": "핑크팬더 무드",
      "context": "요즘 트렌드는 '핑크팬더 무드'가 뜨고있어",
      "verdict": "UNVERIFIED",
      "confidence": 0.1
    }
  ]
}
```

### 상태 조회

```bash
# 가드 전체 상태
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh status

# 최근 검증 이력
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh logs 20

# 통합 리포트
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh report
```

---

## 파이프라인 통합

### 패턴 1: Bash 스크립트 통합

```bash
#!/bin/bash
# content-generation-pipeline.sh

set -euo pipefail

CONTENT="사용자 생성 콘텐츠..."

# 슬랭 검증 게이트
VALIDATION=$( \
  ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh validate "$CONTENT"
)

if ! echo "$VALIDATION" | jq -e '.status == "PASSED"' > /dev/null; then
  echo "❌ 슬랭 검증 실패: 미확인 슬랭 감지"
  
  # 실패 처리
  MARKED_CONTENT=$(mark_content_unverified "$CONTENT" "$VALIDATION")
  
  # 관리자 알림 & 작업 중단
  echo "$MARKED_CONTENT" | tee /tmp/unverified-content.txt
  exit 1
fi

echo "✅ 검증 통과: 콘텐츠 발행 진행"
# 콘텐츠 발행 로직...
```

### 패턴 2: 크론 작업 통합

```bash
# ~/.jarvis/crontab-entries

# 매일 오전 8시, 미확인 슬랭 리포트 생성
0 8 * * * \
  ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh report | \
  jq '.statistics' > ~/.jarvis/runtime/state/slang-daily-report.json
```

### 패턴 3: ask-claude.sh 후킹

```bash
# ask-claude-with-slang-guard.sh

#!/bin/bash
source ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh

PROMPT="$1"

# Step 1: Claude에서 콘텐츠 생성
GENERATED_CONTENT=$(claude -p "카드뉴스 생성하기: $PROMPT" 2>/dev/null)

# Step 2: 슬랭 검증
VALIDATION=$(validate_slang_in_content "$GENERATED_CONTENT" 30)

if should_proceed_with_content "$VALIDATION"; then
  echo "$GENERATED_CONTENT"
else
  # 실패: 마크 처리
  mark_content_unverified "$GENERATED_CONTENT" "$VALIDATION"
  exit 1
fi
```

---

## 검증 엔진 상세

### 1. 슬랭 추출 (Claude)

Claude가 콘텐츠에서 다음을 자동 감지합니다:

| 위험도 | 설명 | 예시 |
|--------|------|------|
| **low** | 광범위하게 인정된 슬랭 | 대박, 꿀잼, 뭐하는데 |
| **medium** | 최근 신조어 (검증 권장) | 휘갈로, 이대남 |
| **high** | 미확인/임의 조합 표현 | 핑크팬더무드, 초금시 |

### 2. WebSearch 검증 (Claude + Search)

각 **high/medium** 위험 슬랭에 대해:

1. Claude가 "이 용어가 실제로 사용되는가?"를 평가
2. 실제 사용 사례·의미 확인
3. 신뢰도 점수 (0.0~1.0) 할당

**신뢰도 임계값**: 0.6 이상 + VERIFIED 판정 = 통과

### 3. 캐시 및 멱등성

```bash
# 캐시 저장소
~/.jarvis/runtime/state/cluster-guards/slang-validation-db.jsonl

# 형식
{
  "timestamp": "2026-07-23T14:30:00Z",
  "term": "꿀잼",
  "isValid": true,
  "sources": ["실제 사용 예시 1", "예시 2"],
  "clusterId": "cl-0bae9367746da340"
}
```

같은 슬랭을 재검증하면 캐시에서 즉시 반환 (API 호출 절약).

---

## 오류 처리

### 타임아웃 (기본값: 30초)

```bash
# 타임아웃 설정 변경
validate_slang_in_content "콘텐츠" 60  # 60초로 연장
```

### API 오류

Claude API 호출 실패 시:

```json
{
  "status": "ERROR",
  "error": "invalid_json",
  "raw": "..."
}
```

→ **작업 중단** (안전한 기본 동작)

### 부분 검증 실패

일부 슬랭만 미확인된 경우:

```bash
{
  "status": "FAILED",
  "unverifiedTerms": [
    {"term": "A", "verdict": "UNVERIFIED"},
    {"term": "B", "verdict": "VERIFIED"}  # 이것은 통과했으나...
  ]
}
```

→ **전체 콘텐츠 차단** (엄격한 정책)

---

## 모니터링 & 리포팅

### 일일 리포트

```bash
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh report | jq '.statistics'

# 출력 예
{
  "total_validations": 45,
  "failed_validations": 3,
  "success_rate": "93%"
}
```

### 미확인 슬랭 추적

```bash
# 모든 미확인 슬랭 목록
grep '"verdict":"UNVERIFIED"' ~/.jarvis/runtime/state/cluster-guards/cl-0bae9367746da340-validations.jsonl | \
  jq '.validation_result.unverifiedTerms[].term'
```

---

## 자주 묻는 질문

### Q. 검증 속도가 느린데?

**A.** Claude API 호출 비용이 있습니다. 
- 캐시를 활용하세요 (같은 슬랭 반복 검증 시)
- 타임아웃을 조정하세요
- 배치 처리 권장 (50개 콘텐츠 검증 시 한 번)

### Q. 오탐지가 많아요.

**A.** 신뢰도 임계값을 조정할 수 있습니다:
```bash
# slang-validator.mjs에서
const CONFIDENCE_THRESHOLD = 0.6;  // 이 값 조정
```

### Q. 신조어를 등화할 수 있나요?

**A.** 캐시에 수동으로 추가:
```bash
echo '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "term": "신조어",
  "isValid": true,
  "sources": ["사용 예시"],
  "clusterId": "'$CLUSTER_ID'"
}' >> ~/.jarvis/runtime/state/cluster-guards/slang-validation-db.jsonl
```

### Q. 완전히 비활성화할 수 있나요?

**A.** 권장하지 않습니다. 하지만 필요시:
```bash
# 에러를 경고로만 변경
# cluster-guard 스크립트에서 'exit 1' → 'exit 0'
```

---

## 디버깅

### 검증 로그 확인

```bash
# 최근 10개 검증 이력
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh logs 10

# 전체 JSON 출력
cat ~/.jarvis/runtime/state/cluster-guards/cl-0bae9367746da340-validations.jsonl | \
  jq '.validation_result | {status, unverifiedTerms}'
```

### 수동 테스트

```bash
# 단일 슬랭 테스트
node ~/.jarvis/lib/slang-validator.mjs check-term "뭐하는데"

# 콘텐츠 전체 테스트
node ~/.jarvis/lib/slang-validator.mjs validate "카드뉴스 텍스트..." \
  --cluster-id=cl-0bae9367746da340
```

---

## 다음 단계

1. **자동화**: 기존 콘텐츠 생성 크론에 검증 게이트 추가
2. **모니터링**: Discord 알림 (미확인 슬랭 감지 시)
3. **교육**: 팀에 가이드 공유 (슬랭 창작 방지)

---

## 참고: 클러스터 가드 패턴

이 가드는 다른 클러스터 가드와 동일한 패턴을 따릅니다:

- 상태 저장소: `~/.jarvis/runtime/state/cluster-guards/`
- 로깅: `.jsonl` (JSON Lines)
- CLI 인터페이스: `status`, `logs`, `report`
- 통합: Bash `source` 또는 CLI 직접 호출

더 많은 정보: `~/.jarvis/lib/CLUSTER-GUARD-*.md`
