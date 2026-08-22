# 중첩 .claude 권한 격리 제안 (2026-06-17) — 폐기, 2026-08-22 이관

## 무엇이었나

`~/jarvis/.claude/settings.json` 에 있던 약 200줄짜리 권한 격리 설계안.
크론 태스크별 도구 허용/차단, Discord 직접 webhook 차단, `~/.env` 접근 금지 등을 선언했다.

## 왜 옮겼나

**Claude Code 가 읽지 않는 스키마였다.** 아래 키는 전부 Claude Code 설정에 존재하지 않는다.

| 그 파일이 쓴 키 | Claude Code 실제 키 |
|---|---|
| `defaultPermissions` | `permissions.allow` / `permissions.deny` |
| `taskContexts` | 없음 |
| `safetyGuards` | 없음 |
| `auditLogging` | 없음 |
| `rolloutStrategy` | 없음 |

파일 자체에 `"status": "awaiting_owner_decision"` 이 박혀 있었다 — 결재 대기 상태로
방치된 평가안이었고, 그 사이 **집행하는 것처럼 보이지만 한 줄도 집행하지 않았다.**

## 의도는 어디로 갔나

2026-08-22 Claude Code 2.1.239 의 **자동 모드 커스텀 규칙**(`autoMode.hard_deny` /
`autoMode.soft_deny`)으로 이관했다. 정본은 `~/.claude/settings.json` 의 `autoMode` 섹션.

| 원안의 의도 | 이관 위치 | 강도 |
|---|---|---|
| Discord 직접 webhook 차단 | `autoMode.hard_deny` | 무조건 차단 |
| 원장·기억 파일 보호 | `autoMode.soft_deny` | 지목 시 통과 |
| 크론 무단 등록·삭제 차단 | `autoMode.soft_deny` | 지목 시 통과 |
| 슬롯 값 일괄 수정 차단 | `autoMode.soft_deny` | 지목 시 통과 |

원안과 달리 자동 모드 규칙은 **Bash 뿐 아니라 모든 도구**(Edit·Write·MCP·SendMessage)를
분류기 모델이 읽고 판정하며, 사용자 설정에 저장되어 프로젝트 설정으로 덮어쓸 수 없다.

`~/.claude/hooks/precheck-dangerous.sh` 는 그대로 유지 — 훅은 빠르고 결정적,
분류기는 넓고 의도를 본다. 둘은 보완 관계다.
