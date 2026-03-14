# Event Triggers — Jarvis 이벤트 트리거 레퍼런스

> 업데이트: 2026-03-14
> 관련 파일: `~/.jarvis/scripts/emit-event.sh`, `~/.jarvis/scripts/event-watcher.sh`

---

## 개요

`emit-event.sh <event_name>` 을 실행하면 `~/.jarvis/state/events/<event_name>.trigger` 파일이 생성되고,
`event-watcher.sh` 데몬이 30초 내에 감지하여 `tasks.json`에서 `event_trigger` 필드가 일치하는 태스크를 즉시 실행합니다.

---

## 지원 이벤트 타입 목록

| 이벤트 이름 | 트리거 조건 | debounce | 트리거되는 태스크 |
|---|---|---|---|
| `morning.trigger` | 아침 루틴 시작 | 86400s | `morning-standup` |
| `market.emergency` | 시장 긴급 상황 감지 | 900s | `tqqq-monitor` |
| `system.alert` | 시스템 이상 감지 | 300s | `system-health` |
| `github.push` | GitHub 푸시 이벤트 | 300s | `github-monitor` |
| `disk.threshold_exceeded` | 디스크 사용량 임계값 초과 | 1800s | `disk-alert` |
| `claude.rate_limit_warning` | Claude API 한도 경고 | 900s | `rate-limit-check` |
| `task.failed` | 태스크 실패 감지 | 120s | `auto-diagnose` |
| `github.pr_opened` | GitHub PR 오픈 | 60s | `github-pr-handler` |
| `discord.mention` | Discord 멘션 수신 | 30s | `discord-mention-handler` |
| `system.cost_alert` | API 비용 초과 | 300s | `cost-alert-handler` |

---

## 이벤트 → 태스크 매핑 상세

### `github.pr_opened` → `github-pr-handler`
- **목적**: GitHub PR 오픈 시 즉시 PR 내용 요약 후 Discord `#jarvis-dev` 채널 알림
- **debounce**: 60초 (동일 이벤트 연속 발생 시 중복 실행 방지)
- **출력 채널**: `discord` (jarvis-dev), `file`

### `discord.mention` → `discord-mention-handler`
- **목적**: Discord에서 봇 멘션 감지 시 즉시 `#jarvis-alerts` 채널에 응답 라우팅
- **debounce**: 30초
- **출력 채널**: `discord` (jarvis-alerts)

### `system.cost_alert` → `cost-alert-handler`
- **목적**: API 비용 임계값 초과 시 현재 사용량 보고 및 비용 절감 권고를 Discord 알림으로 즉시 전송
- **debounce**: 300초 (5분 내 중복 알림 방지)
- **출력 채널**: `discord` (jarvis-alerts)

---

## 사용 예시

```bash
# GitHub PR 오픈 이벤트 발생 (github webhook 수신 시)
~/.jarvis/scripts/emit-event.sh github.pr_opened '{"repo":"my-repo","pr_number":42}'

# Discord 멘션 이벤트 발생
~/.jarvis/scripts/emit-event.sh discord.mention '{"user":"ramsbaby","channel":"general"}'

# 비용 초과 경보 발생
~/.jarvis/scripts/emit-event.sh system.cost_alert '{"usage_usd":50.0,"limit_usd":45.0}'

# 이벤트 발생 후 trigger 파일 확인
ls ~/.jarvis/state/events/

# event-watcher 로그 확인
tail -f ~/.jarvis/logs/event-watcher.log
```

---

## GitHub Webhook 연동 설계 (참고)

GitHub Webhook을 수신하여 Jarvis 이벤트로 변환하는 간단한 연동 구조:

```
GitHub Webhook → 로컬 HTTP 리스너 (예: nc, python -m http.server 또는 smee.io proxy)
                 ↓
                 webhook payload 파싱
                 ↓
                 emit-event.sh github.pr_opened '{"pr_number": ...}'
                 ↓
                 event-watcher.sh 감지 → github-pr-handler 태스크 실행
```

**smee.io를 이용한 개발 환경 프록시 예시**:
```bash
# smee-client 설치
npm install -g smee-client

# GitHub Webhook URL에 smee.io 채널 등록 후 로컬 포워딩
smee --url https://smee.io/YOUR_CHANNEL --target http://localhost:8080/webhook
```

---

## 이벤트 파일 구조

trigger 파일 (`state/events/<event_name>.trigger`) 내용:
```json
{"event":"github.pr_opened","ts":1741920000,"emitted_at":"2026-03-14 10:00:00","payload":{"pr_number":42}}
```
