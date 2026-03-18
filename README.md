<p align="center">
  <a href="https://github.com/Ramsbaby/jarvis/actions/workflows/ci.yml">
    <img src="https://github.com/Ramsbaby/jarvis/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
  <a href="https://github.com/Ramsbaby/jarvis/stargazers">
    <img src="https://img.shields.io/github/stars/Ramsbaby/jarvis?style=flat-square" alt="Stars">
  </a>
  <img src="https://img.shields.io/badge/extra_cost-$0%2Fmonth-brightgreen?style=flat-square" alt="$0/month extra">
  <img src="https://img.shields.io/badge/context_compression-98%25-blueviolet?style=flat-square" alt="98% compression">
  <img src="https://img.shields.io/badge/session_length-3%2B_hours-blue?style=flat-square" alt="3+ hours">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License">
</p>

<h1 align="center">Jarvis — AI Company-in-a-Box</h1>

<p align="center">
  <strong>Your Claude Max subscription sits idle 23 hours a day.<br>Jarvis turns it into a 24/7 AI operations system — 12 AI teams, 49 cron tasks, persistent memory — at $0 extra cost.</strong>
</p>

<p align="center">
  <a href="README.ko.md">한국어</a> · <a href="ROADMAP.md">Roadmap</a> · <a href="discord/SETUP.md">Setup Guide</a> · <a href="docs/INDEX.md">Documentation</a>
</p>

<p align="center">
  <img src="docs/demo.gif" alt="Jarvis demo" width="700">
</p>

---

## Why $0? — The Core Differentiator

Most Discord bots and AI automation tools call the Anthropic API directly. Every message costs money:

- Claude Opus via API: ~$0.015–$0.075 per message
- A busy bot sending 500 messages/month: **$7–$37 extra, every month**

**Jarvis works differently.** It uses `claude -p` — the headless (non-interactive) mode of Claude Code CLI. Claude Code is Anthropic's official developer tool, included in your Claude Max or Pro subscription at no extra charge. Jarvis is simply a harness that wires that tool to Discord, cron jobs, and a memory system.

> Think of it like this: you already pay for a gym membership. Jarvis is the personal trainer who makes sure you actually use it — all day, every day, even while you sleep.

### Side-by-Side Comparison

| | **Jarvis** | **API-based bots** | **OpenClaw / Clawdbot** |
|---|---|---|---|
| Monthly extra cost | **$0** | $5–$50+ | API key required |
| How it calls Claude | `claude -p` (included in subscription) | Anthropic API (token billing) | Anthropic API (token billing) |
| Automation style | 49 cron tasks + 12 AI teams (proactive) | Reactive only | Reactive only |
| Self-healing | 4-layer auto-recovery | None | None |
| Memory (RAG) | LanceDB hybrid vector + BM25 | Rare | None |
| Session continuity | 3+ hours (98% compression) | Per-message | Basic |

### What is `claude -p`?

`claude -p` is Claude Code's "print mode" — it takes a prompt, runs Claude, prints the answer, and exits. Anthropic documents it as the recommended way to use Claude Code in automation pipelines. Because it runs under your existing subscription, there is no per-call fee.

Jarvis calls `claude -p` for every Discord message, every cron task, every AI team report. The same Claude Opus or Sonnet model you use interactively, now working for you 24/7 at no extra cost.

---

## Key Numbers

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

Nexus CIG intercepts every tool call output before it reaches Claude's context window. Heavy-output cases measured at 315 KB → 5.4 KB (98%).

</td>
<td align="center" width="33%">

### 3+ hours
*session length*

Without compression, context fills in ~30 min. With Nexus CIG, multi-turn threads sustain for several hours before auto-compact triggers.

</td>
</tr>
</table>

---

## What Jarvis Does While You Sleep

Normal bots wait for you to type. Jarvis works on its own schedule:

```
 YOU          JARVIS
 ────────────────────────────────────────────────────────────
 03:00  zzz   → Server maintenance scan        #bot-system
 04:45  zzz   → Code Auditor scans all scripts  internal
 07:50  zzz   → Trend team: morning briefing    #bot-daily
 08:00  zzz   → Board Meeting: CEO reviews all  #bot-ceo
 08:05  zzz   → Smart Standup (waits for you)   #bot-daily
 09:00  ☕    ← You wake up: standup is ready
 10:00        ↔ Real-time Discord chat (you type, it answers)
 18:00        ← You stop chatting
 20:00  zzz   → Record team: daily archive      internal
 00:30  zzz   → Log rotation + backup cleanup
 01:00  zzz   → RAG index + Vault sync (hourly)
 ────────────────────────────────────────────────────────────
              49 cron tasks + 12 AI teams. Zero manual intervention.
```

Every task has **exponential backoff retry**, **rate-limit awareness**, and **failure alerts** pushed to your phone via [ntfy](https://ntfy.sh).

---

## Core Features

### 1. Zero Extra Cost
`claude -p` runs under your Claude Max subscription. You pay $100/month for Claude Max regardless — Jarvis makes that subscription work 24/7 instead of just when you're at the keyboard.

### 2. AI Team Organization
Twelve virtual teams each have a defined role and run on their own schedule. You don't need to ask them anything:

| Team | What it does |
|------|-------------|
| **Council** (strategy) | Cross-team synthesis, daily priorities |
| **Infra** | Server health, cost monitoring |
| **Career** | Weekly growth reflection |
| **Record** | Daily activity archiving |
| **Brand** | Content and positioning tracking |
| **Academy** | Research and knowledge management |
| **Trend** | Morning news and market briefings |

### 3. Self-Healing Infrastructure (4 Layers)
The bot recovers from crashes without waking you up:

```
Layer 0: bot-preflight.sh  — validates config on every cold start
          if broken → Claude AI reads the log and fixes the file itself
Layer 1: launchd KeepAlive — OS-level restart on any exit (macOS)
Layer 2: cron */5min → watchdog.sh — checks log freshness, kills stale processes
Layer 3: cron */3min → launchd-guardian.sh — re-registers unloaded LaunchAgents
```

### 4. Persistent Memory (RAG)
Every conversation, cron result, and document is indexed in a local LanceDB database. Ask "what did you say about TQQQ last week?" and it will find it. No cloud, no extra cost.

- **Vector search** — semantic similarity (OpenAI `text-embedding-3-small`)
- **Full-text search** — BM25 keyword matching
- **Reranking** — RRF (Reciprocal Rank Fusion) combines both signals

### 5. 98% Context Compression
The Nexus CIG (Context Intelligence Gateway) MCP server sits between Claude and every system command. It classifies output types and compresses them before they enter the context window. A 315 KB JSON blob becomes 5.4 KB. Multi-turn threads that would exhaust tokens in 30 minutes now run for 3+ hours.

---

## Quick Start

> **Prerequisites**
> - **Claude Max subscription** ($100/mo) — every response and cron task calls `claude -p`. Without it, the bot starts but does nothing useful.
> - **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code` then run `claude` to authenticate
> - **Node.js 20+**, **jq**, and a **Discord bot token** from [discord.com/developers](https://discord.com/developers)

**Option A — Docker (simplest):**

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
cp discord/.env.example discord/.env
# edit discord/.env — add your tokens
docker compose up -d
```

**Option B — Direct install (macOS / Linux):**

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
./install.sh --local
# edit discord/.env
node discord/discord-bot.js
```

For 24/7 operation on macOS:
```bash
launchctl load ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist
```

See [discord/SETUP.md](discord/SETUP.md) for the full step-by-step guide.

---

## Architecture

```
Discord message
      │
      ▼
discord-bot.js ──► handlers.js ──► claude-runner.js
                                         │
                                   claude -p (your subscription)
                                         │
                                   Nexus CIG (MCP server)
                                   98% compression
                                         │
                                   formatForDiscord()
                                         │
                                   Discord thread reply
                                         │
                                   RAG index (LanceDB)
                                   stored for future context
```

**Cron path:**
```
jarvis-cron.sh → bot-cron.sh → ask-claude.sh → claude -p
                                     │
                               cross-team context injected
                               from depends[] tasks
                                     │
                               result → Discord + Vault + RAG
```

---

## Configuration

### `discord/.env` (required)

```env
BOT_NAME=MyBot
BOT_LOCALE=en                        # 'en' or 'ko'
DISCORD_TOKEN=your_bot_token
GUILD_ID=your_server_id
CHANNEL_IDS=channel_id_1,channel_id_2
OWNER_NAME=YourName
OPENAI_API_KEY=your_key              # optional: RAG vector embeddings only
NTFY_TOPIC=your_ntfy_topic          # optional: mobile push notifications
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
| `/remember <text>` | Save a permanent memory entry |
| `/clear` | Reset session context |
| `/stop` | Interrupt a running `claude -p` process |

---

## File Structure

```
~/.jarvis/
├── discord/          # Discord client, handlers, formatting
├── bin/              # Entry points: ask-claude.sh, bot-cron.sh, etc.
├── lib/              # Core: rag-engine, mcp-nexus, llm-gateway
├── config/           # tasks.json, monitoring.json, anti-patterns.json
├── scripts/          # Watchdog, auditor, vault-sync, KPI, local E2E suite
├── teams/            # 12 team definitions (YAML + system prompts)
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

## Roadmap

| Phase | Status | Description |
|-------|--------|-------------|
| Phase 0 | Done | Bug fixes, structured logging, self-healing |
| Phase 1 | Done | LLM Gateway, Bash/Node module split |
| Phase 2 | Done | Plugin system, Lite/Company mode, Team YAML, jarvis init |
| Phase 3 | Done | Open-source checklist 12/12 |
| Phase 4 | Planned | Multi-language support, web dashboard, Slack adapter |

See [ROADMAP.md](ROADMAP.md) for details.

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
git clone https://github.com/Ramsbaby/jarvis
# make changes
bash scripts/e2e-test.sh   # local production validation (requires running bot)
# submit a pull request
```

See [ROADMAP.md](ROADMAP.md) for planned features.

---

## License

MIT — see [LICENSE](LICENSE)

---

<p align="center">
  <a href="README.ko.md">한국어 README →</a><br><br>
  If this project is useful, a star helps others discover it.
</p>
