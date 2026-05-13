---
name: jarvis-goal
description: Goal-driven autonomous execution with completion-condition gating and built-in irreversibility guard. Port of Anthropic /goal (Claude Code v2.1.139) that automatically pauses for explicit user approval when detecting unrecoverable operations — git push, repo visibility changes, payment, secret exposure, mass data deletion.
license: MIT
---

# /goal — Goal-Driven Autonomous Execution

Set a measurable completion condition once; the agent self-verifies every turn until the condition is met, then declares done with evidence.

## How it works (4 stages)

1. **Parse completion condition** → normalize to a verifiable predicate
2. **Per-turn self-check** → after each action, ask "is the condition met?" using actual tool output, not assumption
3. **Auto-continuation** → if not met, continue without waiting for Stop hook
4. **Stop on success** → declare completion citing real command output as evidence

Example inputs:
- `/goal all crons sustained ≥ 95% success over 7 days`
- `/goal /verify 7-gate all PASS`
- `/goal rag indexing complete + integrity check passes`

## ⚠️ Irreversibility Guard (auto-pause triggers)

Autonomous execution pauses and requests explicit user approval when detecting:
- `git push`, `git push --force`
- Repo visibility changes, deletion, archival (`gh repo edit --visibility`, `gh repo delete`, `gh repo archive`)
- External message dispatch (Slack, email, Discord public channels, push notifications)
- Payment, financial transfer, asset movement, trade execution
- Secret or PII exposure to external systems
- Irreversible system changes (production DB schema, mass data deletion, cron mass disable)
- `rm -rf`, `DROP TABLE`, `TRUNCATE`

Pause format:
> "Irreversible operation detected: [name]. Scope: [blast radius]. Approve to proceed?"

## Differentiation vs. Anthropic /goal

- Built-in irreversibility guard with explicit pause behavior (the official command has no such guard)
- Optional ledger integration for token accounting per goal
- Composable with `/verify` and `/doctor` for complex condition predicates

## Self-check (before declaring completion — BLOCKING)

1. Did I confirm the evidence via actual tool output, not assumption?
2. Have I triggered any irreversibility guard pattern unintentionally?
3. Did I avoid declaring completion based on partial metrics (e.g., only load average without memory/disk)?
4. Have I considered at least three alternative hypotheses for any failure I diagnosed?

If any answer is unclear, mark "in progress — verification pending" instead of "done".

## Limitations

- Ambiguous conditions are unverifiable — input must be a measurable predicate, ambiguity prompts immediate clarification request
- One active goal per session
- Requires Claude Code v2.1.139+ (Research Preview)

## Related skills

- `/verify` — 7-gate verification harness (used when completion condition needs deep audit)
- `/doctor` — system-wide health check (used for global-metric conditions)
- `/investigate` — root-cause tracing when completion fails repeatedly
