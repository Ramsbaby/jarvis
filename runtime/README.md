# Runtime Directory

**Private runtime data — 100% git-excluded.**

이 디렉토리는 `~/jarvis/runtime/` 으로 매핑되며 Jarvis의 모든 런타임 데이터를 보관한다:
- `state/` — 봇 세션, 토큰 레저, PID 파일
- `logs/` — 시스템/크론 로그
- `config/` — 개인 설정 (`monitoring.json`, `tasks.json`, `.env` 등)
- `wiki/` — 개인 지식 베이스
- `rag/` — LanceDB RAG DB (~2GB)
- `discord/.env` — Discord 봇 토큰
- `backup/`, `results/`, `reports/` 등

## Git 보호

`.gitignore` 최상단 `/runtime/*` 차단 + `.git/hooks/pre-commit` path guard.
이 디렉토리의 어떤 파일도 `git add`로 스테이징 불가 (이 README + `.gitkeep`만 예외).

## 심링크 호환성

`~/.jarvis` → `~/jarvis/runtime` 심링크는 **2026-10-17까지 유지**.
레거시 코드가 `~/.jarvis/...` 경로로 접근해도 자동 리다이렉트됨.

## Migration

자세한 내용: [../infra/docs/A2-MIGRATION.md](../infra/docs/A2-MIGRATION.md)
