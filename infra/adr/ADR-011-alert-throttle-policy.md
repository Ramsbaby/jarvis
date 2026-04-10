# ADR-011-alert-throttle-policy — 알림 스로틀링 정책

**상태:** accepted
**날짜:** 2026-03-21
**결정자:** Owner (인프라팀 검토)
**관련:** ADR-011 (Task FSM + SQLite)

---

## 맥락 (결정 배경)

Jarvis 알림 시스템(alert.sh)이 Discord + ntfy 이중 전송 구조로 되어 있다. 시스템이 고도화되면서 크론 태스크가 늘어나고 알림 빈도도 함께 증가했다. 주요 증상:

- 동일 이슈가 5분 간격 크론마다 중복 발송
- Discord #alerts 채널에 "System OK" 반복 노이즈로 실제 장애 신호가 묻힘
- Galaxy ntfy 앱 배지가 수십 개씩 쌓여 알림 피로도 유발
- 팀원(자비스 에이전트 포함)이 알림을 무시하는 습관 형성 → 정작 중요한 경고 누락 위험

---

## 검토한 대안

| 옵션 | 검토 결과 | 기각 이유 |
|------|-----------|-----------|
| **Discord 채널 분리** (`#alerts-critical` / `#alerts-info`) | 구조는 간단하나 근본적 중복 문제를 해결하지 못함 | 채널 수만 늘고 노이즈 총량 동일. Discord 웹훅 설정 중복 관리 비용 발생 |
| **응답률 측정 후 임계값 조정** | 클릭/반응 이벤트 수집이 Discord API 제약상 어려움 | ntfy/Discord 양쪽에 응답 추적 로직 추가 필요. 측정 인프라가 알림 시스템보다 복잡해짐 |
| **레벨별 채널 라우팅 + 웹훅 교체** | 완전한 해결책이나 구현 범위가 큼 | ADR-009 Nexus 게이트웨이 개편과 타이밍 충돌. 현 단계에서 오버엔지니어링 |
| **알림 완전 비활성화(야간)** | 의존성 있는 크론들이 silent fail 위험 | 장애 감지 공백 허용 불가 |

---

## 결정 (채택 방향)

### 1단계: dedup 선행 (즉시 적용)

`alert.sh`에 중복 발송 차단 로직을 추가한다.

```bash
# alert.sh dedup 패턴
DEDUP_KEY=$(echo "$TITLE" | md5sum | cut -c1-8)
DEDUP_FILE="$BOT_HOME/state/alert-dedup/${DEDUP_KEY}"
DEDUP_TTL=1800  # 30분 이내 동일 제목 → 스킵

if [[ -f "$DEDUP_FILE" ]]; then
  log "dedup skip: $TITLE (TTL 미만)"
  exit 0
fi
touch "$DEDUP_FILE"
# TTL 초과 파일 정리 (크론 또는 trap)
find "$BOT_HOME/state/alert-dedup/" -mmin +30 -delete 2>/dev/null || true
```

- 동일 알림 제목은 30분 내 재발송 차단
- `state/alert-dedup/` 디렉터리에 md5 키 파일로 관리
- TTL 초과 파일은 alert.sh 호출 시마다 자동 정리

### 2단계: ntfy → CRITICAL only

ntfy Galaxy 알림은 최고 긴급 등급만 전송한다.

```bash
# alert.sh severity 분기
SEVERITY="${SEVERITY:-normal}"

send_discord  # 항상 전송 (Discord는 채널 로그 용도)

if [[ "$SEVERITY" == "critical" ]]; then
  send_ntfy    # Galaxy 폰 알림은 critical만
fi
```

- `SEVERITY=critical`: Discord + ntfy 동시 전송 (기존 동작)
- `SEVERITY=normal` (기본값): Discord만 전송, ntfy 스킵
- 크론 호출 측에서 `SEVERITY=critical`을 명시해야 폰에 옴

---

## 관측 로그 요건

알림 스로틀링 효과를 측정하기 위해 다음 항목을 로그에 기록해야 한다.

```
[alert-log] action=sent|dedup|throttled severity=critical|normal title="..." dedup_key=abc12345
```

- `action=sent`: 실제 발송됨
- `action=dedup`: dedup TTL 이내 중복 발송 차단됨
- `action=throttled`: ntfy 레벨 미달로 Galaxy 알림 생략

로그 파일: `~/.jarvis/logs/alert.log`
집계 방법: 주 1회 `grep action= alert.log | sort | uniq -c` 수동 검토 (또는 system-health 크론에 추가)

---

## 2주 후 튜닝 계획 (2026-04-04 기준)

| 항목 | 확인 방법 | 기대 결과 |
|------|-----------|-----------|
| dedup 효율 | `grep "action=dedup" alert.log \| wc -l` | 주간 중복 차단 건수 > 발송 건수 |
| ntfy 유효 알림 비율 | Galaxy ntfy 앱 배지 누적 속도 | 주간 10건 이하 (현재 50+) |
| Discord 노이즈 감소 | #alerts 채널 주간 메시지 수 | 50% 이상 감소 |
| 놓친 장애 여부 | 수동 크로스체크 (alert.log vs 실제 장애) | 0건 |

dedup TTL 30분이 너무 짧거나 길다면 `DEDUP_TTL` 값 조정. ntfy CRITICAL 기준이 과도하게 제한적이면 `warning` 레벨 추가 검토.

---

## 관련 파일

- `bin/alert.sh` — 알림 발송 핵심 스크립트 (수정 대상)
- `state/alert-dedup/` — dedup 상태 파일 디렉터리 (신규 생성)
- `logs/alert.log` — 알림 발송 로그
- `config/monitoring.json` — 웹훅 엔드포인트 설정
