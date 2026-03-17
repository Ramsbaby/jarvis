# Demo Recording Guide

The `demo.gif` in README is a visual walkthrough of the bot in action. This file documents how to create it.

## Quick Start (Recommended: asciinema + svg-term)

```bash
# 1. Install tools
npm install -g asciinema svg-term

# 2. Start recording
asciinema rec docs/demo.cast

# 3. Run the demo script (60 seconds)
# Simulate:
#   - User typing in Discord
#   - git clone https://github.com/Ramsbaby/claude-discord-bridge ~/.jarvis
#   - cd ~/.jarvis && npm install (fast-forward with Ctrl+L)
#   - cp discord/.env.example discord/.env
#   - cat discord/.env (show config)
#   - node discord/discord-bot.js (bot starting)
#   - Discord message arrives: "what's the system status?"
#   - Bot searches RAG, runs health check
#   - Bot replies in Discord thread with summary

# 4. End recording (Ctrl+D)

# 5. Convert to GIF
svg-term --cast docs/demo.cast --out docs/demo.gif --window --width 120 --height 30
```

## Alternative: OBS Screen Recording

```bash
# 1. Open OBS
# 2. Add display capture (1280x720)
# 3. Run the demo script in terminal
# 4. Record for ~60 seconds
# 5. Export as MP4
# 6. Convert to GIF
ffmpeg -i demo.mp4 -vf "scale=1280:-1" docs/demo.gif
```

## Minimal Option: Static Screenshots

If GIF creation is challenging, three PNG images work fine:

```
docs/demo-01-setup.png        # git clone + npm install
docs/demo-02-chat.png         # Real-time Discord interaction
docs/demo-03-cron.png         # Automated cron task output
```

Add to README:
```markdown
<p align="center">
  <img src="docs/demo-01-setup.png" width="600" alt="Setup"><br/>
  <img src="docs/demo-02-chat.png" width="600" alt="Chat"><br/>
  <img src="docs/demo-03-cron.png" width="600" alt="Automation">
</p>
```

## File Location

Place final GIF at: `/docs/demo.gif`

This matches the existing README reference:
```markdown
![Jarvis demo](docs/demo.gif)
```

---

**Status:** Placeholder added 2026-03-17. To be recorded by owner.
