# Changelog

All notable changes to the Jarvis project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/).

---

## [Unreleased]

### Added
- Bot stability hardening + RAG upsert optimization + 11-team system
- Board meeting parallelization (`parallel-board-meeting.sh`)
- Episodic memory search quality improvements (Windsurf Memories Phase 2/3-B)
- RAG embedding migration: OpenAI → local model (zero cost)
- Dev runner async queue (`dev-runner.sh`) + webhook listener
- Session resume support (`LT-4`)
- Per-team model separation (`LT-2`)
- Demo GIF auto-generation + README embed
- OSS Phase 2: personalization code separation
- OSS Phase 1: dependency layering + onboarding UX
- JIRA career history sync + SQLite WAL auto-optimization
- PDF attachment processing + session auto-compact
- Recon team enhancement
- Windows setup guide + one-click install script (`setup.ps1`)
- Cross-platform compatibility (Linux/Docker)

### Fixed
- Episodic memory dead code → actual invocation path
- ShellCheck high-priority 3 issues (auditor 2026-03-16)
- `webhook-listener` emit-event.sh path (`bin/` → `scripts/`)
- `dev-run-async` cron ID mismatch — `bot-cron.sh` aliases support
- Haiku model ID date normalization + XML 4-Block for 3 teams
- LanceDB warning threshold 500MB → 1GB
- E2E RAG test daily failure
- `stat -f %z` cross-platform bug + compat checker
- Windows `setup.ps1` critical 5 bugs
- Dockerfile `lib/` dependency access
- Cross-platform fallback for `stat -f` (Linux/Docker)
- Auto-compact token accumulation + PDF processing bugs
- Secrets removed from GitHub Actions `if` conditions

### Changed
- Agent SDK updated to 0.2.76
- Bot-cron.sh now supports task aliases
- Council-insight context refreshed

---

## Versioning Note

Jarvis uses continuous deployment. This changelog groups changes by theme rather than semantic version numbers. For the full commit history, see `git log`.
