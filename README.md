<p align="center">
  <img src="https://img.shields.io/badge/cost-$0%2Fmonth-brightgreen?style=flat-square" alt="$0/month">
  <img src="https://img.shields.io/badge/E2E_tests-50%2F50-brightgreen?style=flat-square" alt="Tests">
  <img src="https://img.shields.io/badge/context_compression-98%25-blueviolet?style=flat-square" alt="98% compression">
  <img src="https://img.shields.io/badge/session_length-3%2B_hours-blue?style=flat-square" alt="3+ hours">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License">
</p>

<h1 align="center">Jarvis — AI Company-in-a-Box</h1>

<p align="center">
  <strong>Your Claude Max subscription is idle 23 hours a day.<br>This turns it into a 24/7 AI operations system — 8 AI teams, cron orchestration, knowledge management — at $0 extra cost.</strong>
</p>

<p align="center">
  <a href="README.ko.md">한국어</a> · <a href="ROADMAP.md">Roadmap</a> · <a href="discord/SETUP.md">Setup Guide</a>
</p>

---

<p align="center">
  <img src="docs/demo.gif" alt="Demo: Discord conversation with streaming response and tool indicators" width="700">
  <br>
  <sub>Real-time streaming · tool-use indicators · session continuity across threads</sub>
</p>

> **No demo.gif yet?** Record one with [Kap](https://getkap.co) (macOS) or [Peek](https://github.com/phw/peek) (Linux):
> Show a Discord message → bot thinking reaction → streamed response → ✅ done + cost embed.

---

## TL;DR

| | |
|---|---|
| **What** | Self-hosted Discord bot backed by `claude -p` (Claude Code's headless CLI) |
| **Who** | Claude Max subscribers who want $0 extra AI costs |
| **How** | Spawns `claude -p` per message, streams output to Discord in real-time |
| **Why** | 30 scheduled cron tasks + 8 AI teams + reactive chat, with 3+ hour sessions |

```
You type in Discord  →  claude -p answers  →  streamed reply in your thread
Cron fires at 08:05  →  claude -p writes standup  →  posted to #bot-daily
All while you sleep. No API bills. No context limits.
```

---

## The Numbers

<table>
<tr>
<td align="center" width="33%">

### $0 / month
*extra cost*

Claude Max subscription you already pay for. `claude -p` is included — no API keys, no metered billing.

</td>
<td align="center" width="33%">

### Up to 98% compression
*context reduction*

Nexus CIG intercepts every tool call output before it hits Claude's context window. In documented heavy-output cases (e.g. large JSON payloads), compression reaches 315 KB → 5.4 KB (98%). Typical savings vary by output type.

</td>
<td align="center" width="33%">

### 3+ hours
*session length*

Without compression, context fills in ~30 min on heavy-output tasks. With Nexus CIG active on tool-heavy workloads, multi-turn threads sustain for several hours before context pressure builds.

At 80k tokens, auto-compact triggers: the session is summarized into a 5-section structured digest by a haiku sub-agent, then continues fresh with full context preserved.

</td>
</tr>
</table>

---

## What It Does While You Sleep

Most bots are **reactive** — they wait for you to type. This one is **proactive**:

```
 YOU          BOT
 ────────────────────────────────────────────────────────────
 03:00  zzz   → Server maintenance scan        #bot-system
 04:45  zzz   → Code Auditor scans all scripts  internal
 07:50  zzz   → Trend team: morning briefing    #bot-daily
 08:00  zzz   → Council reviews all teams       #bot-ceo
 08:05  zzz   → Smart Standup (waits for you)   #bot-daily
 09:00  ☕    ← You wake up: standup fires now
 09:15        → Event trigger: TQQQ alert       #bot-market + 📱
 10:00        ↔ Real-time Discord chat (you type, it answers)
 12:00  🍜    → System health check             logs
 15:30        → Event trigger: disk 85%         → L3 approval button
 18:00        ← You stop chatting
 20:00  zzz   → Record team: daily archive      internal
 00:30  zzz   → Log rotation + backup cleanup
 01:00  zzz   → RAG index + Vault sync (hourly)
 ────────────────────────────────────────────────────────────
              30 cron tasks + 8 AI teams. Zero manual intervention.
```

Every task has **exponential backoff retry** (3 attempts), **rate-limit awareness** (shared 5-hour sliding window), and **failure alerts** pushed to your phone via [ntfy](https://ntfy.sh).

---

## vs. the Alternatives

### Monthly Cost

| | **This bot** | **Clawdbot** (60K ⭐) | **Typical API bot** |
|---|---|---|---|
| AI cost | **$0 extra** | ~$36+/mo | $5 – $50+/mo |
| Requires | Claude Max subscription | Anthropic API key | API key + billing |
| Model quality | Opus / Sonnet (full) | Claude (via API) | Varies |

### Features

| | **This bot** | API-based bots | Clawdbot |
|---|---|---|---|
| Behavior model | **Proactive** (30 cron + 8 teams) | Reactive only | Reactive only |
| Context management | **Nexus CIG** (98% compression) | None / basic | Basic |
| RAG / memory | LanceDB (vector + BM25 hybrid) | Rarely | Plugin-dependent |
| Self-healing | 4-layer watchdog + AI auto-recovery | Manual restart | Varies |
| AI team agents | 7 specialized teams | None | None |
| KPI + auto-tuning | Anomaly detection + L3 approval | None | None |
| Human approval gate | Discord button workflow | None | None |
| Session continuity | `--resume` multi-turn threads | Per-message | Varies |
| E2E test suite | **50/50** automated checks | Rare | Partial |
| Messenger support | Discord | Discord | 25+ platforms |

---

## Quick Start

### Prerequisites

- **Node.js ≥ 20** — `node -v`
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **Claude Max subscription** — required for `claude -p` headless mode
- **Discord bot token** — [Discord Developer Portal](https://discord.com/developers/applications)
- **OpenAI API key** — for RAG embeddings (`text-embedding-3-small`, cheap)

### Option A: Docker

```bash
git clone https://github.com/YOUR_USERNAME/jarvis ~/.jarvis
cd ~/.jarvis
cp discord/.env.example discord/.env
# → edit discord/.env with your tokens
docker compose up -d
```

**Done.** Check logs with `docker compose logs -f`.

### Option B: Local (macOS / Linux)

```bash
# 1. Clone
git clone https://github.com/YOUR_USERNAME/jarvis ~/.jarvis
cd ~/.jarvis

# 2. Install
./install.sh --local

# 3. Configure
# edit discord/.env  (copy from discord/.env.example)
# edit discord/personas.json  (optional: per-channel system prompts)

# 4. Run
node discord/discord-bot.js
```

For persistent 24/7 operation on macOS, register as a LaunchAgent:

```bash
launchctl load ~/Library/LaunchAgents/ai.discord-bot.plist
```

See [discord/SETUP.md](discord/SETUP.md) for the full step-by-step setup.

---

## Configuration

### `discord/.env` (required)

```env
BOT_NAME=MyBot                       # Name shown in Discord messages
BOT_LOCALE=ko                        # Bot language: 'ko' (default) or 'en'
DISCORD_TOKEN=your_bot_token
GUILD_ID=your_server_id
CHANNEL_IDS=channel_id_1,channel_id_2
OWNER_NAME=YourName
OPENAI_API_KEY=your_key              # for RAG embeddings
NTFY_TOPIC=your_ntfy_topic          # optional: push notifications
```

### `discord/personas.json` (optional)

Per-channel personality. Each key is a Discord channel ID:

```json
{
  "123456789": "You are a senior developer. Be concise and technical.",
  "987654321": "You are a creative writing assistant with a witty tone."
}
```

### `config/tasks.json` (for cron automation)

```json
{
  "id": "morning-standup",
  "name": "Morning Standup",
  "schedule": "5 8 * * *",
  "prompt": "Summarize today's top priorities...",
  "output": ["discord"],
  "discordChannel": "bot-daily",
  "retry": { "max": 3, "backoff": "exponential" }
}
```

Copy from `config/tasks.json.example` to get started with 3 example tasks (morning-standup, daily-summary, system-health), then extend with your own.

---

## Architecture

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

### Nexus CIG — Context Intelligence Gateway

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

## Slash Commands

| Command | What it does |
|---------|-------------|
| `/search <query>` | Semantic search across RAG knowledge base |
| `/status` | System health + rate limit overview |
| `/tasks` | List configured cron tasks |
| `/run <task_id>` | Manually trigger a cron task |
| `/schedule <task_id> <delay>` | Schedule a task to run after a specified delay |
| `/threads` | List recent conversation threads |
| `/alert <message>` | Send alert → Discord + ntfy push |
| `/memory` | View current session memory |
| `/remember <text>` | Store a persistent memory entry |
| `/usage` | Token usage + rate limit stats |
| `/clear` | Clear session context |
| `/stop` | Cancel active `claude -p` subprocess |

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
  └─ Success → exec node (process replacement — launchd tracks node PID directly)

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
│  Daily 08:00 KST · Sub-agents: kpi-analyst, log-analyst    │
│  Reviews all team outputs, detects cross-team issues        │
├─────────┬──────────┬──────────┬──────────┬──────────────────┤
│  Infra  │  Trend   │  Record  │  Brand   │  Career/Academy  │
│  Daily  │  Daily   │  Daily   │  Weekly  │  Weekly          │
│  09:00  │  07:50   │  08:50   │  Tue     │  Fri/Sun         │
└─────────┴──────────┴──────────┴──────────┴──────────────────┘
```

| Team | Role | Output |
|------|------|--------|
| **Council** | Executive oversight with sub-agents | Cross-team analysis, KPI review |
| **Infra** | System health, service status | Infrastructure daily report |
| **Trend** | News, tech trends, market signals | Morning briefing |
| **Record** | Daily activity logging | Internal archive |
| **Brand** | Content strategy, blog ideas | Weekly brand report |
| **Career** | Learning goals, skill tracking | Weekly growth report |
| **Academy** | Study material curation | Weekly learning digest |

Reports are saved to `rag/teams/reports/` (indexed by RAG) and mirrored to an Obsidian Vault.

### Board Meeting → Decision Dispatcher

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

Any bash script can request approval by writing a JSON file to `state/l3-requests/`:

```json
{
  "label": "Clean old logs",
  "description": "Remove logs older than 30 days",
  "script": "cleanup-logs.sh"
}
```

---

## Proactive Automation

### Event Trigger System

Condition-based triggers that fire independently of cron schedules (`scripts/event-trigger.sh`, every 3 min):

| Trigger | Condition | Cooldown | Action |
|---------|-----------|----------|--------|
| TQQQ price | Market hours + threshold crossed | 4 hours | Discord alert |
| Disk usage | > 85% | 24 hours | L3 approval → cleanup |
| Claude load | 3+ concurrent `claude -p` | 30 min | Discord warning |

Each trigger has independent cooldown tracking via `state/triggers/`.

### Smart Standup

Owner-aware morning briefing (`scripts/smart-standup.sh`):

```
08:05  →  Check if owner is online (Discord activity detection)
           ├─ Online  → Run standup immediately
           └─ Offline → Retry at 08:35, 09:05, 09:35 (max 4 attempts)
```

Prevents posting a standup briefing when nobody is awake to read it. Deduplication via daily state file.

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

Tier 1 issues (e.g. deprecated API usage) are auto-fixed via `sed`. Tier 2 issues are escalated as L3 approval requests.

### Vault Sync

Bi-directional sync between bot data and an Obsidian Vault (`scripts/vault-sync.sh`, every 6 hours):

```
~/.jarvis/rag/teams/reports/*.md  ──►  ~/Jarvis-Vault/03-teams/{team}/
~/.jarvis/docs/*.md               ──►  ~/Jarvis-Vault/06-knowledge/
```

Each team folder retains the 7 most recent reports. Enables browsing AI-generated reports in Obsidian with full graph and backlink support.

---

## LanceDB Hybrid RAG

The bot remembers everything. Every conversation turn, cron result, and context file is indexed into a local LanceDB database:

- **Vector search** — OpenAI `text-embedding-3-small` (1536 dims)
- **Full-text search** — BM25 keyword matching
- **Reranking** — Reciprocal Rank Fusion (RRF) merges both signals

The RAG engine runs an incremental index hourly. When you ask a question, relevant context is injected into the `claude -p` prompt automatically — without consuming extra context window space.

---

## File Structure

```
~/.jarvis/
├── discord/
│   ├── discord-bot.js          # Discord client, slash commands, L3 polling
│   ├── locales/
│   │   ├── en.json             # English locale strings
│   │   └── ko.json             # Korean locale strings (default)
│   └── lib/
│       ├── i18n.js             # t() — locale loader (BOT_LOCALE)
│       ├── handlers.js         # handleMessage — core message logic
│       ├── claude-runner.js    # createClaudeSession() via Agent SDK
│       ├── format-pipeline.js  # formatForDiscord() — 8 output transforms
│       ├── session.js          # SessionStore, RateTracker, Semaphore
│       ├── user-memory.js      # Per-user persistent memory (/remember)
│       ├── company-agent.mjs   # 7-team virtual organization engine
│       ├── orchestrator.mjs    # SQLite message queue + channel routing
│       ├── lounge.js           # Lounge channel logic
│       ├── error-tracker.js    # Error tracker
│       ├── alert-batcher.js    # Alert batch processor
│       ├── commands.js         # Slash command registration
│       └── approval.js         # L3 approval workflow (Discord buttons)
├── bin/
│   ├── ask-claude.sh           # claude -p wrapper (RAG + token isolation)
│   ├── bot-cron.sh             # Cron task runner (semaphore, retry, routing)
│   ├── jarvis-cron.sh          # → bot-cron.sh symlink (backward compat)
│   ├── board-meeting.sh        # Board Meeting CEO agent (daily 08:10, 21:55)
│   ├── decision-dispatcher.sh  # Auto-execute decisions + team scoring
│   ├── bot-preflight.sh        # Pre-start validation + AI auto-recovery trigger
│   ├── bot-heal.sh             # AI auto-recovery (runs in tmux PTY, calls claude -p)
│   ├── bot-watchdog.sh         # Discord bot process monitor
│   ├── deploy-with-smoke.sh    # 47-item smoke test deploy gate
│   ├── jarvis-init.sh          # Fresh install initializer
│   ├── kill-team.sh            # Batch terminate team agents
│   ├── lounge-announce.sh      # Lounge channel announcements
│   ├── plugin-loader.sh        # Plugin loader (file-convention)
│   ├── rag-index.mjs           # Incremental RAG indexer
│   ├── retry-wrapper.sh        # Cron retry wrapper
│   ├── route-result.sh         # Result routing (Discord channel dispatch)
│   └── semaphore.sh            # Concurrency control semaphore
├── lib/
│   ├── rag-engine.mjs          # LanceDB hybrid search
│   ├── mcp-nexus.mjs           # Nexus CIG MCP server
│   ├── llm-gateway.sh          # LLM multi-provider gateway (ADR-006)
│   ├── log-utils.sh            # Structured logging library
│   ├── context-loader.sh       # Cron task context loader
│   ├── insight-recorder.sh     # Insight recorder
│   ├── message-queue.mjs       # SQLite message queue library
│   ├── rag-query.mjs           # RAG query CLI
│   └── rag-watch.mjs           # chokidar real-time RAG watcher
├── config/
│   ├── tasks.json.example      # 3 starter cron task definitions
│   ├── monitoring.json.example # Webhook routing config
│   └── anti-patterns.json      # Code auditor pattern rules
├── scripts/
│   ├── watchdog.sh             # Bot health monitor (Layer 2)
│   ├── launchd-guardian.sh     # LaunchAgent auto-recovery (Layer 3)
│   ├── event-trigger.sh        # Condition-based proactive triggers
│   ├── smart-standup.sh        # Owner-aware morning standup
│   ├── jarvis-auditor.sh       # Automated code quality scanner
│   ├── measure-kpi.sh          # Weekly team KPI measurement
│   ├── kpi-anomaly-detector.sh # KPI anomaly detection + L3 bridge
│   ├── apply-kpi-decisions.sh  # Auto-tuning applier (dry-run default)
│   ├── vault-sync.sh           # Obsidian Vault bi-directional sync
│   ├── e2e-test.sh             # 50-item E2E test suite
│   └── l3-actions/             # Pre-approved L3 action scripts
├── teams/                      # Declarative team definitions (YAML + templates)
│   ├── council/                # Strategy team (council-insight)
│   ├── infra/                  # Infrastructure team (infra-daily)
│   ├── career/                 # Growth team (career-weekly)
│   ├── record/                 # Record team (record-daily)
│   ├── brand/                  # Brand team (brand-weekly)
│   ├── academy/                # Academy team (academy-support)
│   ├── trend/                  # Trend team (news-briefing)
│   └── standup/                # Standup team (morning-standup)
├── plugins/                    # File-convention plugin system (ADR-007)
│   └── system-health/          # Example plugin (manifest.json + context.md + test.sh)
├── context/                    # Per-task background knowledge files
├── results/                    # Cron task output history
├── rag/teams/reports/          # Company agent team reports (RAG-indexed)
├── agents/                     # Team lead agent profiles (CEO, Infra Chief, etc.)
└── state/
    ├── sessions.json           # Active session tracking
    ├── rate-tracker.json       # 5-hour rate limit window
    ├── recovery-learnings.md   # AI auto-recovery: accumulated fix history
    ├── team-scorecard.json     # Team performance tracking (merit/penalty/status)
    ├── decisions/              # Board meeting decision audit log (JSONL)
    ├── board-minutes/          # Board meeting minutes archive
    ├── dispatch-results/       # Decision execution results + cron analysis
    ├── l3-requests/            # Bash → Discord approval bridge
    └── triggers/               # Event trigger cooldown timestamps
```

---

## Platform Notes

| Feature | macOS (native) | Linux (Docker) |
|---------|---------------|----------------|
| Process supervision | `launchd` KeepAlive | Docker `restart: always` |
| Watchdog / Guardian | cron + bash | Same (runs in container) |
| Power management | `pmset` sleep disabled | N/A |
| Apple integrations | Notes, Reminders (optional) | Not available |

---

## Contributing

```bash
# 1. Fork + clone
git clone https://github.com/YOUR_USERNAME/jarvis

# 2. Make changes

# 3. Run the test suite
bash scripts/e2e-test.sh
# → 50 passed, 0 failed

# 4. Submit a pull request
```

See [ROADMAP.md](ROADMAP.md) for planned features. Current completion: **82%**, target: **90%**.

---

## License

MIT — see [LICENSE](LICENSE)

---

<p align="center">
  <a href="README.ko.md">한국어 README →</a>
</p>
