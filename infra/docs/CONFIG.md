# Config Inventory

> Where Jarvis keeps configuration, and how to edit it safely.
> See also: [TASKS-INDEX.md](TASKS-INDEX.md) · [ARCHITECTURE.md](ARCHITECTURE.md)

Jarvis splits config across three locations:

| Location | Purpose |
|---|---|
| `~/.jarvis/config/` | **Runtime** config read by crons, bot, scripts |
| `~/jarvis/infra/*` | **Code-embedded** config (package.json, compose, plists templates) |
| `~/Library/LaunchAgents/ai.jarvis.*.plist` | **macOS launchd** service definitions |

---

## 1. Task Registry — `~/.jarvis/config/tasks.json`

**The SSoT for every scheduled cron in Jarvis.** 82 tasks as of now.

### Schema (per task)

| Field | Required | Notes |
|---|---|---|
| `id` | ✓ | Unique slug, used for log filenames |
| `name` | | Human label |
| `schedule` | ✓ (unless event-triggered) | Standard cron expression |
| `script` | * | Path to shell/node script (mutually exclusive with `prompt`) |
| `prompt` / `prompt_file` | * | LLM prompt sent through `ask-claude.sh` |
| `allowedTools` | | Comma list: `Read,Bash,WebSearch,...` |
| `output` | | `["discord","file"]` |
| `discordChannel` | | Channel slug (e.g. `jarvis-system`) |
| `team` | | Rarely set — teams are inferred via `gen-tasks-index.mjs` |
| `model` | | `claude-sonnet-4-6`, `claude-haiku-4-5-*` |
| `maxBudget` | | USD per run (float as string) |
| `priority` | | `critical` / `daily` / `weekly` / `normal` |
| `retry` | | `{max, backoff}` |
| `timeout` | | Seconds |
| `depends` | | Array of task ids that must succeed first |
| `disabled` / `enabled: false` | | Soft-disable |
| `event_trigger` | | Event name (emit via `emit-event.sh`) |
| `requiresMarket` | | Only run on US market days |

### How to modify safely

```bash
# 1. Validate JSON before save
python3 -m json.tool ~/.jarvis/config/tasks.json > /dev/null

# 2. Regenerate docs
node ~/jarvis/infra/scripts/gen-tasks-index.mjs

# 3. Cron reads tasks.json on every tick — no reload needed
```

> **Never** hand-edit while `cron-sync.sh` is running. Use `tasks.json.bak-<date>` backups if unsure.

---

## 2. Other `~/.jarvis/config/` Files

| File | Used by | Purpose |
|---|---|---|
| `effective-tasks.json` | task-store | Runtime cache of resolved tasks (do not edit) |
| `agent_tiers.json` | Tier 1-5 system | Per-agent tier ceiling & budgets |
| `anti-patterns.json` | evaluator | Gate rules for LLM output |
| `board-discussion-config.json` | board-meeting | Board meeting params |
| `board-personas.json` | board-meeting | 9 persona prompts |
| `brand-keywords.json` | brand-lead | OSS / blog keyword tracking |
| `dev-backlog.json` | dev-runner | Auto-coding queue |
| `discord-channels.json` | discord bot | Channel → team mapping |
| `discord-mcp.json` | discord bot MCP | MCP server registration |
| `doc-map.json` | doc-supervisor | Doc → team ownership |
| `goals.json` | council | OKR / KR tracking |
| `models.json` | llm-gateway | Model ↔ tier routing |
| `monitoring.json` | system-doctor | Threshold config |
| `oss-targets.json` | oss-recon | OSS repos to monitor |
| `team-budget.json` | cost-monitor | Per-team daily budget caps |
| `team-scorecard.json` | council | Team merit/penalty ledger |
| `user-schedule.json` | personal-schedule | Owner calendar rules |
| `user_profiles.json` | discord bot | User preference per Discord ID |
| `agent_tiers.json` | Tier router | Tier 1-5 agent definitions |
| `google-calendar-token.json` | gog CLI | OAuth token (**secret**) |
| `jira.env` | jira-sync | Jira creds (**secret**) |
| `tutoring.env` | finance | tutoring API creds (**secret**) |
| `secrets/` | various | Additional secret material |
| `empty-mcp.json` | ask-claude.sh | Zero-MCP profile (Jarvis gateway) |
| `serena-mcp.json` | Claude Code CLI | Serena-only MCP profile |

### Secret files

`jira.env`, `tutoring.env`, `secrets/`, `google-calendar-token.json` contain credentials. Never commit, never paste into Discord, never log. Rotate via the respective provider when exposed.

### Backups

`tasks.json.bak*` / `effective-tasks.json.bak*` are auto-created by `cron-sync.sh` before structural edits. Clean old ones via `log-cleanup` cron, not by hand.

---

## 3. MCP Configs (`~/jarvis/infra/lib/nexus/`, `~/.mcp.json`)

| File | Consumer | Notes |
|---|---|---|
| `~/.mcp.json` | Claude Code CLI | Project-level MCP servers (brave, github, serena, etc.) |
| `~/.jarvis/config/serena-mcp.json` | Selected crons | Serena LSP-only profile |
| `~/.jarvis/config/empty-mcp.json` | `ask-claude.sh` | Jarvis gateway uses zero MCP |
| `~/jarvis/infra/lib/mcp-nexus.mjs` | infra | In-process MCP bridge |
| `~/jarvis/infra/lib/nexus/` | various | MCP shims |

**Rule**: Jarvis Gateway (`ask-claude.sh`) always passes `--mcp-config empty-mcp.json`. Only Claude Code CLI sessions get full MCP.

---

## 4. Environment Variables

Jarvis code reads these — never hardcode user paths.

| Var | Meaning | Where |
|---|---|---|
| `BOT_HOME` | `~/jarvis` project root | Discord bot, scripts |
| `JARVIS_HOME` | `~/.jarvis` runtime home (state, config, logs) | All crons |
| `JARVIS_RAG_HOME` | `~/jarvis/rag` RAG module root | RAG indexer |
| `VAULT_DIR` | Obsidian vault path | record-daily, memory-sync |
| `GOOGLE_ACCOUNT` | Primary Google account | morning-standup, calendar-alert |
| `GOOGLE_TASKS_LIST_ID` | Default Google Tasks list | morning-standup |
| `ANTHROPIC_API_KEY` | Direct API fallback | llm-gateway |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth for ask-claude.sh | llm-gateway, ask-claude.sh |

Code that reads these lives mostly in `infra/lib/llm-gateway.sh`, `infra/lib/task-store.mjs`, and the per-script wrappers. **Never** commit a `.env` with real values.

---

## 5. LaunchAgents — `~/Library/LaunchAgents/ai.jarvis.*.plist`

Long-running services (not crons) are managed by launchd.

```bash
# List all Jarvis agents
ls ~/Library/LaunchAgents/ai.jarvis.*.plist

# Current load state
launchctl list | grep ai.jarvis

# Reload a specific agent
launchctl unload ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist
launchctl load   ~/Library/LaunchAgents/ai.jarvis.discord-bot.plist

# Force kickstart (if stuck)
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot
```

Key agents:

| Agent | Purpose |
|---|---|
| `ai.jarvis.discord-bot` | 24/7 Discord bot |
| `ai.jarvis.rag-watcher` | RAG incremental indexer |
| `ai.jarvis.rag-compact` | Weekly compact (Sun 03:00) |
| `ai.jarvis.event-watcher` | Event-triggered crons |
| `ai.jarvis.board` | Board meeting scheduler |
| `ai.jarvis.orchestrator` | Multi-agent orchestrator |
| `ai.jarvis.dashboard` | Monitoring dashboard |
| `ai.jarvis.github-runner` | GitHub PR automation |
| `ai.jarvis.langfuse` | LLM trace collector |

### Golden rule — RAG agents

Never edit `tasks.json` RAG entries while `ai.jarvis.rag-watcher` or `ai.jarvis.rag-compact` is loaded. Unload first, edit, reload. See `~/.claude/rules/rag-system.md` for the full procedure (RAG DB has been destroyed twice by ignoring this).

---

## 6. Editing Checklist

Before any config edit:

1. **Identify the SSoT** — which of the 3 locations owns this field?
2. **Check dependents** — grep for consumers (`grep -r "agent_tiers" ~/jarvis/infra/`)
3. **Back up** — `cp file file.bak-$(date +%Y%m%d_%H%M%S)`
4. **Validate** — `python3 -m json.tool file > /dev/null`
5. **Regenerate derived docs** — `node ~/jarvis/infra/scripts/gen-tasks-index.mjs` if touching tasks.json
6. **Smoke test** — run one affected task manually before the next cron tick
