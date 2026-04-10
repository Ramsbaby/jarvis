# Jarvis Documentation

> Central navigation hub for all Jarvis documentation.

---

## Getting Started

| Document | Description |
|----------|-------------|
| [README](../README.md) | Project overview, quick start, configuration |
| [INSTALL.md](../INSTALL.md) | Detailed installation guide |
| [discord/SETUP.md](../discord/SETUP.md) | Discord bot setup walkthrough |

## Architecture & Design

| Document | Description |
|----------|-------------|
| [SYSTEM-OVERVIEW.md](SYSTEM-OVERVIEW.md) | **🤖 자동 생성** — 5층 구조, 7팀, 특장점, 한계, 로드맵, 현재 상태 (매일 04:05 갱신) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture, message flow, Nexus CIG, self-healing |
| [ADR Index](../adr/ADR-INDEX.md) | Architecture Decision Records (ADR-001 ~ ADR-010) |
| [DEPENDENCY-ANALYSIS.md](DEPENDENCY-ANALYSIS.md) | Module dependency analysis |

## Operations

| Document | Description |
|----------|-------------|
| [OPERATIONS.md](OPERATIONS.md) | Cron schedules, monitoring, incident response, log locations |
| [TEAMS.md](TEAMS.md) | 11 AI teams — roles, schedules, outputs, Discord channels |

## Project Management

| Document | Description |
|----------|-------------|
| [CHANGELOG.md](../CHANGELOG.md) | Release history and notable changes |
| [ROADMAP.md](../ROADMAP.md) | Planned features and milestones |

## Developer Reference

| Document | Description |
|----------|-------------|
| [API.md](API.md) | Core module public APIs (task-store, rag-engine, scripts) |
| [EXAMPLES.md](EXAMPLES.md) | Real-world usage examples (calendar, dev-runner, plugins, RAG) |
| [FAQ.md](FAQ.md) | Frequently asked questions (install, debug, calendar, open-source) |

## Contributing

| Document | Description |
|----------|-------------|
| [CONTRIBUTING.md](../CONTRIBUTING.md) | How to contribute |
| [LICENSE](../LICENSE) | MIT License |

---

## Quick Links

- **Config files**: `config/tasks.json`, `config/monitoring.json`
- **Team definitions**: `teams/{team_name}/team.yml`
- **Agent profiles**: `agents/*.md`
- **E2E tests**: `scripts/e2e-test.sh` (60+ checks)
