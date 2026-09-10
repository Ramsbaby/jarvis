# Jarvis Documentation

> Central navigation hub for all Jarvis documentation.
>
> **🗺️ New here?** Start with **[MAP.md](MAP.md)** — the 1-minute AI entry point.

---

## AI Entry Point (read first)

| Document | Description |
|----------|-------------|
| [MAP.md](MAP.md) | **🗺️ Start here** — purpose · layout · subsystems · where to find what |
| [TASKS-INDEX.md](TASKS-INDEX.md) | **🤖 Auto-generated** — 82 scheduled tasks grouped by team (via `gen-tasks-index.mjs`) |
| [TEAMS-CRONS.md](TEAMS-CRONS.md) | Team → cron reverse index |
| [CONFIG.md](CONFIG.md) | Config inventory + safe-edit checklist |

---

## Getting Started

| Document | Description |
|----------|-------------|
| [README](../../README.md) | Project overview, quick start, configuration |
| [INSTALL.md](INSTALL.md) · [INSTALL.en.md](INSTALL.en.md) | Detailed installation guide |
| [ARCHITECTURE.md](ARCHITECTURE.md#message-flow) | Discord bot message flow (별도 SETUP.md 는 없음 — 2026-08-25 확인) |

## Architecture & Design

| Document | Description |
|----------|-------------|
| `runtime/docs/SYSTEM-OVERVIEW.md` (로컬 전용) | **🤖 자동 생성** — 5층 구조, 팀, 한계, 현재 상태 (매일 04:05). 런타임 상태를 담아 저장소에 포함하지 않는다 — 클론에는 없고 `gen-system-overview.sh` 실행 후 생성된다 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture, message flow, Nexus CIG, self-healing |
| [SELF-HEAL-PLAN-2026-09.md](SELF-HEAL-PLAN-2026-09.md) | 자기 치유·자기 발전 계획 — 9/2 소실·9/4 tasks.json 덮어쓰기 실측 기반. 코더 격리(worktree)·fail-closed 판정·리뷰 크론·사고 원장·지표 5개 |
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
| [CHANGELOG.md](../../CHANGELOG.md) | Release history and notable changes |
| [JARVIS-EVOLUTION-ROADMAP.md](JARVIS-EVOLUTION-ROADMAP.md) | Planned features and milestones (루트 ROADMAP.md 는 존재하지 않아 대체 — 2026-08-25) |

## Developer Reference

| Document | Description |
|----------|-------------|
| [API.md](API.md) | Core module public APIs (task-store, rag-engine, scripts) |
| [CAREER-CHANNEL-MODES.md](CAREER-CHANNEL-MODES.md) | `#jarvis-career` 모드 — 코딩테스트(solve·deep·coach) · **AWS DOP-C02 시험(dop, 정답만)** · 토글 방법 |
| [EXAMPLES.md](EXAMPLES.md) | Real-world usage examples (calendar, dev-runner, plugins, RAG) |
| [FAQ.md](FAQ.md) | Frequently asked questions (install, debug, calendar, open-source) |

## Contributing

| Document | Description |
|----------|-------------|
| [CONTRIBUTING.md](../../CONTRIBUTING.md) | How to contribute |
| [LICENSE](../LICENSE) | MIT License |

---

## Quick Links

- **Config files**: `config/tasks.json`, `config/monitoring.json`
- **Team definitions**: `teams/{team_name}/team.yml`
- **Agent profiles**: `agents/*.md`
- **E2E tests**: `scripts/e2e-test.sh` (60+ checks)
