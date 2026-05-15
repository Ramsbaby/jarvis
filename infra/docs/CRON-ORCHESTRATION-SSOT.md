# 크론 오케스트레이션 SSoT

> **작성**: 2026-05-07 / **위치**: `~/jarvis/infra/docs/CRON-ORCHESTRATION-SSOT.md`
> **목적**: 주인님 의도("아무리 많은 크론이 생겨나도 관리할 오케스트레이션이 있으면 문제 없다") 구현 표준.
> **연계**: `tasks.json` (등록 SSoT) · `cron-master.sh` (감사 에이전트) · `validate-tasks.mjs` (입력 검증).

---

## 0. 단일 진실 원칙 (Iron Rule)

**모든 주기 작업은 `tasks.json` 한 곳에만 등록한다.** 단, 아래 명시 예외만 plist 직접 허용.

- ❌ `crontab -e` 직접 등록 — **차단** (precheck 훅이 거부)
- ❌ `~/Library/LaunchAgents/*.plist` 직접 작성 — long-running 데몬 + **명시 예외 카테고리** 외 **차단**
- ✅ `tasks.json` 엔트리 + `gen-tasks-index.mjs` 실행 — **기본 경로**

### 🟡 예외 카테고리 (2026-05-08 등재 — verify B2 fix)

다음 카테고리는 **plist 직접 작성 OK**. 단 카테고리 표기 필수.

| 카테고리 | 이유 | 예시 |
|---|---|---|
| `meta-audit` | tasks.json 자체를 감사 — 자기참조 회피 | `interview-ssot-audit`, `model-version-audit`, `docs-freshness-audit`, `audit-dashboard`, `meta-audit` |
| `system-monitor` | tasks.json runtime 의존성 외부 — supervisor / health | `supervisor`, `resilience-guard`, `llm-cost-cap-monitor` |
| `retention/archive` | 시스템 hygiene — Claude API 비호출 | `docs-daily-regen`, `retention`, `skill-dead-archive`, `skill-dryrun-auto-activate` |
| `bot-runner` | long-running 데몬 (이미 예외) | `discord-bot`, `nexus`, `interview-verifier` |

**추가 룰**:
- 예외 plist도 `LAUNCHAGENT-CATALOG.md`에 자동 카탈로그
- 예외 plist도 `meta-audit`이 last-exit 점검
- 신규 예외 도입 시 위 카테고리 매핑 필수 — 카테고리 없으면 `tasks.json`이 정답

### 진입점 가시성

- `tasks.json` (기본 경로) + `LAUNCHAGENT-CATALOG.md` (예외 카탈로그) = **자비스 시야 100%**
- 두 곳 모두 매주 자동 갱신 (gen-tasks-index + gen-launchagent-catalog)
- meta-audit이 양쪽 일관성 점검

---

## 1. 태스크 라이프사이클 — 4-State Machine

```
[active] ──7일 미실행──> [amber]  (경고만)
   │                      │
   │                      └──30일 0가치──> [cold]  (auto-disable)
   │                                          │
   │                                          └──60일 유지──> [archived]  (tasks.json 제거 + 백업)
   └──manual──> [paused]  (휴면, 가치 메트릭 정지)
```

### 상태 정의

| State | 의미 | 실행 | 가치 측정 |
|---|---|:---:|:---:|
| `active` | 정상 작동 | ✅ | ✅ |
| `amber` | 7일 이상 미실행 — 정황 의심 | ✅ | ✅ |
| `cold` | 30일 0가치 — 자동 비활성 | ❌ | ✅ |
| `paused` | 사용자 수동 휴면 | ❌ | ❌ |
| `archived` | 영구 보관 (60일 cold 유지 후) | ❌ | ❌ |

### 전이 규칙

- **active → amber**: `last_invoke > 7d ago`
- **amber → cold**: `last_invoke > 7d ago` AND `value_score == 0` (30일 평균)
- **cold → archived**: `state == cold` AND `mtime > 60d`
- *** → paused**: 사용자 명시 `enabled: false` (현 37건이 이 상태)
- **archived → tasks.json 제거**: 자동 (백업은 `archived/` 디렉토리)

---

## 2. 가치 메트릭 (Value Signals)

각 태스크마다 매일 자동 갱신. 0~3점 합산 = `value_score`.

| 신호 | 측정 | 점수 |
|---|---|:---:|
| `last_invoke_within_7d` | 최근 7일 내 실행 흔적 (results/*.log mtime) | +1 |
| `discord_seen_7d` | Discord 채널에 결과 카드 도달 (channel-feeds.jsonl) | +1 |
| `result_consumed_7d` | 결과 파일을 다른 태스크/사용자가 read | +1 |

> `value_score == 0` 30일 = **가치 없음** = `cold` 자동 전이.

---

## 3. 라벨 스키마 (tasks.json 확장 필드)

기존 필드 위에 거버넌스 메타데이터 추가:

```jsonc
{
  "id": "rag-lancedb-compact",
  "name": "...",
  "schedule": "...",
  "script": "...",

  // ── 신규 거버넌스 필드 ──
  "kind": "system" | "alert" | "report" | "audit" | "data-pipeline" | "user-tool",
  "owner": "infra" | "growth" | "audit" | "intel" | "learning" | "archive" | "brand" | "user",
  "state": "active" | "amber" | "cold" | "paused" | "archived",
  "value_signals": {
    "last_invoke": "2026-05-07T04:15:00Z",
    "value_score": 3,
    "last_eval": "2026-05-07T00:00:00Z"
  },
  "justification": "왜 사람 손보다 자동화가 나은가 1줄",
  "imported_from": "crontab" | "plist" | "manual"  // 마이그레이션 추적
}
```

---

## 4. 진입점 통합 룰

### 4-A. crontab 차단 가드

**구현**: shell function 래핑 또는 pre-commit/precheck 훅.

```bash
# ~/.zshrc에 추가
crontab() {
  if [[ "$1" == "-e" || "$1" == "-r" ]]; then
    echo "❌ crontab 직접 편집 금지. tasks.json + gen-tasks-index 사용." >&2
    return 1
  fi
  command crontab "$@"
}
```

### 4-B. plist 작성 룰

`~/Library/LaunchAgents/*.plist` 신규 작성은 다음 두 경우만 허용:
1. **Long-running 데몬** — `KeepAlive: true` + 단일 인스턴스 (예: discord-bot, watchdog, cloudflared-tunnel, board)
2. **부팅 트리거** — `RunAtLoad: true` + OnDemand (예: boot-auth-check, claude-zombie-cleanup)

주기 실행(`StartCalendarInterval` / `StartInterval`)은 **금지** — tasks.json으로 가야 함.

`launchagents-watcher`가 매일 위반 plist를 감사하고 알림.

---

## 5. 자동 거버넌스 — 매일 03:00 KST 실행

### 5-A. cron-master 확장 (`cron-master-v2.mjs` 신설 예정)

```
1. Discover    : tasks.json 전수 + crontab + plist 통합 인벤토리
2. Measure     : value_signals 갱신 (3개 신호 측정)
3. Transition  : 상태 머신 적용 (active↔amber↔cold↔archived)
4. Report      : Discord 카드 + dashboard 데이터
5. Self-Audit  : 자신의 사각지대 (ex. 새 진입점 출현) 감지
```

### 5-B. 주간 거버넌스 리포트 (`/cron 명령` 또는 일요일 09:00)

- 신규 등록 (지난 7일)
- 상태 전이 (active→amber→cold)
- 가치 0점 누적 후보
- 시간대 충돌 경고
- 의존성 그래프 변경

---

## 6. 신규 등록 결재 룰

`validate-tasks.mjs`가 다음을 강제:

- ✅ `kind`·`owner`·`justification` 필수
- ✅ `state == "active"` 초기값
- ✅ schedule 시간대 충돌 검사 (같은 분에 5개+면 경고)
- ✅ id 충돌 검사 (대소문자·하이픈/언더스코어 무시)
- ✅ `script` 또는 `prompt` 둘 중 하나 필수

위반 시 PR/등록 거부.

---

## 7. 대시보드 (자비스보드 `/cron`)

### 7-A. 라이프 카드 (per task)

```
┌────────────────────────────────────────┐
│ rag-lancedb-compact     [active]       │
│ kind: system · owner: infra            │
│ schedule: 15 4 * * 0 (Sun 04:15 KST)  │
│ value_score: 3/3 ✅                    │
│ last_invoke: 2 days ago                │
│ next_run: in 4 days                    │
└────────────────────────────────────────┘
```

### 7-B. 시간대 히트맵

24×7 그리드. 각 셀 = 같은 시간에 도는 태스크 수. 빨강(>10) = 분산 권고.

### 7-C. 의존성 그래프

`depends` 배열로 DAG 시각화. 사이클 감지.

---

## 8. 마이그레이션 로드맵

| Phase | 작업 | 산출물 | ETA |
|:---:|---|---|---|
| **P0** | 본 SSoT 문서 확정 | `CRON-ORCHESTRATION-SSOT.md` | ✅ 완료 |
| **P1** | `crontab → tasks.json` importer (dry-run) | `cron-importer.mjs` | 진행 중 |
| **P2** | `plist → tasks.json` 분류기 (dry-run) | `plist-classifier.mjs` | 진행 중 |
| **P3** | 마이그레이션 일괄 실행 (사용자 결재 후) | tasks.json +124건 | 결재 대기 |
| **P4** | crontab 차단 가드 + plist 룰 enforcement | shell hook + audit | P3 후 |
| **P5** | `cron-master-v2` (라이프사이클 머신) | 신규 mjs | P4 후 |
| **P6** | 자비스보드 `/cron` 대시보드 | Next.js 페이지 | P5 후 |

---

## 9. 보존·롤백

- **tasks.json 백업**: `tasks.json.bak.YYYYMMDD-HHMMSS` (매 변경 시)
- **archived 태스크**: `~/jarvis/runtime/state/archived-tasks/<id>.json` (60일 cold 후 이관)
- **crontab 원본 백업**: `~/.jarvis/state/crontab-snapshots/YYYY-MM-DD.txt` (마이그 전 자동)

---

## 10. 핵심 KPI

| 지표 | 현재 (2026-05-07) | 목표 |
|---|---:|---:|
| 크론마스터 시야율 | 48% | **100%** |
| fail_24h | 226 | **<10** |
| 사각지대 (crontab + 직접 plist) | 124 | **0** |
| 0가치 30일+ 태스크 | 미측정 | **<5%** |
| 신규 등록 → SSoT 통합 시간 | 수동 (몇 시간) | **<5분** |

---

## 11. 변경 이력

- **2026-05-07** v1.0 — 초안. 주인님 의도 "오케스트레이션 격차 해소" 반영. P0 완료.
