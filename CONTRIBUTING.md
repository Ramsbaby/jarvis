# Contributing to Jarvis

Thanks for your interest in contributing!

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/jarvis ~/.jarvis   # YOUR_USERNAME = your GitHub username after forking Ramsbaby/jarvis
cd ~/.jarvis
./bin/jarvis-init.sh   # Interactive setup wizard
```

## Development Guidelines

### Shell Scripts
- Always use `set -euo pipefail`
- Quote all variables: `"$var"`
- Use `trap` to clean up temp files
- Follow naming: `[domain]-[target]-[action].sh`

### Code Style
- **SSoT**: Don't duplicate information across files
- **DRY**: Extract functions after 3+ repetitions
- **Max file size**: 1,500 lines per file

### Creating a Plugin

```bash
mkdir -p plugins/my-plugin
cat > plugins/my-plugin/manifest.json << 'EOF'
{
  "id": "my-task",
  "name": "My Custom Task",
  "schedule": "0 9 * * *",
  "prompt": "Your task prompt here",
  "allowedTools": "Read,Bash",
  "timeout": 120,
  "output": ["file"],
  "tags": ["company"]
}
EOF
# Optional: add plugins/my-plugin/context.md for task-specific context
```

Run `bin/plugin-loader.sh --validate` to verify.

### Architecture Decisions

For significant changes, create an ADR in `adr/`:
1. Copy the template from existing ADRs
2. Document context, decision, alternatives, and consequences
3. Add to `adr/ADR-INDEX.md`

## Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make your changes
4. Run `scripts/e2e-test.sh` to verify
5. Submit a pull request

## Reporting Issues

Use the [issue templates](.github/ISSUE_TEMPLATE/) — include logs from `~/.jarvis/logs/` when reporting bugs.
