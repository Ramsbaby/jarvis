Data privacy comes first.

구조·크론·설정은 `infra/docs/MAP.md`부터 본다. 면접봇은 `infra/docs/INTERVIEW-BOT.md`.
`runtime/config/tasks.json` 변경 후 `node infra/scripts/gen-tasks-index.mjs`.

## Development Rules

- 사용자 경로·시크릿 하드코딩 금지 — `BOT_HOME`·`JARVIS_RAG_HOME`·`.env`
- 언어 패턴 하드코딩 금지 — 프롬프트는 언어 중립으로
- 셸: `set -euo pipefail`, 변수 쿼팅, trap 정리. macOS엔 `flock`·`md5sum`·`gtimeout`이 기본 PATH에 없다 — 크론 스크립트는 PATH를 명시한다
- 명명: `[도메인]-[대상]-[동작]`
- 3파일 이상 편집·구조 변경 전 `scripts/pre-edit-scan.sh`, 경로 불확실하면 `scripts/ssot-path-guard.sh --all <파일명>`
- Conventional commits: `feat:` `fix:` `refactor:` `docs:` `chore:`

## 프롬프트 SSoT — 표면마다 다른 파일을 읽는다

| 표면 | SSoT |
|---|---|
| Claude Code CLI (앱에서 `claude rc` 원격 접속 포함) | `~/.claude/rules/jarvis.md` + paths 게이트 파일 |
| 디스코드 봇 | `runtime/context/owner/persona-discord.md` · 감정 턴은 `persona-discord-emotional.md`가 **통째로 대체**한다 |
| claude.ai 앱 직접 사용 | 서버가 프롬프트를 쥔다 — Jarvis 통제 불가 |

말투·응답 규칙은 CLI와 디스코드 **양쪽에** 등재한다. 한쪽만 고치면 표면별로 다른 답이 나온다.
감정 턴 파일은 안전 규칙을 상속하지 않으므로, 금액·검증 규칙을 고칠 때 별도로 확인한다.
