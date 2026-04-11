# Jarvis Setup Guide

> **For Claude Code / AI assistants**: Read this file to set up Jarvis for a new user.
> **For humans**: Follow each section step-by-step or ask Claude Code to do it for you:
> `claude "Read infra/CLAUDE-SETUP-GUIDE.md and help me set up Jarvis"`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Directory Structure](#3-directory-structure)
4. [Step-by-Step Setup](#4-step-by-step-setup)
   - [4.1 Clone & Install Dependencies](#41-clone--install-dependencies)
   - [4.2 Environment Variables (.env)](#42-environment-variables-env)
   - [4.3 Discord Bot Creation](#43-discord-bot-creation)
   - [4.4 Persona Configuration](#44-persona-configuration)
   - [4.5 User Profiles](#45-user-profiles)
   - [4.6 Owner Context Files](#46-owner-context-files)
   - [4.7 MCP Server Configuration (Nexus CIG)](#47-mcp-server-configuration-nexus-cig)
   - [4.8 Model Configuration](#48-model-configuration)
   - [4.9 Monitoring & Alerts](#49-monitoring--alerts)
   - [4.10 RAG Setup (Optional)](#410-rag-setup-optional)
   - [4.11 Cron Tasks](#411-cron-tasks)
   - [4.12 Process Management](#412-process-management)
5. [Verification Checklist](#5-verification-checklist)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. Architecture Overview

Jarvis has two main subsystems:

```
jarvis/
├── infra/          ← Discord bot + automation (this guide)
│   ├── discord/    ← Bot client, handlers, slash commands
│   ├── bin/        ← Entry points: ask-claude.sh, jarvis-cron.sh
│   ├── lib/        ← Core: mcp-nexus.mjs, llm-gateway.sh, rag-engine
│   │   └── nexus/  ← 4 MCP gateways (exec/rag/health/extras)
│   ├── config/     ← tasks.json, monitoring.json, models.json
│   ├── context/    ← Per-user context files (persona, preferences)
│   ├── agents/     ← AI team agent profiles
│   └── scripts/    ← Watchdog, auditor, deployment, e2e tests
│
└── rag/            ← RAG knowledge base (LanceDB + Ollama)
    ├── lib/        ← Engine, query, hybrid search
    └── bin/        ← Indexer, metrics, distiller
```

### How Messages Flow

```
Discord message
    │
    ▼
discord-bot.js        ← Receives message, routes to handler
    │
    ▼
handlers.js           ← Pre-processes: RAG context injection, user profile lookup
    │
    ▼
claude-runner.js      ← Builds system prompt from prompt-sections.js
    │                    Loads persona from personas.json
    │                    Loads MCP servers from discord-mcp.json
    │
    ▼
Claude Agent SDK      ← query() with system prompt + MCP tools
    │
    ├── Nexus CIG     ← MCP server: exec, scan, rag_search, health
    ├── Serena         ← MCP server: code navigation (optional)
    │
    ▼
Streaming response    ← Sent back to Discord thread
    │
    ▼
Auto-indexing         ← Conversation saved to RAG for future context
```

### What Nexus CIG Does (Critical for Quality)

Without Nexus, Claude gets raw tool output (315KB+) which fills the context window in ~30 minutes.
With Nexus, output is compressed to ~5.4KB (98% reduction), enabling 3+ hour sessions.

**Without Nexus**: Bot works but has no system tools (exec, scan, health check, RAG search).
**With Nexus**: Full operational capability — execute commands, search logs, check health, query RAG.

---

## 2. Prerequisites

### Required

| Requirement | How to Get | Verify |
|-------------|-----------|--------|
| **Claude Max or Pro subscription** | [claude.ai](https://claude.ai) | Active subscription |
| **Claude Code CLI** | `npm install -g @anthropic-ai/claude-code` | `claude --version` |
| **Claude CLI authenticated** | Run `claude` once, authenticate in browser | `claude -p "hello"` returns response |
| **Node.js 22+** | [nodejs.org](https://nodejs.org) or `brew install node` | `node --version` → v22+ |
| **jq** | `brew install jq` (macOS) / `apt install jq` (Linux) | `jq --version` |
| **Discord bot token** | [discord.com/developers](https://discord.com/developers/applications) | See [4.3](#43-discord-bot-creation) |

### Optional

| Requirement | What It Enables | How to Get |
|-------------|----------------|-----------|
| **Ollama** | RAG vector search (local embeddings) | [ollama.com](https://ollama.com/download) |
| **Serena** | Code navigation in Discord responses | `npm install -g @anthropic-ai/serena` |
| **ntfy** | Mobile push notifications | [ntfy.sh](https://ntfy.sh) (free) |
| **GNU coreutils** (macOS only) | `gtimeout` for command timeouts | `brew install coreutils` |

### Platform Notes

| Platform | Service Manager | Notes |
|----------|----------------|-------|
| **macOS** | LaunchAgents + cron | Primary platform. `brew install coreutils` for gtimeout |
| **Linux / WSL2** | PM2 + cron | `npm install -g pm2` required |
| **Docker** | PM2 inside container | See `docker-compose.yml` |

---

## 3. Directory Structure

After setup, your Jarvis installation should have:

```
~/.jarvis/              (or wherever you clone — set as BOT_HOME)
├── discord/
│   ├── discord-bot.js           ← Main bot entry point
│   ├── personas.json            ← Channel → persona mapping (from .example)
│   └── lib/                     ← Handlers, runner, streaming
├── config/
│   ├── discord-mcp.json         ← MCP server config (from .example)
│   ├── discord-channels.json    ← Channel ID → role mapping (from .example)
│   ├── models.json              ← Model selection config (from .example)
│   ├── user_profiles.json       ← User profiles (from .example)
│   ├── monitoring.json          ← Webhook/ntfy config
│   ├── tasks.json               ← Cron task definitions
│   └── secrets/                 ← API keys, tokens (gitignored)
│       ├── social.json          ← Optional: social media API keys
│       └── system.json          ← Optional: system credentials
├── context/
│   └── owner/
│       ├── persona.md           ← Response style rules (from .example)
│       ├── preferences.md       ← Tool/service constraints (from .example)
│       └── owner-profile.md     ← Owner background info (from .example)
├── state/                       ← Runtime state (auto-created)
│   ├── session-summaries/
│   ├── config-backups/
│   └── users/
├── logs/                        ← Log files (auto-created)
├── results/                     ← Cron task output (auto-created)
└── .env                         ← Environment variables (from .example)
```

---

## 4. Step-by-Step Setup

### 4.1 Clone & Install Dependencies

```bash
# Clone the repository
git clone https://github.com/Ramsbaby/jarvis.git ~/.jarvis
cd ~/.jarvis

# Install Discord bot dependencies
cd infra/discord && npm install && cd ../..

# Install RAG dependencies (optional — skip if you don't need RAG)
cd rag && npm install && cd ..
```

### 4.2 Environment Variables (.env)

```bash
cd infra
cp .env.example .env
```

Edit `infra/.env` — fill in at minimum:

```env
# ===== REQUIRED =====
DISCORD_TOKEN=your_discord_bot_token       # From Discord Developer Portal
ANTHROPIC_API_KEY=your_anthropic_api_key   # From console.anthropic.com (or leave empty for Max subscription)

# ===== Discord Server =====
GUILD_ID=your_discord_server_id            # Right-click server → Copy Server ID
CHANNEL_ID=your_main_channel_id            # Right-click channel → Copy Channel ID
CHANNEL_IDS=channel1,channel2              # All channels the bot should watch
OWNER_DISCORD_ID=your_discord_user_id      # Right-click yourself → Copy User ID

# ===== Bot Identity =====
BOT_NAME=Jarvis
BOT_LOCALE=en                              # en or ko
BOT_HOME=/path/to/.jarvis/infra            # Absolute path to infra/ directory
OWNER_NAME=YourName
OWNER_TITLE=Owner

# ===== Claude CLI =====
CLAUDE_BINARY=~/.local/bin/claude          # Path to claude CLI binary
```

> **Finding Discord IDs**: Enable Developer Mode in Discord (Settings → App Settings → Advanced → Developer Mode). Then right-click any server, channel, or user to copy their ID.

### 4.3 Discord Bot Creation

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **"New Application"** → name it "Jarvis"
3. Go to **Bot** tab:
   - Click **"Reset Token"** → copy the token → paste into `.env` as `DISCORD_TOKEN`
   - Enable **"Message Content Intent"** (CRITICAL — bot can't read messages without this)
   - Enable **"Server Members Intent"**
   - Enable **"Presence Intent"**
4. Go to **OAuth2 → URL Generator**:
   - Scopes: `bot`, `applications.commands`
   - Bot Permissions: `Send Messages`, `Read Message History`, `Embed Links`, `Attach Files`, `Use Slash Commands`, `Manage Threads`, `Send Messages in Threads`, `Read Messages/View Channels`
   - Copy the generated URL → open in browser → add bot to your server
5. Verify: The bot should appear as offline in your Discord server member list

### 4.4 Persona Configuration

Personas define how Jarvis behaves in each Discord channel.

```bash
cd infra
cp discord/personas.example.json discord/personas.json
```

Edit `discord/personas.json` — replace placeholder channel IDs with your actual Discord channel IDs:

```json
{
  "123456789012345678": "--- Channel: jarvis (Main) ---\nThis is the main channel...",
  "234567890123456789": "--- Channel: jarvis-dev ---\nIn this channel, Jarvis operates as a developer...",
  "345678901234567890": "--- Channel: jarvis-system ---\nSystem alerts channel..."
}
```

> **Key**: Each key is a Discord channel ID (string). The value is the system prompt injected for that channel.

### 4.5 User Profiles

User profiles enable multi-user support with isolated memory.

```bash
cp config/user_profiles.example.json config/user_profiles.json
```

Edit `config/user_profiles.json` — replace Discord IDs:

```json
{
  "discord_YOUR_DISCORD_ID": {
    "name": "YourName",
    "title": "Owner",
    "type": "owner",
    "role": "owner",
    "bio": "Project owner.",
    "persona": ""
  }
}
```

> New users can also be added dynamically via the pairing code system (6-digit code, 10-minute TTL).

### 4.6 Owner Context Files

These files personalize Jarvis's responses. Without them, Jarvis uses generic defaults.

```bash
# Create context directory
mkdir -p context/owner

# Copy example files
cp context/owner/persona.example.md context/owner/persona.md
cp context/owner/preferences.example.md context/owner/preferences.md
cp context/owner/owner-profile.example.md context/owner/owner-profile.md
```

Edit each file to reflect your personal preferences and background. These files are:

| File | Purpose | Impact if Missing |
|------|---------|-------------------|
| `persona.md` | Response style, anti-bias rules, communication principles | Generic responses, no personality |
| `preferences.md` | Tool/service constraints (which calendar, task system, etc.) | May use wrong tools or services |
| `owner-profile.md` | Your professional background, current focus | Can't personalize career/work advice |

### 4.7 MCP Server Configuration (Nexus CIG)

**This is the most important step for feature parity.** Without MCP, the bot has no system tools.

```bash
cp config/discord-mcp.example.json config/discord-mcp.json
```

Edit `config/discord-mcp.json`:

```json
{
  "mcpServers": {
    "nexus": {
      "type": "stdio",
      "command": "node",
      "args": ["/absolute/path/to/.jarvis/infra/lib/mcp-nexus.mjs"],
      "env": {
        "BOT_HOME": "/absolute/path/to/.jarvis/infra",
        "DISCORD_TOKEN": "${DISCORD_TOKEN}",
        "NODE_ENV": "production"
      }
    }
  }
}
```

> **Important**: The `${BOT_HOME}` and `${DISCORD_TOKEN}` placeholders are auto-resolved at runtime from your `.env` file. You can use either placeholders or absolute paths.

**What Nexus enables** (tools available to Claude in Discord):

| Tool | Purpose |
|------|---------|
| `exec` | Execute shell commands |
| `scan` | Parallel multi-command execution |
| `cache_exec` | Cached command execution (TTL) |
| `log_tail` | Read recent log lines |
| `file_peek` | Read file contents |
| `rag_search` | Search RAG knowledge base |
| `health` | System health check |
| `discord_send` | Send messages to other channels |
| `run_cron` | Trigger cron tasks on demand |
| `get_memory` | Read user memory entries |

### 4.8 Model Configuration

```bash
cp config/models.example.json config/models.json
```

Default config uses Claude Haiku for quick responses and Opus for complex tasks. Modify if you prefer different models.

### 4.9 Monitoring & Alerts

Edit `config/monitoring.json` to add webhook URLs:

```json
{
  "webhook": { "url": "" },
  "ntfy": { "topic": "your-ntfy-topic", "server": "https://ntfy.sh" },
  "webhooks": {
    "jarvis": "https://discord.com/api/webhooks/...",
    "jarvis-system": "https://discord.com/api/webhooks/..."
  }
}
```

> Discord webhooks are optional but enable richer formatting. Create them in Discord: Channel Settings → Integrations → Webhooks.

### 4.10 RAG Setup (Optional)

RAG gives Jarvis long-term memory — it remembers past conversations and can search indexed documents.

```bash
# Requires Ollama running locally
ollama serve &                              # Start Ollama (if not already running)
ollama pull snowflake-arctic-embed2         # Download embedding model (~400MB)

# Run RAG setup
cd /path/to/jarvis
python scripts/setup_rag.py
```

**Without RAG**: Bot works for real-time chat but has no memory of past conversations.
**With RAG**: Bot searches past conversations, indexed documents, and auto-extracted facts.

### 4.11 Cron Tasks

Cron tasks run Claude on a schedule (standup reports, health checks, market monitoring, etc.).

Create `config/tasks.json` with your tasks:

```json
[
  {
    "id": "morning-standup",
    "name": "Morning Standup",
    "schedule": "5 8 * * *",
    "prompt": "Summarize today's priorities based on calendar and recent context.",
    "output": ["discord"],
    "discordChannel": "bot-daily",
    "retry": { "max": 3, "backoff": "exponential" }
  },
  {
    "id": "system-health",
    "name": "System Health Check",
    "schedule": "0 */6 * * *",
    "prompt": "Run a system health check. Report disk usage, memory, and service status.",
    "output": ["discord"],
    "discordChannel": "jarvis-system"
  }
]
```

The `depends` field enables cross-task context injection:

```json
{
  "id": "standup",
  "depends": ["stock-monitor", "council-insight"],
  "prompt": "Write standup including market context and council priorities."
}
```

> Output from `stock-monitor` and `council-insight` is automatically prepended to the standup prompt.

### 4.12 Process Management

#### macOS (LaunchAgents)

```bash
# Start the bot
node infra/discord/discord-bot.js

# For 24/7 auto-restart, create a LaunchAgent:
cat > ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.jarvis.discord-bot</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>/path/to/.jarvis/infra/discord/discord-bot.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/path/to/.jarvis/infra</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOT_HOME</key>
    <string>/path/to/.jarvis/infra</string>
    <key>NODE_ENV</key>
    <string>production</string>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/path/to/.jarvis/infra/logs/discord-bot.log</string>
  <key>StandardErrorPath</key>
  <string>/path/to/.jarvis/infra/logs/discord-bot.log</string>
</dict>
</plist>
EOF

# Load the LaunchAgent
launchctl load ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist
```

> **Note**: Replace `/path/to/.jarvis` with your actual installation path. Use `which node` to find the correct Node.js path.

#### Linux / WSL2 (PM2)

```bash
npm install -g pm2

# Start the bot
pm2 start infra/discord/discord-bot.js --name jarvis-bot \
  --env BOT_HOME=/path/to/.jarvis/infra

# Auto-start on boot
pm2 startup
pm2 save
```

#### Docker

```bash
cd infra
docker compose up -d
docker compose logs -f    # Verify: should see "Discord connected"
```

---

## 5. Verification Checklist

Run these checks after setup to confirm everything works:

### Tier 0 — Bot Starts
- [ ] `node infra/discord/discord-bot.js` starts without errors
- [ ] Bot appears **online** in Discord
- [ ] Bot responds to a message in a configured channel

### Tier 1 — Core Features
- [ ] Bot uses correct persona for each channel
- [ ] Owner is recognized (check by asking "Who am I?")
- [ ] Slash commands appear (`/status`, `/search`, `/run`)
- [ ] `/status` returns system health info

### Tier 2 — MCP Tools (Nexus)
- [ ] Ask "What's my disk usage?" — bot should use `exec` tool
- [ ] Ask "Search my notes for [topic]" — bot should use `rag_search`
- [ ] `/run system-health` triggers a cron task

### Tier 3 — RAG (if enabled)
- [ ] `/search test query` returns results
- [ ] `/remember This is a test fact` saves to RAG
- [ ] Subsequent `/search test fact` finds the saved memory

### Quick Smoke Test

```bash
# Test Claude CLI works
claude -p "Reply with just 'OK'"

# Test bot process
cd infra && node -e "
  const { config } = require('dotenv');
  config({ path: '.env' });
  console.log('DISCORD_TOKEN:', process.env.DISCORD_TOKEN ? '✅ set' : '❌ missing');
  console.log('GUILD_ID:', process.env.GUILD_ID ? '✅ set' : '❌ missing');
  console.log('CHANNEL_IDS:', process.env.CHANNEL_IDS ? '✅ set' : '❌ missing');
  console.log('OWNER_DISCORD_ID:', process.env.OWNER_DISCORD_ID ? '✅ set' : '❌ missing');
  console.log('BOT_HOME:', process.env.BOT_HOME ? '✅ set' : '❌ missing');
"
```

---

## 6. Troubleshooting

### Bot won't start

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Error: TOKEN is required` | Missing `DISCORD_TOKEN` in `.env` | Check `.env` file exists and has valid token |
| `Error [TOKEN_INVALID]` | Invalid Discord token | Reset token in Discord Developer Portal |
| `Cannot find module` | Dependencies not installed | `cd infra/discord && npm install` |
| `node: command not found` | Node.js not in PATH | Install Node.js 22+ or fix PATH |

### Bot starts but doesn't respond

| Symptom | Cause | Fix |
|---------|-------|-----|
| Bot is online but ignores messages | Missing Message Content Intent | Enable in Discord Developer Portal → Bot → Privileged Intents |
| Bot responds in wrong channel | Channel ID mismatch | Verify `CHANNEL_IDS` in `.env` matches your channel IDs |
| Bot responds but with generic persona | `personas.json` missing or wrong IDs | Copy from `.example`, replace with your channel IDs |

### MCP / Nexus issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "MCP disabled" in logs | `discord-mcp.json` missing | Copy from `.example` and configure |
| Nexus tools fail | Wrong `BOT_HOME` path in MCP config | Use absolute path, verify `lib/mcp-nexus.mjs` exists |
| `@modelcontextprotocol/sdk` not found | MCP SDK not installed | `cd infra/discord && npm install` |

### RAG issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Ollama connection refused" | Ollama not running | `ollama serve` |
| "Model not found" | Embedding model not pulled | `ollama pull snowflake-arctic-embed2` |
| RAG returns no results | Nothing indexed yet | Run `node rag/bin/rag-index.mjs` to index initial data |

### Cron tasks not running

| Symptom | Cause | Fix |
|---------|-------|-----|
| Tasks never fire | `claude` CLI not in PATH | Set `CLAUDE_BINARY` in `.env` to absolute path |
| "command not found: gtimeout" (macOS) | GNU coreutils missing | `brew install coreutils` |
| Tasks fail silently | Missing `tasks.json` | Create from examples in this guide |

---

## Quick Reference: Example Config Files

| File to Create | Copy From | Required? |
|----------------|-----------|-----------|
| `infra/.env` | `infra/.env.example` | **Yes** |
| `discord/personas.json` | `discord/personas.example.json` | **Yes** |
| `config/discord-mcp.json` | `config/discord-mcp.example.json` | **Yes** (for full features) |
| `config/user_profiles.json` | `config/user_profiles.example.json` | Recommended |
| `config/models.json` | `config/models.example.json` | Optional (has defaults) |
| `context/owner/persona.md` | `context/owner/persona.example.md` | Recommended |
| `context/owner/preferences.md` | `context/owner/preferences.example.md` | Recommended |
| `context/owner/owner-profile.md` | `context/owner/owner-profile.example.md` | Recommended |
| `config/tasks.json` | See [4.11](#411-cron-tasks) | For cron automation |
| `config/monitoring.json` | Already exists (edit values) | For alerts |
| `config/discord-channels.json` | Already exists (edit IDs) | For channel routing |

---

## Minimal Setup (Fastest Path)

If you want the bot running in 5 minutes with basic features:

```bash
git clone https://github.com/Ramsbaby/jarvis.git ~/.jarvis && cd ~/.jarvis

# 1. Install
cd infra/discord && npm install && cd ..

# 2. Configure
cp .env.example .env
# Edit .env: set DISCORD_TOKEN, GUILD_ID, CHANNEL_IDS, OWNER_DISCORD_ID, BOT_HOME

cp discord/personas.example.json discord/personas.json
# Edit personas.json: replace channel ID keys with your actual IDs

cp config/discord-mcp.example.json config/discord-mcp.json
# Edit discord-mcp.json: set absolute path to BOT_HOME

# 3. Run
node discord/discord-bot.js
```

This gives you: Discord chat + Nexus MCP tools. No RAG, no cron, no LaunchAgents — add those later.
