# Jarvis Plugins

Each plugin is a directory containing at minimum a `manifest.json`.

## Directory Structure

```
plugins/
  my-task/
    manifest.json     # Required: task configuration
    context.md        # Optional: injected as system prompt
    test.sh           # Optional: self-test (exit 0 = pass)
    README.md         # Optional: documentation
```

## manifest.json Spec

Compatible with tasks.json entry format. Required fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique task identifier |
| `name` | string | Human-readable name |
| `schedule` | string/null | Cron expression or null (manual only) |
| `prompt` | string | LLM prompt |
| `allowedTools` | string | Comma-separated tool list |
| `output` | string[] | Output modes: "discord", "file", "ntfy" |
| `timeout` | number | Max execution seconds |
| `resultMaxChars` | number | Max result length |

Optional fields: `version`, `description`, `model`, `discordChannel`, `retry`,
`maxBudget`, `priority`, `depends`, `contextFile`, `contextBudget`,
`resultRetention`, `requiresMarket`, `tags`

## Tags

- `lite` — included in Lite Mode (basic setup)
- `company` — included in Company Mode (full 7-team orchestration)
- `infra`, `monitoring`, `news`, `market` — category tags

## Installing a Plugin

```bash
# From git
git clone https://github.com/user/jarvis-plugin-name ~/.jarvis/plugins/plugin-name

# Then reload
~/.jarvis/bin/plugin-loader.sh
```
