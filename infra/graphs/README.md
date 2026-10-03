# infra/graphs — LangGraph 실행 뼈대

**그래프 모양인 일만** 돌리는 전용 엔진이다. 초안→비평→수정을 되풀이하거나, 모델이 다음 길을 고르거나, 사람 승인을 기다리는 일이 여기에 해당한다.
모든 자동화의 뼈대가 아니다. 한 줄로 이어지는 작업은 지금처럼 OpenClaw 예약 잡으로 둔다.
지금(0b)은 운영과 분리된 공통 부품만 있다: 실행기(틱 방식), 관문, 분리 실행, 명령·부수효과 입구, 판정 기록, 연기 시험 그래프(`smoke`), 시험.
첫 실제 대상은 다음 단계(1a)의 고스톱 버그 사냥·수정 루프다.

**왜 이 자리인가:** `packages/`는 따로 배포하는 독립 도구(자체 라이선스)를 두는 자리다. 이것은 이 기기의 OpenClaw 잡이 부르고 런타임 상태 폴더를 쓰는 운영 부품이다.
`infra/`에는 이미 자기 `package.json`·lockfile을 가진 하위 프로젝트(`infra/discord`, `infra/openclaw-plugins/jarvis-rag`)가 있다.

## 설치

```bash
bash infra/graphs/install.sh
```

- 판을 정확히 고정했다: `@langchain/langgraph 1.4.18` · `@langchain/langgraph-checkpoint-sqlite 1.0.4` · `@langchain/core 1.2.14` · `zod 4.6.5` · `better-sqlite3 12.11.1`. lockfile 그대로 `npm ci`로 깐다.
- **`npm install-scripts approve better-sqlite3`** — 승인 안 된 설치 스크립트는 건너뛰어진다. 그러면 설치는 성공(코드 0)하는데 실행할 때 죽는다. 판을 올릴 때마다 다시 승인한다.
- 실행은 고정 Node `~/.nvm/versions/node/v24.21.0/bin/node`로만 한다. `lg.sh`가 그 Node로 부른다. Node 주 버전을 바꾸면 `npm rebuild better-sqlite3`.

## 쓰는 법

```bash
G=~/projects/jarvis/infra/graphs
sh $G/lg.sh tick                                  # 예약 잡의 정본(30분마다). --verbose 면 CONTINUE·HOLD 줄도 보인다
sh $G/lg.sh answer <스레드> approved              # 또는 rejected — 대화 중 자비스가 쓰는 길. 답만 적고 끝난다(1초 안)
sh $G/lg.sh start smoke smoke-2026-10-04 --queue  # 등록만 — 다음 틱이 시작한다(--topic 주제, --llm: haiku 1회)
sh $G/lg.sh status [<스레드>] [--json] [--all]    # 읽기만
node $G/lg-report.mjs [--since 2026-10-07] [--json]   # 판정 집계 M1~M8
sh $G/lg.sh selftest                              # 저장 부품·허용 목록·사용자 훅 누수
# 시험·디버그용(사람이 보고 있을 때): start(바로 돌림)·resume(답을 바로 적용)·retry(바로 이어 감)·sweep·gc
```

### 틱 방식 (PLAN §3)

```
lg-tick(30분마다) → run.mjs tick
  ├─ PAUSED 면 아무것도 하지 않는다(NO_REPLY)
  ├─ 정리: 기한 지난 승인 대기·48시간 진척 없는 보류 → EXPIRED / 오래된 잠금 → STUCK / 하루 1회 gc
  ├─ 관문 하나라도 걸리면 HOLD(종료 0, 사유는 metrics)
  └─ 진행 가능한 스레드를 노드 단위로: 답이 적힌 대기 → 끊긴 실행 → 이어가기 → 실패(재시도) → 보류 → 대기열
       ├─ 그래프를 한 번 부를 때 한 단계만(interruptAfter "*"). 단계 앞마다 예산(8분)·PAUSED 를 본다
       ├─ 예산이 다 되면 다음 노드 앞에서 멈춤 → CONTINUE. 다음 틱이 체크포인트에서 잇는다(invoke(null))
       ├─ 답이 적힌 대기는 Command({resume: 답}) 으로
       └─ 긴 일은 '띄우기 → 확인' 두 노드(분리 실행) — 진행 중이면 CONTINUE(재시도로 세지 않는다)
```

| 상황 | 처리 |
|---|---|
| 같은 오류 | 다음 틱에 다시, 3회까지(`LG_MAX_RETRIES`). 그다음에도 같으면 `GAVE_UP` |
| 로그인 만료·사용량 한도(호출 오류 문구) | 재시도로 세지 않고 보류 + 표식(`llm-hold.json`). 관문이 6시간(한도는 1시간) 쉰 뒤 한 번 다시 해 본다. 성공하면 표식을 지운다 |
| 코드 결함(TypeError 등·규칙 위반·허용 목록 밖 명령) | 보류. 코드(그래프·실행기·허용 목록 지문)가 바뀔 때까지 다시 돌리지 않는다 |
| 노드가 스스로 보류(`throw tools.hold("이유")`)·LLM 상한 | 보류. 다음 틱에 다시 해 본다 |
| 결과 모르는 부수효과(시작만 적히고 끝이 없음) | 보류. 사람이 확인해야 한다 |
| 승인 대기 | 질문을 내보인 때부터 48시간. 그 안에 `answer` 로 적힌 답은 틱이 늦게 와도 유효 |
| 진척 없는 보류·이어가기·대기열·실패 | 마지막으로 단계를 끝낸 때부터 48시간(`LG_HOLD_TTL_HOURS`) → `EXPIRED` |
| 살아 있는 프로세스가 쥔 잠금 | 나이와 상관없이 넘겨받지 않는다(S1). 30분(`LG_LOCK_STUCK_MIN`) 넘으면 `STUCK` 한 줄(같은 잠금은 한 번), 그 스레드는 건드리지 않는다. 죽은 pid 의 잠금만 넘겨받는다 |
| 실행 중 끊김(게이트웨이 재시작·SIGKILL) | 다음 틱이 `interrupted` 로 적고 끊긴 노드부터 다시. 같은 끊김도 재시도 횟수에 든다 |

### 출력·종료 코드

`tick`(예약 잡)은 **주인님께 갈 줄만** 낸다: `DONE` · `WAITING` · `EXPIRED` · `GAVE_UP` · `STUCK`. 낼 것이 없으면 `NO_REPLY` 한 줄(OpenClaw가 조용히 처리한다).
같은 대기·같은 잠금은 한 번만 알린다. `CONTINUE`·`HOLD`·`HELD`·재시도 중 실패는 조용하다(`--verbose`·`status`·`metrics.jsonl`에서 보인다).

| 줄 | 뜻 | 종료 코드 |
|---|---|---|
| `DONE <스레드> <결과>` | 끝남 | 0 |
| `WAITING <스레드> <질문> · 답: lg.sh answer …· 기한 …` | 승인 대기(`pending.jsonl`에도 적힌다). 수동 명령은 둘째 줄에 답하는 법 | 0 |
| `EXPIRED <스레드> …` | 승인 기한 또는 보류 기한(48시간) 초과 → 자동 취소 | 0 |
| `GAVE_UP <스레드> <노드> 같은 오류 N회 — …` | 재시도 끝 | 0 |
| `STUCK <스레드> pid N 가 M분째 …` | 살아 있는 프로세스가 오래 쥔 잠금 | 0 |
| `NO_REPLY` | tick·sweep 에서 낼 것이 없음 | 0 |
| `ERROR <스레드> <종류> <설명>` | 진짜 오류(실행기 고장·자가 시험 실패·잘못된 사용). 수동 명령(start·resume·retry)은 0a 규약대로 노드 실패도 1 | 1 |

OpenClaw는 0이 아니면 error로 적고 2회 연속이면 경보, 10회면 잡을 끈다 — 그래서 정상 상태(대기·보류·이어가기)는 전부 0이다.
평소 실행에서는 stderr에 아무것도 쓰지 않는다(stderr가 섞이면 OpenClaw 알림이 `stdout:`/`stderr:` 묶음으로 바뀐다). 노드의 `console` 출력은 `logs/<스레드>.log`(600)로 간다.

## 스위치 (S11)

| 파일(상태 폴더) | 뜻 |
|---|---|
| `PAUSED` | 전체 정지. 틱은 정리·만료도 하지 않는다. 진행 중인 노드는 끝까지 가고 다음 노드 앞에서 선다. `answer`·`status`는 된다 |
| `LIVE` | 실제 모드. **없으면 그림자.** 모드는 스레드를 시작(또는 대기열 등록)할 때 고정되고 등록부에 저장된다 — 도중에 켜도 그 스레드는 그대로 |

```bash
S=~/.openclaw-data/runtime/state/graphs
touch $S/PAUSED        # 멈춤("랭그래프 멈춰") — 잡도 끈다(PLAN §8)
rm $S/PAUSED           # 다시
```

## 관문 (틱마다, 하나라도 걸리면 HOLD)

| 관문 | 기준 | 출처·설정 |
|---|---|---|
| `paused` | `PAUSED` 있음 | |
| `disk` | 여유 < 15GiB + 사본 예상 + 1GiB(기본 17GiB) | 감지기와 같은 재는 법(statvfs bavail, `/System/Volumes/Data`). `LG_DISK_FLOOR_GIB`·`LG_COPY_EST_GIB`(1a 실측으로 바꾼다)·`LG_DISK_MARGIN_GIB` |
| `usage_high`·`usage_unreadable`·`usage_stale` | 주간 사용량 ≥ 80% · 못 읽음 · 6시간 넘게 묵음 | 감지기(`orchestrator-scan.py` `scan_usage` → `usage_findings`)가 `claude -p /usage`로 받아 `state/orchestrator/latest.md`의 '클로드 사용량' 줄에 쓰는 값을 **읽기만** 한다. 주간 범위 중 Fable(금지 모델)은 뺀다. 스냅샷은 정규 회차(08·11·14·17·20시)에만 새로 쓰이므로 **밤 02시 무렵부터 08시까지는 '묵음'으로 쉰다** |
| `login`·`usage_limit` | 호출 오류 문구로 판정한 표식 | 로그인은 감지기 `LLM_AUTH_FAIL`과 같은 문구 + CLI 문구. 429·사용량 한도는 로그인 고장이 아니다(09-30 오판 전례) |
| `token_cap` | 오늘 토큰(입력·출력·캐시 생성·캐시 읽기 합) ≥ `LG_DAY_TOKEN_CAP`(기본 3,000,000) | 10-28 '그림자 ② 하루 최댓값 × 1.5'로 다시 정한다 |
| `quiet` | 01:30~04:30(`LG_QUIET`) | 야간 소크 시간 |

## 그래프를 쓰는 규칙

`graphs/<이름>.mjs`는 `build({ checkpointer, llm, tools })`, `input(flags)`, `summarize(values)`를 내보낸다. 실행기가 그래프를 열 때마다 두 검사를 건다(위반이면 수동 명령은 ERROR, 틱은 코드 결함 보류).

**도구(실행기가 스레드에 묶어 넘긴다)**

| 도구 | 쓰임 |
|---|---|
| `llm.ask(프롬프트, { model, node, tools, cwd, timeoutMs })` | 짧은 호출(틱 안에 끝남). 모델은 haiku·sonnet·opus 계열만(Fable 금지). 도구는 Read·Grep·Glob(·Edit·Write)만 |
| `llm.launchAsk(…, { node, attempt })` → handle / `llm.checkAsk(handle)` | 긴 호출의 분리 실행. `checkAsk`는 던지지 않는다: `done`(text·usage) · `running` · `dead` · `failed`(kind: login·usage_limit·error). 다시 띄울지(시도 + 1)는 그래프가 정한다 |
| `tools.run(cmdId, 인자)` | 명령은 이것으로만. 허용 목록 밖·모드 밖·형식 밖 인자는 거부(코드 결함) |
| `tools.launch(cmdId, 인자, { node, attempt })` / `tools.check(handle)` / `tools.output(handle)` | 분리 실행. 상태는 `done`·`running`·`dead` |
| `tools.effect(key, kind, fn, { verify })` | 부수효과는 이것으로만. 그림자면 '했을 일'만 적고 `fn`을 부르지 않는다 |
| `throw tools.pending("…")` | 분리 실행이 아직 — CONTINUE(재시도로 세지 않음) |
| `throw tools.hold("이유")` | 스스로 보류(디스크 부족·대화 작업 표식 등) |
| `tools.bench({ bench, reproduced, diag_match, hidden_pass, ai_misjudge })` | 판정 M8 기록 |
| `tools.mode` | `shadow` · `live` |

**정적 검사**
- `scripts/check-interrupt-nodes.mjs`(0a): interrupt가 든 노드는 동기·순수 — 상태 읽기 → `interrupt(...)` → 값 반환. LLM·파일·발송·바깥 값 금지. 노드는 `addNode("이름", 함수)` 형식. 정적 중단점(`interruptBefore/After`) 금지 — 컴파일에 박힌 그래프는 노드 단위 진행이 지나쳐 버리므로 실행기가 돌리지 않는다. 승인 대기는 한 번에 하나.
- `scripts/check-graph-rules.mjs`(0b): 그래프 파일과 그 파일이 상대 경로로 가져오는 모듈 전부에서 `child_process`(정적·동적 import·require)·`process.binding`, 허용 목록에 없는 cmdId, 글자값이 아닌 cmdId, `effect(…)` 밖의 부수효과 명령, 랭그래프 Store(S15), 네트워크(fetch·http·net…), 실행기 내부(`lib/`·`scripts/`) 가져오기를 막는다.
- 둘 다 정규식·괄호 짝 수준이라 다 막지 못한다. 그래서 실행 때 한 번 더 막는다: 허용 목록은 `run`이, effect 범위는 `AsyncLocalStorage`로, 모드는 등록부 값으로.

**명령 허용 목록 `cmd-registry.json`**
```json
{ "version": 1, "commands": {
  "sys.sleep": { "bin": "/bin/sleep", "argv": ["{seconds}"], "params": { "seconds": "^[0-9]{1,4}$" }, "modes": ["shadow", "live"], "timeoutSec": 3600 } } }
```
- `bin`은 절대경로, 자리 표시는 항목 전체가 `{이름}`, 정규식은 `^…$`. 셸을 거치지 않는다(배열 spawn). 환경변수는 PATH·HOME·LANG·TMPDIR·USER + `envPass`(비밀류 이름 금지)만.
- `effect: true` 명령은 실제 모드 전용이고 `effect()` 안에서만 돈다(분리 실행 불가 — 띄운 순간 '성공'으로 적히면 안 된다).
- 올릴 수 없는 것: 셸·`env`·`osascript`·`sudo`·`launchctl`·`crontab`·**OpenClaw CLI**(S15 — 노드에서 오픈클로를 다시 부르지 않는다), 인터프리터의 즉석 코드(`-c`·`-e`).
- 파일이 없으면 빈 목록(아무 명령도 허용하지 않음). 시험만 `LG_CMD_REGISTRY`로 바꿀 수 있다.

## 분리 실행 `lib/detach.mjs` (설계 §6)

작업 폴더 `jobs/<스레드>/<노드>/<시도>/` — 이 폴더 만들기(원자적)가 `(thread, node, attempt)` 잠금이다. 틱이 겹쳐도 한 번만 띄운다.
껍데기(`lib/detach-runner.mjs`)가 detached(새 세션)로 떠서 `spec.json`대로 명령을 돌린다. `meta.json`(pid·시작 시각·cmdId) · `stdout`·`stderr`(파일) · `heartbeat`(30초) · `result.json`(임시 파일 → 이름 바꾸기).
판정: 결과 파일 있음 → `done` / 껍데기 pid 살아 있음 → `running` / 결과 없이 죽음 → `dead`(남은 자식은 끈다 — 재시도와 겹치지 않게). 부모(틱)가 죽어도 산다(시험으로 확인). 게이트웨이 재시작 실측은 아직이다.

## 부수효과 `effect(key, kind, fn)` (S10)

원장 `effects.jsonl`(추가 전용). 그림자: `{key, kind, wouldRun}`만(같은 key는 한 줄). 실제: `started` → `fn` → `ok`/`failed`.
같은 key가 `ok`면 다시 하지 않는다(다른 스레드라도). `started`만 있고 끝이 없으면 결과를 모르니 보류 — `verify()`가 일어났다고 확인하면 `ok`로 적고 넘어간다. 같은 key를 두 프로세스가 동시에 내지 않게 key별 잠금(죽은 주인 것만 넘겨받는다).

## 기록·집계 (S17)

`metrics.jsonl`(추가 전용, 600). **gc 대상이 아니다** — 판정일(11-26) + 30일까지 보존. 원문(질문·프롬프트·출력)은 적지 않는다(오류는 머리말만).

| 사건 | 필드 |
|---|---|
| `start` · `done` · `gave_up` · `expired`(kind: approval·hold) | thread · graph · mode · (done) `verified` ← 그래프 상태의 `verify_log`(M2) |
| `node_start` · `node_end` | node · ok · ms |
| `continue`(reason: budget·pending·paused) · `interrupted`(cause: signal·exit·stalled) · `resumed`(from) | |
| `waiting`(reason ← interrupt 값의 `reason`, M5) · `answered`(decision) | |
| `held` | scope(tick·thread·command·sweep) · reasons(관문 이름·llm_budget·token_cap·login·usage_limit·code_defect·node·effect_unknown·stuck·hook_leak) |
| `llm` | model · models · in · out · cache_create · cache_read · total · cost_usd · ms · ok · detached |
| `effect`(outcome: would_run·ran·dedup·failed·unknown·recovered) · `stuck` · `tick` · `gc` · `failed` · `bench`(M8) | |

`node lg-report.mjs`가 M1(끊긴 스레드 중 이어서 끝낸 비율) · M3(같은 key 중복 실행) · M4(48시간 넘게 보고 없이 남은 대기·보류) · M6(날짜별 호출·토큰·비용, Fable 0) 표와 M2·M5·M8 칸을 낸다.

## claude 자식 격리 (0b 실측, 10-03 haiku 4회)

`claude -p --restricted --strict-mcp-config --no-session-persistence --output-format json --model <m> --disable-slash-commands --tools <…>`, 작업 폴더는 **홈 밖** 빈 폴더(맥 사용자 임시 폴더 `/var/folders/…/T/lg-claude-cwd-<uid>` — OpenClaw는 TMPDIR을 홈 아래로 잡으니 TMPDIR은 쓰지 않는다), 키·토큰 없는 깨끗한 환경변수.

| 방식 | 작업 폴더 | 입력 맥락 토큰 | 사용자 규칙·`~/CLAUDE.md` | 훅 로그 |
|---|---|---|---|---|
| 0a `--setting-sources project` | 홈 아래 | 9,161 | 실림 | 0 |
| `--restricted` | 홈 밖 | 3,695 | 안 실림 | 0 |
| `--restricted` | 홈 아래 | 3,700 | 안 실림 | 0 |

`--restricted` + 읽기 도구: 작업 폴더 안 파일은 읽고, 홈 아래·`/etc` 파일은 거부(`permission_denials`). 키 없는 환경에서 성공 = 구독 로그인. 자가 시험(`selftest`·틱)은 사용자 훅 로그에 graphs 쪽 작업 폴더 흔적이 생기면 ERROR로 멈춘다(S6 — 클로드 판이 오르며 훅이 되살아나는 것을 잡는다).

## 설정(환경변수)

0a: `LG_STATE_DIR` · `LG_DB` · `LG_APPROVAL_TTL_HOURS`(48) · `LG_GC_DAYS`(14) · `LG_LLM_MAX_PER_THREAD`(5) · `LG_LLM_MAX_PER_DAY`(20) · `LG_LLM_MODEL`(sonnet) · `LG_LLM_TIMEOUT_SEC`(300) · `LG_CLAUDE_BIN` · `LG_NODE` · `LG_BUSY_TIMEOUT_MS`(15000).
0b: `LG_TICK_BUDGET_SEC`(480) · `LG_HOLD_TTL_HOURS`(48) · `LG_MAX_RETRIES`(3) · `LG_MAX_STEPS`(500) · `LG_LOCK_STUCK_MIN`(30, 옛 이름 `LG_LOCK_STALE_MIN`도 받는다) · `LG_DAY_TOKEN_CAP`(3000000) · `LG_DISK_PATH` · `LG_DISK_FLOOR_GIB`(15) · `LG_COPY_EST_GIB`(1) · `LG_DISK_MARGIN_GIB`(1) · `LG_USAGE_FILE` · `LG_USAGE_MAX_PCT`(80) · `LG_USAGE_MAX_AGE_H`(6) · `LG_QUIET`(01:30-04:30, 빈 값이면 끔) · `LG_LOGIN_RECHECK_MIN`(360) · `LG_LIMIT_RECHECK_MIN`(60) · `LG_HOOK_LOGS`(콜론 구분).
시험 전용 — `LG_TEST_MODE=1`일 때만 먹는다: `LG_NOW`(시간 주입) · `LG_CMD_REGISTRY` · `LG_TEST_START_AT` · `LG_TEST_HEARTBEAT_SEC` · `LG_SMOKE_TRACE` · `LG_SMOKE_CRASH_ONCE` · `LG_SMOKE_CRASH_CODE`.

## OpenClaw 연결 예(등록하지 않았다)

```bash
~/bin/openclaw automations create "*/30 * * * *" --tz "Asia/Seoul" \
  --name "graphs: lg-tick" \
  --command 'sh infra/graphs/lg.sh tick' \
  --command-cwd "$HOME/projects/jarvis" \
  --timeout-seconds 600 \
  --announce
```

`--command`는 `sh -lc`로 돈다. 1회 상한은 600초, 틱 예산은 480초다(명령형 잡의 실제 시간 상한 실측은 잡 등록이 필요해 아직이다 — PLAN 0b).
야간 금지·관문은 실행기가 스스로 지키므로 잡 일정에 넣지 않는다.

## 대화 중 승인

자비스는 `WAITING` 알림·`status`·`pending.jsonl`에서 스레드 이름을 읽는다. 주인님 답을 받으면:

```bash
sh ~/projects/jarvis/infra/graphs/lg.sh answer <스레드> approved   # 또는 rejected — 답만 적고 끝난다. 진행은 다음 틱
```

`OK … answered`면 끝이다. `ERROR … expired`는 기한이 지나 취소된 것, `ERROR … already-answered`는 이미 다른 답이 적힌 것이다.
`resume`(답을 바로 적용해 진행)은 시험·디버그용으로 남겨 두었다 — LLM 노드가 많으면 맥 노드 exec 20초 함정에 걸린다.

## 시험

```bash
cd infra/graphs && H=$(mktemp -d) && HOME=$H ~/.nvm/versions/node/v24.21.0/bin/node --test test/*.test.mjs   # 임시 HOME·임시 상태 폴더, 실호출 없음
RUN_LLM=1 ~/.nvm/versions/node/v24.21.0/bin/node --test test/llm.test.mjs                               # 실제 haiku 1회(한도 사용)
```

0a 50개 + 0b 33개(틱·답·관문 9종·토큰 상한·로그인·만료·재시도·코드 결함·STUCK·끊김·알림 필터·PAUSED·분리 실행 그래프 / 분리 실행 판정·이중 실행·heartbeat·부모 죽음·LLM 분리 / 정적 검사 양성·음성·가져오기·실행기 거부·허용 목록·run·effect·모드 고정·훅 누수·gc 보존·관문 해석·집계).

## 걷어내는 법

1. 이 실행기를 부르는 잡을 끈다: `~/bin/openclaw automations list --all`에서 찾아 `~/bin/openclaw automations disable <jobId>`.
2. 기록을 내보낸다: `node infra/graphs/lg-report.mjs --json > <보관 위치>`.
3. 폴더를 버린다: `trash ~/projects/jarvis/infra/graphs` 후 커밋.
4. 상태도 필요 없으면 `trash ~/.openclaw-data/runtime/state/graphs`.
