# Contributing to Jarvis

Thanks for your interest! Jarvis is a self-healing AI operations platform, and outside contributions — bug fixes, plugins, docs — are welcome.

## Ground Rules

- **No hardcoded user paths** — use environment variables (`BOT_HOME`, `JARVIS_RAG_HOME`).
- **No hardcoded secrets** — use `.env` files; never commit tokens/webhooks.
- **No hardcoded language patterns** — keep prompts language-agnostic.
- **Shell scripts**: `set -euo pipefail`, quote all variables, trap cleanup.
- **Naming**: `[domain]-[target]-[action]` (e.g., `rag-index-safe.sh`).

See [CLAUDE.md](CLAUDE.md) for the full development rules.

## Getting Started

1. Fork and clone the repo.
2. Copy `infra/.env.example` → `infra/.env` and fill in your own tokens (Discord, etc.).
3. Follow the [Quick Start](README.md#quick-start) in the README.

## Pull Requests

1. Create a topic branch: `git checkout -b fix/short-description`.
2. Keep changes **surgical** — touch only what your PR is about.
3. Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.
4. Run `gitleaks detect` before pushing to avoid leaking secrets.
5. Open the PR with a clear description of *what* changed and *why*.

## Reporting Bugs / Ideas

- Bugs → open a [Bug report](https://github.com/Ramsbaby/jarvis/issues/new?template=bug_report.md)
- Features → open a [Feature request](https://github.com/Ramsbaby/jarvis/issues/new?template=feature_request.md)

## Questions

Open a [Discussion](https://github.com/Ramsbaby/jarvis/discussions) — no question is too small.
