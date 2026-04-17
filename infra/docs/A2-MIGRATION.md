# A2 Runtime Migration (2026-04-17)

Jarvis의 런타임 데이터 위치가 `~/.jarvis/` → `~/jarvis/runtime/` 으로 이동했다.

## 왜 바꿨나

기존 `~/.jarvis/`에 **코드 + 개인정보 + 런타임 로그**가 섞여 있어서:
- git 공개 범위 제어 어려움 (실수로 개인정보 커밋 위험)
- 심링크 3중 의존으로 장애 재발 (2026-04-16 2건)
- 경로 하드코딩 613건이 변경 파급 범위 제어 불가

A2 migration으로 **public 코드 = `~/jarvis/infra/`**, **private 런타임 = `~/jarvis/runtime/`** 로 명확히 분리.

## 구조

```
~/jarvis/                    ← git 추적 (public)
├── infra/                   ← 코드 (SSoT)
│   ├── scripts/
│   ├── discord/
│   ├── lib/
│   └── bin/
├── runtime/                 ← 런타임 (.gitignore 차단)
│   ├── state/
│   ├── logs/
│   ├── config/              ← monitoring.json, tasks.json, .env
│   ├── wiki/
│   ├── rag/                 ← LanceDB
│   ├── discord/.env         ← Discord bot token
│   └── bin, lib, scripts, infra → ../infra/... (SSoT symlinks)
├── .gitignore               ← /runtime/* 차단 (최상단)
├── .gitleaks.toml           ← runtime allowlist
└── .githooks/pre-commit     ← runtime/ path guard

~/.jarvis → ~/jarvis/runtime  (호환성 심링크, 2026-10-17까지 유지)
```

## 기존 사용자 마이그레이션 (fork / git pull 시)

1. 데이터 이사:
   ```bash
   bash ~/jarvis/infra/scripts/migrate-to-runtime.sh --dry-run
   bash ~/jarvis/infra/scripts/migrate-to-runtime.sh --copy
   bash ~/jarvis/infra/scripts/migrate-to-runtime.sh --verify
   ```

2. 호환성 심링크:
   ```bash
   mv ~/.jarvis ~/.jarvis.backup-$(date +%Y%m%d)
   ln -s ~/jarvis/runtime ~/.jarvis
   ```

3. LaunchAgent plist 경로 갱신:
   ```bash
   bash ~/jarvis/infra/scripts/rewrite-plists-to-runtime.sh --apply
   ```

4. Git hooks:
   ```bash
   bash ~/jarvis/infra/scripts/install-hooks.sh
   ```

5. 검증:
   - Discord 봇 재기동: `launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot`
   - heartbeat 확인: `stat -f %m ~/.jarvis/state/bot-heartbeat`
   - 크론 로그: `tail ~/jarvis/runtime/logs/cron.log`

## 신규 설치자

기존 `setup_infra.py` 는 여전히 `~/.jarvis` 경로를 생성 (backward compat).
장기적으로 `~/jarvis/runtime/` 직접 사용하도록 업데이트 예정.

## 심링크 제거 Timeline (Phase E)

| 날짜 | 단계 |
|------|------|
| 2026-04-17 | A2 Phase A~D 완료 (데이터 이사 + 코드 치환) |
| 2026-07-17 (D+90) | 심링크 제거 예비 점검 — `grep -rn '\.jarvis' infra/` = 0 확인 |
| 2026-10-17 (D+180) | **심링크 제거 예정** |

### 심링크 제거 전 선결 작업 (아직 남음)

- [ ] `~/.mcp.json` 4곳 (`workgroup`, `serena` MCP) `~/.jarvis` → `~/jarvis/runtime` 변경
- [ ] `infra/docs/OPERATIONS.md:640` Python 스크립트 하드코딩 경로 환경변수화
- [ ] 문서 36곳 `~/.jarvis` 언급 치환 (OPERATIONS.md, ARCHITECTURE.md 등)
- [ ] gitleaks history 86건 정리 (BFG 또는 `.gitleaks.toml` allowlist.commits SHA 나열)
- [ ] `setup_infra.py`, `setup_rag.py` 가 `~/jarvis/runtime/` 직접 사용하도록 업데이트
- [ ] `README.md`, `README.ko.md` 본문의 `~/.jarvis` 예시 경로 치환

## 주요 방어선 (개인정보 보호 4중)

1. `.gitignore` `/runtime/*` 최상단 — git add 원천 차단
2. `.git/hooks/pre-commit` (`.githooks/pre-commit`) — `runtime/*` 강제 추가 차단
3. `.github/workflows/pii-scan.yml` — 한국 PII 패턴 스캔
4. `.github/workflows/security.yml` (gitleaks) — 토큰/시크릿 스캔

## 롤백 절차 (긴급 시)

1. `rm -rf ~/.jarvis` (심링크 삭제)
2. `mv ~/.jarvis.backup-<date> ~/.jarvis` (백업에서 복원)
3. `cp ~/backup/plists-phase-d/<timestamp>/*.plist ~/Library/LaunchAgents/`
4. 각 LaunchAgent `launchctl bootstrap gui/$(id -u) <plist>` 재등록
5. `git checkout <pre-migration-sha>` 로 코드 리셋

백업 보관 기간:
- `~/.jarvis.backup-*`: 7일 (`backup-retention.sh` 자동 정리)
- `~/backup/plists-phase-d/*`: 30일
