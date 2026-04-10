Data privacy comes first, always.

All user-facing command line output should make use of emojis for visual hierarchy.

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
