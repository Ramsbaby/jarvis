# Operations Guide

> Back to [docs/INDEX.md](INDEX.md) | [README](../README.md)

## Cron Schedule

All cron tasks are defined in `config/tasks.json` and executed by `bin/bot-cron.sh`.

### Critical (always runs)

| Task | Schedule | Description |
|------|----------|-------------|
| `morning-standup` | 09:15 daily | Smart standup (waits for owner online) |
| `board-meeting-am` | 08:10 daily | CEO board meeting (morning) |
| `board-meeting-pm` | 21:55 daily | CEO board meeting (evening) |
| `tqqq-monitor` | */15 22-23 Mon-Fri | TQQQ/SOXL/NVDA price tracking |
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
| `boram-daily-schedule` | 07:30 | Preply lesson briefing |

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
| `doc-supervisor` | 05:00 daily | Documentation freshness check |
| `log-rotate` | 03:15 daily | Log rotation (crontab direct, not in tasks.json) |
| `agent-batch-commit` | 08:20, 22:20 daily | Auto-commit agent outputs |
| `dev-runner` | 22:50 daily | Autonomous dev queue runner |
| `cost-monitor` | Sun 09:00 | API cost tracking |

### Background (high-frequency)

| Task | Schedule | Description |
|------|----------|-------------|
| `rate-limit-check` | */30 | Rate limit monitoring |
| `update-usage-cache` | */30 | /usage command cache |
| `calendar-alert` | */5 | Google Calendar pre-alerts |
| `session-sync` | */15 | Context bus sync |
| `disk-alert` | hourly :10 | Disk threshold check |
| `github-monitor` | hourly | GitHub notification check |
| `system-health` | hourly | Disk/CPU/memory/process check |

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
| `ai.openclaw.glances` | KeepAlive | System monitor (port 61208) |

Plist files: `~/Library/LaunchAgents/ai.jarvis.*.plist`

---

## Monitoring Stack

### Glances Web Dashboard
- URL: `http://localhost:61208`
- API: `http://localhost:61208/api/4/cpu`
- Mobile: accessible via LAN IP on Galaxy browser

### Uptime Kuma
- URL: `http://192.168.219.111:3001`
- Docker container (restart=always)
- Monitors: Gateway, Glances, n8n
- Alerts: Discord webhook

### ntfy Push Notifications
- Topic: `openclaw-f101e56cb98a`
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

---

## Incident Response

### Automatic

1. **Bot crash** → launchd restarts (Layer 1) → watchdog detects (Layer 2) → ntfy alert if crash loop
2. **LaunchAgent unloaded** → guardian re-registers (Layer 3)
3. **Preflight failure** → AI auto-recovery via `bot-heal.sh` (max 3 attempts, exponential backoff)
4. **Task failure** → `auto-diagnose.sh` event trigger → Discord system channel

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

## Deployment

```bash
# Standard deploy (smoke test → restart)
bash ~/.jarvis/scripts/deploy-with-smoke.sh

# Manual restart
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot
```
