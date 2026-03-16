<p align="center">
  <img src="https://img.shields.io/badge/cost-$0%2Fmonth-brightgreen?style=flat-square" alt="$0/month">
  <img src="https://img.shields.io/badge/E2E_tests-57-brightgreen?style=flat-square" alt="Tests">
  <img src="https://img.shields.io/badge/context_compression-98%25-blueviolet?style=flat-square" alt="98% compression">
  <img src="https://img.shields.io/badge/session_length-3%2B_hours-blue?style=flat-square" alt="3+ hours">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License">
</p>

<h1 align="center">Jarvis — AI Company-in-a-Box</h1>

<p align="center">
  <strong>Your Claude Max subscription is idle 23 hours a day.<br>This turns it into a 24/7 AI operations system — 12 AI teams, 45 cron tasks, knowledge management — at $0 extra cost.</strong>
</p>

<p align="center">
  <a href="README.ko.md">한국어</a> · <a href="ROADMAP.md">Roadmap</a> · <a href="discord/SETUP.md">Setup Guide</a> · <a href="docs/INDEX.md">Documentation</a>
</p>

<p align="center">
  <img src="docs/demo.gif" alt="Jarvis demo" width="700">
</p>

---

## TL;DR

| | |
|---|---|
| **What** | Self-hosted Discord bot backed by `claude -p` (Claude Code's headless CLI) |
| **Who** | Claude Max subscribers who want $0 extra AI costs |
| **How** | Spawns `claude -p` per message, streams output to Discord in real-time |
| **Why** | 45 cron tasks + 12 AI teams + reactive chat + RAG memory, at zero extra cost |

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

Nexus CIG intercepts every tool call output before it hits Claude's context window. In documented heavy-output cases, compression reaches 315 KB → 5.4 KB (98%).

</td>
<td align="center" width="33%">

### 3+ hours
*session length*

Without compression, context fills in ~30 min. With Nexus CIG, multi-turn threads sustain for several hours. At 80k tokens, auto-compact triggers with structured digest.

</td>
</tr>
</table>

---

## What It Does While You Sleep

```
 YOU          BOT
 ────────────────────────────────────────────────────────────
 03:00  zzz   → Server maintenance scan        #bot-system
 04:45  zzz   → Code Auditor scans all scripts  internal
 07:50  zzz   → Trend team: morning briefing    #bot-daily
 08:00  zzz   → Council reviews all teams       #bot-ceo
 08:05  zzz   → Smart Standup (waits for you)   #bot-daily
 09:00  ☕    ← You wake up: standup fires now
 10:00        ↔ Real-time Discord chat (you type, it answers)
 18:00        ← You stop chatting
 20:00  zzz   → Record team: daily archive      internal
 00:30  zzz   → Log rotation + backup cleanup
 01:00  zzz   → RAG index + Vault sync (hourly)
 ────────────────────────────────────────────────────────────
              45 cron tasks + 12 AI teams. Zero manual intervention.
```

Every task has **exponential backoff retry**, **rate-limit awareness**, and **failure alerts** pushed to your phone via [ntfy](https://ntfy.sh).

See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the full cron schedule and monitoring stack.

---

## vs. the Alternatives

| | **This bot** | **Clawdbot** (60K ⭐) | **Typical API bot** |
|---|---|---|---|
| AI cost | **$0 extra** | ~$36+/mo | $5 – $50+/mo |
| Behavior | **Proactive** (45 cron + 12 teams) | Reactive only | Reactive only |
| Context mgmt | **Nexus CIG** (98% compression) | None / basic | Basic |
| RAG / memory | LanceDB (vector + BM25 hybrid) | Rarely | Plugin-dependent |
| Self-healing | 4-layer watchdog + AI auto-recovery | Manual restart | Varies |
| E2E tests | **57** automated checks | Rare | Partial |

---

## Quick Start

### Prerequisites

- **Node.js ≥ 20** — `node -v`
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **Claude Max subscription** — required for `claude -p` headless mode
- **Discord bot token** — [Discord Developer Portal](https://discord.com/developers/applications)

### Option A: Docker

```bash
git clone https://github.com/YOUR_USERNAME/jarvis ~/.jarvis
cd ~/.jarvis
cp discord/.env.example discord/.env
# → edit discord/.env with your tokens
docker compose up -d
```

### Option B: Local (macOS / Linux)

```bash
git clone https://github.com/YOUR_USERNAME/jarvis ~/.jarvis
cd ~/.jarvis
./install.sh --local
# edit discord/.env  (copy from discord/.env.example)
node discord/discord-bot.js
```

For persistent 24/7 operation on macOS:
```bash
launchctl load ~/Library/LaunchAgents/ai.discord-bot.plist
```

See [discord/SETUP.md](discord/SETUP.md) for the full step-by-step setup.

---

## Configuration

### `discord/.env` (required)

```env
BOT_NAME=MyBot
BOT_LOCALE=ko
DISCORD_TOKEN=your_bot_token
GUILD_ID=your_server_id
CHANNEL_IDS=channel_id_1,channel_id_2
OWNER_NAME=YourName
OPENAI_API_KEY=your_key              # optional: RAG enrichment only
NTFY_TOPIC=your_ntfy_topic          # optional: push notifications
```

### `config/tasks.json` (cron automation)

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

Copy from `config/tasks.json.example` to get started with 3 example tasks.

---

## Architecture

High-level message flow:

```
Discord msg → discord-bot.js → claude-runner.js (Agent SDK)
                                       │
                                 Nexus CIG (MCP)
                                 98% compression
                                       │
                              formatForDiscord()
                                       │
                              Discord thread reply
                                       │
                              RAG index (LanceDB)
```

**Key components:**
- **Nexus CIG** — MCP server that compresses tool output before context (315 KB → 5.4 KB)
- **Self-healing** — 4-layer recovery (preflight → launchd → watchdog → guardian)
- **12 AI teams** — Virtual organization with Board Meeting + Decision Dispatcher

For detailed diagrams see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
For team details see [docs/TEAMS.md](docs/TEAMS.md).

---

## Slash Commands

| Command | What it does |
|---------|-------------|
| `/search <query>` | Semantic search across RAG knowledge base |
| `/status` | System health + rate limit overview |
| `/tasks` | List configured cron tasks |
| `/run <task_id>` | Manually trigger a cron task |
| `/threads` | List recent conversation threads |
| `/alert <message>` | Send alert → Discord + ntfy push |
| `/usage` | Token usage + rate limit stats |

---

## File Structure

```
~/.jarvis/
├── discord/          # Discord client, handlers, formatting
├── bin/              # Entry points: ask-claude.sh, bot-cron.sh, etc.
├── lib/              # Core: rag-engine, mcp-nexus, llm-gateway
├── config/           # tasks.json, monitoring.json, anti-patterns.json
├── scripts/          # Watchdog, auditor, vault-sync, KPI, E2E tests
├── teams/            # 11 team definitions (YAML + system prompts)
├── plugins/          # File-convention plugin system
├── context/          # Per-task background knowledge
├── results/          # Cron task output history
├── rag/              # LanceDB + team reports
├── agents/           # CEO, Infra Chief, etc. profiles
├── adr/              # Architecture Decision Records
├── docs/             # Architecture, Operations, Teams docs
└── state/            # Sessions, rate tracker, decisions, triggers
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/INDEX.md](docs/INDEX.md) | Documentation hub |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture, Nexus CIG, Self-Healing |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Cron, monitoring, incident response |
| [docs/TEAMS.md](docs/TEAMS.md) | 12 AI teams overview |
| [adr/ADR-INDEX.md](adr/ADR-INDEX.md) | Architecture Decision Records |
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [ROADMAP.md](ROADMAP.md) | Planned features |

---

## Platform Notes

| Feature | macOS (native) | Linux (Docker) |
|---------|---------------|----------------|
| Process supervision | `launchd` KeepAlive | Docker `restart: always` |
| Watchdog / Guardian | cron + bash | Same (runs in container) |
| Apple integrations | Notes, Reminders (optional) | Not available |

---

## Contributing

```bash
git clone https://github.com/YOUR_USERNAME/jarvis
# make changes
bash scripts/e2e-test.sh   # → 57 passed, 0 failed
# submit a pull request
```

See [ROADMAP.md](ROADMAP.md) for planned features.

---

## License

MIT — see [LICENSE](LICENSE)

---

<p align="center">
  <a href="README.ko.md">한국어 README →</a>
</p>
