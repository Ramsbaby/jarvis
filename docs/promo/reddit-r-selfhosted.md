# Reddit r/selfhosted 포스트

> 제출 URL: https://www.reddit.com/r/selfhosted/submit

## Title
Jarvis — self-hosted AI operations platform that runs 24/7 and heals itself (Discord bot + RAG + 99 automation scripts)

## Body

After 3 months of daily use on my Mac Mini, I'm open-sourcing my AI operations platform.

**The pitch:** An AI assistant that doesn't just chat — it manages infrastructure, analyses your behaviour, writes code, and restores crashed services automatically.

**Self-hosted highlights:**
- 100% local. No cloud services needed (except Claude subscription for LLM)
- LanceDB for vector storage — embedded, no server
- Ollama for embeddings — local, free
- 11 macOS LaunchAgents for daemon management
- 40+ cron jobs for scheduled automation
- 4-layer self-recovery: watchdog → process recovery → cron auditor → auto-diagnose

**Discord is the UI:**
- 16+ slash commands
- Voice messages → Whisper STT → Claude response
- Per-channel AI personas
- Multi-user with privacy boundaries (family mode)
- Interactive buttons (cancel, regen, approve/reject)

**The cool parts:**
- Insight Layer: daily behavioural metrics analysis (LLM-free, $0) → Claude interprets → situational awareness in every response
- Dev-Queue: AI extracts tasks → auto-executes code → commits
- Board Meeting AI: 4 agents convene daily for system-level decisions

**Stack:** Node.js 18+, Ollama, Discord.js, LanceDB, macOS LaunchAgents

**Requirements:** Mac/Linux, Node.js, Ollama, Discord bot token

MIT License: https://github.com/Ramsbaby/jarvis
