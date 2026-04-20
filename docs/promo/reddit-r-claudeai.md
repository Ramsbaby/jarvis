# Reddit r/ClaudeAI 포스트

> 제출 URL: https://www.reddit.com/r/ClaudeAI/submit

## Title
I built a self-healing AI platform that runs 99 automation scripts on Claude — zero API charges

## Body

I've been running **Jarvis** on my Mac Mini 24/7 for 3 months. It's an AI operations platform built on Claude that manages itself while I sleep.

**What it does:**
- **Discord bot** with voice recognition (Whisper STT) — talk to Claude naturally
- **RAG knowledge base** — 10,000+ documents, hybrid BM25 + vector search
- **Insight Layer** — daily behavioural analysis that detects what I'm focused on (e.g., "topic X surged 534x this week, focus shifted from infrastructure to another domain")
- **99 automation scripts** with 4-layer self-recovery — if a service crashes, it's back within 3 minutes
- **Dev-Queue** — AI extracts action items from task results, then autonomously executes them via Claude
- **8 AI agent teams** — specialised agents for infrastructure, growth, code review, etc.
- **Multi-user** with family privacy mode — each Discord user gets isolated memory, family channels filter out sensitive data
- **Board Meeting AI** — 4 AI agents convene daily for system-level decisions

**The insight layer is the part I'm most proud of.** Instead of just storing memories like ChatGPT/Claude, Jarvis computes metrics from its RAG database (topic frequency trends, entity momentum, cross-domain correlations) — all without an LLM call ($0). Then Claude interprets the numbers once daily (~$0.03). The result is a ~1.2KB report that's loaded into every system prompt, giving Claude situational awareness.

**Cost: $0.** Everything runs via `claude -p` (Claude Max subscription). No per-token API charges.

**Stack:** Node.js, LanceDB, Ollama (snowflake-arctic-embed2), Discord.js, 11 LaunchAgents, 40+ cron jobs

**Open source (MIT):** https://github.com/Ramsbaby/jarvis

Happy to answer questions about the architecture or share specific automation scripts.
