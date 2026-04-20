# awesome-claude-code 이슈 제출용

> 제출 URL: https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml
> 주의: GitHub 웹 UI에서만 제출 가능 (CLI 금지)

## 폼 입력값

**Display Name**: Jarvis

**Category**: Tooling

**Sub-Category**: Tooling: Orchestrators

**Primary Link**: https://github.com/Ramsbaby/jarvis

**Author Name**: Ramsbaby

**Author Link**: https://github.com/Ramsbaby

**License**: MIT

**Description**:
A self-healing AI operations platform built on Claude Code. Discord bot with voice recognition (Whisper STT), RAG knowledge base (LanceDB hybrid search), daily behavioural insight reports (metrics-driven, $0 LLM-free analysis + Claude interpretation), 99 automation scripts with 4-layer self-recovery, Dev-Queue for autonomous code execution, 8 specialised AI agent teams, multi-user support with family privacy mode, and Board Meeting AI (CEO + 3 agents). Runs 24/7 on a single Mac Mini with zero API charges via claude -p subscription.

**Validate Claims**:
Clone the repo and run `python scripts/setup_rag.py` to set up the RAG module. Then run `cd rag && BOT_HOME=~/.jarvis node bin/insight-metrics.mjs` to see the LLM-free behavioural metrics collector in action — it analyses LanceDB chunks for topic frequency trends, entity momentum, and cross-domain correlations without any API calls.

**Specific Task(s)**:
1. Run the insight metrics collector: `cd rag && BOT_HOME=~/.jarvis node bin/insight-metrics.mjs` — verify topic frequency trends and entity momentum are computed from your indexed documents
2. Run a RAG search: `cd rag && npm run query -- "your search query"` — verify hybrid BM25+vector search returns relevant results
3. Check the self-healing scripts: `ls infra/scripts/ | wc -l` — confirm 80+ automation scripts exist

**Specific Prompt(s)**:
After setup, run `BOT_HOME=~/.jarvis node rag/bin/insight-metrics.mjs | head -30` and observe the topic trend analysis output. No LLM required — pure data analysis on your indexed chunks.

**Additional Comments**:
Jarvis started as a personal AI assistant and evolved into a full operations platform. Key differentiator from other Claude Code projects: it doesn't just assist — it autonomously manages infrastructure, writes code via Dev-Queue, and heals itself when services crash. The insight layer detects behavioural patterns (e.g., "topic X surged ~100x this week") and injects situational awareness into every Claude response. Built and battle-tested on a Mac Mini running 24/7 for 3+ months.
