# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| latest  | ✅ |

## Reporting a Vulnerability

If you discover a security vulnerability in Jarvis, please **do not** open a public GitHub issue.

Instead, report it via one of these methods:

1. **GitHub Private Advisory**: [Security tab → Report a vulnerability](../../security/advisories/new)
2. **Email**: Contact the maintainer through the GitHub profile

### What to include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (optional)

### Response timeline

- Acknowledgement within **48 hours**
- Status update within **7 days**
- Fix or mitigation within **30 days** for critical issues

## Security design notes

- All credentials are stored in `.env` files (never committed to git)
- `discord/.env` and `config/monitoring.json` are `.gitignore`d
- The bot runs locally; no credentials are transmitted to external servers except Discord/OpenAI APIs
- `claude -p` runs as the local user — no elevated privileges required
