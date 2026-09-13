# 슬랭 검증 가드 통합 테스트 가이드

## 빠른 시작

### 1단계: 가드 상태 확인

```bash
# 가드 초기화 및 상태 조회
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh status

# 예상 출력
{
  "cluster_id": "cl-0bae9367746da340",
  "cluster_name": "존재하지 않는 슬랭 의미 조합 후 카드뉴스 제작",
  "total_validations": 0,
  "passed": 0,
  "failed": 0
}
```

### 2단계: 검증 가능 콘텐츠 테스트 (통과 사례)

```bash
# PASSED 예시: 검증된 슬랭만 포함
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh validate \
  "오늘 날씨 정말 좋은데, 완전 대박이야! 꿀잼인 영상도 봤고."

# 예상 결과
# exit code: 0 (성공)
# status: PASSED
# unverifiedTerms: []
```

### 3단계: 검증 불가 콘텐츠 테스트 (실패 사례)

```bash
# FAILED 예시: 미확인 슬랭 포함
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh validate \
  "이건 요즘 뜨는 '무드킹 모멘트'라고 해! 진짜 핑크팬더 에너지야."

# 예상 결과
# exit code: 1 (실패)
# status: FAILED
# unverifiedTerms: [{term: "무드킹 모멘트", verdict: "UNVERIFIED"}, ...]
```

### 4단계: 검증 이력 조회

```bash
# 최근 검증 이력 확인
~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh logs 5

# 예상 출력: JSONL 형식의 검증 기록
```

---

## 파이프라인 통합 테스트

### 패턴 1: Bash 함수 통합

```bash
#!/bin/bash
# test-slang-guard-integration.sh

set -euo pipefail

source ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh

# 테스트 1: 통과 케이스
echo "📋 테스트 1: 슬랭 검증 통과"
CONTENT1="완전 대박이야, 정말 꿀잼이었어!"
RESULT=$(validate_slang_in_content "$CONTENT1")
if should_proceed_with_content "$RESULT"; then
  echo "✅ 통과: 콘텐츠 발행 가능"
else
  echo "❌ 실패: 콘텐츠 발행 불가"
fi
echo ""

# 테스트 2: 실패 케이스
echo "📋 테스트 2: 슬랭 검증 실패"
CONTENT2="이거 완전 '무드킹 파워'야, 핑크팬더 무드네!"
RESULT=$(validate_slang_in_content "$CONTENT2" || true)
if should_proceed_with_content "$RESULT"; then
  echo "✅ 통과: 콘텐츠 발행 가능"
else
  echo "❌ 실패: 콘텐츠 발행 불가"
  # 실패 처리
  MARKED=$(mark_content_unverified "$CONTENT2" "$RESULT")
  echo "마크된 콘텐츠:"
  echo "$MARKED"
fi
```

실행:
```bash
bash test-slang-guard-integration.sh
```

---

## 실제 파이프라인 예시

### 예시: 카드뉴스 생성 + 검증

```bash
#!/bin/bash
# generate-cardnews.sh

set -euo pipefail

source ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh

PROMPT="$1"

echo "🎨 카드뉴스 생성 중..."

# Step 1: Claude에서 콘텐츠 생성
GENERATED=$(claude -p "카드뉴스 주제: $PROMPT" 2>/dev/null)

echo "✓ 콘텐츠 생성 완료 (${#GENERATED}자)"

# Step 2: 슬랭 검증
echo "🔍 슬랭 검증 중..."
VALIDATION=$(validate_slang_in_content "$GENERATED" 30 || true)

if should_proceed_with_content "$VALIDATION"; then
  echo "✅ 검증 통과: 발행 준비 완료"
  echo "$GENERATED"
  exit 0
else
  echo "❌ 검증 실패: 미확인 슬랭 감지"
  # 실패 처리
  MARKED=$(mark_content_unverified "$GENERATED" "$VALIDATION")
  echo "$MARKED"
  exit 1
fi
```

사용:
```bash
bash generate-cardnews.sh "요즘 유행하는 머리 스타일"
```

---

## 수동 테스트 (단일 모듈)

### slang-validator.mjs 직접 호출

```bash
# 단일 슬랭 검증
node ~/.jarvis/lib/slang-validator.mjs check-term "대박"

# 콘텐츠 전체 검증
echo "완전 대박이야!" | \
  node ~/.jarvis/lib/slang-validator.mjs validate -

# 검증 이력 리포트
node ~/.jarvis/lib/slang-validator.mjs report
```

---

## 디버깅

### 로그 확인

```bash
# 검증 이력 전체 조회
cat ~/.jarvis/runtime/state/cluster-guards/cl-0bae9367746da340-validations.jsonl | jq '.'

# 미확인 슬랭만 필터링
cat ~/.jarvis/runtime/state/cluster-guards/cl-0bae9367746da340-validations.jsonl | \
  jq '.validation_result | select(.status == "FAILED") | .unverifiedTerms[]'
```

### 검증 엔진 문제

```bash
# Claude API 키 확인
echo $ANTHROPIC_API_KEY | head -c 10

# 직접 Claude 호출 테스트
echo '{"messages": [{"role": "user", "content": "test"}]}' | \
  curl -X POST https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY"
```

---

## 예상 결과

| 테스트 | 입력 | 예상 exit code | 예상 status |
|--------|------|-----------------|-------------|
| 검증된 슬랭만 | "완전 대박이야!" | 0 | PASSED |
| 미확인 슬랭 포함 | "무드킹 파워야!" | 1 | FAILED |
| 타임아웃 | (30초 초과 후) | 1 | TIMEOUT |
| API 오류 | (API 미접근) | 1 | ERROR |

---

## 체크리스트

- [ ] 가드 스크립트 실행 가능 (`~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh status`)
- [ ] slang-validator.mjs 실행 가능 (`node ~/.jarvis/lib/slang-validator.mjs report`)
- [ ] 상태 디렉토리 생성됨 (`~/.jarvis/runtime/state/cluster-guards/`)
- [ ] 가드 상태 파일 존재 (`...-state.json`)
- [ ] 검증 이력 파일 생성됨 (`...-validations.jsonl`)
- [ ] Claude API 키 설정됨 (`$ANTHROPIC_API_KEY`)
- [ ] 통과/실패 케이스 모두 작동

---

## 문제 해결

### Q. "slang-validator.mjs 없음" 에러

**A.** 파일 위치 확인:
```bash
ls -la ~/.jarvis/lib/slang-validator.mjs
```

### Q. "Claude API 호출 실패"

**A.** API 키 확인:
```bash
test -n "$ANTHROPIC_API_KEY" && echo "✅ 설정됨" || echo "❌ 미설정"
```

### Q. 타임아웃이 자주 발생

**A.** 타임아웃 연장:
```bash
validate_slang_in_content "$CONTENT" 60  # 60초로 설정
```

### Q. 캐시가 쌓여서 용량 부족

**A.** 캐시 정리:
```bash
# 7일 이상 된 캐시 삭제
find ~/.jarvis/runtime/state/cluster-guards -name "*validation*" \
  -mtime +7 -delete
```

---

## 다음 단계

1. **자동 통합**: 기존 크론에 검증 게이트 추가
   ```bash
   # ~/.jarvis/crontab-entries에 추가
   0 */4 * * * ~/.jarvis/lib/cluster-guard-cl-0bae9367746da340.sh report
   ```

2. **모니터링 알림**: Discord 연동
   ```bash
   # 실패 시 Discord 메시지
   if [[ $? -ne 0 ]]; then
     discord_route info "슬랭 검증 실패" "..."
   fi
   ```

3. **팀 교육**: 가이드 공유 및 워크숍
