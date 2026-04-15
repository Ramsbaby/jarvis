Data privacy comes first, always.

All user-facing command line output should make use of emojis for visual hierarchy.

## AI Navigation (Start Here)

Any AI agent or human touching this repo for the first time should read in this order:

1. **[infra/docs/MAP.md](infra/docs/MAP.md)** — 1-minute entry point: purpose, layout, subsystems, "where to find what"
2. **[infra/docs/TASKS-INDEX.md](infra/docs/TASKS-INDEX.md)** — Auto-generated catalog of 82 scheduled tasks, grouped by team
3. **[infra/docs/TEAMS-CRONS.md](infra/docs/TEAMS-CRONS.md)** — Reverse index: team → owned crons
4. **[infra/docs/CONFIG.md](infra/docs/CONFIG.md)** — Config inventory and safe-edit checklist
5. **[infra/docs/ARCHITECTURE.md](infra/docs/ARCHITECTURE.md)** — Deep design (message flow, Discord runner, session mgmt)
6. **[infra/docs/OPERATIONS.md](infra/docs/OPERATIONS.md)** — Incident response, cron schedules, log paths

Regenerate `TASKS-INDEX.md` + `tasks-index.json` after any `~/.jarvis/config/tasks.json` change:

```bash
node ~/jarvis/infra/scripts/gen-tasks-index.mjs
```

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

## Surface Memory Boundary — 표면 통합 메모리 경계

**원칙**: Jarvis는 **뇌 하나**(`~/.jarvis/wiki/` + RAG + memory files). 여러 표면(디스코드/Claude Code CLI/macOS 앱)은 그 뇌의 입·출력 단말일 뿐. 읽기는 표면 무관하게 공유되고, 쓰기도 동일한 저장소로 수렴한다.

### 표면별 역할과 기억 기여 방식

| 표면 | 읽기 | 쓰기(자동) | 쓰기(수동) | 권장 용도 |
|---|---|---|---|---|
| **디스코드 봇** | ✅ RAG + 위키 | ✅ `autoExtractMemory → wikiAddFact` (turn 단위) | ✅ `/remember` | 일상 질의, 가족 대화, 모바일 |
| **Claude Code CLI** | ✅ RAG + 위키 + MEMORY.md | ✅ `stop-wiki-ingest.sh` (세션 종료 단위, Phase 1) | ✅ `/remember` (MCP `wiki_add_fact`) | **기억 누적이 필요한 작업** (코드, 설계, 운영) |
| **Claude macOS 앱** | ✅ RAG + 위키 (MCP nexus 로드 시) | ❌ 원리상 불가 (대화 이력이 claude.ai 서버 전용, 로컬 히스토리 없음) | ✅ `/remember` (**유일한 기억 입금 창구**) | 즉석 질의, 외출 중 빠른 대화 |

### 사용 규칙

- **기억이 쌓여야 하는 작업은 Claude Code CLI**에서 한다 — 세션 종료 자동 주입 + RAG 증분 인덱싱이 보장됨.
- **macOS 앱에서 중요한 결정·사실이 나오면 반드시 `/remember`**로 명시적 주입. 그렇지 않으면 대화 종료와 함께 휘발.
- **디스코드는 이미 turn 단위 자동 주입** 중이므로 `/remember` 호출 불필요 (단, 긴 대화에서 핵심만 추려 명시적으로 남기고 싶을 때는 사용 가능).

### 쓰기 경로 요약 (DRY · SSoT)

```
[Discord]     autoExtractMemory ──┐
[CLI 자동]    stop-wiki-ingest ───┼──► addFactToWiki(source:X)
[모든 표면]   MCP wiki_add_fact ──┘         │
                                            ▼
                                  ~/.jarvis/wiki/{domain}/_facts.md
                                  (SSoT, source 태깅으로 감사 가능)
```

- **Extractor는 여러 개** (LLM 프롬프트가 표면·맥락마다 다름) — 정당한 diversity.
- **Trigger는 표면별** (훅/턴/수동) — 본질적으로 다른 인터페이스이므로 DRY 위반 아님.
- **Store는 하나** (`addFactToWiki`) — 여기가 SSoT. 중복 체크는 source 무관, 첫 주입이 승.
- **Source 태깅** (`[source:X]`) — 나중에 "어느 표면에서 쌓인 기억인가" 감사 필수.

## Git

Commit messages: conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`)
