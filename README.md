# Jarvis

<p align="center">
  <strong>AI operations platform that manages itself 24/7</strong><br>
  Discord Bot + RAG Knowledge Base + Insight Layer + Self-Healing Automation
</p>

<p align="center">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">
  <img src="https://img.shields.io/badge/Node.js-18+-green.svg" alt="Node.js">
  <img src="https://img.shields.io/badge/Ollama-Required-orange.svg" alt="Ollama">
  <img src="https://img.shields.io/badge/Privacy-100%25_Local-brightgreen.svg" alt="Privacy">
</p>

<p align="center">
  <img src="docs/img/discord-dev-chat.png" alt="Discord Bot — Developer Chat" width="700">
</p>
<p align="center"><em>Discord Bot: code review with inline fixes</em></p>

<p align="center">
  <img src="docs/img/discord-system-health.png" alt="System Health Check" width="700">
</p>
<p align="center"><em>Dawn audit: 10 services checked automatically</em></p>

---

## What is Jarvis?

> **"An AI assistant that audits your systems, analyses news, and writes code — while you sleep."**

Message it on Discord and it chats. Send a voice message and it understands. Drop a file and it remembers.
Overnight, 99 automation scripts run cron jobs. If a service dies, it self-recovers within 3 minutes.
Every dawn, it analyses your behavioural patterns and responds knowing what you're focused on right now.
Zero API charges — runs on a Claude subscription. 100% of your data stays on your machine.

**In short**: A personal AI operations platform. Runs 24/7, fixes itself when it breaks, gets smarter as you use it.

### Architecture

| Layer | Components | Role |
|:---:|------|------|
| **Interface** | Discord (text + voice) | 24/7 conversational UI. 16+ slash commands, buttons, voice recognition |
| **Brain** | Claude + 8 AI agent teams | Chat, analysis, code generation, decision-making |
| **Memory** | RAG (LanceDB) + Insight Layer | 10,000+ doc search + daily behavioural metrics analysis |
| **Automation** | 99 scripts + 11 LaunchAgents + 40+ crons | Self-healing, dawn audits, news briefing, auto code execution |
| **Integration** | MCP + Google Calendar + GitHub | External service connectivity |

## Core Features

| | Feature | Description |
|---|---------|-------------|
| 💬 | **Discord Bot** | 24/7 chat with streaming, voice recognition (Whisper STT), per-channel personas, 16+ slash commands |
| 👥 | **Multi-User** | Per-user isolated memory, pairing codes for new users, family mode with privacy boundaries |
| 📚 | **RAG Knowledge Base** | Long-term memory. BM25 + vector hybrid search across 10,000+ documents |
| 🧠 | **Insight Layer** | Daily auto-generated behavioural report — detects activity trends, focus shifts, situational context |
| 📋 | **Dev-Queue** | AI-extracted action items auto-queued, then auto-executed by `jarvis-coder.sh` — hands-free development |
| 🤖 | **8 AI Teams** | Council, Infra, Record, Brand, Career, Academy, Trend, Recon — each with specialised agents |
| 🔧 | **Self-Healing** | Watchdog auto-restart, LaunchAgent guardian (3min), dawn code audits, cron failure tracking |
| 🔒 | **100% Local** | No cloud. No subscriptions. All data stays on your machine |
| 🔌 | **MCP Integration** | Home Assistant, GitHub, Slack, Notion via [MCP ecosystem](https://github.com/topics/mcp-server) |

## How Jarvis Compares

|  | **Jarvis** | **Claude Memory** | **ChatGPT Memory** | **[OpenClaw](https://docs.openclaw.ai) Dreaming** |
|---|:---:|:---:|:---:|:---:|
| **Memory** | RAG + Insight Layer (metrics-driven) | File-based (CLAUDE.md + Auto Dream) | Inject-all (every memory, every turn) | 3-phase sleep cycle (Light → REM → Deep) |
| **Trend Detection** | Yes (topic freq shifts, entity momentum) | No | No | Yes (REM-phase pattern extraction) |
| **Automation** | 99 scripts + self-healing | No (CLI tool) | No | 1 cron (dreaming sweep) |
| **Autonomous Coding** | Yes (Dev-Queue → jarvis-coder) | No | No | No |
| **Multi-User** | Yes (isolated memory + family mode) | No (single user) | No (single user) | No (single agent) |
| **Cost** | $0 (Claude subscription) | $0 (subscription) | $0 (free tier) | $0 (open source) |
| **Data Location** | 100% local | Local (CLI) / Cloud (web) | Cloud (OpenAI servers) | Local |
| **Interface** | Discord (text + voice) | Terminal / Web | Web / App | Terminal / Web |

**What sets Jarvis apart**: It doesn't just remember — it **acts**. Memory + analysis + automation + self-healing in one system. Others stop at the memory layer; Jarvis uses memory to write code, recover services, and generate reports.

## Quick Start

```bash
git clone https://github.com/Ramsbaby/jarvis.git && cd jarvis
```

### Step 1: RAG — Long-Term Memory

```bash
python scripts/setup_rag.py
```

> **Requires**: [Ollama](https://ollama.com/download), Node.js 18+

### Step 2: Discord Bot + Automation

```bash
python scripts/setup_infra.py
```

> **Requires**: Node.js 18+, Discord bot token

## Discord Bot

A 24/7 interface powered by Claude with streaming responses.

### Slash Commands

| Command | Description |
|---------|-------------|
| `/search <query>` | RAG hybrid search across knowledge base |
| `/remember <content>` | Save to long-term memory (auto-categorised: trading/work/family/travel/health) |
| `/memory` | View your stored facts, preferences, corrections |
| `/team <name>` | Summon an AI team (Council/Infra/Career/Academy/Trend/Recon...) |
| `/run <task>` | Manually trigger a cron task (with autocomplete) |
| `/schedule <task> <in>` | Schedule a task 30m/1h/2h/4h/8h from now |
| `/status` | System health dashboard (disk/memory/cron) |
| `/doctor` | Full health check + auto-fix (owner only) |
| `/approve [draft]` | Approve a draft document → auto-apply |
| `/commitments` | View unfulfilled promises Jarvis detected |
| `/usage` | API cost & usage dashboard |
| `/alert <msg>` | Send Discord + push notification (ntfy.sh) |
| `/lounge` | Live activity feed of running tasks |
| `/clear` | Reset channel conversation |
| `/stop` | Cancel running Claude task |

### Voice Recognition

Discord voice messages are automatically transcribed via **OpenAI Whisper** (Korean + multilingual). The transcribed text is processed by Claude with full RAG context — speak naturally, get AI-powered responses.

### File Upload → Auto-Indexing

Drop a file in Discord and it's automatically indexed into RAG. Your knowledge base grows as you chat.

### Auto Memory Extraction

Jarvis detects important information in conversations and auto-extracts it to long-term memory — preferences, facts, corrections. No manual `/remember` needed.

### Interactive Buttons

Every response includes contextual action buttons:
- **Cancel** — stop in-progress Claude tasks
- **Regen** — re-run the last query
- **Summarize** — get a summary of the response
- **Approve / Reject** — for L3 autonomous task approval workflow

### Multi-User & Family Mode

- Each Discord user gets **isolated memory** (facts, preferences, corrections, plans)
- New users join via **pairing code** (6-digit, 10min TTL, owner approval)
- **Family channels** automatically filter out owner's private data (trading, career)
- Per-channel **personas** — different personality per channel (`personas.json`)
- **Message debouncing** — consecutive messages batched (1.5s) into single Claude call

## RAG Knowledge Base + Insight Layer

Two layers work together — RAG retrieves facts, the Insight Layer understands context.

```
📊 Insight Layer (daily, ~1.2KB)                 📚 RAG Layer (per-query)
  "career topic surged 534x"                        semantic search across
  "focus shifted from infra to interviews"           10,000+ indexed documents
              │                                              │
              └──────────────┬───────────────────────────────┘
                             ▼
                    Claude responds with
                    full situational awareness
```

### Insight Layer

Automated behavioural analysis, generated daily at 04:15:

| Step | Script | LLM | Cost |
|------|--------|:---:|:----:|
| Metrics collection | `insight-metrics.mjs` | None | $0 |
| Interpretation | `insight-distill.mjs` | Claude | ~$0.03 |

Detects: topic frequency shifts, cross-domain correlations, entity momentum, daily activity patterns. Integrates Google Calendar for D-day awareness. Output loaded into every system prompt automatically.

### RAG

Hybrid search: BM25 full-text + Ollama vector similarity (`snowflake-arctic-embed2`, 1024-dim).

| Spec | Value |
|------|-------|
| **Vector DB** | LanceDB (local, embedded) |
| **Embedding** | Ollama snowflake-arctic-embed2 |
| **Indexing** | Incremental every 4h, entity-graph daily |
| **Search** | BM25 + vector hybrid (RRF k=60) + GraphRAG expansion |
| **Smart filters** | Auto-excludes dev docs, filters family-sensitive data |

See [`rag/README.md`](rag/README.md) for details.

## Dev-Queue — Autonomous Development

Jarvis doesn't just chat — it **writes code**.

1. **Insight Extractor** analyses task results and news, auto-extracts high-priority action items
2. Items are queued in **SQLite task store** with FSM state tracking (PENDING → RUNNING → SUCCESS/FAILED)
3. **`jarvis-coder.sh`** picks up queued tasks and executes them via Claude — automated commits, fixes, improvements
4. Skip patterns prevent recursive self-modification (manual tasks and self-referential items are filtered)

## Self-Healing Automation

<p align="center">
  <img src="docs/img/discord-system-health.png" alt="System Health Check" width="700">
</p>
<p align="center"><em>Automated system health check: 10 services monitored every 6 hours</em></p>

Jarvis doesn't just run — it **heals itself**. 99 automation scripts, 11 LaunchAgents, 40+ cron jobs, 4-layer self-recovery (`bot-heal` → `process-recovery` → `cron-auditor` → `auto-diagnose`):

| | What it does | When |
|---|---|---|
| 🔄 | **Auto-Recovery** — watchdog detects crashed services, restarts them. Guardian re-registers unloaded daemons every 3 min | 24/7 |
| 🔍 | **Dawn Audit** — scans cron health, RAG integrity, bot status. `jarvis-auditor.sh` + `scorecard-enforcer.sh` reports anomalies before you wake up | Daily 06:00 |
| 📊 | **Insight Report** — behavioural metrics analysis → situational awareness context for every response | Daily 04:15 |
| 🧪 | **E2E Testing** — `e2e-test.sh` validates 50 system components. `weekly-code-review.sh` runs automated code quality audits | Weekly |
| 📚 | **RAG Pipeline** — incremental indexing (4h), entity-graph (03:45), weekly compaction (Sun 04:00), file watcher for real-time updates | Scheduled |
| 📡 | **Health Monitor** — 10 services monitored, disk/memory alerts. Discord + ntfy.sh push notifications on threshold breach | Every 6h |
| 📈 | **Cron Failure Tracker** — `cron-failure-tracker.sh` tracks success rates, detects degradation trends | Continuous |
| 🚀 | **Safe Deployment** — smoke tests, graceful restart, log rotation. Zero-downtime updates | On demand |
| 📰 | **News Briefing** — AI/Tech news curation with dev-queue suggestions | Daily |

### 8 AI Agent Teams

Summon specialised teams via `/team <name>`:

| Team | Role |
|------|------|
| **Council** | CEO-level system review — stability + market + OKR decisions |
| **Infra** | Infrastructure chief — cron/LaunchAgent/disk/memory audits |
| **Record** | Meeting notes + decision audit log |
| **Brand** | Blog content + portfolio management |
| **Career** | Job search strategy + interview prep |
| **Academy** | Learning plans + skill development |
| **Trend** | Market signals + tech trend analysis |
| **Recon** | Reconnaissance — competitive intelligence |

### Board Meeting AI

Automated executive review system. 4 AI agents convene daily:

| Agent | Role |
|-------|------|
| **CEO** | Final decisions — system stability + market + OKR progress |
| **Infra Chief** | Uptime, error rates, performance metrics |
| **Strategy Advisor** | Market signals, investment analysis, career moves |
| **Record Keeper** | Meeting minutes, decision audit log |

Output: `context-bus.md` (shared context) + `decisions/{date}.jsonl` + `board-minutes/{date}.md`

### Smart Features

| Feature | Description |
|---------|-------------|
| **Zero-Cost Automation** | All cron tasks run via `claude -p` (subscription) — no per-token API charges |
| **Commitment Tracking** | Auto-detects promises in Claude responses, tracks fulfilment |
| **L3 Approval Workflow** | Autonomous tasks request human approval via Discord buttons (24h TTL) |
| **Context Budget** | Auto-classifies prompt complexity, adjusts thinking depth |
| **Visual Generation** | Charts (ChartJS) + tables (Puppeteer) rendered as images, cached by SHA256 |
| **Stat Cards** | "disk?", "RAG status?" → auto-generates visual embed cards |
| **Langfuse Observability** | Prompt tracing, cost tracking, error rates, latency monitoring |
| **Rate Limiting** | Per-user token budget + semaphore concurrency control (max 3) |
| **i18n** | Korean + multilingual support |

## Project Structure

```
jarvis/
├── rag/                 # RAG module (LanceDB + Ollama + Insight Layer)
│   ├── lib/             # Core engine, query, paths
│   └── bin/             # Indexer, metrics, distiller, repair
├── infra/               # Infrastructure & automation
│   ├── discord/         # Discord bot + 30 handlers
│   ├── lib/             # Core libraries (MCP, task-store, insight-extractor)
│   ├── bin/             # Cron executables (jarvis-cron, jarvis-coder, bot-cron)
│   ├── scripts/         # Auditors, e2e tests, code review, deployment
│   ├── config/          # Tasks, personas, channels, monitoring
│   ├── agents/          # 8 AI team profiles
│   └── templates/       # Cron & LaunchAgent templates
├── scripts/             # Setup wizards
└── docs/img/            # Screenshots
```

<details>
<summary><strong>Security</strong></summary>

- **gitleaks** pre-commit hook scans for secrets before every commit
- **`private/`** directory excluded from git for sensitive data
- Family channel privacy boundaries (owner data filtered)
- Pairing codes with TTL for new user onboarding

</details>

<details>
<summary><strong>Troubleshooting</strong></summary>

- **Discord bot won't start** — check `.env` has valid `DISCORD_TOKEN`
- **RAG returns no results** — `cd rag && npm run stats` to check DB status
- **Cron jobs not running** — `crontab -l`, check logs in `~/.local/share/jarvis/logs/`
- **Insight report missing** — `BOT_HOME=~/.jarvis node rag/bin/insight-distill.mjs`

</details>

## License

[MIT](LICENSE)

---

<p align="center">
  <a href="README.ko.md">🇰🇷 한국어</a>
</p>
