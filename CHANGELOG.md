# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased] — 2026-04-22 → 2026-05-08

**Scope**: 132 commits · 370 files · +28,680 / −1,761 lines

### Added

- **`/verify` 7-Gate harness with independent auditor Agent** — Production-grade verification skill that delegates audits to a separate Claude context to eliminate same-prior bias. 7 gates (Symptom Root Trace, Assumption Audit, Silent Failure Hunt, Execution Forensics, Blast Radius Map, Regression, Future-State Stress, Observability & Rollback) + Contrarian Challenge.
- **Privacy Guard (pre-push + pre-commit)** — Multi-pattern scanner blocking PII, secrets, career-narratives, financial data, and family identifiers from public-repo pushes. Bypass requires explicit `# privacy:allow <rule-id>` annotation or env-var abstraction (e.g., `process.env.CAREER_DOMAIN_CHANNEL`).
- **OAuth resilience guards (G5/G6)** — `retry-wrapper.sh` detects `AUTH_ERROR` (including `"Invalid API key"`, `"Fix external API key"`, `"Not logged in"` patterns) and triggers `oauth-refresh.sh --force` synchronously before non-retryable fallback. Hourly oauth-refresh cron (2h → 1h) reduces token-expiry race conditions.
- **Self-healing for cron AUTH failures** — 5-stage RECOVERY (original → context_minimal → model_downgrade → prompt_simplified → circuit_breaker) for cron tasks failing on transient auth/rate issues.
- **Schedule Coherence audits** — Validates `tasks.json ↔ LaunchAgent plist ↔ crontab` 3-way drift weekly. Detects orphan tasks, phantom plists, and SSoT divergence.
- **SSoT Cross-Search guard** — Single-file LLM-injected SSoTs (e.g., user-profile.md) must cross-check `wiki/<domain>/_facts.md` before declaring "PENDING" or requesting interviews. Prevents false-PENDING due to surface-file-only reading.
- **Karpathy 4-principles self-audit** — Pre-implementation gate enforcing: assumption explicitness, simplicity-first, surgical changes, goal-driven execution with verification loops.
- **CRON introduction checklist (0순위 지침 3)** — Mandatory 6-section gate before adding new cron/LaunchAgent: Why 1-line, DRY check, frequency downgrade attempt, DRYRUN guard, discord-route severity classification, immediate verification.

### Changed

- **Token-ledger analytics — cumulative-aware aggregation** — `cli-session` entries (written by Claude Code CLI Stop hook) store cumulative session cost on every Stop event. Simple-sum aggregation overcounted by 21–4675×. Reader-side fix: `(window_max − prev_max)` incremental delta. Affected: `llm-cost-cap-monitor.sh`, `session-report.sh`. Real 7-day operating cost: **$9.42** (theoretical API price; Max 20x subscription bills $0).
- **`batch mode` token-saving flags** — `JARVIS_BATCH_MODE=1` cron path now includes `--disable-slash-commands`, `--no-session-persistence`, `--setting-sources ""`, and `--exclude-dynamic-system-prompt-sections` (4th flag added) for cross-user prompt-cache prefix reuse.
- **Cron `claude` binary version** — `bot-cron.sh` PATH order updated: `~/.local/bin` (auto-updating Anthropic install, v2.1.133+) takes priority over `/opt/homebrew/bin` (Homebrew Cask, v2.1.37). Unlocks new CLI flags (e.g., `--exclude-dynamic-system-prompt-sections`) for cron contexts.
- **Discord bot — OAuth-only enforcement** — Removed legacy `ANTHROPIC_API_KEY` fetch branch from `skill-runner.js` (32 lines). Bot environment never set the key (empirically verified); SDK query path was the only active route. Aligns with Iron Law 4 (OAuth-only).

### Fixed

- **morning-standup 5-day silence** — `Invalid API key · Fix external API key` error wasn't classified as `AUTH_ERROR` by `retry-wrapper.sh:130` pattern (missed by `authentication|unauthorized|401` regex), so G5 OAuth-refresh guard never triggered. Pattern extended; subsequent failures auto-recover.
- **Phantom-LA false positives in Schedule Coherence audit** — Plists that don't go through `bot-cron.sh` (e.g., GitHub Actions runner, MCP servers) were flagged as "phantom" when they're legitimate direct-plist agents. Whitelist expanded (Tier 1-6) to distinguish system-core, external-tools, scheduled-reports, and event-watchers.
- **RAG embedding circuit-breaker — zero-vector burst** — RAG restart caused indexer batches to abort with zero vectors before model warmup. Circuit OPEN threshold lowered for early termination.
- **Ledger writer SSoT drift** — `wiki-ingest-claude-session.mjs` writes `source: 'stop-hook'` (cron), but cli-session entries originate from `~/.claude/hooks/session-cost-reporter.sh` (Claude CLI native Stop hook). Documented separation prevents misattribution in audit tools.

### Security

- **Iron Law 4 enforcement — ANTHROPIC_API_KEY eradication** — Removed legacy references from `ai.jarvis.board.plist` (placeholder value), `~/.zshrc` (commented export header), and `infra/discord/lib/skill-runner.js` (active fetch branch — 32 lines). Jarvis is OAuth-only via `~/.claude/.credentials.json`. LLM behavior rules: no env-var inspection, classify any `ANTHROPIC_API_KEY` reference as legacy → remove on sight.
- **Topology Guard pre-commit** — Blocks accidental `.bak` file commits and enforces canonical path conventions (`~/jarvis/runtime/` over deprecated legacy paths).

### Metrics

- 7-day cron LLM cost: **$9.42** (haiku-dominant: `wiki-ingest-claude` $8.11/906 runs, `mistake-extractor` $1.31/519 runs)
- Prompt cache reads (7-day): **39.3 billion tokens** (cache_read >> input by ~20,000×)
- doctor-ledger entries (today, 2026-05-08): 14
- Privacy violations blocked at pre-push: 1 (career-narratives, resolved via env-var abstraction)

---

## How to read this changelog

- **Unreleased** = changes on `main` since the last tagged version (none tagged yet; this is a perpetually evolving operations platform).
- **Date range** in section headers shows the commit window covered.
- Categories follow [Keep a Changelog](https://keepachangelog.com/): Added · Changed · Fixed · Deprecated · Removed · Security.
- For per-commit detail, run `git log --since="YYYY-MM-DD" --oneline`.
