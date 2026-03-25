<div align="center">

<!-- Row 1: health & meta -->
<a href="https://github.com/Ramsbaby/jarvis/actions/workflows/ci.yml"><img src="https://github.com/Ramsbaby/jarvis/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/Ramsbaby/jarvis/stargazers"><img src="https://img.shields.io/github/stars/Ramsbaby/jarvis?style=flat-square&color=yellow" alt="Stars"></a>
<a href="https://github.com/Ramsbaby/jarvis/network/members"><img src="https://img.shields.io/github/forks/Ramsbaby/jarvis?style=flat-square" alt="Forks"></a>
<img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License">
<img src="https://img.shields.io/badge/node-22+-green?style=flat-square&logo=node.js&logoColor=white" alt="Node 22+">
<img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgray?style=flat-square" alt="Platform">

<!-- Row 2: key differentiators -->
<br>
<img src="https://img.shields.io/badge/extra_cost-$0%2Fmonth-brightgreen?style=flat-square" alt="$0/month extra">
<img src="https://img.shields.io/badge/context_compression-98%25-blueviolet?style=flat-square" alt="98% compression">
<img src="https://img.shields.io/badge/session_length-3%2B_hours-blue?style=flat-square" alt="3+ hours">
<img src="https://img.shields.io/badge/AI_teams-12-orange?style=flat-square" alt="12 AI teams">
<img src="https://img.shields.io/badge/cron_tasks-76-orange?style=flat-square" alt="76 cron tasks">

<h1>Jarvis</h1>

<img src="docs/assets/hero.svg" alt="Jarvis — 24/7 AI Ops" width="800">

<h3>Turn your idle Claude Max subscription into a 24/7 AI operations system</h3>

<p>
  <strong>
    You pay $20–$100/month for Claude Max. It sits idle 23 hours a day.<br>
    Jarvis wires it to Discord, cron jobs, and a local memory engine —<br>
    so Claude works, monitors, and learns around the clock, at $0 extra.<br>
    <sub>12 AI teams · 76 cron tasks · self-healing · local RAG memory</sub>
  </strong>
</p>

<p>
  <a href="README.ko.md">한국어</a> ·
  <a href="discord/SETUP.md">Setup Guide</a> ·
  <a href="docs/INDEX.md">Docs</a> ·
  <a href="ROADMAP.md">Roadmap</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<img src="docs/demo.gif" alt="Jarvis — bot startup, cron execution, Discord chat, /status command" width="820">

</div>

---

## What Is Jarvis?

Jarvis is an automation layer around `claude -p` — Claude Code's headless print mode. It wires Claude to **Discord**, **scheduled cron jobs**, and a **local RAG memory system** (RAG = Retrieval-Augmented Generation: past conversations, notes, and reports are indexed and fed as context so Claude's answers get smarter over time), turning your existing subscription into a personal AI operations team.

```
You type in Discord   →  Claude answers in real time  →  saved to memory
Cron fires at 8 AM    →  Claude writes your standup   →  posted to #bot-daily
You wake up at 9 AM   →  briefing, alerts, priorities are already there
```

**No Anthropic API key. No metered billing. No cloud.** Just `claude -p`.

---

## The Core Insight: `claude -p` Is Free

Most Discord bots call the Anthropic API — every message is a paid API call. Jarvis does something different.

`claude -p` is Claude Code's **headless mode** — documented by Anthropic as the recommended way to use Claude in automation pipelines. It runs entirely under your existing Claude Max subscription, with no per-call charge.

| | Jarvis | API-based bot | n8n + Claude |
|---|---|---|---|
| How it calls Claude | `claude -p` (CLI, your subscription) | `POST /v1/messages` (metered) | API node (metered) |
| 500 msgs/month cost | **$0 extra** | ~$7–$37 extra | API cost + n8n fee |
| Model quality | Opus / Sonnet (your tier) | Depends on key | Depends on key |
| Proactive automation | 76 scheduled tasks | Reactive only | Needs visual setup |
| Self-healing | 4-layer auto-recovery | ❌ | ❌ |
| Long-term memory | LanceDB hybrid (local) | Rare | Optional plugin |
| Context compression | 98% (Nexus CIG — see below) | ❌ | ❌ |
| Privacy | 100% local | Varies | Varies |

> You already pay for the gym. Jarvis is the personal trainer who makes sure you actually use it — all day, every day, even while you sleep.

---

## What Happens While You Sleep

```
  TIME     YOU        JARVIS
  ─────────────────────────────────────────────────────────────────
  00:30    😴         → Log rotation + cleanup
  01:00    😴         → RAG index updated (hourly, incremental)
  03:00    😴         → Server maintenance scan  →  #bot-system
  04:45    😴         → Code Auditor reviews all scripts  (internal)
  07:50    😴         → Trend team: morning briefing  →  #bot-daily
  08:00    😴         → Board Meeting: CEO reviews OKRs  →  #bot-ceo
  08:05    😴         → Smart Standup prepared and posted
  09:00    ☕          ← You wake up: briefing, alerts, priorities — ready
  10:00               ↔ Real-time Discord chat (you ask, Claude answers)
  18:00               ← You stop for the day
  20:00    😴         → Record team: daily archive  (internal)
  ─────────────────────────────────────────────────────────────────
                       76 cron tasks · 12 AI teams · 0 manual steps
```

Every task has **exponential backoff retry**, **rate-limit awareness**, and **failure alerts** pushed to your phone via [ntfy](https://ntfy.sh).

---

## Key Numbers

<table>
<tr>
<td align="center" width="33%">

### $0 / month
*extra cost*

Every Discord reply, every cron task, every AI team report calls `claude -p` — included in your Claude Max or Pro subscription. No API keys, no metered billing.

</td>
<td align="center" width="33%">

### 98%
*context compression*

**Nexus CIG** (Context Intelligence Gateway) — an MCP server that intercepts every tool output before it reaches Claude's context window. Measured: **315 KB → 5.4 KB**. Multi-turn threads that would exhaust tokens in 30 minutes now run for hours.

</td>
<td align="center" width="33%">

### 3+ hours
*session length*

Without compression, context fills in ~30 min. With Nexus CIG, threads sustain for several hours before auto-compact triggers — critical for long cron chains.

</td>
</tr>
</table>

---

## How It Works

```
  Discord message
        │
        ▼
  discord-bot.js  ──►  handlers.js  ──►  claude-runner.js
                                               │
                                         claude -p
                                     (your subscription)
                                               │
                                       Nexus CIG (MCP)
                                       98% compression
                                               │
                                   Discord reply  +  RAG index
                                               │
                                     stored for future context

  ─────────────────────────────────────────────────────────────────

  Cron scheduler  ──►  jarvis-cron.sh  ──►  tasks.json
                                               │
                                   cross-team context injected
                                   (from depends[] tasks)
                                               │
                                         claude -p
                                               │
                                   Discord  +  Obsidian Vault  +  RAG
```

<img src="docs/assets/architecture.svg" alt="Jarvis Architecture" width="800">

### Self-Healing — 4 Layers (No Human Needed)

| Layer | Trigger | What It Does |
|-------|---------|-------------|
| **0 · Preflight** | Every cold start | `bot-preflight.sh` validates config; if broken, Claude reads the error log and **fixes the file itself** |
| **1 · OS-level** | Any crash | `launchd KeepAlive = true` (macOS) / Docker `restart: always` (Linux) — OS-level restart |
| **2 · Watchdog** | Every 3 min | `watchdog.sh` checks log freshness; kills and restarts stale processes |
| **3 · Guardian** | Every 3 min | `launchd-guardian.sh` re-registers unloaded LaunchAgents (macOS) |

---


### Pairing Code — Access Control (No Open Invites)

Jarvis uses a **pairing-code system** to restrict who can interact with the bot.
New users must enter a one-time pairing code (`/pair <code>`) before any commands work.
Approved users are stored locally — no Discord role hacking, no public invite links.

## 12 AI Teams

Each team has a defined role, its own system prompt, and runs on its own cron schedule. They share context through a `context-bus.md` that the Council writes and every other team reads.

| Team | Schedule | What it does |
|------|----------|-------------|
| **Council** | Daily 23:00 | Cross-team synthesis; writes priorities to `context-bus.md` for all teams |
| **CEO Digest** | Daily 08:00 | Board-level summary: OKR progress, key decisions, overnight events |
| **Standup** | Daily 08:05 | Morning briefing — calendar, tasks, alerts, market overview |
| **Infra** | Every 30 min | Server health, process monitoring, cost alerts |
| **Finance** | Weekdays | Market monitoring, portfolio tracking, TQQQ / ETF signals |
| **Trend** | Daily 07:50 | News digest and emerging technology signals |
| **Recon** | Weekly | Competitive intelligence, OSS landscape scan |
| **Security Scan** | Weekly | Dependency audit, credential leak detection |
| **Career** | Weekly | Growth reflection, job market trend tracking |
| **Academy** | Weekly | Research digest, knowledge base management |
| **Record** | Daily 20:00 | Activity archiving, decision audit log (`decisions/*.jsonl`) |
| **Brand** | Weekly | Content positioning tracking |

**Cross-team context flow:** A Council insight written at 23:00 is automatically injected into the Standup prompt at 08:05 the next morning via the `depends[]` field in `tasks.json`. No manual wiring.

---

## What You Actually Get

This is Jarvis running on a real developer's machine. All numbers are measured.

**Every morning, before you open your laptop:**
- Standup is posted in Discord: calendar summary, top 3 priorities, overnight Jarvis activity
- If TQQQ or any monitored position crosses a threshold, a push notification is on your phone (ntfy)
- GitHub activity was checked; PRs needing review are surfaced
- CEO Digest summarizes OKR progress so you start the day with strategic clarity

**During your workday:**
- Ask anything in Discord — full Claude Opus / Sonnet quality, zero per-message cost
- `/search <query>` searches your entire knowledge base (Obsidian vault + cron results) semantically
- `/run <task>` manually triggers any of the 76 cron tasks on demand
- Rate limit tracker keeps you safely under the daily ceiling (typical usage: ~17%)

**While you sleep:**
- RAG index updated hourly as you edit notes *(Obsidian integration is optional — any Markdown folder works)*
- Team reports, ADRs, and daily decisions synced to structured Markdown
- Every significant decision logged to `decisions/*.jsonl` — a permanent audit trail
- System health checked every 30 min; anomalies go to Discord before you notice them

**The net result:** Claude works ~18–20 hours/day on your behalf. You spend 10 minutes reviewing what it did instead of doing it yourself.

---

## Quick Start

> **Prerequisites:**
> - **Claude Max or Pro subscription** — every task calls `claude -p` (Claude Pro works for lighter use; Max recommended for 24/7 operation)
> - **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code` then run `claude` once to authenticate in your browser
> - **Node.js 22+** and **jq** — `node --version` and `jq --version` to verify
> - **Discord bot token** — create a bot at [discord.com/developers](https://discord.com/developers/applications); see [discord/SETUP.md](discord/SETUP.md) for screenshots
> - **Platform:** macOS or Linux. Windows users: use WSL2.

**Option A — Docker (simplest):**

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
cp discord/.env.example discord/.env
# Edit discord/.env — add DISCORD_TOKEN, GUILD_ID, CHANNEL_IDS
# (See discord/SETUP.md → "Finding your IDs" if unsure where to get these)
docker compose up -d
```

To verify it's running: `docker compose logs -f` — you should see `Discord connected — Jarvis#XXXX`.

**Option B — Native macOS / Linux:**

```bash
git clone https://github.com/Ramsbaby/jarvis ~/.jarvis
cd ~/.jarvis
./install.sh              # installs deps, sets up LaunchAgents and crontab
# Edit discord/.env with your tokens, then:
node discord/discord-bot.js
```

To verify: type anything in one of your configured Discord channels — Jarvis should respond within a few seconds.

**For 24/7 auto-restart on macOS** (survives crashes and reboots):

```bash
launchctl load ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist
launchctl list | grep jarvis   # should show the service as running
```

> **First time?** [discord/SETUP.md](discord/SETUP.md) walks through Discord bot creation, finding your server/channel IDs, and verifying the first response — with screenshots.

### Dependency Tiers

Choose how much to install:

| Tier | Command | Size | Features |
|------|---------|------|---------| 
| **0 — Core** | `./install.sh --tier 0` | ~150 MB | Discord bot only, no RAG |
| **1 — Standard** | `./install.sh --tier 1` | ~350 MB | + SQLite history + BM25 search |
| **2 — Full** | `./install.sh` (default) | ~700 MB | + LanceDB vector search + OpenAI embeddings |

---

## Configuration

**`discord/.env`** — copy from `.env.example`

```env
BOT_NAME=Jarvis
BOT_LOCALE=en                     # en or ko
DISCORD_TOKEN=                    # from discord.com/developers
GUILD_ID=                         # your Discord server ID
CHANNEL_IDS=                      # comma-separated channel IDs to watch
OWNER_NAME=YourName
OPENAI_API_KEY=                   # optional: vector RAG embeddings
NTFY_TOPIC=                       # optional: mobile push via ntfy.sh
```

**`config/tasks.json`** — define your own cron tasks:

```json
{
  "id": "morning-standup",
  "name": "Morning Standup",
  "schedule": "5 8 * * *",
  "prompt": "Summarize today's top priorities based on calendar and recent context.",
  "output": ["discord"],
  "discordChannel": "bot-daily",
  "depends": ["council-insight", "tqqq-monitor"],
  "retry": { "max": 3, "backoff": "exponential" }
}
```

The `depends` array automatically injects cross-team context: if `tqqq-monitor` ran this morning, its output is prepended to the standup prompt. No extra code needed.

---

## FAQ

<details>
<summary><strong>Do I need Obsidian?</strong></summary>

No. Obsidian is optional. Jarvis uses any Markdown folder as its knowledge base. The vault-sync feature integrates with Obsidian if you have it, but the bot runs fine without it.

</details>

<details>
<summary><strong>Does this work on Windows?</strong></summary>

Not natively — Jarvis uses bash scripts and (on macOS) `launchd` for process management. Windows users should use **WSL2** (Windows Subsystem for Linux) or run Jarvis in Docker.

</details>

<details>
<summary><strong>Will this burn through my Claude rate limits?</strong></summary>

Unlikely. With the default 76 tasks, typical daily usage is around **17% of the Claude Max rate limit** — measured on a real installation. The built-in rate-limit tracker pauses tasks if you're getting close to the ceiling, and resumes automatically.

</details>

<details>
<summary><strong>I only have Claude Pro, not Max. Will it work?</strong></summary>

Yes, with lighter use. Claude Pro works well for the Discord bot and a handful of cron tasks. For the full 63-task schedule running 24/7, Claude Max is recommended to avoid hitting Pro-tier rate limits.

</details>

<details>
<summary><strong>What if a cron task fails?</strong></summary>

Each task has configurable retry logic (exponential backoff, up to 3 attempts by default). If it still fails, an alert is sent to Discord and optionally to your phone via ntfy. The bot keeps running — one failed task doesn't affect the others.

</details>

---

## Slash Commands

| Command | What it does |
|---------|-------------|
| `/search <query>` | Semantic search across the full RAG knowledge base |
| `/status` | System health: uptime, rate limit, cron task overview |
| `/tasks` | List all configured cron tasks and their schedules |
| `/run <task_id>` | Manually trigger any cron task on demand |
| `/threads` | List recent conversation threads |
| `/alert <message>` | Send alert → Discord + ntfy mobile push |
| `/usage` | Token usage stats + rate limit breakdown |
| `/remember <text>` | Save a permanent memory entry to RAG |
| `/clear` | Reset the current session context |
| `/stop` | Interrupt a running `claude -p` process |

---

## Roadmap

| Phase | Status | What Was Delivered |
|-------|--------|-------------------|
| **Phase 0** | ✅ Done | Bug fixes, structured logging, 4-layer self-healing |
| **Phase 1** | ✅ Done | LLM Gateway (multi-provider), Bash/Node module split |
| **Phase 2** | ✅ Done | Plugin system, Lite/Company mode, Team YAML, `jarvis init` |
| **Phase 3** | ✅ Done | Open-source release (checklist 12/12), Nexus CIG v3 |
| **Phase 4** | 🔜 Planned | Web dashboard, Slack adapter, multi-language support |

See [ROADMAP.md](ROADMAP.md) for details and contribution opportunities.

---

## File Structure

```
~/.jarvis/
├── discord/          # Discord client, handlers, formatters, slash commands
├── bin/              # Entry points: ask-claude.sh, bot-cron.sh, jarvis-init.sh
├── lib/              # Core: rag-engine.mjs, mcp-nexus.mjs, llm-gateway.sh
├── config/           # tasks.json, monitoring.json, anti-patterns.json
├── scripts/          # watchdog, auditor, vault-sync, KPI, E2E test suite
├── teams/            # 12 team definitions (YAML + system prompts)
├── plugins/          # File-convention plugin system (drop a .yml, it's registered)
├── context/          # Per-task background knowledge (injected at runtime)
├── results/          # Cron task output history
├── rag/              # LanceDB database + team reports
├── agents/           # CEO, Infra Chief, Strategy Advisor agent profiles
├── adr/              # Architecture Decision Records (ADR-001 to ADR-010)
└── docs/             # Architecture, Operations, Teams documentation
```

---

## Platform Notes

| Feature | macOS (native) | Linux / Docker |
|---------|----------------|----------------|
| Process supervision | `launchd` KeepAlive — restarts on crash, starts at login | Docker `restart: always` |
| Watchdog / Guardian | cron + bash (included) | Same — runs inside container |
| Apple integrations | Notes.app, Reminders (optional) | Not available |
| Storage | Local filesystem | Docker volume |

---

## Documentation

| | |
|--|--|
| [discord/SETUP.md](discord/SETUP.md) | Complete setup guide: bot creation, channel config, first run |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture deep dive: Nexus CIG, self-healing, RAG |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Cron operations, monitoring, incident response |
| [docs/TEAMS.md](docs/TEAMS.md) | 12 AI teams: roles, schedules, context flow |
| [adr/ADR-INDEX.md](adr/ADR-INDEX.md) | Architecture Decision Records (10 decisions documented) |
| [CHANGELOG.md](CHANGELOG.md) | Full release history |
| [ROADMAP.md](ROADMAP.md) | Planned features and contribution areas |

---

## Contributing

```bash
git clone https://github.com/Ramsbaby/jarvis
# make your changes
bash scripts/e2e-test.sh   # 50-item local validation suite
# open a pull request
```

Contributions welcome — especially for Phase 4 items (web dashboard, Slack adapter). See [ROADMAP.md](ROADMAP.md) for open areas.

---

## License

MIT — see [LICENSE](LICENSE)

---

<p align="center">
  <a href="README.ko.md">한국어 README →</a>
  <br><br>
  If Jarvis saves you time or money, a ⭐ helps others find it.
</p>
