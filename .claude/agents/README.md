# Claude Code Subagents — `.claude/agents/`

Spawnable subagents for the **Claude Code CLI** (invoked via the Agent tool, or
auto-selected by their `description`). These are distinct from
[`infra/agents/*.md`](../../infra/agents/) — those are personas for Jarvis's own
internal company teams (Board Meeting, cron ops). The agents **here** serve the
**owner's real businesses**.

## Apollo constellation — owner-business chief of staff

| Agent | Lane | Spawn when |
|---|---|---|
| 🎯 [`apollo`](apollo.md) | Cross-domain synthesis / chief of staff | Question spans >1 domain or needs a decision-ready recommendation |
| 🪙 [`heist`](heist.md) | Finance & cash control | Revenue, expenses, cash/runway, withdrawals, taxes |
| 🛠️ [`hustler`](hustler.md) | Business operations | KPIs, bottlenecks, pipelines, vendors (per-business) |
| 📣 [`herald`](herald.md) | Outreach & comms | Outbound campaigns, inbound triage, drafts (never sends) |
| 💻 [`hit`](hit.md) | Technology & systems | Outages, service requests, tooling, security basics |

### Invariants (do not break)

1. **Apollo is a facet of Jarvis, not a separate identity.** Every agent opens by
   binding itself to Jarvis's Iron Laws, SSoT (`CLAUDE.md`), and the
   privacy-first rule. Do not let Apollo announce itself as a rival system or
   override the Jarvis persona.
2. **Guardrails live in config, not in the prompts.** All agents read
   `runtime/private/apollo-owner-prefs.json` first (git-ignored real values;
   falls back to [`infra/config/apollo-owner-prefs.example.json`](../../infra/config/apollo-owner-prefs.example.json)
   and *says so*). Thresholds (min cash buffer, spend approval, businesses, tax
   jurisdiction) are placeholders until that file is filled.
3. **Privacy-first tool scoping.** Specialists are read-only/local. None move
   money, send externally, or make irreversible changes without owner approval.
   Herald drafts only, writing solely to `runtime/private/apollo-drafts/`.
4. **Flat orchestration.** Claude Code subagents cannot nest-spawn each other.
   Apollo synthesizes across the four lenses itself and *flags* when a separate
   deep specialist pass is worth spawning — it does not fake live delegation.

### Setup

Copy the template and fill in real values:

```bash
cp infra/config/apollo-owner-prefs.example.json runtime/private/apollo-owner-prefs.json
# then edit runtime/private/apollo-owner-prefs.json (git-ignored)
```

Until filled, the agents run but treat every threshold as a placeholder.
