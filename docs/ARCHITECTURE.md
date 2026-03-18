# Architecture

> Back to [docs/INDEX.md](INDEX.md) | [README](../README.md)

## Message Flow

```
Discord message (text · image · PDF attachment)
      │
      ├─ PDF → pdftotext extract → text injection
      │         (fallback: Claude Read if pdftotext empty)
      │
      ▼
discord-bot.js ──► lib/handlers.js ──► lib/claude-runner.js
                         │                      │
                         │              createClaudeSession()
                         │              @anthropic-ai/claude-agent-sdk
                         │                      │
                  StreamingMessage         async event stream
                  (live edits,                  │
                  1900-char chunks)      RAG via MCP tool call
                         │              (LanceDB hybrid search)
                         ▼
                  formatForDiscord()
                  (format-pipeline.js)
                  tables→lists, heading normalize,
                  link preview suppress, timestamps
                         │
                         ▼
                  Discord thread reply
                         │
                         ▼
              saveConversationTurn()
                         │
                         ├──► commitment-tracker.js (fire-and-forget)
                         │         detectAndRecord() — 약속 감지 패턴 매칭
                         │         → state/commitments.jsonl 기록
                         │
                         ▼
              context/discord-history/YYYY-MM-DD.md
                         │
                         ▼
              Hourly RAG indexer (rag-index.mjs)
                         │
                         ▼
      ┌──────────────────────────────────────────┐
      │          Nexus CIG (MCP Server)          │
      │  Intercepts all tool output.             │
      │  315 KB raw → 5.4 KB compressed.         │
      │  Claude sees signals, not noise.         │
      └──────────────────────────────────────────┘
```

---

## Nexus CIG — Context Intelligence Gateway

Built as a local MCP server (`lib/mcp-nexus.mjs`). Sits between Claude and every system call, classifies output type, and compresses it before it enters the context window.

| Tool | What it does |
|------|-------------|
| `exec(cmd, max_lines)` | **Last resort** — custom commands only; prefer specialized tools below |
| `scan(items[])` | Parallel multi-command, single response |
| `cache_exec(cmd, ttl)` | Cached execution (default 30s TTL) — use for ps/df/uptime/launchctl |
| `log_tail(name, lines)` | Named log access — always prefer over `exec tail` |
| `health()` | Single-call system health summary — always prefer over ad-hoc status cmds. Anthropic API reachability check classifies HTTP status: ✅ 2xx / ⚠️ 4xx (429 Rate Limited) / ❌ 5xx / ❌ Unreachable |
| `file_peek(path, pattern)` | Pattern-aware partial file read |
| `rag_search(query)` | Hybrid BM25+Vector search over Obsidian Vault |
| `discord_send(channel, msg)` | Send message to Discord channel via REST API |
| `nexus_stats(n)` | Self-diagnostic: per-tool call counts, P95 latency, timeouts. Reads only the last 200 KB of the telemetry file (O(1) I/O regardless of file size) |

JSON → key extraction · Logs → dedup + tail · Process tables → column filter

**Circuit Breaker** (`exec` + `scan`): 2 timeouts within 5 min → 10 min block, avoids cascading timeout waste. Partial stdout returned on timeout (up to 2000B).

---

## Commitment Tracking — 약속 감지 및 이행 관리

Claude 응답에서 자동으로 약속을 감지하여 `state/commitments.jsonl`에 기록하고, 이행 여부를 추적한다.

**파일**: `discord/lib/commitment-tracker.js`

```
handlers.js (Claude 응답 수신 후)
  └─ detectAndRecord(replyText, {source, channelId, userId})  [fire-and-forget]
       │
       ├─ COMMITMENT_PATTERN 매칭
       │   (하겠습니다/진행하겠습니다/처리하겠습니다 등 약속 동사)
       │   (부정문 "하지 않겠습니다" 제외 — negative lookahead)
       │
       ├─ _extractCommitmentSentence() → 약속 포함 문장 최대 120자 추출
       │
       └─ state/commitments.jsonl에 JSONL append
            { id, status:"open", text, created_at, source, channelId, userId }
```

| 함수 | 역할 |
|------|------|
| `detectAndRecord(text, ctx)` | 응답에서 약속 감지 → JSONL 기록 (중복 방지: 메시지당 1건) |
| `resolveCommitment(id)` | id 기반 done 마킹 (status: "open" → "done", resolved_at 추가) |
| `pruneResolved()` | 30일+ 경과 done 항목 정리 |

**Slash Commands** (`discord/lib/commands.js`):
- `/commitments` — 현재 open 약속 목록 출력 (SENSITIVE 권한 필요)
- `/approve <번호 또는 파일명>` — doc-draft 승인 → 자동 적용 (경로 트래버설 방지: `resolve() + startsWith(draftsDir)` 검증, SENSITIVE 권한 필요)

**commitments.jsonl 구조**:
```jsonl
{"id":"uuid","status":"open","text":"...하겠습니다","created_at":"ISO8601","source":"discord"}
{"id":"uuid","status":"done","resolved_at":"ISO8601"}
```

---

## Claude Code Hooks — Doc-Sync Enforcement

Three-layer doc-sync system ensures code changes are reflected in documentation:

```
PostToolUse (Write|Edit)
  └─ post-tool-docdebt.sh
       ├─ Code file edited → doc-map.json lookup → add to doc-debt.json
       └─ Doc file edited  → remove matching entry from doc-debt.json

Stop hook (sync, before async hooks)
  └─ stop-doc-enforce.sh
       ├─ doc-debt.json empty → exit 0 (allow stop)
       └─ debts present      → exit 2 (Claude continues, must update docs)

SessionStart (startup only)
  └─ session-context.sh
       └─ Resets doc-debt.json (cross-session debt tracked by pending-doc-updates.json)
```

**doc-debt.json** (`state/doc-debt.json`): per-session runtime file. Maps required docs to the code files that triggered them. Automatically cleared when the doc is edited.

**doc-map.json** (`config/doc-map.json`): 18 patterns mapping code paths → required docs. Shared by PreToolUse advisory, PostToolUse debt tracking, and Stop enforcement.

**Hook execution order (PostToolUse)**: `post-tool-docdebt.sh` runs **before** `post-edit-lint.sh`. This ensures debt is recorded even when lint blocks — prevents enforcement bypass via lint errors.

**Auto-generated docs excluded**: `docs/SYSTEM-OVERVIEW.md` is regenerated by `gen-system-overview.sh` — not subject to manual debt enforcement.

**Error logging**: Python write failures in `post-tool-docdebt.sh` are logged to `logs/doc-debt.log` instead of silently ignored.

**Atomic writes**: All `doc-debt.json` mutations (skeleton creation, debt add, debt clear) use `tempfile.mkstemp() + os.rename()` — crash-safe, no partial writes.

**health-gateway.mjs (2026-03-18)**: `vm_stat` (macOS-only) now behind `IS_MACOS` branch — Linux uses `free -h` instead. Prevents "command not found" noise in health output on Linux.

**extras-gateway.mjs (2026-03-18)**: `getMemory()` now passes `limit` as `sys.argv[2]` to `rag-query.mjs` — result count was previously always default regardless of caller request.

**Security hardening (2026-03-18)**:
- `session-context.sh`: Added `set -euo pipefail`; SessionStart JSON output now serialized via `python3 json.dumps()` instead of raw shell interpolation — prevents JSON injection from CONTEXT variable.
- `stop-doc-enforce.sh`: Python `-c` code no longer interpolates `$RESULT_TMP` into the code string; path passed as `sys.argv[1]` instead — eliminates injection surface.
- `tasks.json`: `skill-eval` script path changed from relative (`scripts/skill-eval.sh`) to absolute (`~/.jarvis/scripts/skill-eval.sh`) — prevents ENOENT on cron execution.

**OSS readiness hardening (2026-03-18)**:
- All personal files (boram-*.sh, relay-to-owner.sh, PERSONALIZATION-AUDIT.md, backup files) untracked from git index; `.gitignore` updated to cover them permanently.
- Personal identifiers (names, email, Discord channel IDs, LAN IP, ntfy topic) removed from all git-tracked files; replaced with env var placeholders (`FAMILY_MEMBER_NAME`, `FAMILY_CHANNEL`, `GOOGLE_ACCOUNT`, etc.).
- `NODE` hardcoding fixed in 10 scripts: `NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"` pattern applied; `commands.js` uses `process.execPath` for runtime node binary.
- `rag-compact-wrapper.sh`: rewritten to use `$BOT_HOME` and `$NODE` — was hardcoding absolute paths.
- `memory-sync.sh`: project path calculation changed from broken `sed` chain to `tr '/' '-'` for correct Claude Code project dir encoding.
- `auto-diagnose.sh`, `check-gh-auth.sh`: upgraded to `set -euo pipefail` per project standard.
- `js-yaml ^4.1.0` added to `discord/package.json` (missing declared dependency).
- `SECURITY.md` created with responsible disclosure policy.
- `discord/.env.example`: added `FAMILY_MEMBER_NAME=` placeholder.

---

## Self-Healing Infrastructure

Four independent layers. Each failure mode is caught by a different layer:

```
Layer 0: bot-preflight.sh  (every cold start)
  ├─ Validates: node binary, discord-bot.js, .env keys (4 required), JSON configs
  ├─ Failure → tmux jarvis-heal session → Claude auto-fixes files
  │   ├─ ANTHROPIC_API_KEY passed via tmux -e flag (launchd env isolation)
  │   ├─ Recovery Learnings: past fixes accumulated in state/recovery-learnings.md
  │   └─ MAX_HEAL_ATTEMPTS=3, exponential backoff 30s→90s→180s, 6h auto-decay
  └─ Success → monitoring mode (fast crash detection: 3 crashes in <10s → auto-heal)

Layer 1: launchd  (KeepAlive unconditional — restarts on SIGTERM, crash, or clean exit)
  └─ discord-bot.js auto-restarts on any exit (ThrottleInterval=10s)

Layer 2: cron */5 min  →  watchdog.sh (macOS + Linux/Docker)
  ├─ Checks log freshness (15 min silence = unhealthy)
  ├─ Crash loop detection: PID tracking, 3 restarts/30 min → ntfy alert
  ├─ Out-of-band alerts: ntfy direct HTTP (works even when Discord bot is down)
  ├─ macOS: launchctl kickstart | Linux: pm2 restart jarvis-bot
  └─ Kills stale claude -p processes

Layer 3: cron */3 min  →  launchd-guardian.sh
  ├─ Detects unloaded LaunchAgents
  └─ Re-registers them automatically

Deploy gate: deploy-with-smoke.sh
  └─ 47-item smoke test before any restart (syntax, files, functions, JSON, .env)
```

**AI Auto-Recovery flow (bot-preflight.sh → bot-heal.sh):**
```
preflight FAIL
  → tmux new-session jarvis-heal (PTY environment)
    → claude -p reads logs, edits broken files
      → "복구완료: <summary>" written
        → launchd restarts → preflight runs again
```

**Rate limiting:** shared `state/rate-tracker.json` — 900 requests per 5-hour window, split between bot and cron tasks.

---

## Company Agent Teams

A virtual organization of AI teams, each with a specialized role. Every team runs as a scheduled `claude -p` session via `@anthropic-ai/claude-agent-sdk`, produces a report, and posts it to its designated Discord channel.

```
┌─────────────────────────────────────────────────────────────┐
│                    Council (Oversight)                       │
│  Daily 23:05 KST · Sub-agents: kpi-analyst, log-analyst    │
│  Reviews all team outputs, detects cross-team issues        │
├─────────┬──────────┬──────────┬──────────┬──────────────────┤
│  Infra  │  Trend   │  Record  │  Brand   │  Career/Academy  │
│  Daily  │  Daily   │  Daily   │  Weekly  │  Weekly          │
│  09:00  │  07:50   │  22:30   │  Tue     │  Fri/Sun         │
└─────────┴──────────┴──────────┴──────────┴──────────────────┘
```

For team details see [TEAMS.md](TEAMS.md).

---

## Board Meeting → Decision Dispatcher

The CEO agent doesn't just report — it **delegates and holds teams accountable**:

```
Board Meeting (08:10, 21:55 KST)
  │
  ├─ CEO judgment → decisions/{date}.jsonl
  │
  └─ decision-dispatcher.sh (auto-runs after meeting)
       ├─ Actionable decisions → execute immediately
       │   (service restart, log cleanup, cron analysis)
       ├─ Report-only decisions → flag for human review
       │   (investment actions, architecture changes)
       └─ Update team-scorecard.json
            ├─ Success → +1 merit
            ├─ Failure → +1 penalty
            └─ Thresholds:
                 3 penalties → WARNING
                 5 penalties → PROBATION
                10 penalties → DISCIPLINARY (team lead dismissed)
```

Penalty decay: 30% reduction every Monday (no permanent marks).

Configuration: `agents/*.md`, `state/team-scorecard.json`

---

## Orchestrator — Event Bus

A SQLite-backed message queue (`messages.db`) that decouples producers from consumers:

```
Cron tasks / Event triggers / Teams
         │
         ▼
  ┌─────────────────────┐
  │   Orchestrator MQ    │
  │  SQLite + 5s poll    │
  │  Channel routing:    │
  │  alert│market│system │
  │  kpi  │general       │
  └─────────────────────┘
         │
         ▼
  Discord webhooks / KPI aggregation / Alerts
```

Two-phase processing: validate message → execute delivery. KPI metrics auto-aggregated per task.

Runs as a LaunchAgent (`ai.jarvis.orchestrator`), not cron.

---

## LanceDB Hybrid RAG

The bot remembers everything. Every conversation turn, cron result, and context file is indexed into a local LanceDB database:

- **Vector search** — Local `all-MiniLM-L6-v2` (384 dims, zero API cost)
- **Full-text search** — BM25 keyword matching
- **Reranking** — Reciprocal Rank Fusion (RRF) merges both signals
- **Upsert indexing** — `mergeInsert` for efficient incremental updates (no destructive deletes)

The RAG engine runs an incremental index hourly, plus real-time file watching via `rag-watch.mjs`. When you ask a question, relevant context is injected into the `claude -p` prompt automatically — without consuming extra context window space.

---

## Operational Intelligence

### KPI Measurement

Weekly automated performance tracking for all cron tasks and agent teams:

```
measure-kpi.sh (Mon 08:30)
  └─ Reads task-runner.jsonl (all cron execution logs)
  └─ Calculates per-team success rate, duration, cost
  └─ Outputs text + JSON report
  └─ Posts to Discord with --discord flag
```

### Anomaly Detection + Auto-Tuning

```
kpi-anomaly-detector.sh (Mon 08:35)
  └─ Calls measure-kpi.sh --json
  └─ Classifies: CRITICAL (<70%) / WARNING (<85%)
  └─ Proposes timeout increases for failing tasks
  └─ Creates L3 approval request (see below)
```

### L3 Approval Workflow

Risky autonomous actions require human approval via Discord buttons:

```
Bash script drops JSON ──► state/l3-requests/
                                    │
Discord bot polls (10s) ◄───────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  [Approve]   [Reject]   │  ← Discord button message
  └─────────────────────────┘
         │
         ▼ (on approve)
  execFileSync(scripts/l3-actions/*)
```

Pre-configured L3 actions: `cleanup-logs`, `cleanup-results`, `kill-stale-claude`, `restart-bot`, `apply-kpi-decisions`, `auditor-fix-*`

---

## Proactive Automation

### Event Trigger System

Condition-based triggers that fire independently of cron schedules (`scripts/event-trigger.sh`, every 3 min):

| Trigger | Condition | Cooldown | Action |
|---------|-----------|----------|--------|
| TQQQ price | Market hours + threshold crossed | 4 hours | Discord alert |
| Disk usage | > 85% | 24 hours | L3 approval → cleanup |
| Claude load | 3+ concurrent `claude -p` | 30 min | Discord warning |

### Smart Standup

Owner-aware morning briefing (`scripts/smart-standup.sh`):

```
08:05  →  Check if owner is online (Discord activity detection)
           ├─ Online  → Run standup immediately
           └─ Offline → Retry at 08:35, 09:05, 09:35 (max 4 attempts)
```

### Code Auditor

Automated code quality scanner (`scripts/jarvis-auditor.sh`, daily 04:45):

| Phase | What it checks |
|-------|---------------|
| ShellCheck | Static analysis of all `.sh` files, auto-fix for high-priority issues |
| Node syntax | `node --check` on all `.js`/`.mjs` files |
| Anti-patterns | Custom pattern matching via `config/anti-patterns.json` |
| LaunchAgent | Service loaded + PID verification |
| Health freshness | `state/health.json` staleness check |
| E2E results | Scan latest E2E test results for failures |

**Safety:** protected file list, 20-hour cooldown per file, max 5 auto-fixes per run, syntax verification after each fix with automatic rollback on failure.

### Vault Sync

Bi-directional sync between bot data and an Obsidian Vault (`scripts/vault-sync.sh`, every 6 hours):

```
~/.jarvis/rag/teams/reports/*.md  ──►  ~/Jarvis-Vault/03-teams/{team}/
~/.jarvis/docs/*.md               ──►  ~/Jarvis-Vault/06-knowledge/
```

Each team folder retains the 7 most recent reports. Enables browsing AI-generated reports in Obsidian with full graph and backlink support.

---

## Task FSM — Autonomous Development Queue

Self-directed task execution engine for long-running autonomous work. Replaces ad-hoc Python3 JSON manipulation with a typed state machine backed by SQLite.

### State Machine (`lib/task-fsm.mjs`)

Pure functions only — no side effects, no DB dependency. Storage is the caller's responsibility.

```
pending ──► queued ──► running ──► done
              │           │
              ▼           ▼
           skipped      failed
              │           │
              └──► pending └──► queued  (manual recovery / auto-retry)
```

| Function | Signature | Purpose |
|----------|-----------|---------|
| `canTransition(from, to)` | `(string, string) → boolean` | Guard: is this transition allowed? |
| `applyTransition(task, to)` | `(Object, string) → Object` | Returns new task object, throws on invalid transition |
| `pickNextTask(tasks[])` | `(Object[]) → Object\|null` | Selects highest-priority queued task with satisfied dependencies |

### Storage (`lib/task-store.mjs`)

`node:sqlite` (Node.js 22.5+ built-in, zero external dependencies). WAL mode for concurrent read/write safety.

```sql
tasks (id PK, status, priority, retries, depends JSON, meta JSON, updated_at)
task_transitions (task_id, from_status, to_status, triggered_by, created_at)
```

- `transition()` wraps UPDATE + INSERT in `BEGIN/COMMIT/ROLLBACK` — atomicity guaranteed (`node:sqlite` has no `.transaction()` helper)
- `addTask()` uses `INSERT OR IGNORE` — idempotent, safe to call multiple times
- Full CLI: `node task-store.mjs [list|pick|get|field|transition|count-queued|export]`

### Integration

```
insight-extractor.mjs  ──► addTask()        (new tasks from AI synthesis)
extras-gateway.mjs          ──► listTasks()      (MCP tool: dev_queue)
dev-runner.sh               ──► node task-store.mjs [pick|field|transition|count-queued]
```

### Design Decisions (ADR-011)

- **LangGraph rejected**: LLM branching tool, not a state machine. 수십 MB 의존성 대비 효용 없음
- **XState rejected**: `@xstate/fsm` deprecated in v5, unnecessary abstraction for 6-state FSM
- **better-sqlite3 rejected**: native addon requiring node-gyp; breaks on Node version upgrades
- **node:sqlite chosen**: built-in since v22.5, identical sync API (`.prepare().get()/.run()`)
