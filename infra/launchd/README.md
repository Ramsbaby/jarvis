# launchd LaunchAgents (jarvis SSoT)

이 디렉토리는 `~/Library/LaunchAgents/`에 설치되는 LaunchAgent plist의 **레포 SSoT**.

## 왜 레포에 두나

macOS 재설치·Mac 교체·실수 삭제 시 로컬(`~/Library/LaunchAgents/`)만 있으면 전부 손실된다.
레포 보관하면 `launchd-sync.sh` 한 번으로 복구 가능.

## 설치 / 재설치 / 수정 후 반영

```bash
bash infra/scripts/launchd-sync.sh
```

- 각 plist를 `~/Library/LaunchAgents/`에 복사 (내용 동일 시 스킵)
- 기존 잡이 로드되어 있으면 `bootout` → `bootstrap` 순으로 재등록
- 여러 번 실행해도 안전 (idempotent)

## 수정 규칙

1. **이 디렉토리의 plist를 편집** (레포가 SSoT)
2. `git commit` + push
3. `bash infra/scripts/launchd-sync.sh` 실행 → 로컬 반영 + 재등록
4. 동작 확인: `launchctl kickstart -k gui/$(id -u)/ai.jarvis.<label>`

**로컬 `~/Library/LaunchAgents/` 파일을 직접 편집하지 말 것.** 다음 sync에서 덮어써진다.

## 현재 관리 대상

| plist | 역할 | 스케줄 | 스크립트 |
|---|---|---|---|
| `ai.jarvis.report-daily.plist` | 일일 보고서 생성 | 매일 23:50 KST | `infra/scripts/report-generate.sh daily` |
| `ai.jarvis.report-weekly.plist` | 주간 보고서 생성 | 토요일 23:50 KST | `infra/scripts/report-generate.sh weekly` |
| `ai.jarvis.report-monthly.plist` | 월간 보고서 생성 (전월 기준) | 매월 1일 00:05 KST | `infra/scripts/report-generate.sh monthly` |
| `ai.jarvis.report-healthcheck.plist` | 보고서 미생성 감시 → Discord 경보 | 매일 06:05 KST | `infra/scripts/report-healthcheck.sh` |

## 동작 테스트 (fire-now)

```bash
# 지금 즉시 실행 (스케줄 무시)
launchctl kickstart -k gui/$(id -u)/ai.jarvis.report-healthcheck

# 로그 확인
tail -20 ~/.jarvis/logs/report-healthcheck.log
```

## 제거 (해당 잡만 끄기)

```bash
launchctl bootout gui/$(id -u)/ai.jarvis.<label>
rm ~/Library/LaunchAgents/ai.jarvis.<label>.plist
# 레포에서도 해당 plist 삭제 + commit
```
