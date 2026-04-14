Data privacy comes first, always.

All user-facing command line output should make use of emojis for visual hierarchy.

## AI Navigation (Start Here)

Any AI agent or human touching this repo for the first time should read in this order:

1. **[infra/docs/MAP.md](infra/docs/MAP.md)** — 1-minute entry point: purpose, layout, subsystems, "where to find what"
2. **[infra/docs/TASKS-INDEX.md](infra/docs/TASKS-INDEX.md)** — Auto-generated catalog of 82 scheduled tasks, grouped by team
3. **[infra/docs/TEAMS-CRONS.md](infra/docs/TEAMS-CRONS.md)** — Reverse index: team → owned crons
4. **[infra/docs/CONFIG.md](infra/docs/CONFIG.md)** — Config inventory and safe-edit checklist
5. **[infra/docs/ARCHITECTURE.md](infra/docs/ARCHITECTURE.md)** — Deep design (message flow, Discord runner, session mgmt)
6. **[infra/docs/OPERATIONS.md](infra/docs/OPERATIONS.md)** — Incident response, cron schedules, log paths

Regenerate `TASKS-INDEX.md` + `tasks-index.json` after any `~/.jarvis/config/tasks.json` change:

```bash
node ~/jarvis/infra/scripts/gen-tasks-index.mjs
```

## Project Structure

- `infra/` — Discord bot, automation scripts, MCP nexus, agents
- `rag/` — RAG knowledge base (LanceDB + Ollama hybrid search)
- `scripts/` — Setup wizards (setup_rag.py, setup_infra.py)
- `docs/img/` — README screenshots

## Development Rules

- No hardcoded user paths — use environment variables (`BOT_HOME`, `JARVIS_RAG_HOME`)
- No hardcoded secrets — use `.env` files, never commit tokens/webhooks
- No hardcoded language patterns — keep prompts language-agnostic
- Shell scripts: `set -euo pipefail`, quote all variables, trap cleanup
- Naming: `[domain]-[target]-[action]` (e.g., `rag-index-safe.sh`)

## Git

Commit messages: conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`)
