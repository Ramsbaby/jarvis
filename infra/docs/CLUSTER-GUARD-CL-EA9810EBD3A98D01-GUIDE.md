# 반복 실수 클러스터 cl-ea9810ebd3a98d01 방어 가이드

**목적**: 감시 규칙 설계 시 거짓양성(false positive) 미고려 및 기존 감시 시스템 미탐색 후 신규 도구 제안 반복 실수 방어

**버전**: 1.0 (2026-08-01)

---

## 1. 문제 정의

### 반복 실수의 특징 (최근 7일 재발 14건)
- **기존 감시 인프라 미탐색**: 새 경보·도구 제안 전 crontab/launchd/monitoring.json 확인 누락
- **거짓양성 미고려**: 정상 운영 중에도 발생하는 조건을 경보로 설정 → 알림 피로
- **중복 경보 생성**: 이미 존재하는 경보와 동일 조건의 새 경보 추가
- **기존 경보 장기 무인지**: 기존 경보가 방치된 상태에서 새 감사 도구 제안

---

## 2. SOP: 감시·경보 관련 작업 전 의무 절차

> **원칙**: 새 감시 규칙·도구 제안 전 반드시 아래 순서를 따른다.

### Step 1 — 기존 인프라 조회 (필수, 30초 소요)

```bash
~/jarvis/scripts/list-monitors.sh
```

출력 항목:
- Crontab 전체 항목 수 + 감시 관련 항목
- LaunchAgents 전체 수 + 감시 관련 에이전트 (로드 상태 포함)
- monitoring.json 웹훅 채널 구성
- 기존 감시·알림 스크립트 목록

**⚠️ 이 단계를 생략하면 중복 경보 생성 위험**

### Step 2 — 거짓양성 체크리스트 확인 (필수)

```bash
~/jarvis/scripts/list-monitors.sh --fp-check
```

8개 항목을 모두 확인하고, 하나라도 미확인 시 새 규칙 추가 보류.

### Step 3 — 거짓양성 자동 검사 (선택, 새 규칙 추가 시)

```bash
# 형식: false-positive-guard.sh <규칙명> <탐지키워드> [--threshold <값>] [--window <쿨다운초>]
~/jarvis/infra/guards/false-positive-guard.sh "disk-usage-alert" "disk" --threshold 90 --window 3600
```

FAIL 또는 WARN 발생 시 각 항목 해결 후 진행.

### Step 4 — 기존 경보 상태 확인

```bash
~/jarvis/infra/scripts/monitoring-pre-check.sh
```

기존 경보가 방치(비활성)된 경우, 새 경보 추가 대신 기존 경보 복구를 우선 검토.

---

## 3. 거짓양성 설계 원칙

| 원칙 | 잘못된 예 | 올바른 예 |
|------|-----------|-----------|
| 임계값을 "최악 정상 수치" 이상으로 | 디스크 사용률 50% 경보 | 90% 초과 + 3회 연속 시 경보 |
| 연속 N회 초과 시에만 트리거 | 1회 초과 즉시 경보 | 5분 간격 3회 연속 초과 시 경보 |
| 중복 억제(cooldown) 필수 | 매 점검마다 경보 발송 | 동일 경보 1시간 이내 재발송 금지 |
| 자동 해제(auto-resolve) 설계 | 조건 해소 후에도 경보 지속 | 정상 복구 시 "해제" 알림 자동 발송 |

---

## 4. 스크립트 위치

| 스크립트 | 경로 | 용도 |
|----------|------|------|
| list-monitors.sh | `~/jarvis/scripts/list-monitors.sh` | 기존 인프라 전수 조회 |
| false-positive-guard.sh | `~/jarvis/infra/guards/false-positive-guard.sh` | 거짓양성 자동 검사 |
| monitoring-pre-check.sh | `~/jarvis/infra/scripts/monitoring-pre-check.sh` | 기존 경보 상태 점검 |

---

## 5. 관련 문서

- `~/jarvis/infra/docs/JARVIS-RUNBOOK.md` — 운영 전반 가이드
- `~/jarvis/infra/docs/NOISE-REDUCTION-PLAN.md` — 알림 잡음 감소 계획
- `~/jarvis/infra/docs/CLUSTER-GUARD-CL-A823CC27FBF689FF-IMPLEMENTATION.md` — 유사 클러스터 가드 참고
