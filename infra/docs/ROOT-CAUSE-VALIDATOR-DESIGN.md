# 근본원인 분석 검증 가드 설계 문서

**클러스터 ID**: cl-d8daa113f8bb5b30 (최근 7일 재발 4건)
**대표 시드**: 초기 권고가 근본 해법이 아니었음
**구현 날짜**: 2026-06-17

---

## 1. 문제 정의

### 반복 실수 패턴

클러스터 cl-d8daa113f8bb5b30에서 확인된 반복 실수:

1. **초기 권고가 근본 해법이 아니었음**
   - 표면 증상만 해결하고 근본 원인 미분석
   - 사용자 질문으로 추가 분석 요청 필요

2. **초기 진단에서 근본까지 내려가지 못한 임시방편 제시**
   - 임시방편(workaround) 중심 솔루션
   - 장기적 해결책 미제시

3. **근본 원인 분석 없이 표면 증상 조정만 계획**
   - "조정", "비활성화", "억제" 중심 조치
   - 실제 원인 파악 부재

4. **증상 억제 vs 근본 원인 재검토**
   - 사용자 지적 후 판정 기준 근본화

### 근본 원인

근본원인 분석(Root Cause Analysis) 체크포인트 부재 → 솔루션 제안 시 자동 검증 불가능

---

## 2. 솔루션 아키텍처

### 2.1 계층 구조

```
ask-claude.sh (메인 실행 흐름)
  ├─ LLM 호출 (claude -p)
  ├─ Tier 1: evaluator.sh (결과 품질 검증)
  │   ├─ 빈 결과 감지
  │   ├─ 프롬프트 echo 감지
  │   ├─ LLM 거부 감지
  │   └─ 스키마 정합성 검증
  │
  ├─ Tier 1.5: root-cause-validator.sh ← NEW
  │   ├─ 근본원인 분석 검증 (문제 해결 태스크에만)
  │   ├─ 근본 미분석 감지 시 솔루션 차단
  │   └─ 부분 분석 경고 (warn)
  │
  └─ 결과 저장 및 outcome 기록
```

### 2.2 판정 로직

#### 진입 조건

다음 태스크 패턴에만 근본원인 검증 적용:

```
- *bug-fix* : 버그 수정
- *debug*   : 디버깅
- *diagnos* : 진단
- *troubleshoot* : 문제 해결
- *error*   : 오류 처리
- *fix-*    : 수정 작업
- *performance* : 성능 개선
- *optimize*    : 최적화
- *issue*       : 이슈 해결
- *problem*     : 문제 해결
```

**제외** (검증 불필요):
- *health*, *summary*, *briefing*, *monitor*, *report* 등 모니터링/리포팅 태스크

#### 판정 기준

| 판정 | 조건 | 동작 |
|------|------|------|
| **pass** | 근본원인 충분히 분석됨 | 통과, 결과 저장 |
| **warn** | 부분 분석 (근본 마커 1~2개) | 경고 기록, 결과 저장 |
| **block** | 근본분석 전무 (마커 0개) | 차단, 재시도 트리거 |

#### 검증 체크포인트

##### 1. 근본원인 마커 (근본 키워드 개수)

```bash
근본|원인|이유|왜|cause|reason|why|분석|analyze|investigation|진단|diagnose|root|발생|occur
```

- 0개: **block** (차단)
- 1개+: 다음 검증 진행

##### 2. 증상억제 패턴 (표면 조정 표현)

```bash
조정|adjust|임시|temporary|우회|workaround|억제|suppress|비활성화|무시|ignore|마스킹
```

- 3개 이상 + 근본마커 부족 → **block**
- 5개 이상 → **warn** (부분 분석 의심)

##### 3. 문제 분석 검증

문제를 명시적으로 정의/분석했는가?

```bash
문제|issue|symptom|문제점|실제 문제|근본적|결국
```

- 없음 → **warn**

##### 4. 솔루션 정당성 검증

솔루션이 "왜 근본해결인가" 설명했는가?

```bash
따라서|그래서|이를 통해|이렇게 함으로써|이유는|결과적으로|이것이 근본적
```

- 없음 → **warn**

##### 5. 다단계 인과 분석 (5-why 근사)

인과관계 표현 2개 이상 확인:

```bash
때문|because|due to|으로 인해|caused by|resulted from|기인|attributed|stems from
```

- 2개 미만 → **warn**

---

## 3. 구현 상세

### 3.1 파일 구조

```
~/.jarvis/infra/lib/
  ├─ root-cause-validator.sh (새로 추가)
  │   ├─ _ROOT_CAUSE_KEYWORDS[]        : 근본 키워드
  │   ├─ _SYMPTOM_SUPPRESSION_PATTERNS[] : 억제 패턴
  │   ├─ _check_root_cause_markers()  : 마커 개수 세기
  │   ├─ _count_symptom_patterns()    : 억제 패턴 개수
  │   ├─ _has_problem_analysis()      : 문제 분석 검증
  │   ├─ _has_solution_justification(): 솔루션 정당성
  │   ├─ _has_multi_level_analysis()  : 다단계 인과 분석
  │   ├─ _should_validate_root_cause(): 진입 조건
  │   └─ validate_root_cause()        : 메인 검증 함수
  │
  └─ ask-claude.sh (수정)
      └─ Line ~303: root-cause-validator.sh 통합
```

### 3.2 통합 지점

ask-claude.sh 303줄에 아래 로직 추가:

```bash
# --- Tier 1.5: 근본원인 분석 검증 가드 ---
ROOT_CAUSE_VERDICT="pass"
ROOT_CAUSE_REASON=""
ROOT_CAUSE_BLOCKED=false
ROOT_CAUSE_LIB="${BOT_HOME}/lib/root-cause-validator.sh"
if [[ -f "$ROOT_CAUSE_LIB" ]]; then
    source "$ROOT_CAUSE_LIB"
    validate_root_cause "$TASK_ID" "$RESULT" "$PROMPT" || true
    if [[ "$ROOT_CAUSE_BLOCKED" == "true" ]]; then
        # 재시도 트리거 (exit 1)
        exit 1
    elif [[ "$ROOT_CAUSE_VERDICT" == "warn" ]]; then
        # 경고 기록
        log_jsonl "warn" "root_cause_analysis_warn: ..." "$DURATION"
    fi
fi
```

### 3.3 환경변수 인터페이스

| 변수 | 값 | 의미 |
|------|-----|------|
| `ROOT_CAUSE_VERDICT` | pass\|warn\|block | 판정 결과 |
| `ROOT_CAUSE_REASON` | string | 판정 사유 |
| `ROOT_CAUSE_BLOCKED` | true\|false | 차단 여부 |

---

## 4. 차단 조건 (정의서)

### 차단 기준 (block)

다음 중 하나 만족 시 차단:

1. **근본 키워드 0개** (근본 분석 없음)
   ```
   markers=0 → block
   ```

2. **증상억제 패턴 3개+ & 근본마커 1개 이하**
   ```
   symptom_patterns≥3 AND markers≤1 → block
   ```

### 경고 기준 (warn)

다음 중 하나 만족 시 경고:

1. **근본 마커 충분하지만 억제 패턴 다수**
   ```
   markers≥2 AND symptom_patterns>5 → warn
   ```

2. **문제 분석 명시 부재**
   - 문제/증상/실제문제 표현 없음

3. **솔루션 정당성 설명 부재**
   - "따라서", "그래서" 등 연결 표현 없음

4. **다단계 인과분석 불충분**
   - 인과 표현 2개 미만

### 통과 기준 (pass)

모든 검증 통과:
- 근본 마커 1개+
- 문제 분석 명시
- 솔루션 정당성 설명
- 다단계 인과분석 (2개+)

---

## 5. 예외 정책 (호출자 제어)

### 가드 bypass 옵션

특정 상황에서 검증을 우회하는 메커니즘:

#### 방법 1: 환경변수 제어

```bash
# ask-claude.sh 호출 시
SKIP_ROOT_CAUSE_VALIDATION=1 ask-claude.sh task-id "prompt..."
```

구현: `root-cause-validator.sh`에 다음 추가

```bash
if [[ "${SKIP_ROOT_CAUSE_VALIDATION:-0}" == "1" ]]; then
    return 0  # 검증 스킵
fi
```

#### 방법 2: 강제 재시도 (retry-wrapper.sh)

근본 미분석으로 차단되면:

```bash
exit 1  # ask-claude.sh 재시도 유발
        # run_with_retry()의 자동 재시도 (최대 3회)
```

---

## 6. 호환성 검증

### 기존 태스크 영향도

#### 검증 대상 태스크

| 태스크 | 포함 여부 | 이유 |
|--------|---------|------|
| system-health | ❌ | 모니터링 (검증 제외) |
| daily-summary | ❌ | 리포팅 (검증 제외) |
| morning-standup | ❌ | 리포팅 (검증 제외) |
| council-insight | ❌ | 리포팅 (검증 제외) |
| bug-fix-* | ✅ | 버그 수정 (검증 필수) |
| performance-* | ✅ | 성능 개선 (검증 필수) |
| troubleshoot-* | ✅ | 문제 해결 (검증 필수) |

#### 테스트 결과

```
✅ system-health: 검증 제외, 통과
✅ daily-summary: 검증 제외, 통과
✅ bug-fix-test (근본분석O): pass
❌ bug-fix-test (근본분석X): block (의도적 차단)
```

### 기존 정상 태스크 파괴 없음

- **모니터링/리포팅** 태스크: 검증 완전 제외 → 기존 동작 유지
- **문제 해결** 태스크: 근본분석 기준 적용 → 품질 향상
- **재시도 메커니즘**: 기존 `run_with_retry()` 활용 → 자동 복구

---

## 7. 운영 가이드

### 7.1 모니터링

로그 위치:
```
~/.jarvis/runtime/logs/task-runner.jsonl
```

근본분석 검증 로그 필터:
```bash
grep "root_cause_analysis" ~/.jarvis/runtime/logs/task-runner.jsonl
```

### 7.2 문제 해결

#### 정상 작동 확인

```bash
# 스크립트 단독 테스트
/Users/ramsbaby/.jarvis/infra/lib/root-cause-validator.sh "bug-fix-test" "근본원인을..."

# ask-claude.sh 통합 확인
ask-claude.sh "test-task" "문제 해결 프롬프트..."
```

#### 차단된 태스크 복구

차단된 경우:

```bash
# 1. 결과 파일 확인
cat ~/.jarvis/runtime/results/[TASK_ID]/[TIMESTAMP]-root-cause-fail.json

# 2. 판정 이유 확인
jq '.result' [fail-file]

# 3. 프롬프트 수정 후 재시도
# → 근본원인 분석 추가 후 다시 실행
```

### 7.3 커스터마이징

#### 키워드 추가

`root-cause-validator.sh` 수정:

```bash
_ROOT_CAUSE_KEYWORDS=(
    # 기존...
    "새 키워드|추가 표현"
)
```

#### 새 태스크 패턴 추가

```bash
_should_validate_root_cause() {
    case "$task_id" in
        # 기존...
        *new-pattern*) return 0 ;;
    esac
}
```

---

## 8. 성공 기준 체크리스트

- [x] **[1] 근본원인 분석 검증 스크립트 작성 완료**
  - ✓ 증상억제 vs 근본해결 판별 로직 포함
  - ✓ 체크포인트 5가지 구현 (마커, 억제패턴, 문제분석, 정당성, 인과분석)

- [x] **[2] 가드 스크립트를 ask-claude.sh 워크플로에 통합**
  - ✓ ask-claude.sh line ~303 통합
  - ✓ Tier 1.5 계층 추가

- [x] **[3] 근본원인 미분석 감지 시 솔루션 제안 차단 로직 구현**
  - ✓ ROOT_CAUSE_BLOCKED 플래그 기반 차단
  - ✓ exit 1로 재시도 트리거

- [x] **[4] 기존 정상 크론 태스크 실행 파괴 없음 검증**
  - ✓ 모니터링 태스크 검증 제외
  - ✓ 테스트 완료 (system-health, daily-summary)

- [x] **[5] 가드 로직 설계 문서 작성**
  - ✓ 이 문서 (ROOT-CAUSE-VALIDATOR-DESIGN.md)
  - ✓ 체크포인트, 차단조건, 예외정책 명기

---

## 9. 용어 정의

| 용어 | 의미 |
|------|------|
| **근본원인** | 문제 발생의 최초 원인 (5-why 분석의 최종 단계) |
| **증상억제** | 근본원인 해결 없이 표면 증상만 완화 |
| **임시방편** | 단기 해결책 (workaround) |
| **다단계 인과** | 원인 → 중간 결과 → 최종 문제 연쇄 관계 |
| **마커** | 근본분석을 나타내는 키워드/표현 |
| **체크포인트** | 검증 단계별 평가 항목 |

---

## 10. 참고

- **클러스터 ID**: cl-d8daa113f8bb5b30
- **대상 기간**: 최근 7일 (재발 4건)
- **구현 계층**: ask-claude.sh Tier 1.5
- **의존성**: bash 3.2+, grep, jq (이미 존재)
- **성능 영향**: <10ms (regex 기반 검증만)
