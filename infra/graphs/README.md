# infra/graphs — LangGraph 실행 뼈대

**그래프 모양인 일만** 돌리는 전용 엔진이다. 초안→비평→수정을 되풀이하거나, 모델이 다음 길을 고르거나, 사람 승인을 기다리는 일이 여기에 해당한다.
모든 자동화의 뼈대가 아니다. 한 줄로 이어지는 작업은 지금처럼 OpenClaw 예약 잡으로 둔다.
공통 부품(0a·0b): 실행기(틱 방식), 관문, 분리 실행, 명령·부수효과 입구, 판정 기록, 연기 시험 그래프(`smoke`), 시험.
첫 실제 대상(1a): 고스톱 버그 루프의 읽기 전용 부분 — 접수(`gostop-intake`)·수정(`gostop-fix` ①~⑥·⑭). 아래 '고스톱 루프(1a)'.
1b: 같은 `gostop-fix` 에 ⑦~⑯(빨간 시험·수정·격리 검증·검토·반영) + `gostop-release`(서명 지문 정지). 아래 '고스톱 루프 1b'.

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
sh $G/lg.sh answer <스레드> approved [N]          # 또는 rejected — 대화 중 자비스가 쓰는 길. 답만 적고 끝난다(1초 안). N = WAITING 의 '질문 #N'
sh $G/lg.sh start smoke smoke-2026-10-04 --queue  # 등록만 — 다음 틱이 시작한다(--topic 주제, --llm: haiku 1회)
sh $G/lg.sh status [<스레드>] [--json] [--all]    # 읽기만
node $G/lg-report.mjs [--since 2026-10-07|--hours 24] [--json]   # 판정 집계 M1~M8
sh $G/lg.sh watch [--dry-run]                     # 감시 — 기준 밖이면 한국어 요약 + 지시함 '- [ ]', 없으면 NO_REPLY(예약 잡 graphs: lg-watch daily 08:40)
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
| 노드가 스스로 보류(`throw tools.hold("이유")`) | 보류. 다음 틱에 다시 해 본다 |
| LLM 하루 상한(`llm_day`)·하루 토큰(`token_cap`)·스레드 상한(`llm_thread`) | 보류. 풀릴 수 없는 동안(같은 날·같은 상한 값)은 노드를 다시 돌리지 않는다 |
| 멈출 때 기록한 다음 노드가 그래프에서 사라짐(배포로 이름이 바뀜) | '끝남'으로 보지 않고 코드 결함 보류 |
| 결과 모르는 부수효과(시작만 적히고 끝이 없음) | 보류. 사람이 확인해야 한다 |
| 승인 대기 | 질문을 내보인 때부터 48시간. 그 안에 `answer` 로 적힌 답은 틱이 늦게 와도 유효 |
| 답은 질문 번호에 묶인다 | 질문마다 `질문 #N`(같은 문구로 다시 물어도 새 번호). 첫 질문은 번호 없이도 받고, 둘째 질문부터는 번호가 맞아야 받는다 — 되풀이된 옛 답이 못 본 재확인을 승인하지 않게 |
| 진척 없는 보류·이어가기·대기열·실패, 답을 받고도 진행 못 한 대기 | 마지막 단계 완료·답 기록 중 늦은 때부터 48시간(`LG_HOLD_TTL_HOURS`) → `EXPIRED` |
| 살아 있는 프로세스가 쥔 잠금 | 나이와 상관없이 넘겨받지 않는다(S1). 30분(`LG_LOCK_STUCK_MIN`) 넘으면 `STUCK` 한 줄(같은 잠금은 한 번), 그 스레드는 건드리지 않는다. 죽은 pid 의 잠금만 넘겨받는다 |
| 실행 중 끊김(게이트웨이 재시작·SIGKILL) | 다음 틱이 `interrupted` 로 적고 끊긴 노드부터 다시. 같은 끊김도 재시도 횟수에 든다 |

### 출력·종료 코드

`tick`(예약 잡)은 **주인님께 갈 줄만** 낸다: `DONE` · `WAITING` · `EXPIRED` · `GAVE_UP` · `STUCK`. 낼 것이 없으면 `NO_REPLY` 한 줄(OpenClaw가 조용히 처리한다).
같은 대기·같은 잠금은 한 번만 알린다. `CONTINUE`·`HOLD`·`HELD`·재시도 중 실패는 조용하다(`--verbose`·`status`·`metrics.jsonl`에서 보인다).
알림 줄은 상태 변경과 같은 트랜잭션으로 알림함(`lg_notices`)에 넣고 틱 끝에서 낸다 — 틱이 도중에 죽어도(게이트웨이 재시작·잡 시간 초과) 다음 틱이 낸다.
그래프 하나의 예상 밖 오류는 그 스레드만 코드 결함으로 보류하고 틱은 계속 간다(그래프 하나가 잡 전체를 꺼뜨리지 않게).

| 줄 | 뜻 | 종료 코드 |
|---|---|---|
| `DONE <스레드> <결과>` | 끝남 | 0 |
| `WAITING <스레드> <질문> · 질문 #N · 답: lg.sh answer <스레드> approved\|rejected N · 기한 …` | 승인 대기(`pending.jsonl`에도 `qid`와 함께 적힌다). 수동 명령은 둘째 줄에 답하는 법 | 0 |
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
| `disk` | 여유 < 15GiB + 사본 예상 + 1GiB(기본 16.2GiB — 사본 실측 0.2) | 감지기와 같은 재는 법(statvfs bavail, `/System/Volumes/Data`). `LG_DISK_FLOOR_GIB`·`LG_COPY_EST_GIB`(1a 실측으로 바꾼다)·`LG_DISK_MARGIN_GIB` |
| `usage_high`·`usage_unreadable`·`usage_stale` | 주간 사용량 ≥ 80% · 못 읽음 · 13시간 넘게 묵음 | 감지기(`orchestrator-scan.py` `scan_usage` → `usage_findings`)가 `claude -p /usage`로 받아 `state/orchestrator/latest.md`의 '클로드 사용량' 줄에 쓰는 값을 **읽기만** 한다. 주간 범위 중 Fable(금지 모델)은 뺀다. 스냅샷은 정규 회차(08·11·14·17·20시)에만 새로 쓰인다 — 밤 공백(20→08시, 12시간)을 견디게 기준을 13시간으로 둔다(10-06: 6시간이면 매일 02~08시가 통째로 쉬었다). 밤에 쉬는 것은 `LG_QUIET` 몫이다 |
| `login`·`usage_limit` | 호출 오류 문구로 판정한 표식 | 로그인은 감지기 `LLM_AUTH_FAIL`과 같은 문구 + CLI 문구. 429·사용량 한도는 로그인 고장이 아니다(09-30 오판 전례) |
| `token_cap` | 오늘 토큰(입력·출력·캐시 생성·캐시 읽기 합) ≥ `LG_DAY_TOKEN_CAP`(기본 3,000,000) | 10-28 '그림자 ② 하루 최댓값 × 1.5'로 다시 정한다 |
| `quiet` | 01:30~04:30(`LG_QUIET`) | 야간 소크 시간 |

## 그래프를 쓰는 규칙

`graphs/<이름>.mjs`는 `build({ checkpointer, llm, tools })`, `input(flags)`, `summarize(values)`를 내보낸다. 실행기가 그래프를 열 때마다 두 검사를 건다(위반이면 수동 명령은 ERROR, 틱은 코드 결함 보류).

**도구(실행기가 스레드에 묶어 넘긴다)**

| 도구 | 쓰임 |
|---|---|
| `llm.ask(프롬프트, { model, node, tools, cwd, timeoutMs })` | 짧은 호출(틱 안에 끝남 — 시간 제한은 잡 상한까지 남은 시간 안으로 줄고, 30초도 못 남으면 다음 틱). 모델은 haiku·sonnet·opus 계열만(Fable 금지). 도구는 Read·Grep·Glob(·Edit·Write — 쓰기 도구는 `cwd`(사본)를 꼭 준다)만 |
| `llm.launchAsk(…, { node, attempt, timeoutMs, maxMs })` → handle / `llm.checkAsk(handle)` | 긴 호출의 분리 실행(시간 제한 기본 15분, 최대 시간 기본 그 1.5배 22.5분). `checkAsk`는 던지지 않는다: `done`(text·usage) · `running` · `dead`(최대 시간 초과면 reason `timeout`) · `failed`(kind: login·usage_limit·error). 다시 띄울지(시도 + 1)는 그래프가 정한다 |
| `tools.run(cmdId, 인자)` | 명령은 이것으로만. 허용 목록 밖·모드 밖·형식 밖 인자는 거부(코드 결함) |
| `tools.launch(cmdId, 인자, { node, attempt })` / `tools.check(handle)` / `tools.output(handle)` | 분리 실행. 상태는 `done`·`running`·`dead`. 최대 시간(목록 `maxSeconds`)을 넘기면 `check`가 묶음째 끄고 `dead`(reason `timeout`) — 그래프는 다른 `dead`처럼 던져 재시도 규칙(같은 오류 3회 → GAVE_UP)에 맡긴다. 던지는 문구 머리에 `st.reason`을 넣으면(예: `` `분리 실행 ${st.reason}` ``) metrics `failed`·`gave_up`의 error 칸에 사유가 남는다(R21 지표) |
| `tools.effect(key, kind, fn, { verify })` | 부수효과는 이것으로만. 그림자면 '했을 일'만 적고 `fn`을 부르지 않는다 |
| `throw tools.pending("…")` | 분리 실행이 아직 — CONTINUE(재시도로 세지 않음) |
| `throw tools.hold("이유")` | 스스로 보류(디스크 부족·대화 작업 표식 등) |
| `tools.bench({ bench, reproduced, diag_match, hidden_pass, ai_misjudge })` | 판정 M8 기록 |
| `tools.mode` | `shadow` · `live` |
| `tools.enqueue(그래프, 스레드, 입력)` | 다른 그래프의 스레드를 대기열에 올린다(접수 → 수정). 다음 틱이 시작. 이미 있으면 `{ok:false, kind:"exists"}`(멱등). 모드는 이 스레드 모드와 지금 `LIVE` 중 낮은 쪽 |
| `tools.stateDir` · `tools.now()` | 읽기 전용 값: 상태 폴더(사본·원문 파일 자리), 실행기 시계(시험은 `LG_NOW`) |
| `llm.ask/launchAsk(…, { jsonSchema })` | 구조화 출력(`--json-schema`). 결과의 `structured`(없으면 null — 본문에서 다시 찾는다) |

**정적 검사**
- `scripts/check-interrupt-nodes.mjs`(0a): interrupt가 든 노드는 동기·순수 — 상태 읽기 → `interrupt(...)` → 값 반환. LLM·파일·발송·바깥 값 금지. 노드는 `addNode("이름", 함수)` 형식. 정적 중단점(`interruptBefore/After`) 금지 — 컴파일에 박힌 그래프는 노드 단위 진행이 지나쳐 버리므로 실행기가 돌리지 않는다. 승인 대기는 한 번에 하나.
- `scripts/check-graph-rules.mjs`(0b): 그래프 파일과 그 파일이 상대 경로로 가져오는 모듈 전부에서 `child_process`(정적·동적 import·require)·`process.binding`, 허용 목록에 없는 cmdId, 글자값이 아닌 cmdId, `effect(…)` 밖의 부수효과 명령, 랭그래프 Store(S15), 네트워크(fetch·http·net…), 실행기 내부(`lib/`·`scripts/`) 가져오기를 막는다.
  상대 경로가 아닌 가져오기는 허용 목록만(`@langchain/langgraph`·`@langchain/core`·`zod`·순한 node 내장 fs·path·crypto…), 우회로(`createRequire`·`process.getBuiltinModule`·`eval`·`Function` 생성자·`.constructor(…)`·글자값 아닌 동적 import·위험 이름 글자값)도 위반이다.
- 둘 다 정규식·괄호 짝 수준이라 다 막지 못한다. 그래서 실행 때 한 번 더 막는다:
  - **실행 시 차단층 `lib/guard.mjs`:** 실행기가 저장소를 연 직후 `child_process`의 모든 실행 함수·`worker_threads.Worker`·`process.binding("spawn_sync"|"process_wrap")`·`process.dlopen`·`process.execve`를 감싼다. 실행기 내부(`allowSpawn`)가 아니면 던진다(코드 결함). 내보내기 객체를 바꾸므로 import·require·`getBuiltinModule`·npm 패키지 어느 길이든 같다(0b 검토에서 정적 검사만으로는 우회됨을 재현 → 이 층으로 막음, 시험으로 확인).
  - 허용 목록은 `run`이, effect 범위는 `AsyncLocalStorage`로, 모드는 등록부 값으로.
  - 한계: 같은 프로세스 안이라 파일 쓰기·네트워크는 실행 때 막지 않는다(정적 검사만). 완전한 격리는 별도 프로세스·sandbox-exec(1b).

**명령 허용 목록 `cmd-registry.json`**
```json
{ "version": 1, "commands": {
  "sys.sleep": { "bin": "/bin/sleep", "argv": ["{seconds}"], "params": { "seconds": "^[0-9]{1,4}$" }, "modes": ["shadow", "live"], "timeoutSec": 3600, "maxSeconds": 5400 } } }
```
- `bin`은 절대경로, 자리 표시는 항목 전체가 `{이름}`, 정규식은 `^…$`. 셸을 거치지 않는다(배열 spawn). 환경변수는 PATH·HOME·LANG·TMPDIR·USER + `envPass`(비밀류 이름 금지)만.
- `timeoutSec`(1~3600, 기본 120)은 명령 시간 제한이다. `maxSeconds`는 분리 실행 최대 시간이다 — `timeoutSec`보다 크고 86400 이하, 첫 값은 알려진 상한의 1.5배(설계 §6). 없으면 `LG_DETACH_MAX_SEC`(5400).
- `effect: true` 명령은 실제 모드 전용이고 `effect()` 안에서만 돈다(분리 실행 불가 — 띄운 순간 '성공'으로 적히면 안 된다).
- 올릴 수 없는 것: 셸·`env`·`osascript`·`sudo`·`launchctl`·`crontab`·**OpenClaw CLI**(S15 — 노드에서 오픈클로를 다시 부르지 않는다. 파일 이름이 openclaw 이거나 openclaw 패키지 안 스크립트. 경로에 `.openclaw`가 든 인자는 괜찮다), 인터프리터의 즉석 코드(`-c`·`-e`).
- `envPass`에 비밀류 이름(TOKEN·KEY·SECRET·PASS·AUTH·COOKIE·PAT·WEBHOOK·CRED·URL·SESSION…)은 올릴 수 없다.
- 파일이 없으면 빈 목록(아무 명령도 허용하지 않음). 시험만 `LG_CMD_REGISTRY`로 바꿀 수 있다.

## 고스톱 루프(1a, 설계 `DESIGN-gostop-loop.md` v2.2)

LLM 이 쓴 코드는 실행하지 않는다. 사본에서 도는 것은 사람이 쓴 기존 시험뿐이다(벤치 회귀 주입도 사람이 적은 변형). 본 저장소는 읽기만 한다.

```
gostop-intake:<날짜>  (LG_DAILY — 04:30 뒤 첫 틱이 대기열에 올림, LLM 0회)
  preflight(소크 잠금이면 HOLD) → collect(소크 summary.json 3일 치 · CI 7일 치 지금도 빨간 워크플로 — 늘 다시 보고 장부로 뺀다.
  씨앗 없는 소크 문제·미커밋 소크는 기록만) → dedupe(gostop/intake-state.json · 새것이 없으면 벤치 1건) → enqueue(gostop-fix 대기열, 하루 3건 — 넘친 것은 다음 접수로)
gostop-fix:<sigkey>  (meta.serial — 한 번에 하나, S13)
  ① preflight  대화 작업 표식(.jarvis-busy · 모든 가지 30분 안 커밋)이면 HOLD(busy). 대상 커밋을 전체 해시로
  ② sandbox    git archive → gostop/sandbox/<키>/work(사본)·clean(깨끗한 내보내기, 1b 패치 기준). .git 없음(역사 0),
               .claude·.mcp.json·key.properties·*.jks·*.keystore·google-services.json 제외, 기록 문서(docs 중 rules 외·context·qa·
               coverage·루트 md 등 — 수정 원장에 정답이 있다) 정리, 벤치면 정답 표지 누설 검사(있으면 진단 없이 gave_up), pub get --offline
  ③ reproduce  기존 시험 2회(분리 실행) → reproduced · not_reproduced · flaky · tool_error. 죽음·시간 초과·신호 종료는 같은 회차를 다시(3회 → gave_up)
  ④ diagnose   sonnet ×≤2(형식·호출 오류·죽음 포함), --restricted, Read·Grep·Glob, 작업 폴더 = 사본, --json-schema(가설·파일·규칙 공백·확신도·근거).
               로그인 만료·사용량 한도는 시도로 세지 않고 6시간·1시간 쉰 뒤 새 실행 번호로(3회까지)
  ⑤ scope_precheck  §4① 허용 목록 밖·AI 영역(lib/domain/ai/**·MCTSConstants)이면 승인 사유
  ⑥ owner_gate 실제 모드 + 사유일 때만(순수 interrupt). 그림자는 plan 이 would_ask 로 적기만
  ⑭ plan       runs/<키>/plan.md·result.json(+haiku 요약 1회). 상태: ready·rule_decision·would_ask·not_reproduced·flaky·gave_up.
               벤치면 판정 M8(bench, 스레드당 1회 — 채점: 기대 파일 1~2위 + 근거 '파일:줄'이 정답 자리 ±15줄). 사본의 build·.dart_tool 은 지운다.
사본은 3일 보관 — 실행기가 관문 앞에서 틱마다 정리한다(끝나지 않은 스레드 것은 남김). runs/ 원문은 gc 14일.
```

- 신호 열쇠: `soak:normal:<씨앗>:<head8>` · `soak:problem:<날>:<head8>:<해시>` · `ci:<워크플로>:<sha8>` · `bench:<id>:r<회차>`.
- 벤치 `bench/gostop.json`: 역사 2(69a0144 국진 두 길 → ready, 02d61dc 판 끝 조커 → rule_decision) + 회귀 주입 14(현재 코드에 지난 수정의 핵심 줄을 거꾸로 — 지금 있는 시험이 잡는 것만). 사례마다 빨간불 직접 확인 기록(`red`).
- 명령(cmd-registry): `git.rev-parse`·`git.last-commit-time`·`git.archive`(본 저장소 읽기) · `tar.extract-sandbox` · `flutter.pub-get-offline`·`flutter.test-defines`·`flutter.test-file`(사본 안, 작업 폴더 정규식이 `…/gostop/sandbox/<키>/work|clean` 만) · `gh.run-list`·`gh.run-log-failed`(읽기 전용, 작업 폴더 = 본 저장소 → 원격으로 저장소를 정한다). 최대 시간은 실측 × 1.5(재현 49초 → 74초, 시험 파일 37.8초 → 57초).
- 실측(10-03): 기록 문서를 뺀 사본 31MB + 깨끗한 내보내기 31MB + 시험 뒤 build 91MB(풀기 전 tar 91MB 는 시험 전에 지움) → 최고 0.15GiB → `LG_COPY_EST_GIB` 0.2. 1판 재현 15~49초(첫 컴파일·부하 포함). `--restricted` 에서도 작업 폴더의 CLAUDE.md 가 실린다(고스톱 41.8KB → 입력 맥락 약 +2만 토큰, 캐시됨).
- 실호출: `RUN_LLM=1 node --test test/gostop-live.test.mjs`(haiku 1회 — 밖 읽기 거부·구독 로그인·훅 0·CLAUDE.md) · `node test/gostop-bench-live.mjs <출력> hist-69a0144 hist-02d61dc`(임시 상태 폴더, 진짜 flutter·sonnet).
- 설정: `LG_GOSTOP_REPO`(기본 ~/projects/gostop_app) · `LG_GOSTOP_SOAK_DIR`(기본 ~/.openclaw/workspace/state/gostop-soak) · `LG_DAILY`(기본 `gostop-intake@04:30`, 빈 값이면 끔).

## 고스톱 루프 1b — 빨간 시험·수정·격리 검증(설계 §5.2 ⑦~⑯)

기본은 1b 다(`LG_GOSTOP_STAGE=1a` 면 1a 처럼 ⑥ 뒤 plan). **그림자가 기본**이라 `LIVE` 가 없으면 ⑮ 는 건너뛰고 ⑯ 은 effect 가 '했을 일'만 적는다.
LLM 이 사본에 쓴 뒤에는 그 사본에 격리 밖 시험 명령(`flutter.*`)을 쓰지 않는다 — 시험·분석은 전부 `sandbox.*`(lg-test.sb 격리 실행)로.

```
⑤ scope_precheck → (규칙 공백이면 plan) → (실제 + 사유) ⑥ owner_gate
⑦ repro_test     sonnet ×≤2, --restricted + Read·Grep·Glob·Edit·Write, 작업 폴더 = 사본. 결과(정본 패치)가 test/repro/ 새 .dart 뿐인지 다시 본다
                 (시험 1개 + 도우미 2개까지, 밖은 되돌리고 실패로 센다) → repro.three-path(-h5): 엔진·라이브 사람·라이브 AI(어려움) 묶음
                 → redbase = 깨끗한 내보내기 + 재현 시험(이후 '이번 수정만' 패치의 기준)
⑧ verify_red     격리 점검(sandbox.canary) → sandbox.flutter-test 로 패치 전 빨간불(표식 붙은 경로 시험이 Expected/Actual 단언으로 실패 —
                 컴파일 오류·파일 싣다 죽음(loading [E])·예외만은 빨간불이 아니다).
                 시험 실행 뒤 사본이 redbase 와 같아야(다르면 격리 위반). 아니면 ⑦ 다시, 2회면 no_red(수정하지 않는다)
⑨ fix            opus ×1 + 재수정 ×≤2. 정본 패치는 git 없이(patch.extract): fix-N.diff(redbase 대비) · patch-N.diff(clean 대비 — 반영할 것)
   [AI 결정 비교] 사본에 고스톱 test/ai_policy(H5)가 있고 lib 를 바꿨을 때만: 기준 사본(base)에서 gen(결과는 격리 밖 runs/ai-gen 에 지문과 함께)
                 → 패치 사본에서 compare(sandbox.ai-policy, 종료 코드와 판정이 맞아야 pass). 비교기 두 파일이 깨끗한 쪽과 같아야 믿는다.
                 없으면 폴백(aiCheck unavailable — AI 영역·MCTSConstants·규칙 처리부는 승인 사유)
⑩ scope_check    patch.allowlist(이번 수정, --frozen test/repro/) + AI 호출부(고스톱 callsites 규칙의 옮김 — 결정 비교가 같아도 AI 호출을 더하거나
                 바꾸면 ai_callsite). 재현 시험을 건드렸으면 되돌리고 재수정. 사유가 있으면 실제는 scope_gate(순수 interrupt),
                 그림자는 끝까지 검증하고 would_ask
⑪ verify         단계 묶음 앞 격리 점검. 대상 시험(신호 재현 명령) · 3경로 시험 · 실행 증명(라이브 AI 묶음 --coverage → cov.check) ·
                 분석(오류·경고 수가 기준 사본보다 늘지 않음) · 전체 시험 · 미니 대조 30판(차분 대조 20 + 라이브 소크 어려움 6·쉬움 4, 씨앗 = sigkey).
                 전체·미니가 실패하면 같은 명령을 기준 사본(base)에서 돌려 실패 항목을 견준다 — 새 실패가 없으면 통과(격리 환경·기존 결함 탓을 수정 탓으로 몰지 않게).
                 끝나면 '이번 수정' 패치를 다시 뽑아 지문이 같아야 한다(시험 코드가 lib 를 고쳐 놓는 길 → 격리 위반)
⑫ review         sonnet ×1, 새 맥락, 읽기 도구, --json-schema(승인·3경로·무관한 변경·규칙 일치·고칠 점)
⑬                ⑩(재현 시험 건드림)·⑪·⑫ 실패 → ⑨(실패 내용을 피드백으로), 수정 통틀어 3회 → gave_up
⑮ merge_prep     실제 전용·벤치 제외(벤치는 정답이 이미 master 에 있다 — ready 로 끝). 최신 master 를 git archive 로 내보내 pub get(LLM 코드 전)
                 → 재현 시험만 얹어 격리 실행 빨강(master_red — 이미 고쳐졌으면 반영하지 않는다) → 수정 패치 적용 → 3경로·대상·전체 시험 초록
⑯ commit_push    effect('gostop-commit:<sigkey>:<패치 지문>') 안에서만: worktree add → git apply --index → commit(LG-Key 트레일러) → push → worktree remove.
                 훅은 끈다(core.hooksPath=/dev/null·--no-verify) — 본 저장소 훅이 LLM 코드를 격리 밖에서 돌리므로. 설계 §5.2⑯ 'pre-push 관문 그대로'와
                 다르다(실제 모드 켜기 전 주인님 결정). verify: 원격 master 가 남겨 둔 커밋 해시면 '일어남'(틱이 push 중에 죽어도 이어 간다)
⑭ plan           상태 ready · no_red · would_ask · gave_up(격리 위반·재현 시험 실패·수정 3회·반려) · rule_decision · not_reproduced · flaky.
                 plan.md 에 재현 시험 자리·빨간불 로그·정본 패치·검증 표·검토·커밋 기록, result.json 에 전부
```

- 사본 셋: `work`(LLM 작업 폴더) · `clean`(패치 기준 — pub get·시험을 돌리지 않는다. 돌리면 생성 파일이 '바뀐 파일'로 섞인다) · `base`(기준 실행용, pub get 함).
  격리 실행마다 새 임시 폴더 `tmp/<실행 번호>`(앞 실행의 시험 코드가 심은 바로가기를 밟지 않게). 그래프가 사본에 쓰거나 읽을 때는 바로가기를 따라가지 않는다(safeTarget·readNoFollow).
- ⑦ 을 띄우기 직전 사본 뿌리에 `.llm-touched` 를 남긴다. 같은 sigkey 로 다시 시작하면 ② 가 사본을 새로 만들고, ③(격리 밖 재현)은 표식이 있으면 코드 결함으로 멈춘다.
- 예산: 진단 2 + 재현 시험 2 + 수정 3 + 검토 3 + 요약 1 = 11, 스레드 상한 12(그래프 `meta.llmPerThread` — 실행기가 `LG_LLM_MAX_PER_THREAD` 보다 크면 이 값을 쓴다, 12 이하). 모델별 상한 `LG_GOSTOP_SONNET_CAP`(7)·`LG_GOSTOP_OPUS_CAP`(3). Fable 금지.
- 격리 위반(종료 98·사본 무단 변경)은 gave_up + 지표 `sandbox_violation`(§8). 준비 오류(97)는 던져 재시도(3회 → GAVE_UP). 격리 점검 실패는 보류(`sandbox_canary`).
- 명령(cmd-registry, 1b): `sandbox.canary`·`sandbox.flutter-test`·`sandbox.flutter-test-defines`·`sandbox.flutter-test-all`·`sandbox.flutter-analyze`·`sandbox.flutter-cov-ai`·`sandbox.ai-policy`
  · `patch.extract`·`patch.allowlist`·`repro.three-path`·`repro.three-path-h5`·`cov.check`(그림자·실제) · `patch.apply-copy`·`apk.cert-fingerprint`(실제) · effect(실제): `git.worktree-add`·`git.apply-index`·`git.commit-file`·`git.push-master`·`git.worktree-remove`·`fad.distribute`.
  홈 경로를 목록에 박지 않는다: `bin: "@node"`(이 실행기의 고정 Node) · `argv: "@graphs/<경로>"`(이 폴더 아래 파일, `..` 금지).
- `gostop-release:<versionCode>`(실제 전용, 최소판): APK 를 상태 폴더 비공개 복사본으로 옮겨 해시를 고정 → `apksigner verify --print-certs`(v1·v2·v3 서명 검사)
  서명자 SHA-256 을 `LG_RELEASE_CERT_SHA256` 과 대조 — 다르면 `signing_mismatch` 로 멈추고 배포 effect 를 내지 않는다. 맞으면 복사본 해시를 다시 보고
  `fad.distribute`(effect, `LG_FAD_APP_ID`). 버전 올리기·빌드·설치는 다음 판. `bin: "@android-sdk/<경로>"` = ANDROID_HOME·ANDROID_SDK_ROOT(없으면 ~/Library/Android/sdk).
- 한계: AI 결정 비교 결과 파일은 패치 코드가 같은 프로세스에서 쓸 수 있다(격리는 유출을 막지 판정 위조는 못 막는다 — 정적 호출부 검사·검토가 함께 본다).
  검증은 정본 패치가 아니라 work 전체에서 돈다(맨 위 build·.dart_tool 은 지문 밖). 로그인·한도 뒤 다시 띄운 호출도 스레드 상한 12 에 든다.
- 실호출: `LG_GOSTOP_STAGE=1b node test/gostop-bench-live.mjs <출력> hist-69a0144` — 상태는 /private/tmp 아래(격리 실행 뿌리), 끝나면 숨긴 정답 시험으로 채점(대조군 빨강 → 패치 뒤 초록). `LG_BENCH_STATE` 로 이어 돌릴 수 있다.
- 쓰기 노드(⑦·⑨)는 `--permission-mode acceptEdits`(-p 에서는 쓰기 허락을 물을 사람이 없어 Write 가 거부된다 — 10-03 실호출). --restricted 가 작업 폴더 밖 쓰기를 막는다(haiku 실측).
- 시험: `test/gostop-1b.test.mjs` 24개(가짜 claude script 모드 — 허락 모드 없으면 쓰기 거부, 가짜 격리 실행기 `fake-sandboxed.mjs`, 가짜 apksigner·firebase).

## 당직 D0 그림자 — 게이트웨이 재시작 뒤 확인 (`duty-verify`, PLAN §13.3)

주인님 10-04 동결 예외(`docs/duty-standing-approvals.md`). **결과는 `lg.` 기록에만** — 당직 장부·감지기·절차서는 읽기만 한다. 새 잡 없이 `lg-tick` 이 한다.

```
틱 고리(lib/duty-intake.mjs, 관문 앞·PAUSED 면 안 함)
  ├─ 게이트웨이 확인(gateway.listen-pid·gateway.proc) → 기록 lg.restart.heartbeat {gw_pid, gw_start, gw_up, open[상태 스레드], jobs[돌고 있는 분리 실행]}
  └─ 재시작 접수: ~/.openclaw/logs/gateway-restart.log 의 'restart attempt' 줄(커서 뒤) + 기록에 없는 pid 바뀜
       → 재시작마다 스레드 'dv-<재시작 초>' 하나(그림자 고정 — LIVE 스위치와 무관, 이미 있으면 안 올림). 처음 틱은 지금부터 본다
duty-verify:dv-<초>
  wait     재시작 + 3분(LG_DV_WAIT_SEC) 전이면 CONTINUE
  verify   LLM 0. 포트 주인(lsof)·새 pid·시작 시각 ≥ 재시작 − 2분(ps etime)·HTTP /health(curl 127.0.0.1) · 재시작 뒤 대화 기록(~/.claude/projects)의
           오픈클로 도구 결과 중 'Gateway client authority closed…' 로 시작하는 오류(감지기 authority_failures 와 같은 판별) 0 ·
           게이트웨이 로그(/tmp/openclaw/openclaw-<날>.log·~/Library/Logs/openclaw/gateway.log 끝 8MB)의 같은 문구 0 → ok | broken | unknown(다음 재시작에 덮임 등)
  record   lg.duty.verify(phase verify, 근거 숫자만) + effect 'would append ledger line key=gateway.tool_authority verified=…' — 그림자라 실행 안 함(fn 은 장부를 쓰지 않고 실패)
  compare  재시작 뒤 첫 장부 gateway.tool_authority 판정 줄(이 재시작을 부른 줄 — verified≠true·first_seen 이 재시작 전·조치에 재시작 — 은 뺌)과 대조
           → lg.duty.verify(phase compare: agreement true·false(kind mismatch·later_break)·none·n/a + survival). 줄이 없으면 14시간(LG_DV_COMPARE_H)까지 CONTINUE
```

- 끝(DONE)은 알리지 않는다(`meta.quietDone`) — 틱 출력엔 `--verbose` 의 `OK … done(알림 없음)` 만. GAVE_UP·EXPIRED 는 그대로 알린다.
- 재시작 생존 실측(PLAN §3 미실측): compare 가 재시작 직전 heartbeat 의 열린 스레드·분리 실행을 본다 — 스레드는 재시작 뒤 단계를 끝냈나(progressed·waiting·stalled), 분리 실행은 재시작 뒤 결과를 썼거나 heartbeat 가 이어졌나(survived·killed). `node lg-report.mjs` 의 'D0' 칸이 일치율·생존 실측 횟수를 낸다.
- OpenClaw CLI(`openclaw health`·`sessions`)는 쓰지 않는다 — 목록에 올릴 수 없다(S15). 그래서 능동 확인(세션 목록 호출)은 없고, 살아 있음은 포트·프로세스·`/health`, 도구 경로는 재시작 뒤 실제 도구 결과(수동 관찰)로 본다. `tool_ok`(재시작 뒤 성공한 오픈클로 도구 결과 수)가 0 이면 '실패 없음'이지 '작동 확인'은 아니다.
- 관문(사용량 묵음 02~08시·야간 01:30~04:30 등)에 걸린 틱도 heartbeat·접수는 하지만 스레드는 관문이 풀린 틱에 돈다 — 그만큼 확인이 늦다(`delay_s`).
- 끄기: `touch ~/.openclaw-data/runtime/state/graphs/DUTY_VERIFY_OFF`(heartbeat·접수 멈춤. 이미 올라간 dv 스레드는 읽기만 하고 끝난다). 다시: 그 파일을 지운다. 접수 상태 `duty-verify/intake.json`.
- 설정: `LG_DV_WAIT_SEC`(180) · `LG_DV_COMPARE_H`(14) · `LG_GATEWAY_PORT`(18789) · 읽는 곳 `LG_DV_RESTART_LOG`·`LG_DV_CLAUDE_PROJECTS`·`LG_DV_GW_LOG_DIR`·`LG_DV_GW_LOG`·`LG_DV_DUTY_LEDGER` · `LG_DUTY_VERIFY=0`(끔 — 시험 모드에서는 `1` 일 때만 켜짐).
- 손으로: `sh lg.sh start duty-verify dv-manual-1 --topic 2026-10-04T16:55:49+09:00`(바로 돌림 — 지난 재시작을 다시 보기. LIVE 면 보류).
- 시험: `test/duty-verify.test.mjs` 19개(가짜 lsof·ps·curl `fixtures/fake-gw.mjs`, 가짜 재시작 기록·대화 기록·게이트웨이 로그·장부, 진짜 당직 장부 지문 앞뒤 대조).

## 분리 실행 `lib/detach.mjs` (설계 §6)

작업 폴더 `jobs/<스레드>/<노드>/<시도>/` — 이 폴더 만들기(원자적)가 `(thread, node, attempt)` 잠금이다. 틱이 겹쳐도 한 번만 띄운다.
껍데기(`lib/detach-runner.mjs`)가 detached(새 세션)로 떠서 `spec.json`대로 명령을 돌린다. `meta.json`(pid·시작 시각·cmdId) · `stdout`·`stderr`(파일) · `heartbeat`(30초) · `result.json`(임시 파일 → 이름 바꾸기).
판정: 결과 파일 있음 → `done` / 껍데기 pid 살아 있음 → `running` / 결과 없이 죽음 → `dead`(남은 자식은 끈다 — 재시도와 겹치지 않게). 부모(틱)가 죽어도 산다(시험으로 확인). 게이트웨이 재시작 실측은 아직이다.

**최대 시간(10-03 실측 반영).** 분리 실행은 띄운 잡이 정상 종료해도, 잡이 시간 초과로 SIGTERM을 맞아도 살아서 결과를 썼다 — 오픈클로 잡 시간 상한은 여기에 닿지 않는다. 그래서 스스로 끈다.
- 껍데기는 detached라 자기 프로세스 묶음의 우두머리다(pgid = 껍데기 pid). 그 아래 명령·손주(시험 프로세스 등)까지 한 신호로 닿는다. 스스로 새 묶음을 만든 후손(setsid·detached)에는 닿지 않는다.
- `check()`: 껍데기가 살아 있어도 시작 + `maxMs`를 넘겼으면 묶음째 SIGTERM → 30초 안에 안 비면 SIGKILL → `dead`(reason `timeout`). 표식 `kill.json`을 먼저 남기므로 같은 시도를 다시 확인해도 `timeout`이다. 30초 유예 동안 `check`는 동기로 기다린다(보통은 바로 꺼진다).
  - 결과의 `gone`이 묶음이 비었는지다(SIGKILL 뒤에도 5초까지 기다린다). `false`면 커널 대기 중인 프로세스 등이 남은 것이다.
  - pid가 우리 껍데기임을 증명할 때만(시작 시각이 기록과 같음) 끈다. 못 하면 끄지 않고 `running`(`overdue: true`)으로 두고 다음 확인에서 다시 본다. 자식 하나를 따로 끌 때도 시작 시각이 같아야 한다.
- 껍데기 자신도 묶음째 정리한다. 시간 제한(`timeoutMs`)이 걸리거나 바깥에서 SIGTERM을 받으면(`check`가 보낸 것, 명령의 `kill 0` 포함) 명령에 넘긴다.
  - 명령이 끝나면 결과를 쓰고, 묶음에 남은 것이 스스로 정리하고 끝나기를 기다린다(멈춤 신호 30초 `stopGraceMs`, 시간 제한 5초). 비면 바로 끝난다.
  - 유예가 지나도 남으면 그때 살아 있는 모든 것을 SIGKILL한다. 결과를 못 써도(작업 폴더가 지워짐) 같다.
  - 그동안 껍데기가 우두머리로 살아 있어 `check`도 묶음을 증명할 수 있다. 그래서 `check`가 유예 중에 죽어도 손주가 남지 않는다.
- 껍데기만 죽고(SIGKILL) 명령이 살아 있으면 `dead`. 명령이 아직 껍데기 묶음에 있으면 그 묶음째 끈다. 명령도 이미 끝났으면 남은 손주의 묶음이 우리 것임을 증명할 길이 없어 건드리지 않는다.
- 보통은 `timeoutMs`가 먼저 걸려 `done`(`timedOut`)이 된다. `maxMs`는 껍데기마저 멈췄을 때의 뒷받침이다. `launch` 때 `spec.json`에 적으므로 띄운 뒤 목록을 바꿔도 그 시도에는 닿지 않는다.
- 한계: `maxMs`는 누군가 `check`를 부를 때만 걸린다. 스레드가 끝나(GAVE_UP·만료·보류) 아무도 확인하지 않으면 껍데기 자신의 `timeoutMs`만 남는다. 껍데기마저 멈춘 것을 치우려면 틱이 `jobs/`를 훑어야 한다(1a 제안).
- 순서: 목록 검사는 `maxSeconds > timeoutSec`만 본다. `LG_DETACH_MAX_SEC`를 명령의 `timeoutSec`보다 작게 주거나 둘의 차이가 5초 이하면, 그 사이에 `check`가 불릴 때 껍데기보다 먼저 끈다(`done`(timedOut) 대신 `dead`(timeout)).
- `tools.check`의 `done`은 성공이 아닐 수 있다 — 그래프는 `timedOut`·`code`를 직접 본다(`checkAsk`는 실패를 `failed`로 낸다).

## 부수효과 `effect(key, kind, fn)` (S10)

원장 `effects.jsonl`(추가 전용). 그림자: `{key, kind, wouldRun}`만(같은 key는 한 줄). 실제: `started` → `fn` → `ok`/`failed`.
**보고성 종류(`REPORT_KINDS` — 지금 `orders_append`)는 그림자에서도 실제 길로 낸다**(기록에 `report:true`). 그림자가 막는 것은 코드 변경·배포이지 발견을 알리는 일이 아니다(10-06: 고스톱 QA 발견 9건이 '했을 일'로만 남아 수리 목록에 0건). 당직 장부(`duty.ledger_append`)는 공사 동결이라 그대로 그림자. 중복 막기는 모드를 가리지 않고 같은 key 의 실제 기록(`would_run` 이 아닌 줄)으로 본다 — 옛 그림자 '했을 일'은 실행을 막지 않는다.
같은 key가 `ok`면 다시 하지 않는다(다른 스레드라도). `started`만 있고 끝이 없으면 결과를 모르니 보류 — `verify()`가 일어났다고 확인하면 `ok`로 적고 넘어간다. 같은 key를 두 프로세스가 동시에 내지 않게 key별 잠금(죽은 주인 것만 넘겨받는다).

## 기록·집계 (S17)

`metrics.jsonl`(추가 전용, 600). **gc 대상이 아니다** — 판정일(11-26) + 30일까지 보존. 원문(질문·프롬프트·출력)은 적지 않는다(오류는 머리말만).

| 사건 | 필드 |
|---|---|
| `start` · `done` · `gave_up` · `expired`(kind: approval·hold) | thread · graph · mode · (done) `verified` ← 그래프 상태의 `verify_log`(M2) |
| `node_start` · `node_end` | node · ok · ms |
| `continue`(reason: budget·pending·paused) · `interrupted`(cause: signal·exit·stalled) · `resumed`(from) | |
| `waiting`(reason ← interrupt 값의 `reason`, M5) · `answered`(decision) | |
| `held` | scope(tick·thread·command·sweep) · reasons(관문 이름·llm_day·llm_thread·token_cap·login·usage_limit·code_defect·node·effect_unknown·stuck·hook_leak) |
| `reclaim` | scope(tick) · ran · busy · free_before · free_after · steps · error — 디스크 관문 자가 회복(10-05, lib/reclaim.mjs → 워크스페이스 scripts/disk-reclaim.sh, 당직과 같은 도구) |
| `llm` | model · models · in · out · cache_create · cache_read · total · cost_usd · ms · ok · detached |
| `effect`(outcome: would_run·ran·dedup·failed·unknown·recovered, key 는 지문만 — 원문은 effects.jsonl) · `stuck` · `tick` · `gc` · `failed` · `bench`(M8) | |
| `lg.duty.verify`(D0) | phase(verify·compare) · verdict · restart · reasons · tool_fail·tool_ok·gwlog_fail · agreement · kind · survival |
| `lg.restart.heartbeat`(D0, 틱마다) | gw_pid · gw_start · gw_up · open · jobs |

**M2 확인 기록(`verify_log`):** 그래프는 끝나기 전에 확인한 것을 상태 `verify_log` 에 적고, 확인이 안 되면 비워 둔다(빈 값 = 검증 없는 완료). gostop-qa 요약 파일 + 올린 발견 id 가 전부 지시함에 있음 · gostop-intake 장부를 다시 읽어 올린 것이 '본 것'에 있고 전날까지 본 것을 다시 올리지 않았고 하루 상한 안 · gostop-fix 끝난 상태의 근거(`fixVerifyLog` — ready·would_ask 는 마지막 수정의 격리 검증 전부 통과 + 검토 통과, 포기는 비움) · duty-verify 판정 ok·broken(unknown 은 비움) · smoke 수집·초안·승인 답.

**감시(`scripts/lg-watch.mjs`, 매일 08:40):** `lg-report --json` 을 최근 24시간·전체·7일(벤치) 세 창으로 읽어 기준 밖이면 요약을 내고 지시함 끝에 `- [ ] (당직 몫) **랭그래프 이상 — …** [lg-watch:<열쇠>]` 를 덧붙인다(같은 열쇠의 열린 줄이 있으면 다시 안 올림). 보는 것: 틱 0회 · M2 · M3 중복·결과 모름 · M4 · M7 · M1 버려짐 · Fable · 보류(같은 사유 하루 6회 또는 연속 4틱, 야간 금지 quiet 는 뺌, code_defect·effect_unknown·hook_leak·stuck 은 1회부터) · 벤치 M8 기준 미달·한 번도 안 잰 칸 · 고스톱 실기 QA 상급 발견(오늘·어제 `signals.json`)이 지시함에 없음.

`node lg-report.mjs`가 M1(끊긴 스레드 중 다음 틱들이 이어 간 비율 — 끊긴 뒤 단계를 하나라도 끝냄. 그 뒤 사람이 답하지 않은 승인 만료는 '버려짐'이 아니다) · M3(같은 key 중복 실행 — verify 가 '안 일어났다'고 확인한 뒤의 재실행은 중복이 아니다) · M4(끝나지 않은 스레드 중 마지막 기록이 48시간 넘은 것 — 대기열·답 받음 포함) · M6(날짜별 호출·토큰·비용, Fable 0) 표와 M2·M5·M8 칸을 낸다.

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
1a: `LG_DAILY`(gostop-intake@04:30) · `LG_GOSTOP_REPO` · `LG_GOSTOP_SOAK_DIR`.
1b: `LG_GOSTOP_STAGE`(1b, 스레드 시작 때 고정) · `LG_GOSTOP_SONNET_CAP`(7) · `LG_GOSTOP_OPUS_CAP`(3) · `LG_RELEASE_CERT_SHA256` · `LG_FAD_APP_ID` · `LG_FAD_GROUPS`(testers).
0b: `LG_TICK_BUDGET_SEC`(480) · `LG_JOB_LIMIT_SEC`(600, 틱 안 LLM·명령이 끝나야 하는 시각) · `LG_DETACH_MAX_SEC`(5400, 목록에 `maxSeconds`가 없을 때의 분리 실행 최대 시간) · `LG_HOLD_TTL_HOURS`(48) · `LG_MAX_RETRIES`(3) · `LG_MAX_STEPS`(500) · `LG_LOCK_STUCK_MIN`(30, 옛 이름 `LG_LOCK_STALE_MIN`도 받는다) · `LG_DAY_TOKEN_CAP`(3000000) · `LG_DISK_PATH` · `LG_DISK_FLOOR_GIB`(15) · `LG_COPY_EST_GIB`(0.2, 1a 실측) · `LG_DISK_MARGIN_GIB`(1) · `LG_USAGE_FILE` · `LG_USAGE_MAX_PCT`(80) · `LG_USAGE_MAX_AGE_H`(13) · `LG_QUIET`(01:30-04:30, 빈 값이면 끔) · `LG_LOGIN_RECHECK_MIN`(360) · `LG_LIMIT_RECHECK_MIN`(60) · `LG_HOOK_LOGS`(콜론 구분).
시험 전용 — `LG_TEST_MODE=1`일 때만 먹는다: `LG_NOW`(시간 주입) · `LG_CMD_REGISTRY` · `LG_TEST_START_AT` · `LG_TEST_HEARTBEAT_SEC` · `LG_SMOKE_TRACE` · `LG_SMOKE_CRASH_ONCE` · `LG_SMOKE_CRASH_CODE`.

## OpenClaw 연결 예(등록하지 않았다)

```bash
~/bin/openclaw automations create "*/30 * * * *" --tz "Asia/Seoul" \
  --name "graphs: lg-tick" \
  --command 'sh infra/graphs/lg.sh tick' \
  --command-cwd "$HOME/projects/jarvis" \
  --timeout-seconds 900 \
  --announce
```

`--command`는 `sh -lc`로 돈다. 명령형 잡 10분은 기본값이지 상한이 아니다(10-03 실측: `--timeout-seconds 900`에서 700초를 끝까지 돌았다. 900초를 넘는 값은 재지 않았다).
- 틱 예산은 480초 그대로다. 예산은 다음 노드 앞에서 재므로 노드 하나가 넘칠 수 있다. 900으로 등록하면 그 여유가 2분에서 7분으로 는다.
- 틱 안 LLM·명령은 `LG_JOB_LIMIT_SEC`(600초) 안에 끝나게 줄인다. 남는 5분은 여유로 둔다.
- 분리 실행은 잡 시간 상한 밖에서 돈다. 그래서 `maxSeconds`로 스스로 끈다(위 '분리 실행').
- 실패한 1회성(`--at`) 잡은 30초·1분·5분 뒤 세 번 더 돈다. 그런 잡의 내용은 여러 번 돌아도 안전해야 한다.

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

0a 50개 + 0b 59개(틱·답·관문 9종·토큰 상한·로그인·만료·재시도·코드 결함·STUCK·끊김·알림 필터·PAUSED·분리 실행 그래프·겹친 틱·알림함·고장 격리 / 분리 실행 판정·이중 실행·heartbeat·부모 죽음·최대 시간 초과(시간 주입·SIGTERM만으로·SIGKILL까지·증명 못 하면 안 끔·끄는 쪽이 죽어도·정리하는 손주는 기다림)·시간 제한 때 묶음째(결과를 못 써도)·껍데기만 죽음·LLM 분리 / 정적 검사 양성·음성·가져오기·실행기 거부·허용 목록(maxSeconds 포함)·run·effect·모드 고정·훅 누수·gc 보존·관문 해석·집계·잡 상한 / 독립 검토 재현 13건). + 1a 29개(사본 역사 없음·비밀·기록 문서 제외·본 저장소 불변·재현 2회·흔들림·재현 안 됨·제보만 → 규칙 공백·범위 미리 보기(그림자 would_ask / 실제 owner_gate)·대화 작업 표식 HOLD·시간 초과 묶음째·죽음 뒤 다시 띄움·이중 실행·진단 재시도(sonnet ×≤2, 한도 뒤 쉼)·회귀 주입·벤치 누설·채점·접수(소크·CI·벤치·하루 3건·이월)·S13(차례 대기는 만료 안 함)·하루 1회 접수·사본 정리·허용 목록·디스크 계산식·도우미·벤치 목록·고장 주입 2). 실호출 2개(haiku·gostop-live)는 평소 건너뛴다.
0a 시험 기대값 3곳은 의도된 변경으로 바꿨다: 격리 플래그(`--restricted`), claude 작업 폴더(홈 밖), DB 판 번호(4).

## 걷어내는 법

1. 이 실행기를 부르는 잡을 끈다: `~/bin/openclaw automations list --all`에서 찾아 `~/bin/openclaw automations disable <jobId>`.
2. 기록을 내보낸다: `node infra/graphs/lg-report.mjs --json > <보관 위치>`.
3. 폴더를 버린다: `trash ~/projects/jarvis/infra/graphs` 후 커밋.
4. 상태도 필요 없으면 `trash ~/.openclaw-data/runtime/state/graphs`.
