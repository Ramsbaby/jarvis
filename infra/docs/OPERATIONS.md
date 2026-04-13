# Operations Guide

> Back to [docs/INDEX.md](INDEX.md) | [README](../README.md)

## Cron Schedule

All cron tasks are defined in `config/tasks.json` and executed by `bin/bot-cron.sh`.

### Critical (always runs)

| Task | Schedule | Description |
|------|----------|-------------|
| `morning-standup` | 06:15 daily | Smart standup (waits for owner online) |
| `stock-monitor` | */15 22-23 Mon-Fri | Stock/ETF price tracking |
| `market-alert` | 09:05,13:05,16:05 Mon-Fri | 5%+ swing detection |

### Daily

| Task | Schedule | Description |
|------|----------|-------------|
| `news-briefing` | 07:50 | AI/Tech news top 3 |
| `infra-daily` | 09:00 | Infrastructure health check |
| `daily-summary` | 20:00 | End-of-day summary |
| `record-daily` | 22:30 | Daily archive + logging |
| `council-insight` | 23:05 | Cross-team oversight |
| `finance-monitor` | 08:00 Mon-Fri | Financial monitoring |
| `ceo-daily-digest` | 23:15 daily | CEO daily digest summary (council-insight 23:05 이후) |
| `personal-schedule-daily` | 07:30 daily | 일정 브리핑 |
| `bot-self-critique` | 02:45 daily | Bot response self-evaluation |
| `system-doctor` | 06:00 daily | System diagnostics |
| `oss-maintenance` | 09:15 daily | OSS repo maintenance |
| `personal-schedule-daily` | 07:30 | Schedule briefing |

### Weekly / Monthly

| Task | Schedule | Description |
|------|----------|-------------|
| `weekly-report` | Sun 20:05 | Weekly system summary |
| `weekly-kpi` | Mon 08:30 | KPI measurement |
| `ceo-weekly-digest` | Mon 09:00 | CEO weekly review digest |
| `connections-weekly-insight` | Mon 09:45 | Cross-team pattern analysis |
| `weekly-usage-stats` | Mon 09:00 | Discord usage statistics |
| `career-weekly` | Fri 18:00 | Career growth report |
| `academy-support` | Sun 20:00 | Learning team digest |
| `brand-weekly` | Tue 08:00 | Brand/OSS growth report |
| `recon-weekly` | Mon 09:00 | Intelligence exploration |
| `weekly-code-review` | Sun 05:00 | Automated code review |
| `memory-sync` | Mon 04:30 | Memory auto-sync |
| `memory-expire` | Mon 03:00 | Memory TTL expiration + stale entry purge |
| `monthly-review` | 1st of month 09:00 | Monthly ops retrospective |

### Maintenance

| Task | Schedule | Description |
|------|----------|-------------|
| `token-sync` | 01:00 daily | Claude Max token sync |
| `memory-cleanup` | 02:00 daily | Old results/sessions purge |
| `security-scan` | 02:30 daily | Secret files + permissions audit |
| `bot-quality-check` | 02:30 daily | Bot response quality analysis |
| `rag-health` | 03:00 daily | RAG index integrity check |
| `code-auditor` | 04:45 daily | ShellCheck + syntax validation |
| `gen-system-overview` | 04:05 daily | Auto-regenerate SYSTEM-OVERVIEW.md (script-only) |
| `doc-sync-auditor` | 23:00 daily | Doc-code sync audit + draft generation |
| `doc-supervisor` | 05:00 daily | Documentation freshness check |
| `log-rotate` | 03:15 daily | Log rotation (crontab direct, not in tasks.json) |
| `cost-monitor` | Sun 09:00 | API cost tracking |
| `skill-eval` | Sun 04:30 | Auto-evaluate Claude Code skill quality |
| `schedule-coherence` | Mon 04:00 | Crontab ↔ tasks.json 정합성 검증 |
| `connections-weekly-insight` | Mon 09:45 | Cross-team connection pattern analysis |
| `recon-weekly` | Mon 09:00 | Intelligence reconnaissance |
| `oss-recon` | Mon 10:30 | OSS landscape monitoring |
| `oss-docs` | Wed 11:00 | OSS documentation update |
| `oss-promo` | Fri 17:00 | OSS promotion activity |

### Background (high-frequency)

| Task | Schedule | Description |
|------|----------|-------------|
| `rate-limit-check` | */30 | Rate limit monitoring |
| `update-usage-cache` | */30 | /usage command cache |
| `session-sync` | */15 | Context bus sync |
| `stale-task-watcher` | */30 | Stale FSM task detection + cleanup |
| `cron-auditor` | 05:30 daily | Crontab vs tasks.json 실행 감사 |
| `disk-alert` | hourly :10 | Disk threshold check |
| `github-monitor` | hourly | GitHub notification check (timeout=720s) |
| `system-health` | */30 | Disk/CPU/memory/process check (`skipDuringRagRebuild: true` — RAG 재인덱싱 중 자동 스킵) |

### Board HR Scripts (비동기 트리거)

| Script | Trigger | Description |
|--------|---------|-------------|

**관련 파일**
- `config/agent_tiers.json` — 티어 오버라이드 (기본: exec/team-lead/staff 하드코딩)
- `logs/peer-vote.log` — 동료 투표 수집 로그
- `logs/perf-review.log` — 성과 평가 실행 로그
- API: `POST /api/posts/:id/peer-votes`, `GET /api/agents/scores?window=30`, `POST /api/agents/tier-history`

### Event-triggered (no cron schedule)

| Task | Trigger | Description |
|------|---------|-------------|
| `auto-diagnose` | `task.failed` | Automatic failure diagnosis |
| `github-pr-handler` | `github.pr_opened` | PR opened → review + notify |
| `discord-mention-handler` | `discord.mention` | Mention → route to handler |
| `cost-alert-handler` | `system.cost_alert` | Cost threshold → alert |

---

## LaunchAgents

Managed by `launchd` on macOS. Guardian cron (*/3 min) auto-recovers unloaded agents.

| Agent | Type | Description |
|-------|------|-------------|
| `ai.jarvis.discord-bot` | KeepAlive | Discord bot process |
| `ai.jarvis.watchdog` | 180s interval | Bot health + stale process cleanup |
| `ai.jarvis.board` | KeepAlive | Dashboard Next.js server (port 3100) |
| `ai.jarvis.serena-mcp` | KeepAlive | Serena LSP 심볼 서버 SSE (port 24285) |
| `ai.jarvis.glances` | KeepAlive | System monitor (port 61208) |

Plist files: `~/Library/LaunchAgents/ai.jarvis.*.plist`

### Jarvis Board 환경 설정 (재구성 시 필수)

`~/jarvis-dashboard/.env.local` — git에 포함되지 않으므로 수동 생성 필요:

```bash
# plist 값 확인
grep -A2 VIEWER_PASSWORD ~/Library/LaunchAgents/ai.jarvis.board.plist

# .env.local 생성
cat > ~/jarvis-dashboard/.env.local <<'EOF'
VIEWER_PASSWORD=<위에서 확인한 값>
EOF
```

> ⚠️ `.env.local` 없이 배포하면 비밀번호 인증이 항상 실패함.

### Workgroup Board → RAG Pipeline

```
  └─ 외부 에이전트 이벤트 → $VAULT_DIR/02-daily/board/YYYY-MM-DD.md
       └─ rag-watch.mjs 자동 감지 → LanceDB 인덱싱
            ├─ council-insight (23:05): "외부 에이전트 동향" 섹션에 참조
            └─ morning-standup / RAG 검색 시 자동 활용
```


---

## Monitoring Stack

### Nexus MCP Tools — Performance Notes

- **`nexus_stats`**: reads only the last 200 KB of `logs/nexus-telemetry.jsonl`. File size has no impact on response time.
- **`health` — Anthropic API check**: HTTP status is classified rather than raw-printed: `✅ OK (2xx)` / `⚠️ Rate Limited (429)` / `⚠️ Client Error (4xx)` / `❌ Server Error (5xx)` / `❌ Unreachable`.

### Glances Web Dashboard
- URL: `http://localhost:61208`
- API: `http://localhost:61208/api/4/cpu`
- Mobile: accessible via LAN IP on Galaxy browser

### Uptime Kuma
- URL: `http://YOUR_LAN_IP:3001`
- Docker container (restart=always)
- Monitors: Gateway, Glances, n8n
- Alerts: Discord webhook

### ntfy Push Notifications
- Topic: `YOUR_NTFY_TOPIC`
- Script: `scripts/alert.sh` (Discord + ntfy dual delivery)
- Config: `config/monitoring.json`

---

## Self-Healing Layers

| Layer | Component | Frequency | What it does |
|-------|-----------|-----------|-------------|
| 0 | `bot-preflight.sh` | Every cold start | Validates env, triggers AI auto-recovery |
| 1 | `launchd` | Continuous | KeepAlive unconditional restart |
| 2 | `bot-watchdog.sh` | */5 cron | Log freshness, crash loop detection |
| 3 | `launchd-guardian.sh` | */3 cron | Re-registers unloaded agents |
| Gate | `deploy-with-smoke.sh` | On deploy | 47-item smoke test |

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed flow diagrams.

---

## Log Locations

| Log | Path | Retention |
|-----|------|-----------|
| Cron execution | `logs/cron.log` | Rotated daily |
| Task runner (JSONL) | `logs/task-runner.jsonl` | 30 days |
| Discord bot | `logs/discord-bot.jsonl` | Rotated |
| Watchdog | `logs/watchdog.log` | 7 days |
| RAG indexer | `logs/rag-index.log` | 7 days |
| LaunchAgent guardian | `logs/launchd-guardian.log` | 7 days |
| E2E tests | `logs/e2e-cron.log` | 30 days |
| System overview gen | `logs/gen-system-overview.log` | 7 days |
| Doc sync audit drafts | `rag/teams/reports/doc-draft-*.md` | 14 days |

> **⚠️ cron.log JSON 오염 주의**: `task-store.mjs` 호출 시 `>/dev/null 2>&1` 없이 `2>/dev/null`만 쓰면 `{"ok":true,...}` JSON이 stdout으로 cron.log에 혼입됩니다. FSM 헬퍼(`_fsm_ensure`, `_fsm_transition`)와 event_trigger 스크립트(auto-diagnose.sh 등)는 반드시 `>/dev/null 2>&1 || true` 패턴을 사용해야 합니다. (2026-04-11 구현 P)
>
> **⚠️ best-effort 스크립트는 `set -e` 사용 금지**: context-bus 갱신(`session-sync.sh`)처럼 실패해도 서비스에 영향 없는 스크립트에 `set -e`를 적용하면 예측 불가 조건에서 Circuit Breaker가 누적되어 Discord 알림 노이즈로 이어집니다. 이런 스크립트는 `set -uo pipefail`만 사용하고 개별 실패는 `|| true`로 처리하세요. (2026-04-11 구현 Q)

---

## Incident Response

### Automatic

1. **Bot crash** → launchd restarts (Layer 1) → watchdog detects (Layer 2) → ntfy alert if crash loop
2. **LaunchAgent unloaded** → guardian re-registers (Layer 3)
3. **Preflight failure** → AI auto-recovery via `bot-heal.sh` (max 3 attempts, exponential backoff)
4. **Task failure** → `auto-diagnose.sh` event trigger → Discord `#jarvis-system` channel
   - `bot-cron.sh` 태스크 실패/FSM 요약 알림도 `webhooks["jarvis-system"]` 우선 전송 (`jarvis-system` 미설정 시 `jarvis` fallback)
5. **Claude AUTH_ERROR** → `bot-cron.sh`가 CB 3회 대기 없이 즉시 ntfy urgent 발송 (30분 쿨다운)
   - 감지 패턴: `"is_error":true` + `"duration_api_ms":0` 또는 `"Not logged in"` 문자열
   - 쿨다운 파일: `state/auth-alerted-expired.ts`
   - `pre-cron-auth-check.sh` (30분 주기)도 병행 — 만료 4시간 전 headless 자동 갱신 시도

### Manual Escalation

```bash
# Check system status
bash ~/.jarvis/scripts/e2e-test.sh

# Force restart bot
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot

# View recent failures
grep 'FAILED\|ABORTED' ~/.jarvis/logs/cron.log | tail -20

# Kill stale claude processes
pkill -f 'claude.*-p'
```

---

## Human-in-the-Loop 승인/반려 (Board Approval)

에이전트가 `decision` / `inquiry` 타입 게시글을 올리면 owner이 Board에서 승인(👍) / 반려(👎)를 결정한다.

### 흐름

```
owner 클릭 → posts.owner_reaction = 'approved'|'rejected' (Board DB)
                      │
에이전트 크론 실행 시 ask-claude.sh
  └─ board_get_pending_reactions "${TASK_AUTHOR}"
       └─ GET https://${BOARD_URL}/api/posts
              ?agent_pending=true&author={name}   (x-agent-key 인증)
  └─ 반응 있으면 SYSTEM_PROMPT 끝에 ## owner 승인/반려 알림 섹션 주입
  └─ 에이전트 실행 완료 후 PATCH /api/posts/{id} { owner_reaction_processed: true }
```

### 관련 파일

| 파일 | 역할 |
|------|------|
| `bin/ask-claude.sh` | 크론 실행 전 pending 조회 → 프롬프트 주입, 실행 후 processed 마킹 |
| `bin/jarvis-cron.sh` | `TASK_AUTHOR` export (tasks.json `author` → `id` 폴백) |

### 수동 확인

```bash
# 전체 에이전트 미처리 반응 조회

# 특정 에이전트 확인
board_get_pending_reactions "council"
```

### 환경 변수 필수

- `AGENT_API_KEY` — Board API 인증 (`.env` 또는 환경에 설정)
- `BOARD_URL` — 기본값: `https://${BOARD_URL}`

> `BOARD_URL` + `AGENT_API_KEY` + `TASK_ID`가 모두 설정되면 `retry-wrapper.sh`가 실행 중 Board에 실시간 로그를 전송한다. `.env` 파일에 두 변수가 있으면 자동 로드됨.

### 실시간 스트리밍 (stream-to-board.sh)

- `retry-wrapper.sh`가 `DEV_TASK_ID=$TASK_ID`를 환경변수로 전달
- `llm-gateway.sh`가 이를 감지하면 `--output-format stream-json` 모드로 실행
- `stream-to-board.sh`가 claude의 도구 호출(Read, Edit, Bash 등)을 실시간 파싱하여 Board에 `PATCH log_entry`로 전송
- 3초 스로틀 (API 부하 방지), 도구별 이모지 아이콘 포함 (📖 Read, ✏️ Edit, 💻 Bash, 🔍 Grep)
- 완료 메시지(`✅ 완료`)는 스로틀 우회 — 마지막 상태가 반드시 전달되도록 보장
- `DEV_TASK_ID` 미설정 시 기존 `--output-format json` 모드로 폴백 (cron 태스크 등)


- 60초마다 Board `system-metrics`에 heartbeat 전송 (대시보드 데몬 상태 표시)
- 멈춘 태스크(running >10분) 자동 재큐잉, Board API 3회 연속 실패 시 Discord 경고

### 태스크 활성/비활성 제어

`config/tasks.json`의 두 가지 필드로 태스크 실행을 제어할 수 있다:

| 필드 | 기본값 | 동작 |
|------|--------|------|
| `"disabled": true` | false | `bot-cron.sh`가 `SKIPPED (disabled)` 로그 후 즉시 종료 |
| `"enabled": false` | true | `bot-cron.sh`가 `SKIPPED (enabled: false)` 로그 후 즉시 종료 |

두 필드 모두 `_TASK_DONE=true`로 설정 후 `exit 0` — 재시도 없이 조용히 스킵됨.


### 재시도 정책 (retry-wrapper.sh)

- **기본 재시도 횟수**: 3회 (지수 백오프)
- **태스크별 재시도 횟수 설정**: `config/tasks.json`의 `retry.max` 또는 `maxRetries` 필드로 지정 — `bot-cron.sh`가 읽어서 `retry-wrapper.sh`에 8번째 인수(`MAX_RETRIES`)로 전달
- **실행 로그 개선**: 시작 시 Board API에서 태스크 제목을 가져와 "⚙️ 작업 시작 — {제목}" 로그 전송. heartbeat(30초 간격)에 경과 시간 포함 ("⏳ 진행 중 (120s 경과)")
- **non-retryable exit code**: 2 (명시적 실패), 124 (timeout), 127 (command not found)
- **retryable exit code**: 1, 137(OOM kill), 143(SIGTERM), 기타

### crontab 환경 PATH 주의사항

macOS crontab은 기본 PATH가 `/usr/bin:/bin`으로 매우 제한적이다.
`bot-cron.sh`는 9번째 줄에서 `/opt/homebrew/bin:/usr/local/bin` 등을 수동으로 추가하지만,
`/sbin`은 포함되지 않는다.

**알려진 이슈 (2026-03-22 수정)**: `bot-cron.sh`의 프롬프트 변경 감지(regression) 로직에서
`md5` 명령 호출 시 crontab 환경에서 `command not found`(exit 127) 발생 → `set -euo pipefail`에
의해 스크립트 즉시 ABORTED. `shasum`(모든 macOS에 기본 탑재)으로 대체 수정됨.

```bash
# 수정 전 (문제)
_cur_md5=$(printf '%s' "$PROMPT" | md5 2>/dev/null || printf '%s' "$PROMPT" | shasum | awk '{print $1}')

# 수정 후 (안전)
_cur_md5=$(printf '%s' "$PROMPT" | shasum 2>/dev/null | awk '{print $1}' || true)
```

> 향후 외부 명령 추가 시 `which <명령어>` 또는 `command -v <명령어>`로 존재 여부 확인 후 fallback 구현 필수.

```json
// tasks.json 예시
{ "id": "my-task", "retry": { "max": 5 } }
```

---

## Deployment

```bash
# Standard deploy (smoke test → restart)
bash ~/.jarvis/scripts/deploy-with-smoke.sh

# Manual restart
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot
```

---

## Development Backlog

현재 개발 대기 중인 항목들 (이사회 승인 후 구현 예정). 자세한 내용은 `docs/fsm-guide.md` 섹션 10 참고.

### High Priority (이번 주 예정)

| Task | Title | Status | Blocker | ETA |
|------|-------|--------|---------|-----|
| `dashboard-null-handling` | sysMetrics null 처리 (버그 수정) | in-development | — | 2026-04-02 |
| `dashboard-aggregation-api` | 백엔드 aggregation API 구현 | in-development | null-handling | 2026-04-05 |

### Medium Priority (aggregation API 완료 후)

| Task | Title | Status | Phase | ETA |
|------|-------|--------|-------|-----|
| `dashboard-progress-bar` | 그룹 태스크 진행률 바 | backlog | post-aggregation | 2026-04-07 |
| `dashboard-archive` | 완료 태스크 아카이브 기능 | backlog | polish-sprint | 2026-04-10 |

### Low Priority (오픈소스 공개 전 polish sprint)

| Task | Title | Status | Phase | Notes |
|------|-------|--------|-------|-------|
| `dashboard-empty-state` | 빈 상태 UI 추가 | backlog | polish-sprint | UX 개선, 낮은 개발 비용 |

### 백로그 파일 위치

- **중앙 저장소**: `~/.jarvis/config/dev-backlog.json`
- **상태 조회**: `cat ~/.jarvis/config/dev-backlog.json | jq '.backlog[] | {id, title, status}'`
- **차단 요인 확인**: `cat ~/.jarvis/config/dev-backlog.json | jq '.blocked_by'`

### 배포 전략

- **배포 1**: null 처리 + aggregation API (같은 스프린트) — 데이터 레이어 통합
- **배포 2**: 진행률 바 + 차트 기초 — aggregation API 완성 후
- **배포 3**: 아카이브 + 빈 상태 UI — polish sprint (공개 준비 단계)

> **근거** (ADR-012): 일괄 배포로 리그레션 위험 1회로 감소, 코어 기능부터 순차 배포

---

## Token Ledger (Tier 0 — 토큰 지출 SSoT)

모든 LLM 크론 호출의 지출 원장. `bin/ask-claude.sh`가 성공 종료 직후 한 줄을 append한다.
이 원장 위에 글로벌 일일 캡, 80% 예산 경고, 결과 해시 dedup, 영구 실패 auto-disable 등이 구축된다.

### 위치

- **파일**: `~/.jarvis/state/token-ledger.jsonl` (append-only, 라인당 JSON 1개)
- **Writer**: `bin/ask-claude.sh` (line ~253 직후, log_jsonl/record_outcome 블록 뒤)
- **Rotation**: 없음 (SSoT 보존). 필요 시 월 단위 아카이브 별도 스크립트.

### 스키마

각 라인:

```json
{
  "ts": "2026-04-14T09:10:23Z",
  "task": "github-monitor",
  "model": "claude-haiku-4-5-20251001",
  "status": "success",
  "input": 512,
  "output": 1024,
  "cost_usd": 0.0156,
  "duration_ms": 3400,
  "result_bytes": 691,
  "result_hash": "a6a7c9c06246e461",
  "max_budget_usd": 0.50
}
```

| 필드 | 출처 | 설명 |
|------|------|------|
| `ts` | `date -u +%FT%TZ` | UTC ISO8601 |
| `task` | `$TASK_ID` | tasks.json id |
| `model` | `$MODEL` | 없으면 `default` |
| `status` | 고정 `success` (v1) | v2에서 `error_*` 경로도 추가 예정 |
| `input` / `output` | `jq '.usage.*'` | claude CLI 응답에서 추출 |
| `cost_usd` | `jq '.cost_usd'` | 이미 COST_USD로 추출된 값 |
| `duration_ms` | `DURATION * 1000` | 실행 시간 |
| `result_bytes` | `wc -c $RESULT_FILE` | 결과 파일 바이트 |
| `result_hash` | `shasum -a 256` 첫 16자 | dedup/waste 감지용 |
| `max_budget_usd` | `$MAX_BUDGET` | 경고 임계값 계산용 |

### 쿼리 예시

```bash
# 오늘 총 지출
jq -s 'map(select(.ts | startswith("'"$(date -u +%Y-%m-%d)"'"))) | map(.cost_usd) | add' \
  ~/.jarvis/state/token-ledger.jsonl

# 태스크별 24h 집계
jq -s 'map(select(.ts > (now - 86400 | strftime("%Y-%m-%dT%H:%M:%SZ")))) \
  | group_by(.task) \
  | map({task: .[0].task, runs: length, cost: (map(.cost_usd) | add), unique_hashes: ([.[].result_hash] | unique | length)}) \
  | sort_by(-.cost)' \
  ~/.jarvis/state/token-ledger.jsonl

# 결과 해시 중복 탐지 (같은 해시가 N번 이상 나오면 dedup 후보)
jq -s 'group_by(.result_hash) | map(select(length >= 3)) | map({hash: .[0].result_hash, task: .[0].task, count: length})' \
  ~/.jarvis/state/token-ledger.jsonl
```

### 실패 모드

- `|| true` 로 감싸져 있어 ledger 쓰기 실패가 태스크 실행을 차단하지 않는다
- jq 미설치 시 (이미 ask-claude.sh 의존성) 빈 라인도 쓰지 않는다

### 다음 단계 (Tier 1~4)

원장이 쌓이면 아래 레이어가 순차 위에 붙는다:

1. **Tier 1**: 글로벌 일일 캡 — 태스크 시작 전 ledger 오늘 합계 읽음, 임계 초과 시 non-critical skip
2. **Tier 2**: 해시 dedup — `result_hash`가 최근 N시간 내 동일하면 LLM 호출 skip
3. **Tier 3**: 영구 실패 auto-disable — 같은 error type 3회 연속 시 tasks.json `enabled: false`
4. **Tier 4**: 80% 예산 경고 — `cost_usd > 0.8 × max_budget_usd` 시 Discord 경고
