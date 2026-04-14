# Jarvis — Style & Conventions

## Shell scripting (primary language)

### Mandatory header
```bash
#!/usr/bin/env bash
set -euo pipefail
```

### Quoted variables always
```bash
echo "$var"               # OK
cp "$src" "$dst"          # OK
for x in "${arr[@]}"; ... # OK (배열도 쿼팅)

echo $var                 # 금지 (단어분리/glob)
```

### Anti-pattern: set -e + `[[ ]] && cmd`
**금지**:
```bash
set -e
[[ -f file ]] && do_something  # FAILS silently in some cases
```
**올바름**:
```bash
if [[ -f file ]]; then
    do_something
fi
```

(post-edit-lint.sh hook가 자동으로 잡음)

### Temp file handling
```bash
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
```

### Error handling
```bash
command || { echo "[ERROR] command failed" >&2; exit 1; }
command || true   # 정말 무시해야 할 때만 (남용 금지)
```

### Logging pattern
```bash
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log "단계 시작"
```

### `claude -p` 호출
**금지**: `claude -p ...` (timeout 없이 직접 호출)
**필수**: `timeout 180 claude -p ...` 또는 `_safe_claude` 사용 (`source lib/common.sh`)

(post-edit-lint.sh가 검사)

## 파일/스크립트 명명 규칙

`[도메인]-[대상]-[동작]` 패턴:
- `discord-bot-restart.sh`
- `jarvis-cron.sh`
- `bot-watchdog.sh`
- `rag-index.mjs`
- `alert-send.sh`

도메인 키워드: `discord`, `jarvis`, `watchdog`, `rag`, `alert`

## LaunchAgent plist 명명
`ai.jarvis.<service-name>` 패턴
- 예: `ai.jarvis.discord-bot`, `ai.jarvis.serena-mcp`, `ai.jarvis.watchdog`

## Time / Timezone
- 모든 시간은 **KST (UTC+9)**로 표기. UTC 금지.
- 로그/리포트/일정 모두 KST.
- 코드 내부에서는 UTC ISO 8601 (`date -u +%FT%TZ`) 사용 후 표시 시 KST 변환.

## Markdown / 한국어
- 사용자 facing 출력은 한국어 우선 (Discord 알림, 리포트)
- 코드 주석은 한글/영어 혼용 가능
- 이모지 적극 사용 (시각적 계층)

## Soft 정책 (CLAUDE.md 최상위)

1. **빈 사과 금지** — "죄송합니다" 류 응답 금지. 사실 정정만.
2. **땜질식 수정 금지** — root cause + blast radius + recurrence guard 3-자문 필수.
3. **시스템적 방어 우선** — 1회용 스크립트는 최후 수단.
4. **큰 틀 먼저** — 작업 착수 전 시스템 전체 위치 자문.

## Node.js (Discord bot, RAG)
- ESM (`type: "module"` in package.json)
- `import` only, no `require`
- File extensions explicit (`./foo.mjs`)
- prefer `node:fs` over `fs`

## Python (utilities, voice agent)
- Python 3.12+
- venv at `~/jarvis/venv` (voice assistant)
- 한국어 docstring 가능
