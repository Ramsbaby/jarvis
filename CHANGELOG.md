# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased] — 2026-05-13

**Scope**: Claude Code marketplace launch + 5 atomic commits (`c6493b1` → `4a817fa` → `c1022eb` → `3fc0d73` → `c426c68`)

### Added

- **`jarvis-skills` Claude Code plugin marketplace** at `.claude-plugin/marketplace.json` — registers 3 plugins for distribution via `/plugin marketplace add Ramsbaby/jarvis`.
- **`plugins/jarvis-goal`** — Goal-driven autonomous execution with built-in irreversibility guard. Port of Anthropic `/goal` (Claude Code v2.1.139) that auto-pauses on git push, repo visibility changes, payment, secret exposure, or mass data deletion. Adds completion-evidence self-check absent from the official command.
- **`plugins/jarvis-deep-interview`** — Convergent Socratic interview that narrows vague requirements into a production spec via 8-15 rounds with mathematical ambiguity gating + Contrarian/Simplifier Challenge Mode + JSONL decision log. Inspired by Sorbh/interview-me.
- **`plugins/jarvis-plan-review`** — 11-section rigorous design plan review (problem framing, scope, architecture, security, observability, deployment, performance, reliability, testing, maintainability, migration) adapted from gstack `/plan-ceo-review` for sole-developer + AI-pair-programming workflows.
- **`infra/bin/claude-xhigh.sh`** — Wrapper that starts Claude Code with `--effort xhigh` (Opus 4.7 only) for skills where reasoning depth is decisive. Includes model + CLI-version guards.
- **`xhigh` effort guidance** inserted into `/verify` and `/plan-review` skill bodies (5 lines each).
- **`LLM_EFFORT` env-var branch in `infra/lib/llm-gateway.sh`** — propagates `--effort` flag to claude CLI when caller sets `LLM_EFFORT=xhigh`.
- **README marketplace banner** in English + Korean READMEs pointing to `/plugin marketplace add Ramsbaby/jarvis`.
- **Plugin standard structure adoption** — each plugin migrated from flat `plugins/<name>/SKILL.md` to canonical `plugins/<name>/.claude-plugin/plugin.json` + `plugins/<name>/skills/<name>/SKILL.md` layout per `code.claude.com/docs/en/plugins`.
- **Submitted all 3 plugins** to Anthropic's official Plugin Directory via `claude.ai/settings/plugins/submit` (status: 제출됨 및 검토 대기 중).

### Changed

- **`infra/lib/llm-gateway.sh` batch mode**: added `--exclude-dynamic-system-prompt-sections` to the claude CLI argument list — moves per-machine prompt sections to the first user message, materially improving cross-user prompt-cache prefix reuse for every cron task. (Option was documented in comments but missing from the actual `cmd+=(...)` array.)
- **`.privacy-blocklist.yml`** github-username rule `allow_paths` extended to cover `.claude-plugin/marketplace.json` and `plugins/**/.claude-plugin/plugin.json` — these contain the intentional public homepage URL for the OSS marketplace.

### Fixed

- **Persona scrub** in `infra/bin/claude-xhigh.sh` and `infra/lib/llm-gateway.sh` (commit `4a817fa`) — first marketplace push (`c6493b1`) leaked 24 lines of Korean persona / `~/jarvis/...` absolute paths discovered by post-publication audit, contradicting `marketplace.json`'s `"personaScrub": "complete"` declaration (Iron Law 2 integrity violation). Follow-up commit restored honesty: all public-facing comments and stderr messages are now English-only. Korean-persona variants remain in maintainer-private `~/.claude/skills/` (gitignored).
- **Orphaned flat-layout SKILL.md files** removed (commit `c426c68`) — initial standard-structure migration (`3fc0d73`) duplicated SKILL.md at both old and new paths because `git commit --only` did not capture the rename's delete side.

### Verified

- **Public audit (Iron Law 6)**: independent agent fetched all 7 published files via `gh api ...?ref=<commit>` and grep'd line-by-line for PII / secrets / persona leaks / jarvis-internal paths. Final state at `c426c68` and `4a817fa`: 0 violations (verified by external 200/404 responses, not assumed).
- **Form submission** (Iron Law 6): 3 plugins all visible at `claude.ai/settings/plugins/submissions` as "제출됨 및 검토 대기 중" (Submitted, Pending Review) — verified by screen capture, not assumed.

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
