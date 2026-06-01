# 🔐 인증 구조 — B안 듀얼 토큰 (refresh 레이스 영구 차단)

> 2026-06-01 도입 + 동일자 커버리지 보강. "토큰 무한 소멸" 사후 재설계.
> SSoT: 본 문서 + `infra/lib/automation-auth.sh` + 래퍼(`~/.local/bin/claude`).

## 1. 왜 (사고 원인)

자비스의 **모든 인증이 `~/.claude/.credentials.json` 하나에 의존**했고, 코드 어디에도
`CLAUDE_CODE_OAUTH_TOKEN` 주입이 없었다(검증: `grep CLAUDE_CODE_OAUTH_TOKEN infra/` → 0건).

→ credentials.json의 **short-lived** 토큰이 만료되면, **크론 ~90개 + 봇 + 추출기/훅**이
각자 `claude`를 돌리며 **같은 `refresh_token`으로 동시에 refresh** → Anthropic 재사용 탐지 →
**revoke → 전원 401**. 이게 "토큰 무한 소멸"이다. (구) `oauth-refresh.sh` 류는 refresh 경로를
더 늘려 thundering herd를 악화시켰다.

## 2. 구조 (B안 — 듀얼 토큰 + 래퍼 단일 주입점)

| 용도 | 토큰 | refresh |
|---|---|---|
| 주인님 인터랙티브 + **원격제어** | 풀스코프 로그인 (`~/.claude/.credentials.json`, `claude auth login`) | CLI 자체(단일 사용자 → 레이스 없음) |
| 자동화(크론·봇·**SDK 추출기·훅**) | **long-lived** (`~/.claude-bot/.long-lived-token`, `claude setup-token`) | **없음 → 레이스 구조적 불가** |

```
[보편 주입점] ~/.local/bin/claude (래퍼)
   ├─ 모든 SDK 호출(pathToClaudeCodeExecutable) 38곳이 여기로 funnel
   ├─ bare `claude -p` CLI 호출도 PATH로 여기 해석(맥미니에서 확인 필요)
   └─ CLAUDE_CODE_OAUTH_TOKEN 미설정 + ~/.claude-bot 토큰 있으면 → 주입 후 exec

[2차 belt-and-suspenders] automation-auth.sh
   └─ bot-cron.sh · jarvis-cron.sh · bot-preflight.sh 상단에서 source
        → 동시폭주의 주범인 90개 크론·봇을 진입 즉시 커버(래퍼 도달 전 이미 주입)
```

핵심: **long-lived 토큰은 refresh_token이 없어, 동시에 100개가 떠도 재사용 레이스가 불가능.**
credentials.json은 주인님 로그인 전용이라 *혼자 쓰므로 자기끼리 refresh 충돌 없음* → 원격제어 유지.

## 3. 커버리지 (왜 전부 덮이나 — 검증됨)

| 경로 | 주입 주체 | 상태 |
|---|---|---|
| 크론 ~90 (bot-cron/jarvis-cron) | automation-auth.sh (진입 즉시) | ✅ 동시폭주 주범, 1차로 커버 |
| 디스코드 봇 SDK | bot-preflight → 자식 상속 | ✅ |
| **standalone SDK 추출기·훅** (insight/mistake/wiki/weekly-critique 등) | **래퍼** (CLAUDE_BIN=`~/.local/bin/claude`) | ✅ 래퍼 경로 통일로 커버 |
| bare-CLI 셸 (health/watchdog 등, 비-chokepoint) | 래퍼(PATH 해석 시) | ⚠️ 단발·저빈도 → 동시폭주 아님. PATH 확인으로 닫음 |

> **잔여 리스크**: bare `claude`가 `/opt/homebrew/bin/claude`로 해석돼 래퍼를 우회하는 일부
> 셸 스크립트. 이들은 **단발·저빈도**라 thundering herd(레이스)를 만들지 못한다. 마이그레이션
> ⑦에서 `which -a claude`로 래퍼가 PATH 우선인지 확인하면 완전히 닫힌다.

## 4. 불변식 (절대 깨지 말 것)

1. **토큰 경로 일치**: `automation-auth.sh` · `long-lived-token-rotate.sh` · `long-lived-token-healthcheck.sh`
   · **래퍼** 가 모두 `~/.claude-bot/.long-lived-token`을 본다. 하나라도 어긋나면 래퍼 주입 실패 → 레이스 부활.
2. `long-lived-token-rotate.sh`는 **credentials.json을 건드리지 않는다** (건드리면 원격제어 차단 = Gen1 회귀).
3. credentials.json에는 **주기적 OAuth refresh 크론을 절대 다시 붙이지 않는다** (race-adder).
4. 래퍼는 `CLAUDE_CODE_OAUTH_TOKEN`이 이미 설정돼 있으면 **존중**한다(2차 주입과 충돌 없음).

## 5. 마이그레이션 (맥미니, **순서 중요**)

```bash
# ① 풀스코프 로그인 → credentials.json = 주인님 토큰(원격제어 가능)
claude auth login

# ② 자동화용 long-lived 토큰 발급 (출력되는 sk-ant-oat01-... 복사)
claude setup-token

# ③ 전용 파일로 회전 (검증 + ~/.claude-bot/에 저장, credentials.json 미변경)
bash ~/jarvis/runtime/scripts/long-lived-token-rotate.sh 'sk-ant-oat01-...'
#    → "✅ 새 토큰 사전 검증 통과" + "ℹ️ credentials.json 미변경" 확인

# ④ 래퍼(~/.local/bin/claude) 주입 블록을 아래로 교체 (.token-alive 플래그 의존 제거 → 항상 주입)
#    기존 _TOKFILE/_FLAG 블록을 이걸로:
#      _TOKFILE="$_HOME/.claude-bot/.long-lived-token"
#      if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -r "$_TOKFILE" ]]; then
#        _t="$(cat "$_TOKFILE" 2>/dev/null)"
#        [[ "$_t" == sk-ant-oat01-* ]] && export CLAUDE_CODE_OAUTH_TOKEN="$_t"
#      fi

# ⑤ 이 PR(#47) 코드 반영
cd ~/jarvis && git pull   # 또는 머지 후

# ⑥ 레이스-유발 크론 제거 (crontab -e):  oauth-refresh.sh / pre-cron-auth-check.sh 줄 삭제
#    + 봇 재기동
launchctl kickstart -k gui/$(id -u)/ai.jarvis.discord-bot

# ⑦ 검증
which -a claude                 # 첫 줄이 ~/.local/bin/claude(래퍼)여야 bare-CLI도 커버
~/jarvis/runtime/bin/bot-cron.sh system-health && echo "automation OK"
claude                          # /remote-control 정상 진입 (풀스코프 유지 확인)
```

> ⚠️ 순서 핵심: ①②③(토큰 준비)·④(래퍼)를 **코드 반영(⑤)보다 먼저**. 그래야 ⑤ 직후 자동화가
> 곧바로 주입 토큰을 집어 credentials.json을 refresh하지 않는다.

## 6. 토큰이 죽으면 (1년 후 또는 revoke 시)

`long-lived-token-healthcheck`(6h)가 `~/.claude-bot/.long-lived-token`을 ping → 실패 시 Discord 경보.
복구는 ②③ 반복. **블래스트 반경은 자동화 한정** — 주인님 로그인·원격제어는 무영향.
(래퍼가 죽은 토큰을 주입하면 자동화는 401로 *조용히 실패*할 뿐 레이스는 안 난다 — refresh가 없으므로.)

## 7. 롤백

```bash
git revert <머지 커밋>           # 코드 원복 (단, 레이스 위험 부활 — 비권장)
```

## 8. 변경된 파일

| 파일 | 변경 |
|---|---|
| `infra/lib/automation-auth.sh` | **신규** — long-lived(`~/.claude-bot/`)를 `CLAUDE_CODE_OAUTH_TOKEN`으로 주입 (2차) |
| `infra/bin/bot-cron.sh` · `jarvis-cron.sh` | 주입 로더 source |
| `infra/scripts/bot-preflight.sh` | 주입 로더 source (봇 SDK 상속) |
| `infra/scripts/long-lived-token-rotate.sh` | credentials.json 주입 제거 + 토큰 경로 `~/.claude-bot/` + `mkdir -p` |
| `infra/scripts/long-lived-token-healthcheck.sh` | 검사 대상 = `~/.claude-bot/.long-lived-token` |
| `infra/templates/crontab.example` | `oauth-refresh`·`pre-cron-auth-check` 크론 제거 |
| **래퍼 `~/.local/bin/claude`** (맥미니, 레포 외) | 주입 블록을 `~/.claude-bot/` + 플래그 의존 제거로 교체 (마이그레이션 ④) |

> 후속(별도 PR): `retry-wrapper.sh` 죽은 `oauth-refresh --force` 정리(현 `DISABLE_G5_FORCE=1`로 이미 비활성),
> `oauth-refresh.sh`/`watchdog` deprecation stub화, bare-CLI 셸들의 `CLAUDE_BINARY` 명시화(잔여 완전 차단).
