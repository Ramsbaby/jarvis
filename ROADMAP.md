# Jarvis 종합 로드맵

> 작성: 2026-03-01 | 업데이트: 2026-03-04 | 현재 완성도: **~77%** | 목표: **90%**
> 상세 업그레이드 항목: → `~/Jarvis-Vault/01-system/UPGRADE-ROADMAP.md` (24개 항목)
> "체계적으로 계획하고, 실행하고, 검토하고, 반성한다."

---

## 1. 현재 상태 평가

### 완료된 것 (Phase 1 — 2026-03-01 완료)

| 영역 | 상태 | 상세 |
|------|------|------|
| Discord Bot | ✅ 가동 중 | 976줄, 멀티턴 세션, 스트리밍, /search /threads /alert |
| LanceDB RAG | ✅ 작동 | 1,933 chunks, 240 sources, 하이브리드 검색 (매시간 증분) |
| 장기 기억 이관 | ✅ 23개 핵심 파일 | domains, knowledge, teams, strategy, career |
| ntfy 푸시 | ✅ 연동 | Galaxy 폰 알림, 크래시/에러 시 자동 전송 |
| 크론 태스크 | ✅ 24개 활성 | morning-standup, stock-monitor, health, 팀크론 5개, cleanup 등 |
| E2E 테스트 | ✅ 28/28 PASS | 프로세스, RAG, 파일, 의존성, 크론 검증 |
| ask-claude.sh | ✅ RAG 통합 | 시맨틱 검색 + 정적 파일 fallback |

### 미완료 갭 분석

| 영역 | 현재 | 갭 | 우선순위 |
|------|------|-----|---------|
| 기반 인프라 | ✅ 완료 | - | - |
| RAG 엔진 | ✅ 1,933 chunks | 커버리지 확대 | 🟡 P1 |
| 채널별 페르소나 | ✅ 11채널 | - | - |
| 자비스 컴퍼니 팀 크론 | ✅ 7/7 구성 완료 | 실제 실행 검증 필요 | 🟡 P1 |
| 웹훅 라우팅 | ✅ 5채널 완성 | 나머지 채널 추가 | 🟢 P2 |
| KPI 자동 측정 | ✅ measure-kpi.sh | crontab 통합 | 🟡 P1 |
| 크론 성공률 | 🟡 84% | 목표 90%+ (timeout 240s로 수정 완료, 검증 중) | 🟡 P1 |
| Company DNA SSoT | ✅ 동기화 완료 | - | - |
| 자율처리 레벨 체계 | ❌ 미구현 | autonomy-levels.md 실제 적용 | 🟢 P2 |
| measure-kpi cron | 🟡 구현 완료 | crontab 등록 대기 중 (P1-C) | 🟡 P1 |

---

## 2. 로드맵 (4 Phase)

### Phase 2: 페르소나 & 기억 완성 (P0 — 즉시)

> 예상 소요: 1세션 | 임팩트: Discord 대화 품질 급상승

#### Task 2-1. 자비스 페르소나 시스템 프롬프트 주입

**파일**: `~/.jarvis/discord/discord-bot.js` (SYSTEM_PROMPT 수정)

현재 시스템 프롬프트에 persona.md 내용 통합:
- 영국식 위트 + 드라이한 유머
- 금지 표현 (알겠습니다!, 완료!, 제가 도와드리겠습니다)
- Discord 포매팅 규칙 (소제목 빈 줄, 테이블 사용, 코드블록 최소화)
- Pre-Send Checklist (ChatGPT 같은 답변 차단)
- Opening Lines by Task Type (검색/코딩/분석별 다른 톤)

**검증**: Discord에서 "자기소개 해봐" → 자비스다운 응답 확인

#### Task 2-2. RAG 인덱싱 확장 (20% → 60%+)

**파일**: `~/.jarvis/bin/rag-index.mjs`

추가 인덱싱 대상 (~150개 파일):
```
~/.jarvis/rag/teams/reports/*.md       # 주간 보고서
~/.jarvis/rag/teams/learnings/*.md     # 교훈 기록
~/.jarvis/rag/teams/shared-inbox/*.md  # 팀 간 메시지
~/.jarvis/context/*.md                 # 크론 컨텍스트 파일 전체
~/.jarvis/results/**/*.md              # 태스크 결과 (최근 7일)
```
또는 `BOT_EXTRA_MEMORY` 환경변수로 외부 메모리 디렉토리 지정 가능.

**주의**: 파일 수 증가 → 임베딩 비용 증가. 초기 인덱싱 시 OpenAI API 호출량 확인 필요.

**검증**: `node rag-index.mjs` 후 stats > 800 chunks

#### Task 2-3. context 파일 생성 (크론 태스크용)

**디렉토리**: `~/.jarvis/context/`

현재 tasks.json에 contextFile이 정의되어 있지만 실제 파일 미존재.
각 크론 태스크에 필요한 배경 지식을 컨텍스트 파일로 생성:

- `morning-standup.md` — 오너 일과, 중요 일정 패턴
- `stock-monitor.md` — 시장 손절선(DNA-C001), 포트폴리오 현황 (로컬 전용)
- `market-alert.md` — 급변 기준, VIX 병행 조회 규칙 (로컬 전용)
- `daily-summary.md` — 하루 요약 포맷, 핵심 지표
- `weekly-report.md` — 주간 리포트 구조, KPI 항목

---

### Phase 3: 거버넌스 & 운영 체계 (P1 — 1주 내)

> 예상 소요: 2~3세션 | 임팩트: 자비스가 "회사"처럼 자율 운영

#### Task 3-1. 운영 주기 (Cadence) 설정

**일간 (Daily)**
| 시간 | 태스크 | 설명 |
|------|--------|------|
| 07:50 | news-briefing | AI/Tech 뉴스 3건 |
| 08:05 | morning-standup | 통합 브리핑 (일정+시장+시스템) |
| 09~16시 | stock-monitor | 15분 간격 시세 (평일, 선택) |
| 20:00 | daily-summary | 하루 요약 + 이슈 |
| 02:00 | memory-cleanup | 7일 초과 정리 |

**주간 (Weekly)**
| 요일 | 태스크 | 설명 |
|------|--------|------|
| 일 20:05 | weekly-report | 주간 리포트 (태스크 성공률, 이슈, 개선안) |
| 월 08:30 | **weekly-kpi** (신규) | KPI 주간 집계 + CEO 리포트 |

**월간 (Monthly)**
| 일자 | 태스크 | 설명 |
|------|--------|------|
| 1일 09:00 | **monthly-review** (신규) | 월간 회고 (비용, 성과, 개선, 다음달 계획) |

#### Task 3-2. 주간 KPI 리포트 크론 추가

**파일**: `~/.jarvis/config/tasks.json`에 `weekly-kpi` 태스크 추가

```json
{
  "id": "weekly-kpi",
  "name": "주간 KPI 리포트",
  "schedule": "30 8 * * 1",
  "prompt": "이번 주 봇 시스템 KPI 집계: 1) 크론 태스크별 성공/실패율 (~/.jarvis/logs/cron.log) 2) RAG 인덱스 통계 3) Discord 응답 건수 4) 에러/경고 빈도. 개선 제안 1~2개 포함.",
  "output": ["discord", "file"]
}
```

#### Task 3-3. 월간 회고 크론 추가

**파일**: `~/.jarvis/config/tasks.json`에 `monthly-review` 태스크 추가

```json
{
  "id": "monthly-review",
  "name": "월간 회고",
  "schedule": "0 9 1 * *",
  "prompt": "지난 달 봇 운영 회고: 1) 목표 vs 달성 비교 2) 비용 현황 (API 사용량) 3) 시스템 안정성 (업타임, 크래시 횟수) 4) 가장 많이 사용된 기능 5) 다음 달 개선 목표 3가지. 한국어로 간결하게.",
  "output": ["discord", "file"]
}
```

#### Task 3-4. 자율처리 레벨 정의

**파일**: `~/.jarvis/config/autonomy-levels.md` (신규)

4단계 자율처리 체계:

| 레벨 | 설명 | 예시 | 승인 |
|------|------|------|------|
| **L1** | 자동 실행, 로그만 남김 | 로그 정리, 디스크 체크, RAG 인덱싱 | 불필요 |
| **L2** | 자동 실행, Discord 보고 | 모닝 브리핑, 뉴스, 시세 모니터링 | 불필요 |
| **L3** | 실행 전 Discord에서 확인 요청 | 파일 삭제, 설정 변경, 크론 수정 | 오너 확인 |
| **L4** | 실행 불가, 오너 직접 지시 필요 | 토큰 갱신, 서비스 재시작, 배포 | 오너 명령 |

#### Task 3-5. Company DNA 마이그레이션

**파일**: `~/.jarvis/config/company-dna.md` (신규)

Company DNA 패턴 정의:
- DNA-C001: 시장 분석 체크 (손절선 기준, 트렌드+VIX)
- DNA-C002: 알림 시간 원칙 (23:00~08:00 조용한 시간)
- DNA-S001: Discord 보고 형식 (1800자, 헤더 최소화)

---

### Phase 4: 고급 크론 & 지능 강화 (P1~P2 — 2주 내)

> 예상 소요: 3~4세션 | 임팩트: 팀 수준의 자동화

#### Task 4-1. 고급 크론 태스크 5개 추가

기본 18개 → 24개. 실용성 높은 태스크 + 팀 크론 5개 선별:

| ID | 이름 | 스케줄 | 설명 |
|---|---|---|---|
| `weekly-kpi` | 주간 KPI | 월 08:30 | 크론 성공률, RAG 통계, 에러 빈도 |
| `monthly-review` | 월간 회고 | 1일 09:00 | 비용/성과/개선 회고 |
| `security-scan` | 보안 스캔 | 매일 02:30 | .env 노출, 권한 이상, 로그 감사 |
| `rag-health` | RAG 건강 체크 | 매일 03:00 | 인덱스 무결성, 검색 품질, 커버리지 |
| `career-weekly` | 커리어 주간 | 금 18:00 | 이직 시장 동향, 채용 트렌드 |

#### Task 4-2. Discord 채널 라우팅 (선택)

현재: 모든 크론 결과가 단일 채널로 전송
개선: 태스크별 채널 지정 (tasks.json의 `output` 배열에 채널 ID 추가)

```
#bot-system  → system-health, disk-alert, rate-limit-check
#bot-market  → stock-monitor, market-alert
#bot-daily   → morning-standup, daily-summary, news-briefing
#bot-ceo     → weekly-kpi, monthly-review, weekly-report
```

**주의**: Discord 서버에 채널이 이미 11개 존재 (CHANNEL_IDS in .env). 기존 채널 매핑 확인 필요.

#### Task 4-3. 실시간 RAG 파일 워처 (선택)

**파일**: `~/.jarvis/lib/rag-watcher.mjs` (신규)

```bash
npm install chokidar  # ~/.jarvis/discord/
```

chokidar로 `~/.jarvis/context/`, `~/.jarvis/rag/`, `~/.jarvis/results/` 감시.
파일 변경 즉시 RAG 재인덱싱 (현재 1시간 크론 → 실시간).

**고려사항**: LaunchAgent로 상시 구동 필요. 메모리 사용량 확인.

---

### Phase 5: 성숙도 향상 (P2 — 1개월 내)

> 장기 개선 항목. 당장 급하지 않지만 90% → 95% 달성에 필요.

#### Task 5-1. 자가 진단 & 자동 복구

- E2E 테스트를 크론으로 실행 (매일 03:00)
- 실패 시 자동 복구 시도 (L1 수준) + ntfy 알림
- 복구 불가 시 Discord + ntfy로 에스컬레이션

#### Task 5-2. 비용 모니터링

- OpenAI API 사용량 일간 추적
- 월 $10 초과 시 경고 (RAG 임베딩 + 크론 비용)
- 주간 KPI에 비용 항목 추가

#### Task 5-3. 성과 대시보드

- `~/.jarvis/results/` 데이터 기반 간단한 통계
- 크론 성공률, 평균 응답 시간, RAG 검색 히트율
- 주간/월간 리포트에 자동 포함

#### Task 5-4. Obsidian Vault 연동 (선택)

- `~/.jarvis/rag/` 디렉토리를 Obsidian Vault로 활용
- 그래프 뷰로 지식 연결 시각화
- RAG와 양방향 동기화

---

## 3. 운영 프레임워크: PDCA 사이클

### Plan (계획) — 매주 월요일 08:30

- 주간 KPI 리포트 확인
- 이번 주 목표 설정 (tasks.json 또는 Discord)
- 블로커 식별 및 해결 방안 수립

### Do (실행) — 매일 자동

- 크론 태스크 자동 실행
- Discord 대화를 통한 수시 작업
- RAG 인덱싱으로 지식 자동 축적

### Check (검토) — 매일 20:00

- daily-summary로 하루 성과 확인
- 실패 태스크 원인 분석
- RAG 검색 품질 간접 확인 (Discord 대화 품질)

### Act (반성/개선) — 매주 일요일 20:00 / 매월 1일

- weekly-report: 주간 이슈 & 개선안
- monthly-review: 월간 회고 & 다음달 계획
- Company DNA 업데이트 (검증된 패턴 추가)

---

## 4. 즉시 실행 가능한 TODO (다음 세션)

> 우선순위 순. 한 세션에 1~2개씩 진행 권장.

### ✅ 완료 (2026-03-02)

- [x] **Task 2-1**: discord-bot.js 자비스 페르소나 주입
- [x] **Task 2-2**: RAG 인덱싱 확장 (reports/, decisions/ 추가)
- [x] **Task 2-3**: context/*.md 파일 생성 (stock-monitor, market-alert, morning-standup 등)
- [x] **Task 3-1**: 운영 주기 Cadence 확인 (모두 정상 스케줄)
- [x] **Task 3-2**: weekly-kpi 크론 추가 (월 08:30)
- [x] **Task 3-3**: monthly-review 크론 추가 (1일 09:00)
- [x] **Task 3-4**: autonomy-levels.md (L1~L4 자율처리 체계)
- [x] **Task 3-5**: company-dna.md SSoT 생성

- [x] **Task 4-1**: 고급 크론 3개 추가 (security-scan 02:30, rag-health 03:00, career-weekly 금18:00)
- [x] **Task 4-2**: Discord 채널 라우팅 (bot-daily/market/ceo/system 4채널 프레임워크)

- [x] **Task 5-1**: E2E 자가 진단 크론화 (e2e-cron.sh, 매일 03:30, 실패 시 ntfy 에스컬레이션)
- [x] **Task 5-2**: 비용 모니터링 (cost-monitor, 매주 일요일 09:00)
- [x] **Task 5-3**: 성과 대시보드 (weekly-kpi 프롬프트에 통합)
- [x] **Task 5-4**: Obsidian 가이드 문서화 (archived)

### 🟡 수동 작업 필요 (코드 외)

- [ ] **Discord webhook 등록**: bot-market, bot-daily, bot-ceo 웹훅 생성 → `monitoring.json` 추가
- [x] **Obsidian**: Jarvis-Vault git init + .obsidian config 완료 (2026-03-05). obsidian-git 플러그인은 Obsidian 앱에서 수동 설치 필요

### 🟢 선택 개선 (P2)

- [x] **Task 4-3**: 실시간 RAG 워처 (rag-watch.mjs, chokidar — ~/Jarvis-Vault/ 실시간 감시 중)

---

## 5. 완성도 예상 로드맵

| 시점 | 완성도 | 핵심 달성 사항 |
|------|--------|--------------|
| Phase 1 완료 (2026-03-01) | **60%** | RAG, Discord bot, ntfy, 기본 크론 |
| Phase 2 완료 (2026-03-02) | **68%** | 페르소나, RAG 커버리지 확장, 컨텍스트 파일 |
| Phase 3 완료 (2026-03-02) | **75%** | 거버넌스, PDCA 사이클, KPI, 자율처리 레벨 문서화 |
| Phase 4 완료 (2026-03-02) | **80%** | 고급 크론 24개, 채널 라우팅, 팀 크론 5개 |
| Phase 4 완료 시점 | **~77%** | 고급 크론 24개, 채널 라우팅, 팀 크론 5개 (실사 기준) |
| **현재** (2026-03-04) | **~77%** | Vault 동기화 구축, RAG 재귀 인덱싱, 업그레이드 로드맵 24개 정립 ← **현재** |
| 잔여 작업 완료 시 | **90%** | 피드백 루프, 세마포어 큐, Skills 마이그레이션, 이벤트 버스 |

---

## 6. 파일 구조 참조

```
~/.jarvis/
├── bin/
│   ├── ask-claude.sh          # Claude CLI 래퍼 (RAG 통합)
│   ├── bot-cron.sh         # 크론 실행기
│   ├── rag-index.mjs          # RAG 증분 인덱서
│   ├── retry-wrapper.sh       # 재시도 래퍼
│   ├── route-result.sh        # 결과 라우터 (Discord/파일/ntfy)
│   └── semaphore.sh           # 동시성 제어
├── config/
│   ├── tasks.json             # 크론 태스크 정의 (24개)
│   ├── monitoring.json        # 모니터링 설정
│   ├── autonomy-levels.md     # 자율처리 레벨 (L1~L4, 문서화 완료)
│   └── company-dna.md         # Company DNA (SSoT 동기화 완료)
├── context/                   # 크론 태스크별 배경 지식 (생성 완료)
├── discord/
│   ├── discord-bot.js         # Discord 봇 (976줄)
│   ├── .env                   # 환경변수 (DISCORD_TOKEN, OPENAI_API_KEY 등)
│   └── node_modules/          # @lancedb, openai, discord.js 등
├── lib/
│   ├── rag-engine.mjs         # LanceDB RAG 엔진
│   └── rag-query.mjs          # RAG 쿼리 CLI
├── logs/                      # 크론 로그, RAG 로그
├── rag/
│   ├── lancedb/               # LanceDB 벡터 DB (~1,933 chunks)
│   ├── memory.md              # 장기 기억
│   ├── decisions.md           # 의사결정 기록
│   ├── handoff.md             # 세션 인계 노트
│   └── index-state.json       # RAG 인덱스 상태 (mtime 추적)
├── results/                   # 크론 실행 결과
├── scripts/
│   ├── e2e-test.sh            # E2E 테스트 (28개)
│   ├── alert.sh               # 알림 (Discord + ntfy)
│   ├── health-check.sh        # 헬스체크
│   ├── launchd-guardian.sh    # LaunchAgent 감시자
│   ├── log-rotate.sh          # 로그 로테이션
│   ├── sync-discord-token.sh  # 토큰 동기화
│   ├── vault-sync.sh          # Vault 미러링 (6시간마다)
│   └── watchdog.sh            # 와치독
├── state/
│   ├── sessions.json          # Discord 세션 상태
│   └── rate-tracker.json      # Rate limit 추적
└── ROADMAP.md                 # ← 이 문서
```

---

*이 문서는 봇의 발전 과정을 추적하는 살아있는 문서입니다.*
*새로운 Phase가 완료될 때마다 업데이트하세요.*
