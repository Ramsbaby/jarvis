# 자비스 소음 감축 계획 (2026-07-27)

> 실측 기반. 모든 수치에 측정 명령을 병기한다. 추정은 "추정"이라 표기한다.
> 이 문서는 **계획**이며 실행 전 주인님 승인이 필요하다.

---

## 1. 현황 — 무엇이 얼마나 시끄러운가

### 알림 총량

```
측정: runtime/ledger/discord-send-audit.jsonl, 최근 7일
7일 1,110건 = 일평균 158건 = 시간당 6.6건
```

주인님이 깨어 계신 16시간 기준 **약 10분에 한 번** 알림이 옵니다.

### 발신자별 (상위 3개가 100%)

| 발신자 | 7일 건수 | 비중 |
|---|---:|---:|
| `discord-visual` | 716 | 64% |
| `task-result-route` | 297 | 27% |
| `alert-send` | 97 | 9% |

### discord-visual 716건의 내역

```
system-doctor  490건  (일 70건)
stats          226건  (일 32건)
```

`system-doctor` 카드는 **7개 스크립트가 공유**한다. 발신자 구분이 안 되므로
받는 쪽에서 "누가 왜 보냈는지"를 알 수 없다.

```
측정: grep -rln 'system-doctor' infra/scripts/*.sh infra/bin/*.sh
disk-alert.sh · gen-system-overview.sh · runaway-process-guard.sh
system-doctor.sh · doctor-ledger-audit.sh · github-actions-monitor.sh
supervisor-tick.sh
```

### 채널별

```
jarvis-system  639 (58%)   default 241   jarvis-retro 121
jarvis-info     44         jarvis-ceo 27  jarvis 15
```

`jarvis-system`이 전체의 58%를 받는다. 사실상 단일 채널 폭격이다.

### 반복 알림 (5회 이상 같은 제목)

| 제목 | 7일 횟수 |
|---|---:|
| 🧠 오답노트 추출 — 세션 종료 | 111 |
| personal-schedule-daily | 13 |
| ⚠️ LLM 무성 실패 유성화: budget_exceeded | 13 |
| 🚨 유령 디렉토리 자동 복구 | 11 |
| 🔑 OAuth 야간 검증 실패 — 재발 신호 | 7 |
| debug-cron-cf-pages-deploy-notify.sh-contract | 7 |
| ⚠️ skill-loop 조용한 무산출 3일 연속 | 6 |
| 🚨 LA-Cron 진짜 중복 발견 | 5 |

11종이 5회 이상 반복. **총 반복 발송 190건.**

### 실행 주기

```
측정: ~/Library/LaunchAgents/ai.jarvis.*.plist 파싱
달력 기반 50 · KeepAlive 11 · 5분 4 · 10분 2 · 30분 1 · 1시간 2
```

5분 주기 4개(`board-watchdog` `resilience-guard` `supervisor` `sync-system-metrics`)는
각각 하루 288회 실행된다.

---

## 2. 진단 — 소음의 두 종류

### 종류 A: 정상을 반복 보고 (약 84%)

`system-doctor` 490 + `오답노트 추출` 111 + `stats` 226 중 상당수가
"이상 없음"을 반복 확인하는 알림이다. **수준 기반(level-triggered)** 발송이라
상태가 그대로여도 매 주기 발송된다.

### 종류 B: 실패를 반복 보고하는데 아무도 안 고침 (56건 / 12종)

```
측정: 제목에 실패·오류·에러·무산출·🚨·⚠️ 포함 행 집계
13회  LLM 무성 실패: budget_exceeded
11회  유령 디렉토리 자동 복구
 7회  OAuth 야간 검증 실패 — 재발 신호
 6회  skill-loop 조용한 무산출 3일 연속
 5회  LA-Cron 진짜 중복 발견
 3회  봇 시작 실패 — Merge Conflict 마커 잔존
```

**이게 더 심각하다.** 같은 실패가 7일간 반복된다는 것은
알림이 행동으로 이어지지 않았다는 뜻이다. A가 B를 묻고 있다.

### 근본 원인

오늘 전수검사에서 확인된 구조적 원인과 동일하다.

1. **만들 때 폐기·억제 조건을 안 정한다** — 알림을 추가하는 비용은 0이고 지우는 사람은 없다
2. **정상도 보고한다** — "돌고 있음"을 증명하려는 알림이 대부분이다
3. **수신자가 하나다** — `jarvis-system`에 58%가 몰려 심각도 구분이 무의미하다

---

## 3. 개선 원칙 (실행 규칙)

### 원칙 1 — 변화에만 알린다 (edge-triggered)

상태가 **바뀔 때만** 보낸다. 정상 → 정상은 침묵한다.
직전 상태를 해시로 저장하고 같으면 발송하지 않는다.

```
정상→이상  발송 ✅
이상→이상  억제 (일일 요약에만 집계)
이상→정상  발송 ✅ ("복구됨")
정상→정상  침묵 ❌
```

### 원칙 2 — 같은 실패는 억제하고 집계한다

동일 알림 재발 시: **최초 1회 즉시 + 이후 억제 + 하루 1회 요약**.
요약에는 "N회 반복, 최초 발생 시각"을 포함한다.

### 원칙 3 — 행동 불가 알림은 알림이 아니다

받고 나서 **할 일이 없으면** 로그로 강등한다.
자기검열: "이 알림을 받고 주인님이 하실 행동이 있는가?" 없으면 삭제.

### 원칙 4 — 심각도로 채널을 나눈다

```
critical → jarvis-system  (즉시 대응 필요. 하루 5건 넘으면 실패한 설계)
info     → jarvis-info    (참고용. 읽지 않아도 손해 없음)
retro    → jarvis-retro   (사후 분석용. 주 1회 묶음)
```

### 원칙 5 — 발신자를 밝힌다

`system-doctor` 카드를 7개 스크립트가 공유하는 현 구조를 끝낸다.
모든 알림에 발신 스크립트명을 넣는다.

---

## 4. 실행 계획 (4단계)

### 1단계 — 즉시 억제 (예상 감축 약 60%)

| 대상 | 조치 | 근거 |
|---|---|---|
| `오답노트 추출 — 세션 종료` 111건 | 발송 중단, 로그로 강등 | 세션 종료는 정상 동작. 행동 불가 |
| `system-doctor` 정상 카드 | 이상 감지 시에만 발송 | 490건 대부분이 "이상 없음" |
| `stats` 정례 카드 | 일 1회 묶음 | 226건 → 7건 |

**되돌리기**: 각 스크립트의 발송 조건 한 줄이므로 원복 쉬움.

### 2단계 — 반복 억제 게이트 도입

공용 함수 하나를 만들어 모든 발송부가 경유하게 한다.

```bash
# infra/lib/alert-gate.sh (신규)
# 같은 키의 알림이 N시간 내 재발하면 억제하고 카운트만 올린다.
alert_gate() {
    local key="$1" ttl_h="${2:-6}"
    local f="${BOT_HOME}/state/alert-gate/$(echo "$key" | md5)"
    ...  # 최근 발송 시각 비교 → 억제 여부 반환
}
```

**새 크론을 만들지 않는다.** 기존 발송 경로에 게이트만 끼운다.

### 3단계 — 실패 12종 실제 해결

억제만 하면 실패가 숨는다. 12종 각각에 대해 판정한다.

| 실패 | 판단 필요 |
|---|---|
| `LLM budget_exceeded` 13회 | 예산 상향인가, 호출 감축인가 |
| `유령 디렉토리 자동 복구` 11회 | 오늘 심링크 사고와 동일 뿌리인가 |
| `OAuth 야간 검증 실패` 7회 | 실제 인증 문제인가, 검사기 오탐인가 |
| `skill-loop 무산출 3일` 6회 | 이 크론이 필요한가 |
| `LA-Cron 중복` 5회 | 중복 제거 |
| `봇 시작 Merge Conflict` 3회 | 이미 해결됐는가 |

각각 실측 후 **고치거나 끄거나** 둘 중 하나. 방치는 없다.

### 4단계 — 크론 실효성 정리

```
현황: crontab 53 · LaunchAgent 70(ai.jarvis.*) · tasks.json 137
```

판정 기준 (전부 실측):
- 최근 30일 **산출물이 0인가** → 끈다
- 산출물을 **읽는 코드가 없는가** → 끈다
- 같은 일을 하는 게 **둘 이상인가** → 하나로 합친다
- 주기가 **과한가** (5분 → 1시간 → 하루로 낮출 수 있는가)

5분 주기 4개(`board-watchdog` `resilience-guard` `supervisor` `sync-system-metrics`)를
1순위로 검토한다. 각 288회/일이다.

---

## 5. 성공 측정 기준

실행 후 7일 뒤 같은 명령으로 재측정한다.

| 지표 | 현재 | 목표 |
|---|---:|---:|
| 일평균 알림 | 158건 | **20건 이하** |
| critical 채널 일평균 | 91건 | **5건 이하** |
| 5회+ 반복 알림 종수 | 11종 | **0종** |
| 미해결 반복 실패 | 12종 | **0종** (고치거나 끈다) |

```bash
# 재측정 명령 (그대로 재실행)
python3 -c "
import json,collections,datetime
cut=(datetime.datetime.now()-datetime.timedelta(days=7)).isoformat()
ch=collections.Counter(); n=0
for l in open('runtime/ledger/discord-send-audit.jsonl',encoding='utf-8',errors='replace'):
    try: o=json.loads(l)
    except: continue
    if str(o.get('ts') or '') < cut: continue
    n+=1; ch[o.get('channel') or '?']+=1
print(f'7일 {n}건 = 일평균 {n//7}건'); print(ch.most_common(5))
"
```

---

## 6. 하지 않을 것 (명시)

- **새 감시 크론 추가 금지.** 소음을 줄이려고 감시자를 늘리면 소음이 는다.
  필요한 검사는 기존 주간 감사(`token-ledger-audit.sh`)에 붙인다.
- **알림 전면 차단 금지.** 종류 B(진짜 실패)는 살려야 한다. 억제는 A에만 적용한다.
- **일괄 크론 비활성화 금지.** 137개가 서로 얽혀 있어 연쇄 영향이 있다.
  하나씩 실측 후 개별 판정한다.

---

## 부록 — 측정 재현 명령

```bash
# 발신자별
python3 -c "import json,collections;print(collections.Counter(json.loads(l).get('source','?') for l in open('runtime/ledger/discord-send-audit.jsonl')).most_common(10))"

# 실행 주기 분포
ls ~/Library/LaunchAgents/ai.jarvis.*.plist | while read p; do
  si=$(/usr/libexec/PlistBuddy -c "Print :StartInterval" "$p" 2>/dev/null)
  [ -n "$si" ] && echo "$si $(basename $p .plist)"
done | sort -n

# system-doctor 카드 발신처
grep -rln 'system-doctor' infra/scripts/*.sh infra/bin/*.sh
```
