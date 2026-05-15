# claude-model-audit

> Anthropic Claude API 사용자를 위한 모델 버전 자동 audit

새 Claude 모델이 출시되면 코드베이스 곳곳에 흩어진 deprecated 모델 ID를 일일이 찾기 번거롭습니다. 이 도구는 **단일 정책 파일(`model-policy.json`)** 기반으로 deprecated 모델 사용을 자동 검출하고 webhook으로 알립니다.

## 핵심 기능

- 단일 정책 파일 SSoT — 새 모델 출시 시 한 줄만 업데이트
- Bash 스크립트 — 의존성 최소 (jq만 필요)
- Discord / Slack / 일반 webhook 알림
- 매주/매일 cron + LaunchAgent 패턴 그대로 사용 가능

## 빠른 시작

```bash
# 1. 정책 파일 복사 + 수정
cp config/model-policy.example.json config/model-policy.json
# → currentLatest와 deprecated를 환경에 맞게 수정

# 2. 즉시 audit
bash bin/audit.sh

# 3. webhook 알림 활성화
NOTIFY_WEBHOOK=https://discord.com/api/webhooks/... bash bin/audit.sh
```

## 환경변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `POLICY` | `./config/model-policy.json` | 정책 파일 경로 |
| `AUDIT_PATHS` | `.` | 검사 경로 (콤마 구분) |
| `AUDIT_EXCLUDE` | `node_modules,.git,docs` | 제외 패턴 |
| `NOTIFY_WEBHOOK` | (없음) | Discord/Slack webhook URL |
| `LOG_FILE` | `./audit.log` | 로그 경로 |

## Exit code

- `0` — PASS (위반 0건)
- `1` — FAIL (위반 발견)
- `2` — Config error (정책 파일 부재 등)

## 자동화 — LaunchAgent (macOS)

```bash
# ~/Library/LaunchAgents/com.example.claude-model-audit.plist
# StartCalendarInterval: 매주 월 09:00 KST
launchctl load ~/Library/LaunchAgents/com.example.claude-model-audit.plist
```

## 자동화 — cron (Linux)

```cron
# 매주 월 09:00 KST
0 9 * * 1 cd /path/to/claude-model-audit && bash bin/audit.sh
```

## 사고 사례 — 왜 만들었나

2026-05-08 — Jarvis 프로젝트에서 `news-briefing` 모델을 Opus 4.7로 승격하던 중, **`claude-opus-4-6` 사용 task가 다른 곳에 2건 더 있었으나 누락**. audit cron 신설 후 첫 실행에서 9건의 추가 누락(코드 5건 + 스키마 1건 + 문서 3건) 적발. 신모델 마이그레이션 시 grep 누락이 자주 발생하여 자동 audit이 필수.

## 라이선스

MIT — `LICENSE` 파일 참조.

## 출처

- 원본: [Jarvis](https://github.com/...) `infra/scripts/model-version-audit.sh`
- 패키지화: 2026-05-08
