# infra/graphs — LangGraph 실행 뼈대

**그래프 모양인 일만** 돌리는 전용 엔진이다. 초안→비평→수정을 되풀이하거나, 모델이 다음 길을 고르거나, 사람 승인을 기다리는 일이 여기에 해당한다.
모든 자동화의 뼈대가 아니다. 한 줄로 이어지는 작업은 지금처럼 OpenClaw 예약 잡으로 둔다.
공통 부품(0a·0b): 실행기(틱 방식), 관문, 분리 실행, 명령·부수효과 입구, 판정 기록, 연기 시험 그래프(`smoke`), 시험.
첫 실제 대상(1a): 고스톱 버그 루프의 읽기 전용 부분 — 접수(`gostop-intake`)·수정(`gostop-fix` ①~⑥·⑭). 아래 '고스톱 루프(1a)'.

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
| `disk` | 여유 < 15GiB + 사본 예상 + 1GiB(기본 16.4GiB — 사본 실측 0.4) | 감지기와 같은 재는 법(statvfs bavail, `/System/Volumes/Data`). `LG_DISK_FLOOR_GIB`·`LG_COPY_EST_GIB`(1a 실측으로 바꾼다)·`LG_DISK_MARGIN_GIB` |
| `usage_high`·`usage_unreadable`·`usage_stale` | 주간 사용량 ≥ 80% · 못 읽음 · 6시간 넘게 묵음 | 감지기(`orchestrator-scan.py` `scan_usage` → `usage_findings`)가 `claude -p /usage`로 받아 `state/orchestrator/latest.md`의 '클로드 사용량' 줄에 쓰는 값을 **읽기만** 한다. 주간 범위 중 Fable(금지 모델)은 뺀다. 스냅샷은 정규 회차(08·11·14·17·20시)에만 새로 쓰이므로 **밤 02시 무렵부터 08시까지는 '묵음'으로 쉰다** |
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
  preflight(소크 잠금이면 HOLD · 3일 지난 사본 정리) → collect(어젯밤 소크 summary.json · 직전 접수 뒤 CI 실패 · 없으면 벤치 1건)
  → dedupe(gostop/intake-state.json) → enqueue(gostop-fix 대기열, 하루 3건)
gostop-fix:<sigkey>  (meta.serial — 한 번에 하나, S13)
  ① preflight  대화 작업 표식(.jarvis-busy · 모든 가지 30분 안 커밋)이면 HOLD(busy). 대상 커밋을 전체 해시로
  ② sandbox    git archive → gostop/sandbox/<키>/work(사본)·clean(깨끗한 내보내기, 1b 패치 기준). .git 없음(역사 0),
               .claude·.mcp.json·key.properties·*.jks·*.keystore·google-services.json 제외, pub get --offline
  ③ reproduce  기존 시험 2회(분리 실행) → reproduced · not_reproduced · flaky. 죽음·시간 초과는 같은 회차를 다시(3회 → gave_up)
  ④ diagnose   sonnet ×≤2, --restricted, Read·Grep·Glob, 작업 폴더 = 사본, --json-schema(가설·파일·규칙 공백·확신도·근거)
  ⑤ scope_precheck  §4① 허용 목록 밖·AI 영역(lib/domain/ai/**·MCTSConstants)이면 승인 사유
  ⑥ owner_gate 실제 모드 + 사유일 때만(순수 interrupt). 그림자는 plan 이 would_ask 로 적기만
  ⑭ plan       runs/<키>/plan.md·result.json(+haiku 요약 1회). 상태: ready·rule_decision·would_ask·not_reproduced·flaky·gave_up.
               벤치면 판정 M8(bench). 사본의 build·.dart_tool 은 지우고 사본은 3일 보관
```

- 신호 열쇠: `soak:normal:<씨앗>:<head8>` · `soak:problem:<날>:<head8>:<해시>` · `ci:<워크플로>:<sha8>` · `bench:<id>:r<회차>`.
- 벤치 `bench/gostop.json`: 역사 2(69a0144 국진 두 길 → ready, 02d61dc 판 끝 조커 → rule_decision) + 회귀 주입 14(현재 코드에 지난 수정의 핵심 줄을 거꾸로 — 지금 있는 시험이 잡는 것만). 사례마다 빨간불 직접 확인 기록(`red`).
- 명령(cmd-registry): `git.rev-parse`·`git.last-commit-time`·`git.archive`(본 저장소 읽기) · `tar.extract-sandbox` · `flutter.pub-get-offline`·`flutter.test-defines`·`flutter.test-file`(사본 안, 작업 폴더 정규식이 `…/gostop/sandbox/<키>/work|clean` 만) · `gh.run-list`·`gh.run-log-failed`(읽기 전용, 작업 폴더 = 본 저장소 → 원격으로 저장소를 정한다). 최대 시간은 실측 × 1.5(재현 46초 → 69초).
- 실측(10-03): 사본 92MB + 시험 뒤 build 91MB + 깨끗한 내보내기 92MB(+ 풀기 전 tar 91MB) → `LG_COPY_EST_GIB` 0.4. 1판 재현 15~46초(첫 컴파일 포함). `--restricted` 에서도 작업 폴더의 CLAUDE.md 가 실린다(고스톱 41.8KB → 입력 맥락 약 +2만 토큰, 캐시됨).
- 실호출: `RUN_LLM=1 node --test test/gostop-live.test.mjs`(haiku 1회 — 밖 읽기 거부·구독 로그인·훅 0·CLAUDE.md) · `node test/gostop-bench-live.mjs <출력> hist-69a0144 hist-02d61dc`(임시 상태 폴더, 진짜 flutter·sonnet).
- 설정: `LG_GOSTOP_REPO`(기본 ~/projects/gostop_app) · `LG_GOSTOP_SOAK_DIR`(기본 ~/.openclaw/workspace/state/gostop-soak) · `LG_DAILY`(기본 `gostop-intake@04:30`, 빈 값이면 끔).

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
| `llm` | model · models · in · out · cache_create · cache_read · total · cost_usd · ms · ok · detached |
| `effect`(outcome: would_run·ran·dedup·failed·unknown·recovered, key 는 지문만 — 원문은 effects.jsonl) · `stuck` · `tick` · `gc` · `failed` · `bench`(M8) | |

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
0b: `LG_TICK_BUDGET_SEC`(480) · `LG_JOB_LIMIT_SEC`(600, 틱 안 LLM·명령이 끝나야 하는 시각) · `LG_DETACH_MAX_SEC`(5400, 목록에 `maxSeconds`가 없을 때의 분리 실행 최대 시간) · `LG_HOLD_TTL_HOURS`(48) · `LG_MAX_RETRIES`(3) · `LG_MAX_STEPS`(500) · `LG_LOCK_STUCK_MIN`(30, 옛 이름 `LG_LOCK_STALE_MIN`도 받는다) · `LG_DAY_TOKEN_CAP`(3000000) · `LG_DISK_PATH` · `LG_DISK_FLOOR_GIB`(15) · `LG_COPY_EST_GIB`(0.4, 1a 실측) · `LG_DISK_MARGIN_GIB`(1) · `LG_USAGE_FILE` · `LG_USAGE_MAX_PCT`(80) · `LG_USAGE_MAX_AGE_H`(6) · `LG_QUIET`(01:30-04:30, 빈 값이면 끔) · `LG_LOGIN_RECHECK_MIN`(360) · `LG_LIMIT_RECHECK_MIN`(60) · `LG_HOOK_LOGS`(콜론 구분).
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
