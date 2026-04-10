# Jarvis Installation Guide

Jarvis supports macOS (native), Linux, and Windows (Docker).

---

## Prerequisites — Gather these before you start

Collect the following 4 items before installing. With them ready, setup takes under 5 minutes.

**① Discord Bot Token**

1. Go to https://discord.com/developers/applications
2. Click **New Application** (top right) → enter a name → Create
3. Click **Bot** in the left sidebar
4. Click **Reset Token** → copy the token (shown only once — store it safely)
5. Scroll down to **Privileged Gateway Intents** → enable **Message Content Intent**
6. Go to **OAuth2 → URL Generator**
7. Scopes: check `bot` → Bot Permissions: check `Send Messages`, `Read Message History`, `View Channels`
8. Use the generated URL to invite the bot to your Discord server

**② Anthropic API Key**

1. Go to https://console.anthropic.com → log in or sign up
2. Click **API Keys** in the left sidebar
3. Click **Create Key** → copy the key (shown only once)

> **Note:** Jarvis v1 requires a **Claude Max subscription** ($100/mo). The bot calls `claude -p` for every response — without it, the bot starts but does nothing. API key alone is insufficient.

**③ Discord Server ID (Guild ID)**

1. In Discord: **Settings (gear icon)** → **Advanced** → enable **Developer Mode**
2. Right-click your server icon
3. Click **Copy Server ID**

**④ Discord Channel ID(s)**

1. Right-click the channel where you want the bot to respond
2. Click **Copy Channel ID**
3. For multiple channels, separate with commas: `123456789,987654321`

---

## Windows — Quick Start (5 minutes)

### Requirements

- Windows 10 21H2+ / Windows 11
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (free)
- [Git for Windows](https://git-scm.com/download/win)

### Step 1 — Enable WSL2

Docker Desktop requires WSL2. Open PowerShell as **Administrator** and run:

```powershell
wsl --install
```

Reboot after installation. If WSL2 is already installed, skip this step.

After reboot, verify:

```powershell
wsl --status
```

`Default Version: 2` means you're good.

---

### One-click Install (setup.ps1 — recommended)

Open PowerShell as **Administrator**:

```powershell
# Allow script execution (one-time)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

git clone https://github.com/your-username/jarvis $env:USERPROFILE\.jarvis
cd $env:USERPROFILE\.jarvis
.\setup.ps1
```

The script automatically handles: Docker check, `.env` creation, interactive token input, Claude path setup, and container startup.

---

### Manual Install

**1. Install Docker Desktop**

Download from https://www.docker.com/products/docker-desktop/ and install.
After install, launch Docker Desktop and confirm the tray icon is green.

**2. Clone the repository**

```powershell
git clone https://github.com/your-username/jarvis $env:USERPROFILE\.jarvis
cd $env:USERPROFILE\.jarvis
```

**3. Configure environment**

```powershell
copy .env.example .env
notepad .env
```

**4. .env checklist**

Fill in the following in Notepad:

Required:
- [ ] `DISCORD_TOKEN` — Discord bot token (see ① above)
- [ ] `ANTHROPIC_API_KEY` — Anthropic API key (see ② above)
- [ ] `GUILD_ID` — Discord server ID (see ③ above)
- [ ] `CHANNEL_IDS` — Channel IDs the bot responds in (see ④ above, comma-separated)
- [ ] `OWNER_DISCORD_ID` — Your Discord user ID (right-click your profile → Copy ID)

Optional (leave blank to use defaults):
- [ ] `BOT_NAME` — Bot display name (default: `Jarvis`)
- [ ] `BOT_LOCALE` — Language `en` or `ko` (default: `ko`)
- [ ] `OWNER_NAME` — Your name (default: `Owner`)
- [ ] `NTFY_TOPIC` — Mobile push notification topic (ntfy.sh)
- [ ] `OPENAI_API_KEY` — For RAG vector embeddings (optional)

**5. Start**

```powershell
docker compose up -d
```

**6. Verify**

```powershell
docker logs jarvis --follow
docker compose ps
```

**7. Stop**

```powershell
docker compose down
```

---

## macOS (Native) — Recommended

### Requirements

- macOS 12+
- Node.js 22+
- Homebrew
- **Claude Max subscription** — all responses and cron tasks call `claude -p`. Without it, nothing works.
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code` then run `claude` to authenticate via browser. Verify with `claude --version`.

### One-click Install (setup.sh — recommended)

```bash
git clone https://github.com/your-username/jarvis ~/.jarvis
cd ~/.jarvis
chmod +x setup.sh
./setup.sh
```

### Manual Install

```bash
git clone https://github.com/your-username/jarvis ~/.jarvis
cd ~/.jarvis
cp .env.example .env
nano .env   # fill in your tokens
```

### Run with launchd (auto-start on boot)

```bash
cp templates/ai.jarvis.discord-bot.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist

# Check status
launchctl list | grep jarvis

# View logs
tail -f ~/.jarvis/logs/discord-bot.log
```

### Run with PM2 (alternative)

```bash
npm install -g pm2
pm2 start ecosystem.config.cjs
pm2 startup && pm2 save
```

---

## Linux (Native)

### Requirements

- Ubuntu 22.04+ / Debian 12+ / RHEL 9+
- Node.js 22+
- PM2

### One-click Install (setup.sh — recommended)

```bash
git clone https://github.com/your-username/jarvis ~/.jarvis
cd ~/.jarvis
chmod +x setup.sh
./setup.sh
```

### Manual Install

```bash
git clone https://github.com/your-username/jarvis ~/.jarvis
cd ~/.jarvis
cp .env.example .env
nano .env   # fill in your tokens
```

### Run with PM2 + systemd

```bash
npm install -g pm2
cd ~/.jarvis
pm2 start ecosystem.config.cjs
pm2 startup systemd   # copy and run the output command
pm2 save
```

### Verify

```bash
pm2 list
pm2 logs jarvis-bot --lines 50
```

---

## Environment Variables Reference

**Required**

| Variable | Description |
|----------|-------------|
| `DISCORD_TOKEN` | Discord bot token (discord.com/developers/applications) |
| `ANTHROPIC_API_KEY` | Anthropic API key (console.anthropic.com) |
| `GUILD_ID` | Discord server ID for slash command registration |
| `CHANNEL_IDS` | Comma-separated channel IDs the bot listens in |
| `OWNER_DISCORD_ID` | Your Discord user ID |

**Optional**

| Variable | Default | Description |
|----------|---------|-------------|
| `BOT_NAME` | `Jarvis` | Bot display name |
| `BOT_LOCALE` | `ko` | Response language: `en` or `ko` |
| `OWNER_NAME` | `Owner` | Your name used in prompts |
| `OWNER_TITLE` | — | Your title/role |
| `JARVIS_HOME` | `~/.jarvis` | Installation directory |
| `NODE_ENV` | `production` | Runtime environment |
| `NTFY_TOPIC` | — | ntfy.sh topic for mobile push alerts |
| `OPENAI_API_KEY` | — | RAG vector embeddings (optional) |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | — | Google Calendar integration |

---

## Troubleshooting

### Bot is online but not responding to messages

- Confirm the channel ID is listed in `CHANNEL_IDS` in `.env`
- Re-copy the channel ID from Discord Developer Mode and compare
- Multiple IDs must be comma-separated with no spaces: `123,456` ✓ / `123, 456` ✗
- Check the bot has Send Messages and Read Message History permissions in that channel

### `docker compose up` fails

- Confirm Docker Desktop is running (green tray icon)
- Verify WSL2: `wsl --status`
- If WSL2 missing: run `wsl --install` in Admin PowerShell, then reboot
- Port conflict: `docker ps` to check existing containers, then `docker compose down`

### Anthropic API errors

- Confirm `ANTHROPIC_API_KEY` starts with `sk-ant-`
- Check the key is active at https://console.anthropic.com
- Verify your Claude Max subscription is active

### Discord token errors

- Confirm `DISCORD_TOKEN` was copied correctly (no leading/trailing spaces)
- Regenerate the token in Discord Developer Portal and update `.env`
- After updating token: `docker compose down && docker compose up -d`

### Restart PM2 process

```bash
pm2 restart jarvis-bot
```

### Rebuild Docker container

```bash
docker compose down
docker compose up -d --build
```

### View logs

```bash
pm2 logs jarvis-bot --lines 100       # Linux/macOS PM2
docker logs jarvis --tail 100          # Windows/Docker
tail -f ~/.jarvis/logs/discord-bot.log # macOS/Linux native
```

---

## Platform Support Matrix

| Platform | Method | Auto-start | Status |
|----------|--------|-----------|--------|
| macOS 12+ | launchd or PM2 | ✅ | Official |
| Ubuntu 22.04+ | PM2 + systemd | ✅ | Official |
| Windows 10/11 | Docker Desktop | ✅ | Official |
| Windows (WSL2) | PM2 | ✅ | Experimental |

---

For further help, open an issue at https://github.com/your-username/jarvis/issues
