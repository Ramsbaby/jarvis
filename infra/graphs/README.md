# infra/graphs — LangGraph 실행 뼈대

**그래프 모양인 일만** 돌리는 전용 엔진이다. 초안→비평→수정을 되풀이하거나, 모델이 다음 길을 고르거나, 사람 승인을 기다리는 일이 여기에 해당한다.
모든 자동화의 뼈대가 아니다. 한 줄로 이어지는 작업은 지금처럼 OpenClaw 예약 잡으로 둔다.
1단계에는 운영과 분리된 뼈대만 있다: 실행기, 안전장치, 연기 시험 그래프(`smoke`), 시험. 첫 실제 대상은 2단계의 고스톱 버그 사냥·수정 루프다.

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
sh $G/lg.sh start smoke smoke-2026-10-03 [--topic 주제] [--llm]   # 승인 대기까지 돌고 멈춘다(--llm: haiku 1회)
sh $G/lg.sh resume smoke-2026-10-03 approved                     # 또는 rejected
sh $G/lg.sh retry smoke-2026-10-03          # 고장·보류로 멈춘 스레드를 마지막 저장 단계부터 잇는다
sh $G/lg.sh status [<스레드>] [--json] [--all]   # 읽기만 한다(만료 확정·알림은 다른 명령과 sweep 이 한다)
sh $G/lg.sh sweep                           # 기한 지난 승인 대기를 자동 취소
sh $G/lg.sh gc [--days 14]                  # 오래된 스레드 삭제 + VACUUM
sh $G/lg.sh selftest
```

### 출력·종료 코드 규칙

표준 출력 **첫 줄이 결과**다. 첫 낱말은 정해진 몇 개뿐이다.

| 첫 줄 | 뜻 | 종료 코드 |
|---|---|---|
| `DONE <스레드> <결과>` | 끝남 | 0 |
| `WAITING <스레드> <질문 요약>` | 승인 대기. `pending.jsonl`에 적힌다. 둘째 줄은 답하는 법과 기한 | 0 |
| `HELD <스레드> <이유>` | LLM 호출 상한에 닿아 보류. 풀리면 `retry` | 0 |
| `EXPIRED <스레드> <질문>` | 승인 기한(기본 48시간) 초과 → 자동 취소 | 0 |
| `NO_REPLY` | `sweep`에서 치울 것이 없음. OpenClaw가 아무것도 보내지 않는다 | 0 |
| `ERROR <스레드> <종류> <설명>` | 종류: `busy`·`exists`·`expired`·`not-waiting`·`failed`·`crashed`·`multi-interrupt`·`blocked`·`selftest`·`usage` 등 | 1 |

**대기를 0으로 끝내는 이유:** OpenClaw는 0이 아닌 종료 코드를 error로 적고 실패 경보를 낸다. 승인 대기는 정상 상태이므로 경보 소음이 되면 안 된다.
그 대신 첫 줄을 `WAITING`으로 시작해 알림에 그대로 보이게 했다. 평소 실행에서는 stderr에 아무것도 쓰지 않는다(stderr가 섞이면 OpenClaw 알림이 `stdout:`/`stderr:` 묶음으로 바뀐다).

`pending.jsonl`은 지금 대기 중인 스레드만 한 줄씩 담는다: `{"thread","graph","question","since","deadline"}`. 명령마다 등록부에서 다시 만든다.
만료 알림: 어느 명령이든 자기가 이번에 만료시킨 것을 결과 줄 뒤에 `EXPIRED` 줄로 붙인다(명령이 실패해도). '알렸음' 표시는 `sweep`만 한다 — 예약 sweep 잡의 알림이 정본이고, 대화 중 명령이 그 알림을 가로채지 않는다.
노드가 찍는 `console` 출력은 표준 출력에 섞이지 않고 `state/graphs/logs/<스레드>.log`(600)로 간다. gc 가 스레드와 함께 지운다.

## 안전장치

| 장치 | 막는 것 | 시험 |
|---|---|---|
| 스레드별 잠금(SQLite 즉시 트랜잭션), 죽은 pid의 잠금은 인계 | 동시 재개 때 승인·반려가 둘 다 실행(위험 1) | 3스레드×5회 동시 재개 → 스레드당 finalize 1회 |
| 이미 있는 스레드에 start 거부 | 대기 중 스레드가 처음부터 다시 돌아 LLM 반복(위험 2) | 중복 start |
| 시작하자마자 `LANGSMITH_*`·`LANGCHAIN_*` 삭제 | 추적 변수 하나로 데이터가 밖으로 나감(위험 3) | 닫힌 프록시 + `NODE_USE_ENV_PROXY=1` → 연결 시도 0 |
| DB는 공개 저장소 밖 `~/.openclaw-data/runtime/state/graphs/checkpoints.db`(폴더 700·파일 600, umask 077), `secure_delete=ON`, `gc` 14일 + VACUUM | 체크포인트에 평문이 쌓이고 지워도 남음(위험 4) | gc 뒤 가짜 표식 0, 권한 |
| interrupt 노드 정적 검사(`scripts/check-interrupt-nodes.mjs`). 실행기도 그래프를 열 때마다 검사 | 재개 때 노드가 처음부터 다시 돌아 LLM·발송이 두 번(위험 5) | 양성·음성 |
| 시작할 때 better-sqlite3 자가 시험 | 설치 스크립트 누락으로 생기는 조용한 고장(위험 6) | 네이티브 파일을 뺀 사본 → 원인·처방을 말하고 1 |
| `claude -p`를 project 설정만·빈 폴더·깨끗한 환경변수로 부름. 로그인은 이 맥의 것 그대로 | 사용자 훅이 운영 위키·RAG에 씀(위험 7·8) | 가짜 claude로 인자·환경 확인 |
| LLM 상한 스레드당 5회·하루 20회 → `HELD`, Fable 차단, 기본 sonnet | 구독 한도 잠식 | 상한·차단 |
| 승인 기한 48시간 → `EXPIRED` 자동 취소(그래프 코드는 돌리지 않음). 기한은 실행기가 그 질문을 내보인 때부터, 답을 적용하면 대기 기록을 비운다. 고장으로 기록이 빠지면 마지막 실행 시작·체크포인트 시각 중 늦은 쪽부터(기한이 늘지 않게). sweep 은 장부로 후보를 고르고 그래프 상태로 확인한다(그래프 파일이 없으면 장부 기한으로) | 영원히 멈춘 일, 기한 연장, 보이기도 전 만료 | 시간 주입·장부 훼손·변이 |
| 승인 대기가 동시에 2개 이상이면 받지 않음(`multi-interrupt`) | 답 하나가 사람이 못 본 질문까지 승인 | 병렬 interrupt 그래프 |
| interrupt 없이 멈춘 스레드는 `blocked` — retry 거부 | 정적 중단점을 retry 가 승인 없이 통과 | 중단점 그래프 |
| gc: 1일 이상만, 기한 전 대기·잠긴 스레드는 안 지움, VACUUM 뒤 `-wal` 이 비워졌는지 확인해 못 비우면 ERROR | 승인 대기 삭제·하루 상한 초기화·평문 잔존을 OK 로 보고 | 빈 값·0일·읽기 연결 |
| 노드 출력은 스레드 로그로(자식 프로세스 `stdio: "inherit"`·fd 1 직접 쓰기는 검사기가 막음), 노드가 `process.exit(0)` 해도 종료 1, 잠금에 프로세스 시작 시각 | 첫 줄 규약 깨짐·경보 묻힘·pid 재사용 | 각 시험 |
| 판이 오르면 빠진 칸을 더한다(`PRAGMA user_version`) | 옛 DB 에서 새 판이 죽음 | 옛 표 구조 |

## 설정(환경변수)

`LG_STATE_DIR`(상태 폴더, 전용 폴더여야 한다) · `LG_DB` · `LG_APPROVAL_TTL_HOURS`(48) · `LG_GC_DAYS`(14) · `LG_LLM_MAX_PER_THREAD`(5) · `LG_LLM_MAX_PER_DAY`(20) · `LG_LLM_MODEL`(sonnet) · `LG_LLM_TIMEOUT_SEC`(300) · `LG_CLAUDE_BIN` · `LG_LOCK_STALE_MIN`(360) · `LG_NODE`.
`LG_BUSY_TIMEOUT_MS`(15000).
시험 전용 — `LG_TEST_MODE=1`일 때만 먹는다: `LG_NOW`(시간 주입, 시험 모드 밖이면 오류로 멈춘다) · `LG_TEST_START_AT`(동시성 시험 출발선) · `LG_SMOKE_TRACE` · `LG_SMOKE_CRASH_ONCE` · `LG_SMOKE_CRASH_CODE`.

## 그래프를 쓰는 규칙(2단계용)

- `graphs/<이름>.mjs`는 `build({ checkpointer, llm })`, `input(flags)`, `summarize(values)`를 내보낸다.
- **interrupt가 든 노드는 동기·순수다:** 상태 읽기 → `interrupt(...)` → 값 반환. LLM·파일·발송은 앞뒤 노드로 뺀다. 그 안의 호출은 허용 목록(문자열·배열 메서드, `JSON`·`Math`·`Object` 등)만 통과한다.
- 노드는 `addNode("이름", 함수)` 형식으로 쓴다(같은 파일 함수만 따라가 검사한다). `interrupt`는 그래프 파일 안에서 직접 부르기만 한다 — 별칭·다른 모듈에 감추기 금지(가져오는 모듈까지 따라가 검사한다).
- 노드 안에서 하위 그래프·모델을 `.invoke()`/`.stream()` 하지 않는다. 정적 중단점(`interruptBefore/After`)은 쓰지 않는다. 승인 대기는 한 번에 하나.
- 자식 프로세스 출력은 받아서 다룬다(`stdio: "inherit"` 금지) — 실행기의 첫 줄을 차지한다.
- interrupt 노드는 자기 인자·지역 값·안전한 내장(`JSON`·`Math`·`String` 등)·같은 파일 함수만 쓴다. 바깥(모듈 수준) 값이나 다른 모듈의 것을 쓰면 위반이다(상수도) — 필요한 값은 앞 노드에서 상태에 넣는다. 허용 목록 메서드도 그런 값에서만 통과한다.
- 같은 꾸러미 모듈은 상대 경로로 가져온다(`#별칭`은 검사가 따라가지 못해 위반).
- 검사기는 정규식·괄호 짝 수준의 정적 검사다. 다 막지 못한다 — 2단계에선 부수효과를 `effect(key, fn)` 같은 한 입구로 모으는 것을 함께 쓴다.
- LLM은 `llm.ask(prompt, { model, node, timeoutMs })`로만 부른다. 상태에는 원문 대신 참조(경로·id)를 둔다.
- 노드가 스스로 멈춰야 하면(디스크 부족·잠금 등) `throw Object.assign(new Error("이유"), { held: true })`. 실행기가 `HELD`(0)로 두고, `retry`로 그 노드부터 잇는다.
- 실행기가 시간 초과 신호(SIGTERM)로 끝나면 장부에 `failed`를 남기고, 잠금을 풀고, 돌던 claude 자식도 끈다.

## OpenClaw 연결 예(등록하지 않았다)

```bash
~/bin/openclaw automations create "0 9 * * *" --tz "Asia/Seoul" \
  --name "graphs: smoke" \
  --command 'sh infra/graphs/lg.sh start smoke "smoke-$(date +%F)"' \
  --command-cwd "$HOME/projects/jarvis" \
  --timeout-seconds 600 \
  --announce
~/bin/openclaw automations create "30 9 * * *" --tz "Asia/Seoul" \
  --name "graphs: sweep" \
  --command 'sh infra/graphs/lg.sh sweep' \
  --command-cwd "$HOME/projects/jarvis" \
  --announce
```

`--command`는 `sh -lc`로 돌기 때문에 `$(date +%F)`가 실행할 때마다 풀린다. 1회 상한은 600초다. 스레드 이름은 흐름+날짜로 고정한다.

## 대화 중 재개

자비스는 `WAITING` 알림이나 `status`에서 스레드 이름을 읽는다. 주인님의 답을 받으면 아래 명령을 실행한다.

```bash
sh ~/projects/jarvis/infra/graphs/lg.sh resume <스레드> approved   # 또는 rejected
```

첫 줄이 `DONE`이면 끝난 것이다. `ERROR … busy`는 다른 쪽이 처리 중이라는 뜻이고, `ERROR … expired`는 기한이 지나 이미 취소됐다는 뜻이다. 둘 다 같은 명령을 되풀이하지 않는다.
LLM 노드가 많은 그래프는 맥 노드 exec 20초 함정에 걸릴 수 있다. 그럴 때는 하네스 셸이나 `host=gateway`로 부른다.

## 시험

```bash
cd infra/graphs && ~/.nvm/versions/node/v24.21.0/bin/node --test test/*.test.mjs        # 임시 HOME·임시 상태 폴더, 실호출 없음
RUN_LLM=1 ~/.nvm/versions/node/v24.21.0/bin/node --test test/llm.test.mjs               # 실제 haiku 1회(한도 사용)
```

## 걷어내는 법

1. 이 실행기를 부르는 잡을 끈다: `~/bin/openclaw automations list --all`에서 찾아 `~/bin/openclaw automations disable <jobId>`.
2. 폴더를 버린다: `trash ~/projects/jarvis/infra/graphs` 후 커밋.
3. 상태도 필요 없으면 `trash ~/.openclaw-data/runtime/state/graphs`.
