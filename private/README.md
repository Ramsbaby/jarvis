# Private Directory

This directory is for personal configurations and secrets.
It is entirely gitignored — nothing here will be committed.

## Setup

Copy example files from the repo and customise:

```bash
cp infra/config/user-schedule.example.json private/infra/config/user-schedule.json
cp infra/.env.example private/infra/.env
# Edit with your personal values
```

## Structure

```
private/
├── infra/
│   ├── .env                    # API keys, tokens
│   └── config/
│       ├── user-schedule.json  # Your daily schedule
│       ├── tasks.json          # Your cron tasks
│       ├── goals.json          # Your OKR goals
│       └── secrets/            # Certificates, tokens
├── .gitleaks-personal.toml     # Your personal identifier patterns
└── ...                         # Any other personal files
```
