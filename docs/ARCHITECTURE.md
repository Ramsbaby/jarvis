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
| `exec(cmd, max_lines)` | Run command, return compressed output |
| `scan(items[])` | Parallel multi-command, single response |
| `cache_exec(cmd, ttl)` | Cached execution (default 30s TTL) |
| `log_tail(name, lines)` | Named log access by shorthand |
| `health()` | Single-call system health summary |
| `file_peek(path, pattern)` | Pattern-aware partial file read |

JSON → key extraction · Logs → dedup + tail · Process tables → column filter

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
knowledge-synthesizer.mjs  ──► addTask()        (new tasks from AI synthesis)
extras-gateway.mjs          ──► listTasks()      (MCP tool: dev_queue)
dev-runner.sh               ──► node task-store.mjs [pick|field|transition|count-queued]
```

### Design Decisions (ADR-011)

- **LangGraph rejected**: LLM branching tool, not a state machine. 수십 MB 의존성 대비 효용 없음
- **XState rejected**: `@xstate/fsm` deprecated in v5, unnecessary abstraction for 6-state FSM
- **better-sqlite3 rejected**: native addon requiring node-gyp; breaks on Node version upgrades
- **node:sqlite chosen**: built-in since v22.5, identical sync API (`.prepare().get()/.run()`)
