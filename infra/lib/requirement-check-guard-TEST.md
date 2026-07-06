# Requirement Check Guard (cl-28e5202af0584c23) - 통합 테스트 문서

## 개요
클러스터 cl-28e5202af0584c23 방어를 위한 요청사항 추출 및 검증 시스템

## 구현 모듈

### 1. requirement-extractor.sh
**목적**: 사용자 프롬프트에서 구조적 요구사항 추출
- 형식(PDF, HTML, JSON, CSV 등)
- 섹션(요약본, 숙제, 정답지 등)
- 병기 여부(한글_영어)
- 구조(제목, 본문, 이미지 등)
- 추가 키워드(교사용, 학생용, 전체적용 등)

**출력**: JSON 형식 요청사항 객체
```json
{
  "task_id": "test-task-001",
  "formats": ["pdf"],
  "sections": ["요약본", "숙제", "정답지"],
  "languages": ["korean", "english"],
  "bilingual": true,
  "additional_keywords": ["교사용"],
  "structure": [],
  "completeness": "unknown",
  "requirement_hash": "e7a1577f096c683f",
  "timestamp": "2026-07-07T..."
}
```

### 2. requirement-validator.sh
**목적**: 생성된 결과물이 추출된 요구사항을 충족하는지 검증
- 필요한 섹션 포함 여부 확인
- 병기 요구사항 충족 확인 (한글 + 영어)
- 파일 크기 및 완전성 검증
- 검증 결과 JSON 출력

**출력**: 검증 결과 JSON
```json
{
  "task_id": "test-001",
  "status": "pass|warn|fail",
  "result_file": "...",
  "file_size_bytes": 347,
  "file_lines": 25,
  "validation_errors": [...],
  "validation_warnings": [...],
  "requirement_hash": "abc123",
  "timestamp": "2026-07-07T..."
}
```

### 3. requirement-check-guard.sh
**목적**: 추출과 검증을 통합하는 가드 (선택적 활성화)
- 함수: `check_requirements_pre()` - 실행 전 요구사항 추출
- 함수: `check_requirements_post()` - 실행 후 검증
- 검증 실패 시 dev-queue에 Tier 2 작업 등록

## ask-claude.sh 통합

### 프로-실행 (Line 134-139)
```bash
if [[ -f "${BOT_HOME}/lib/requirement-check-guard.sh" ]]; then
    source "${BOT_HOME}/lib/requirement-check-guard.sh" 2>/dev/null || true
    if command -v check_requirements_pre >/dev/null 2>&1; then
        check_requirements_pre "$TASK_ID" "$PROMPT" 2>/dev/null || true
    fi
fi
```

### 포스-실행 (Line 418-420)
```bash
if command -v check_requirements_post >/dev/null 2>&1; then
    check_requirements_post "$TASK_ID" "$RESULT_FILE" 2>/dev/null || true
fi
```

## 설계 원칙 (Sprint Contract 충족)

### [1] 요청사항 추출 모듈 ✓
- requirement-extractor.sh 구현 완료
- 형식, 섹션, 병기 여부, 구조를 JSON으로 파싱
- 정규표현식 기반 키워드 감지

### [2] 검증 스크립트 ✓
- requirement-validator.sh 구현 완료
- 각 추출된 요구사항을 생성 결과물과 대조
- 섹션 유무, 병기, 파일 완전성 검증

### [3] 누락 항목 감지 및 경고 ✓
- 검증 실패 시 validation_errors 배열에 누락 항목 기록
- requirement-check-guard.sh에서 실패 시 경고 로깅
- dev-queue에 자동 Tier 2 작업 등록

### [4] 기존 동작 보존 ✓
- ask-claude.sh의 기존 로직 미변경
- 모든 가드 호출은 선택적 (if command -v)
- 가드 실패 시에도 스크립트 진행 (|| true)

### [5] Discord 보고 (별도 처리)
- discord_route 명령으로 jarvis-system 채널 발송 예정

## 테스트 사례

### 테스트 1: 요약본 누락 감지
**입력 프롬프트**: "PDF로 숙제 섹션만 생성"
**생성 결과**: 요약본 없음
**예상 결과**: validation_error = "missing_section:요약본"

### 테스트 2: 병기 요구사항 감지
**입력 프롬프트**: "한글_영어 병기하여 교재 생성"
**생성 결과**: 영어만 포함
**예상 결과**: validation_error = "missing_bilingual_content"

### 테스트 3: 전체 요구사항 충족
**입력 프롬프트**: "PDF 형식으로 한글_영어 병기하여 요약본, 숙제, 정답지(교사용) 섹션"
**생성 결과**: 모든 요구사항 충족
**예상 결과**: status = "pass"

## 상태 저장 구조

```
~/jarvis/runtime/state/requirements/
├── {TASK_ID}.json              # 추출된 요구사항
└── {TASK_ID}-validation.json   # 검증 결과
```

## 안전성 보장

1. **기존 동작 차단 없음**: 모든 가드는 graceful handling (|| true)
2. **선택적 통합**: 모듈이 없으면 ask-claude.sh는 정상 작동
3. **에러 추적**: 검증 실패는 Tier 2로 등록하여 사람의 개입 가능
4. **감사 추적**: 모든 요구사항과 검증은 JSON 파일로 기록

## 배포 체크리스트

- [x] requirement-extractor.sh 생성
- [x] requirement-validator.sh 생성
- [x] requirement-check-guard.sh 생성
- [x] ask-claude.sh 통합 (프로-실행)
- [x] ask-claude.sh 통합 (포스-실행)
- [x] 각 모듈 실행 권한 설정
- [x] 기본 기능 테스트
- [ ] Discord 완료 보고
