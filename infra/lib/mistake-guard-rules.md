# 오답 클러스터 가드 룰 - cl-a3200445ee1623e8

> 이 파일은 반복되는 실수 패턴에 대한 자동 검사 및 교정 가드를 정의합니다.
> **자동 관리 파일** — 구조적 개선 작업에 의해 자동 갱신될 수 있습니다.
> 수정 시 기존 동작 파괴 금지. 각 규칙 블록은 ID로 추적됩니다.

## 규칙 블록 구조

```
<!-- GUARD:BEGIN id=<rule_id> cluster=cl-a3200445ee1623e8 severity=[high|medium|low] -->
**규칙 제목**
- **조건**: 언제 이 규칙이 적용되는가
- **검사**: 어떻게 검증하는가
- **교정**: 실수를 피하기 위한 행동
<!-- GUARD:END id=<rule_id> -->
```

---

## 규칙 1: 인자 순서 검증 (argument-order-strict)

<!-- GUARD:BEGIN id=rule-arg-order severity=high cluster=cl-a3200445ee1623e8 -->

**반복되는 인자 순서 오류 근본 해결**

- **조건**: 함수·메서드·도구 호출 시 인자(parameter) 순서가 뒤바뀌는 경우
- **검사**:
  1. 응답에서 호출 명령(function, method, bash command)을 찾는다
  2. 각 호출의 인자 순서를 대상 함수의 서명(signature)과 대조
  3. 불일치 시 FAIL로 마크
- **교정 (필수)**:
  - 함수 호출 전에 항상 API 문서·함수 서명을 참조
  - 위치적 인자(positional arg)는 항상 왼쪽부터 정의된 순서대로
  - 예: `git commit -m "msg" --amend` (O), `git commit --amend -m "msg"` (△ — 순서 상관없지만 모범은 O)
  - 보조 함수(utils, helper)의 서명이 불명확하면 문서/테스트/예제를 먼저 읽기
  - 한 번 호출할 때마다 "인자 순서 체크" 멘탈 모델 실행

<!-- GUARD:END id=rule-arg-order -->

---

## 규칙 2: 포맷 규칙 일관성 (format-consistency-strict)

<!-- GUARD:BEGIN id=rule-format-consistency severity=high cluster=cl-a3200445ee1623e8 -->

**반복되는 포맷 규칙 누락 (세그먼트별 불일치)**

- **조건**: 응답이 일관된 포맷·구조·표기를 따르도록 지정된 경우
- **검사**:
  1. 이전 응답들의 포맷 패턴 (제목 스타일, 구분자, 마크다운 수준, 나열 기호)을 파악
  2. 현재 응답의 각 섹션이 동일한 포맷을 준수하는지 확인
  3. 섹션별 불일치 항목 리스트:
     - 제목 수준 (## vs ### vs **굵음**)
     - 나열 기호 (-  vs * vs +)
     - 마크다운 구문 일관성
     - 줄바꿈·들여쓰기 규칙
- **교정 (필수)**:
  - 문서 시작 시 포맷 규칙을 명시적으로 정리 (체크리스트 항목으로 기록)
  - 응답 작성 중 주기적(50줄마다)으로 포맷 검증
  - 이전 섹션과 스타일이 다르면 즉시 수정

<!-- GUARD:END id=rule-format-consistency -->

---

## 규칙 3: 자격증 난이도 기준 (certification-level-strict)

<!-- GUARD:BEGIN id=rule-cert-level severity=high cluster=cl-a3200445ee1623e8 -->

**자격증 선택 근거 오류 (절대 난이도만 고려)**

- **조건**: 학생에게 자격증·시험·교재 선택을 제안할 때
- **검사**:
  1. 제안할 자격증의 난이도 (easy, medium, hard) 파악
  2. 학생의 현재 레벨·목표·학습 이력 확인
  3. 근거:
     - ❌ 절대 난이도만 (예: "이건 어렵지 않아")
     - ✅ 학생 레벨 대비 상대 난이도 + 필요성 (예: "당신의 중급 수준으로는 medium이 적당, 차기 목표 달성에 필요")
  4. 예상 시간·비용·학습 경로도 함께 제시
- **교정 (필수)**:
  - 자격증 제안 전에 학생 프로필(현재 레벨, 목표, 진행 중인 학습) 재확인
  - 근거 문장에 "당신의" + "현재 레벨" + "이유" 세 요소 모두 포함
  - 만약 프로필 정보가 없으면 먼저 물어보기 (가정하지 말 것)

<!-- GUARD:END id=rule-cert-level -->

---

## 규칙 4: 모순응답 및 기억력 (consistency-across-sessions)

<!-- GUARD:BEGIN id=rule-session-consistency severity=medium cluster=cl-a3200445ee1623e8 -->

**이전 직후 모순된 응답 + 기억 못함 지적**

- **조건**: 세션 중 또는 세션 간에 이전에 말한 것과 모순되는 내용 응답
- **검사**:
  1. 현재 요청을 보기 전에 해당 학생의 최근 세션 이력 로드
  2. 이전 응답의 주요 결론·약속·확인사항 확인
  3. 현재 응답과 대조:
     - 같은 주제에 다른 답변 → CONTRADICTION
     - 이전에 확인한 정보를 "모른다"고 답변 → MEMORY LOSS
- **교정 (필수)**:
  - 응답 작성 전에 학생 메모리(세션 이력) 자동 주입
  - 이전 응답과 충돌 가능성이 있으면 "저번에 말씀드렸던 것처럼..."으로 연결
  - 정보 부족 시 "이전 대화에서 설정하신 것을 다시 확인하실 수 있나요?" 역질문

<!-- GUARD:END id=rule-session-consistency -->

---

## 규칙 5: 학생별 요청 이력 단일화 (single-source-of-truth)

<!-- GUARD:BEGIN id=rule-student-sso-memory severity=medium cluster=cl-a3200445ee1623e8 -->

**세션 간 학생별 요청 이력 단일화 실패 + 메모리 자동 주입 미흡**

- **조건**: 학생과의 반복 상호작용에서 이전 대화·선호·제약이 손실되는 경우
- **검사**:
  1. 학생 메모리 파일 존재 확인: `~/jarvis/runtime/state/student-memory/{student_id}.json`
  2. 파일이 존재하면: 최근 N개 세션 이력 로드
  3. 현재 응답에 반영 여부 확인
  4. 반영 없으면 MEMORY_INJECTION_FAILED
- **교정 (필수)**:
  - 세션 시작 시 `student-memory-manager.mjs --action load --student-id <id>` 실행
  - 로드한 메모리를 시스템 프롬프트에 자동 주입
  - 세션 종료 시 상호작용 기록을 메모리에 추가 저장
  - 학생 메모리가 없으면 `init-template` 으로 생성

<!-- GUARD:END id=rule-student-sso-memory -->

---

## 체크리스트: 응답 생성 전 자동 검사

응답을 생성하기 전에 아래 항목을 모두 확인하세요. 하나라도 실패하면 응답을 수정 후 재확인:

```
[ ] rule-arg-order: 함수 호출 인자 순서 검증 완료
[ ] rule-format-consistency: 포맷 일관성 세그먼트별 확인 완료
[ ] rule-cert-level: 자격증 제안 시 학생 레벨 + 근거 포함 확인
[ ] rule-session-consistency: 이전 응답과 모순 없음 확인
[ ] rule-student-sso-memory: 학생 메모리 로드 및 반영 확인
```

---

## 룰 적용 로그

| 날짜 | 규칙 ID | 클러스터 | 상태 | 비고 |
|------|--------|---------|------|------|
| 2026-07-04 | rule-arg-order | cl-a3200445ee1623e8 | ACTIVE | 초기 등재 |
| 2026-07-04 | rule-format-consistency | cl-a3200445ee1623e8 | ACTIVE | 초기 등재 |
| 2026-07-04 | rule-cert-level | cl-a3200445ee1623e8 | ACTIVE | 초기 등재 |
| 2026-07-04 | rule-session-consistency | cl-a3200445ee1623e8 | ACTIVE | 초기 등재 |
| 2026-07-04 | rule-student-sso-memory | cl-a3200445ee1623e8 | ACTIVE | 초기 등재 |
