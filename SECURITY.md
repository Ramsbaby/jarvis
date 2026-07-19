# Security Policy

## Reporting a Vulnerability

Jarvis handles personal data (Discord tokens, RAG memory, API credentials), so security reports are taken seriously.

**Please do NOT open a public issue for security vulnerabilities.**

Instead:
- Open a [private security advisory](https://github.com/Ramsbaby/jarvis/security/advisories/new), or
- Contact the maintainer directly via GitHub ([@Ramsbaby](https://github.com/Ramsbaby)).

Please include:
- A description of the vulnerability and its impact
- Steps to reproduce
- Affected version / commit

You can expect an initial response within **72 hours**.

## Sensitive Areas

Jarvis is a self-hosted personal platform. The most security-relevant areas are:
- `.env` secret handling and token rotation (`infra/scripts/*token*`)
- Discord bot permission boundaries and multi-user isolation
- RAG / wiki memory, which may contain personal information

## Secret Hygiene

- Secrets live in `.env` files and are never committed. See `infra/.env.example`.
- [`gitleaks`](https://github.com/gitleaks/gitleaks) (`.gitleaks.toml`) scans for accidental secret commits.
- If you find a leaked credential in the git history, **report it privately — do not post the value**.
