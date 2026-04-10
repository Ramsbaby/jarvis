# Company Agent Teams

> Back to [docs/INDEX.md](INDEX.md) | [README](../README.md)

A virtual organization of 12 AI teams. Each team runs as a scheduled `claude -p` session, produces a report, and posts it to its designated Discord channel.

---

## Team Overview

| # | Team | Role | Schedule | Discord | Output |
|---|------|------|----------|---------|--------|
| 1 | **Council** | Executive oversight, cross-team review | Daily 23:05 | `#jarvis-ceo` | KPI analysis, executive report |
| 2 | **Infra** | System health, service monitoring | Daily 09:00 | `#jarvis-ceo` | Infrastructure report |
| 3 | **Trend** | News, tech trends, market signals | Daily 07:50 | `#jarvis` | Morning briefing |
| 4 | **Record** | Daily activity logging, archival | Daily 22:30 | `#jarvis-ceo` | Internal archive |
| 5 | **Brand** | Content strategy, OSS growth | Weekly Tue 08:00 | `#jarvis-ceo` | Brand report |
| 6 | **Career** | Job market analysis, skill tracking | Weekly Fri 18:00 | `#jarvis-dev` | Growth report |
| 7 | **Academy** | Study curation, learning goals | Weekly Sun 20:00 | `#jarvis-ceo` | Learning digest |
| 8 | **Finance** | Stock/ETF monitoring | Daily Mon-Fri 08:00 | `#jarvis-ceo` | Market report |
| 9 | **Recon** | Deep research on demand | Weekly Mon 09:00 | `#jarvis-ceo` | Intelligence report |
| 10 | **Security-Scan** | Codebase security audit | Daily 02:30 | `#jarvis-system` | Vulnerability report |
| 11 | **Standup** | Owner-aware morning briefing | Daily 09:15 | `#jarvis` | Daily standup |
| 12 | **CEO Digest** | Weekly CEO review | Weekly Mon 09:00 | `#jarvis-ceo` | Weekly digest |

---

## Team Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Council (Oversight)                       │
│  Sub-agents: kpi-analyst, log-analyst                       │
│  Reads all team outputs, detects cross-team issues          │
├─────────┬──────────┬──────────┬──────────┬──────────────────┤
│  Infra  │  Trend   │  Record  │  Brand   │  Career/Academy  │
│  Daily  │  Daily   │  Daily   │  Weekly  │  Weekly          │
└─────────┴──────────┴──────────┴──────────┴──────────────────┘
              Finance · Recon · Security-Scan · Standup
```

---

## Team Definitions

Each team is defined in `teams/{team_name}/`:

```
teams/council/
├── team.yml      # Config: name, taskId, discord, model, tools, agents
├── system.md     # System prompt (personality, role, constraints)
└── prompt.md     # Task-specific prompt template
```

### team.yml Format

```yaml
name: "팀 이름"
taskId: council-insight     # maps to config/tasks.json ID
discord: jarvis-ceo         # Discord channel name
maxTurns: 40                # max agent turns
model: large                # large (Sonnet) | small (Haiku)
tools: [Read, Write, Glob]  # allowed tools
agents:                     # optional sub-agents
  kpi-analyst:
    description: "..."
    tools: [Read, Glob]
```

---

## Board Meeting System

CEO agent runs twice daily (08:10, 21:55) with data pre-collected by bash:

**Outputs:**
- `state/context-bus.md` — Cross-team summary (read by all cron tasks)
- `state/board-minutes/{date}.md` — Meeting minutes
- `state/decisions/{date}.jsonl` — Decision audit log
- `config/goals.json` — OKR KR progress auto-update

**Decision Dispatcher** (`bin/decision-dispatcher.sh`) auto-runs after each meeting:
- Actionable decisions → execute immediately
- Report-only decisions → flag for human review
- Updates `state/team-scorecard.json` (merit/penalty system)

---

## Cross-Team Communication

| Channel | Direction | Purpose |
|---------|-----------|---------|
| `state/context-bus.md` | Council → All | Broadcast summaries |
| `rag/teams/shared-inbox/` | Teams → Council | Urgent escalations |
| `state/connections.jsonl` | System | Cross-team signal tracking |

---

## Reports & Storage

All reports are saved to `rag/teams/reports/{team}-{date}.md` and:
1. Indexed by RAG engine (searchable via `/search`)
2. Synced to Obsidian Vault (`$VAULT_DIR/03-teams/{team}/`)
3. Retained per `resultRetention` config (7-365 days)
