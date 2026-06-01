# 🔐 인증 구조 — B안 듀얼 토큰 (refresh 레이스 영구 차단)

> 2026-06-01 도입. "토큰 무한 소멸" 사후 재설계.
> SSoT: 본 문서 + `infra/lib/automation-auth.sh`.

## 1. 왜 (사고 원인)

자비스의 **모든 인증이 `~/.claude/.credentials.json` 하나에 의존**했고, 코드 어디에도
`CLAUDE_CODE_OAUTH_TOKEN` 주입이 없었다(검증: `grep CLAUDE_CODE_OAUTH_TOKEN infra/` → 0건).

→ credentials.json의 **short-lived** OAuth 토큰이 만료되면, **크론 ~90개 + 봇 + 병렬 에이전트**가
각자 `claude -p`를 돌리며 **같은 `refresh_token`으로 동시에 refresh** → Anthropic이 *재사용 탐지* →
**토큰 revoke → 전원 401**. 이게 "토큰 무한 소멸"이다.

이를 막겠다고 만든 `oauth-refresh.sh` + `oauth-refresh-watchdog.sh` + `retry-wrapper G5 force` +
`pre-cron-auth-check --force` 는 오히려 **refresh 경로를 더 늘려** thundering herd를 악화시켰다.

## 2. 구조 (B안)

| 용도 | 토큰 | 출처 | refresh |
|---|---|---|---|
| 주인님 인터랙티브 + **원격제어** | 풀스코프 로그인 (`credentials.json`) | `claude auth login` | CLI 자체(단일 사용자 → 레이스 없음) |
| 자동화 (크론·봇·에이전트) | **inference-only long-lived** (`~/.claude/.long-lived-token`) | `claude setup-token` | **없음 → 레이스 구조적 불가** |

```
크론/봇 프로세스
  └─ source automation-auth.sh
        └─ export CLAUDE_CODE_OAUTH_TOKEN=<long-lived>   ← refresh_token 없음
              └─ claude -p …   (credentials.json 안 건드림)

주인님 인터랙티브 / /remote-control
  └─ credentials.json (claude auth login, 풀스코프)        ← 혼자 쓰므로 자기끼리 refresh 충돌 없음
```

핵심: **자동화는 refresh가 없는 토큰을 쓰므로, 동시에 100개가 떠도 refresh_token 재사용이 불가능**하다.

## 3. 불변식 (절대 깨지 말 것)

1. `long-lived-token-rotate.sh`는 **credentials.json을 건드리지 않는다** (건드리면 원격제어가 막힘 = Gen1 회귀).
2. 자동화 진입점(`bot-cron.sh`·`jarvis-cron.sh`·`bot-preflight.sh`)은 **반드시 `automation-auth.sh`를 source**한다.
3. 자동화 토큰 SSoT = `~/.claude/.long-lived-token` (단일 파일, 600). 회전은 `long-lived-token-rotate.sh`만.
4. credentials.json에는 **주기적 OAuth refresh 크론을 절대 다시 붙이지 않는다** (race-adder).

## 4. 마이그레이션 (맥미니, **순서 중요**)

```bash
# ① 풀스코프 로그인 → credentials.json = 주인님 토큰(원격제어 가능)
claude auth login

# ② 자동화용 long-lived 토큰 발급 (인터랙티브로 떠서 출력되는 sk-ant-oat01-... 복사)
claude setup-token

# ③ 그 토큰을 전용 파일로 회전 (검증 + 저장, credentials.json은 미변경)
bash ~/jarvis/runtime/scripts/long-lived-token-rotate.sh 'sk-ant-oat01-...'
#    → "✅ 새 토큰 사전 검증 통과 (HTTP 200)" + "ℹ️ credentials.json 미변경" 확인

# ④ 이 브랜치(PR) 코드 반영 (automation-auth.sh + 주입 지점)
cd ~/jarvis && git pull   # 또는 PR 머지 후

# ⑤ 레이스-유발 크론 2개 제거 (crontab -e 에서 아래 줄 삭제/주석)
#    - 0 */2 * * * ... oauth-refresh.sh
#    - */30 * * * * ... pre-cron-auth-check.sh

# ⑥ 봇 재기동 (preflight가 자동화 토큰을 주입한 상태로 기동)
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot

# ⑦ 검증
#    자동화가 long-lived 토큰을 쓰는지 (크론 1회 실행 후)
~/jarvis/runtime/bin/bot-cron.sh system-health && echo "automation OK"
#    원격제어가 살아있는지
claude   # → /remote-control 정상 진입
```

> ⚠️ 순서 핵심: ①②③(토큰 준비)를 **코드 반영(④)보다 먼저** 한다. 그래야 ④ 직후 자동화가
> 곧바로 주입 토큰을 집어 credentials.json을 refresh하지 않는다.

## 5. 토큰이 죽으면 (1년 후 또는 revoke 시)

`long-lived-token-healthcheck`(6h)가 `~/.claude/.long-lived-token`을 ping → 실패 시 Discord 경보.
복구는 ②③ 반복(`claude setup-token` → `long-lived-token-rotate.sh '<새 토큰>'`). **블래스트 반경은
자동화 한정** — 주인님 로그인(credentials.json)과 원격제어는 영향 없음.

## 6. 롤백

```bash
git revert <이 PR 머지 커밋>      # 코드 원복
# 그리고 과거 방식이 필요하면 crontab에 oauth-refresh / pre-cron-auth-check 재등록
```
단, 롤백하면 refresh 레이스 위험이 되살아난다 — 권장하지 않음.

## 7. 변경된 파일

| 파일 | 변경 |
|---|---|
| `infra/lib/automation-auth.sh` | **신규** — long-lived 토큰을 `CLAUDE_CODE_OAUTH_TOKEN`으로 주입 |
| `infra/bin/bot-cron.sh` | 주입 로더 source |
| `infra/bin/jarvis-cron.sh` | 주입 로더 source |
| `infra/scripts/bot-preflight.sh` | 주입 로더 source (봇 SDK 상속) |
| `infra/scripts/long-lived-token-rotate.sh` | credentials.json 주입 **제거** (로그인 토큰 보존) |
| `infra/scripts/long-lived-token-healthcheck.sh` | 검사 대상을 long-lived 토큰 파일로 전환 |
| `infra/templates/crontab.example` | `oauth-refresh`·`pre-cron-auth-check` 크론 제거 |

> 후속(별도 PR): `retry-wrapper.sh`의 죽은 `oauth-refresh --force` 코드 정리(현재 `DISABLE_G5_FORCE=1`로
> 이미 비활성), `oauth-refresh.sh`/`watchdog` deprecation stub화.
