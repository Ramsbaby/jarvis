# 자기 치유 · 자기 발전 계획 (2026-09-04)

> 한 문장: **고치는 자·채점하는 자·적용하는 자를 분리하고, 자율 에이전트는 본체를 못 만지게 하며, 권한은 실측 지표로만 올린다.**
> 전제 문서: [JARVIS-EVOLUTION-PROGRAM.md](JARVIS-EVOLUTION-PROGRAM.md) ("자비스가 자기 완료를 자기가 채점하지 못하게 만든다"). 이 계획은 그 프로그램의 빈 구멍을 메우는 것이지 5번째 층을 얹는 것이 아니다.

## 0. 왜 지금까지 안 됐나 — 실측 (2026-09-04 조사)

| 층 | 설계 의도 | 실제 상태 | 근거 |
|---|---|---|---|
| 고장 감지 | 크론 실패 → 티켓 | cron.log 마지막 줄 grep(`FAILED`)이라 **빈 출력·xtrace 잔재도 고장** | `infra/scripts/cron-auditor.sh:44-57`, 9/4 daily-summary 4회 |
| 수리공(코더) | 격리된 곳에서 고침 | cwd 만 `/tmp/bot-work`, 도구는 `Bash,Read,Write,Edit` + `bypassPermissions` → **`~/jarvis` 전역 쓰기**. worktree 없음, 금지 경로 0줄 | `infra/bin/ask-claude.sh:94,501`, `infra/lib/llm-gateway.sh:141-146` |
| 스냅샷/롤백 | 실패하면 되돌림 | `git -C runtime add -A` = 저장소 전체 스테이징(남의 편집까지 삼킴). 원복은 `infra/**` 에 안 닿아 **2026-07-27 항복 주석** | `infra/lib/coder-functions.sh:612-620, 286-296` |
| 성공 판정 | 독립 검증 | 성공 기준을 코더가 쓰고, `verifyCmd` 빈 값이면 **자동 통과**. verify-gate 는 호출 실패·파싱 실패 시 **통과(fail-open)** | `infra/scripts/verify-sprint-contract.sh:85-91`, `infra/lib/verify-gate.sh:127-152` |
| 반복 제어 | 한 번 시도 후 판단 | `task-store ensure` 가 done 을 매일 밤 queued 로 되돌려 **같은 티켓 무한 반복** → 9/4 쿨다운으로 지혈 | `runtime/lib/task-store.mjs:371-385`, 커밋 3b5e9e4 |
| 차단 훅 | 위험 명령 사전 차단 | 9/2 03:03 오너 지시로 41개 제거, 재배선 8개는 전부 수집형. **exit 2 훅은 runtime-guard 1개** | `~/.claude/settings.json:144 _hooksRemoved` |
| 설정 무결성 | tasks.json 감시 | `enabled_total` 개수만 기록, **해시 없음·정기 백업 없음** → 9/4 7월 백업(136개)으로 덮어써도 통과 | `infra/scripts/tasks-integrity-audit.sh`(sha/md5 0건) |
| 실수→규칙 반영 | 자동 학습 | 수집 ● 패턴화 ◐ 반영 ○. `PROMOTER_WRITE_RULES` 게이트로 2026-07-19 부터 OFF, 대상 파일 8/2 철거. ~~입력도 끊김(learned-mistakes 223건 vs ledger 4건)~~ → 9/5 정정: 입력은 멀쩡(30일치 vs 7일치 오비교). 진짜 단절은 판정 결과(rule_block)가 `report_only` 로 버려진 것 — 4b 에서 제안서로 수리 | `infra/scripts/mistake-promoter.mjs:227-237` |
| 스킬 합성 | 반복 작업 스킬화 | **83일 연속 0바이트**, `runtime/skills/skills.jsonl` 부재 | `runtime/state/skill-drafts/selected-*.jsonl` |
| 주간 자기평가 | 월 09:00 north-star·scorecard | 로그 8/17 이후 없음 — 8/24·8/31 분은 9/2 소실로 잃었을 가능성. **9/7 월요일 실행으로 판정** | `runtime/logs/self-evolution-weekly.log` |
| 되돌리기 | 잘못 고친 것 revert | **없음.** 유일한 차단 게이트 `capability-merge-gate.sh` 는 호출자·근거 원장 7/25 정지 | `runtime/ledger/independent-verify.jsonl` |

요약: 감시는 30개 넘게 돌고(LaunchAgent 감사류), **집행은 1개, 검토는 0개, 되돌리기는 0개**. 그래서 "고치는 놈"만 있는 구조에서 9/2 소실과 9/4 덮어쓰기가 났다.

## 1. 원칙

1. **분리** — 고장 판정 / 수정 / 검토 / 적용은 서로 다른 프로세스가 한다. 같은 세션이 둘 이상을 겸하지 않는다.
2. **본체 불가침** — 자율 에이전트(코더·heal)는 `~/jarvis` 본체에 쓰지 않는다. worktree 에서 작업하고 브랜치·패치로 제출한다. 집행은 훅(코드)이 한다, 프롬프트 문장이 아니다.
3. **신호가 틀리면 치유는 파괴다** — 고장 판정은 exit code + 결과 파일 + 상태 DB 로 하고, 오탐율을 지표로 잰다.
4. **한 번 실패한 자동 수리는 사람에게** — 쿨다운(적용됨). 두 번째 실패는 구조 문제다.
5. **권한은 실측으로만 상승** — 자동 머지 허용 범위는 클래스별 승인 이력으로 넓힌다. 처음엔 0.
6. **죽은 층은 지운다** — 돌지만 산출 0인 자동화는 오탐과 비용만 낸다. 되살릴 근거가 없으면 비활성.

## 2. 단계

### 0단계 — 지혈 (9/4 완료 / 주인님 조치 대기)

| 항목 | 상태 |
|---|---|
| 빈 출력 = 정상(`allowEmptyResult`/`emptyResultToken`) | ✅ fc4ca46 |
| `unknown` 티켓 생성 차단, auditor 라벨 확장 | ✅ 10dd381 |
| xtrace 잔재 BUDGET_EXCEEDED 오분류 | ✅ fe9845b |
| tracker `DRY_RUN` env 존중 + 72h 쿨다운 | ✅ 60a5d24·3b5e9e4 |
| tasks.json 122개 복원, 7월 파일 격리 | ✅ (백업 `bak-coder-clobber-20260904-155246`) |
| 코더가 만든 `com.jarvis.mistake-promoter.plist` 제거 | ⏳ 주인님 (`launchctl bootout`) |
| `settings.json` `_hooksRemoved` 제거 (2.1.257 훅 0개 문제) | ⏳ 주인님 |

### 1단계 — 코더 격리 (D+1~2) · 승인 필요: 배치 경로 차단 훅 확장

| # | 작업 | 파일 | 완료 기준 |
|---|---|---|---|
| 1a | runtime-guard 에 **에이전트 쓰기 경계** 추가: 배치 세션(`JARVIS_AGENT_ROLE=coder`)에서 `runtime/config/`·`runtime/context/`·`runtime/wiki/`·`~/.claude/`·`infra/config/` 로의 `cp/mv/tee/>/sed -i` 와 `Write/Edit` 도구를 exit 2. 대화형 세션은 영향 없음 | `~/.claude/hooks/jarvis-runtime-guard.py`, `infra/config/claude-batch-hooks.json`(Write\|Edit matcher 추가), `llm-gateway.sh`(역할 env 주입) | 테스트 64→90건 PASS, 카나리아 코더 세션이 `cp x runtime/config/tasks.json` 시 원장에 `kind:agent-write-boundary` 기록 |
| 1b | **worktree 실행**: `git worktree add /tmp/bot-work/<task>/repo -b coder/<task>`; LLM cwd·스냅샷·롤백·문법 게이트 전부 worktree 기준. 본체는 읽기만. 결과 = 브랜치 + `runtime/results/<task>/patch.diff` | `infra/lib/coder-functions.sh` (`run_one_task` 556~, `run_task_group` 361~, `rollback_snapshot` 239~), `ask-claude.sh:94` | 본체 `git status` 가 코더 실행 전후 동일. `snapshot:` 커밋이 본체 로그에 더 이상 생기지 않음 |
| 1c | **성공 판정 fail-closed**: `verifyCmd` 빈 값 → `unverified`(통과 아님); verify-gate `SKIPPED_*` 3종 → `needs_human`; 검증 인프라 파일 변경 감지 시 즉시 중단 | `verify-sprint-contract.sh:85-91`, `verify-gate.sh:127-152` | 원장 `verify-gate.jsonl` 에 `SKIPPED_*` 가 pass 로 집계되지 않음 |
| 1d | 테스트 셋업의 외부 송출 차단: `JARVIS_NO_EXTERNAL=1` 이면 `route-result.sh`/`discord-route.sh` 가 파일로만 기록 | `infra/bin/route-result.sh` | 9/4 낮의 "empty-shim-b 실패" 같은 실경보 재발 0 |

9/2 결정과의 관계: 오너 지시는 "훅이 **기능 개선**을 과도하게 막음"(대화형 작업)이었다. 1a 는 배치(코더) 경로에만 걸고 대화형 `settings.json` 은 건드리지 않는다. 그래도 차단형 훅의 재도입이므로 승인 후 진행.

### 2단계 — 신호 정화 · 표면 축소 (D+3~7) · 승인 필요: 크론 삭제 목록

| # | 작업 | 완료 기준 |
|---|---|---|
| 2a | ✅ aeb2c26 — auditor `judge_db()`: `tasks.db` 마지막 done/failed 전이 + `results/` mtime + exit code 로 판정. DB 와 cron.log 가 같은 실행을 두고 다르게 말하면 **SUSPECT**(티켓 보류, 요약에 "DB-로그 불일치" 집계). 티켓·큐 `meta.evidence` → 코더 프롬프트 주입, 오탐이면 결과 첫 줄 `오탐: <이유>`. 부수 발견: bot-cron 이 result 없이 done 을 찍어 RESULT_REQUIRED 에 거부됐고 stale-watcher 가 성공한 스크립트 태스크를 매일 ~93건 failed 로 찍던 근본 원인 수정(`bot-cron.sh:947`) | 오탐율 = (auditor 요약 mismatch 건수 + 코더 결과 `오탐:` 건수) / 티켓 수, 4d 주간 회고에서 산출. 목표 <10%. 9/4 22:20 기준선: mismatch 16건(7/22 이후 누적 오탐, 태스크 재실행되며 소거) · 테스트 `test-cron-auditor-judge.sh` 38/0 |
| 2b | 🟡 준비 완료 · 주인님 실행 대기 — `bash infra/scripts/self-heal-2bc-apply.sh` (dry-run) → `--apply`. 정정: "com.jarvis + tasks.json = 이중"(감사 99~101건)은 **오탐**이었다. tasks.json 을 스케줄링하는 Nexus 실행기는 없고 `cron-sync.sh` 가 만든 `com.jarvis.<id>` 가 실행기다 (`mistake-extractor`·`mistake-pattern-analyzer` 도 정상). 진짜 중복은 **crontab 병행 8줄**: news-briefing·cost-cap-audit·cron-master-smoke·disk-alert·update-claude-md-meta(구현 2개)·cron-completion-hook(*/15+@reboot)·monitoring-pre-check(crontab 단독→tasks.json 이관). plist 5개 bootout: cron-completion-hook(orca 사본)·skill-loop-nightly·skill-synthesis-verify·mistake-promoter(코더 산)·disk-alert(5/19 직접호출→bot-cron 경유로 재생성). 감사 오탐 4종 수정 9ec0ed6 | `validate-tasks.mjs` SSoT 경고 7→0, `tasks-integrity-audit` dup 0·orphan 0·ghost 0, `ai.jarvis.symlink-audit` exit 0 (9/4 22:41 실측 OK) |
| 2c | 🟡 2b 와 같은 적용기에 포함. `gen-gotchas`·`symlink-health-check` 는 tasks.json 에 이미 없음(스크립트 파일만 잔존, 미배선). 비활성 3건에 `_disabled_reason` 기입: `cron-completion-hook`(신규 발견 — 인자 없이 하루 192회, 소비자 0, stale-watcher 오탐 1위), `skill-loop-nightly`(47일 선별 0건), `skill-synthesis-verify`(입력 0건 → 매일 "검증 생략"). 등재 1건: `runaway-process-guard`(plist 단독 → SSoT 추적) | 적용 후 `cron-completion-hook` 로그 증가 0, stale-watcher failed 전이 중 cron-completion-hook 0건, 6:03/9:15 이중 실행 로그 소멸 |
| 2d | **tasks.json 무결성**: `tasks-integrity-audit` 에 sha256·개수 기록, 전일 대비 개수 ±5 또는 해시 변경 시 Discord 경보 + 원인 커밋/세션 표시. 일 1회 백업을 `~/backup/jarvis-topology/tasks-json/`(14일 회전)로, `runtime/config/` 의 `.bak-*` 42개는 이관 | 7월 파일로 덮어쓰는 시나리오를 재현하면 10:07 감사에서 경보 |
| 2e | `e2e-cron.sh` 주석/실제 스케줄 불일치, `*.test.sh` 8개를 `e2e-test.sh` 에서 호출 | e2e 리포트에 가드 테스트 결과 포함 |

### 3단계 — 검토하는 놈 (D+7~14)

| # | 작업 | 완료 기준 |
|---|---|---|
| 3a | ✅ e41c8e4 — `infra/scripts/coder-review.sh` + tasks.json `coder-review`(07:30, cron-sync 가 plist 생성). 브랜치마다 `coder-merge.sh --dry-run` 게이트 + 큐 행(요구·결과·검증 피드백) + verify-gate verdict + diff(400줄 상한)를 Read 전용 `claude-opus-5` 에 주고 `merge / reject / needs_human` + 근거 → `runtime/ledger/coder-review.jsonl`. merge 이고 3c 정책이 허용하면 `--auto` 머지, 아니면 사람 호출 명령을 요약에. reject 는 자동 삭제하지 않고(모델 오판 대비) 3d 만료에 맡김. 같은 tip 재리뷰·큐 `running` 브랜치는 건너뜀. stdout 이 bot-cron 경유 jarvis-system 으로 감 | 리뷰 없는 코더 브랜치 0 — 원장에 tip 별 1행. 테스트 `test-coder-review.sh` 65/0. 9/5 첫 실제 실행은 9/6 07:30(plist 는 9/5 :15 생성) |
| 3b | ✅ d37f87f — `infra/scripts/coder-merge.sh <task>`: 문법(bash -n/node --check/jq/py_compile) → shellcheck -S error → 변경 파일 basename 을 언급하는 `test-*.sh` → `validate-tasks`(ERROR 만 차단) → verify-gate 원장 마지막 verdict PASS → base 위 rebase → `--ff-only`. 결과: `ledger/coder-merge.jsonl` + tasks.db meta(`merge_pending:false, merged_at, merged_commit` — `task-store.mjs meta-patch` 신설) + worktree·브랜치 정리. `--dry-run`(브랜치 무변경) / `--auto`(3c 허용 시만) / `--reject "사유"` / `--expire` / `--keep-branch` / `--skip-gate-check`. 종료코드 0 머지·1 전제·2 게이트·3 정책·4 rebase 충돌. coder-functions 의 완료 안내가 이 경로를 가리킴 | 본체에 들어가는 코더 변경은 전부 이 경로 — `git log --merges` 0, 원장 action=merged 만. 테스트 `test-coder-merge.sh` 112/0. 실제 카나리아 dry-run 9/4 22:59 게이트 전부 통과 |
| 3c | ✅ d37f87f — `infra/config/coder-autonomy.json` + `infra/lib/coder-autonomy.sh`. class 는 파일 경로 glob 으로: `manual_forever`(tasks.json·schema·정책표·guard/monitoring/channel-map·`infra/lib/*`·`infra/bin/*`·hooks·guards·launchagents·`.claude/*`·plist·env·secrets) > `scripts`(문턱 10) > `tests`(5) > `docs`(3). 혼합 변경은 가장 엄격한 쪽. 스트릭은 `coder-merge.jsonl` 에서 `merged` +1, `rejected/reverted` 0 리셋, `expired/dry_run/blocked` 무시. `--auto` 는 `coder_autonomy_allows_auto` 가 0 일 때만 | 정책표 밖 자동 머지 0 — 원장 `approved_by=auto` 행의 class 가 전부 문턱 이상. 현재 스트릭 전 class 0 → 당분간 전부 사람 승인 |
| 3d | ✅ e41c8e4 — coder-review 가 tip 커밋 7일(정책표 `expiry_days`) 경과 브랜치를 `coder-merge.sh --expire` 로 폐기(브랜치 삭제·worktree 제거·원장 `expired/auto`·tasks.db `discard_action`). 큐 `running` 은 제외. 만료는 승인 스트릭을 깎지 않음 | worktree 누적 0 — `git worktree list` 의 coder 항목은 실행 중 1개 이하, `coder/*` 브랜치 tip 은 전부 7일 이내 |

### 4단계 — 반성 루프 (D+14~28)

| # | 작업 | 완료 기준 |
|---|---|---|
| 4a | ✅ 9/5 — `runtime/ledger/incidents.jsonl` (append-only 이벤트: open/update/close/reopen/discard, 상태는 fold). `infra/lib/incident-ledger.sh` + CLI `incident-ctl.sh`(open/close/update/reopen/discard/list/show/count/summary) + 수집기 `incident-ingest.sh`(tasks.json `incident-ingest` 07:50): `state/runtime-guard.jsonl`(canary 무시) · `coder-review.jsonl` reject · `coder-merge.jsonl` blocked/rejected/reverted · `tasks-integrity-audit.jsonl` critical/missing/ghost → key 당 1건. **close 는 `--fix` 커밋/티켓 없이는 거부**, 오탐·시험은 `discard`(오탐율 재료), 닫힌 뒤 새 사건은 재발(reopen, 옛 행 재스캔은 재발 아님). 첫 수집 4건 중 3건 닫힘(1건은 `git merge-base` 오탐 → ~/.claude 029c272 로 수정)·1건 폐기, 이번 주 사고 11건 시드(8 닫힘·3 미닫힘 + 사람 대기 3) | 미닫힘 사고 수를 주간 보고 첫 줄에 — `incident-ctl.sh summary` 첫 줄이 그 문장. 9/5 현재 **미닫힘 6건**(high 1: `_hooksRemoved`) |
| 4b | ✅ 9/5 (66c22b0·179d987) — **진단 정정**: "입력 단절(223 vs 4)" 은 오진. 223 은 `mistake-pattern-analysis.json` 의 30일치, 4 는 ledger 의 7일치(8/16~9/2 세션 공백 + 9/2 소실 직후)를 비교한 것. md ↔ ledger 일별 건수는 ±1 로 일치(총 4677 vs 4968 제목). 실제 단절 두 곳: ① tier_a 판정이 `report_only` 로 끝나며 **rule_block 이 원장에서 버려짐**(제안이 어디에도 안 남음) ② 클러스터 id 가 날마다 바뀌는 시드 문장 해시라 같은 실수가 새 클러스터로 재판정(7/19 17중복). 수리: `infra/lib/rule-proposals.mjs` 정본 `state/rule-proposals.json` → 렌더 `wiki/meta/rule-proposals.md`(RAG 색인, "규칙이 아니다" 머리말). id = 시드 **지문** 해시(`rp-`+sha256[:10]), 근거 = mistake-ledger 의 고유 (ts,지문) 행, **근거 3건 미만은 등재 안 함**(`held_insufficient_evidence`, LLM 호출 전 차단), 시드 지문 일치·멤버 지문 겹침 ≥0.5 면 병합, 결정(승격·기각) 후 재발 카운터. CLI `rule-proposal-ctl.mjs list/show/promote --to/reject --reason/reopen/summary`. 이미 판정한 클러스터는 LLM 0회로 근거만 갱신. 테스트 `test-rule-proposals.sh` 77/0(17변형 → 2건 dedupe 포함), e2e 가드 등록. 보강: 센서 크론 자체의 실패(cron.log `FAILED`)를 사고로 여는 ingest 소스 추가(`test-incident-ledger.sh` 91/0) — 9/5 감사 크론이 exit 2 로 죽고도 사고가 안 열린 사각지대. 실데이터: `rp-aefdca12a4` "통지일 미확인 기한 단언" 근거 4건 등재 → 주인님 결정 대기(`promote --to ~/.claude/rules/<파일>` 또는 `reject --reason`). `PROMOTER_WRITE_RULES` 계속 OFF | 제안서에 근거 3건 미만 항목 0 — 9/5 현재 1건(근거 4) ✅ |
| 4c | 🟡 9/5 (2a6f9a4·20342b8) — **데드맨 스위치 가동**, 판정은 9/7. 월 09:xx 클러스터 7개(heatmap 09:00 · master-smoke 09:15 · north-star·rule-effectiveness 09:20 · self-evolution 09:30 · star-diversity 09:40 · hook-canary 09:50)의 로그 mtime 이 전부 **8/17** — 8/24·8/31 실행 여부는 8/24~9/2 소실 구간이라 **알 수 없다**(runtime/logs 에 그 구간 mtime 파일 0개). 그래서 `sensor-deadman-check.sh`(tasks.json 매일 11:30, jarvis-system)는 FLOOR=9/3 이전 증거뿐이면 죽음이 아니라 **보류**로 두고, 9/7 11:30 에 09:50 까지 유예 90분 포함해 실제 판정한다. 감시 12개 = 주간 7 + e2e-cron 05:00 · recurrence-audit 03:30 · promoter 04:10 · integrity-audit 10:07 · scorecard-enforcer 23:20. 침묵 → 사고(`deadman:<name>`, high) · 회복 → 💚 줄(close 는 사람) · 평일은 침묵·회복 있을 때만 출력, 월요일은 생존 표까지. 테스트 57/0, e2e 가드 등록. 첫 실행: 생존 5 · 보류 7 · 침묵 0. **자초 결함 1건**: bot-cron 이 scriptArgs 기본값 `daily` 를 넘기는데 새 센서 3개(coder-review·incident-ingest·sensor-deadman-check)의 파서가 거부 → 9/6 첫 실행이 전부 exit 1 될 상태였다. 수동 실행에서 발견, 20342b8 수정, 4b 의 cron-failed ingest 가 이 실패를 `inc-20260905-f14ca4d3` 로 자동 등재 → 커밋으로 close(센서→사고→수정 고리 실증) | 9/7 11:30 보고에서 주간 7개 생존/침묵 확정, 9/8 화요일 보고에 첨부. 침묵이면 사고 7건이 자동으로 열린다 |
| 4d | ✅ 9/5 (5be22ba) — `infra/scripts/self-heal-weekly-retro.sh`, tasks.json `self-heal-weekly-retro` **월 12:00**(09:30 계획을 옮김: 11:30 데드맨 판정과 09:xx 클러스터가 끝난 뒤 읽어야 같은 주를 본다). 지난 7일 지표 5개(3절 정의 그대로: ① 오탐율=(auditor mismatch+코더 `오탐:`)/(신규 티켓+mismatch) ② 리뷰 통과율 ③ 설정 변조 감지 시간=감사 행 ts−tasks.json mtime ④ 사고 닫힘률(폐기 제외) ⑤ 크론 성공률 SUCCESS/START) + `incident-ctl summary` 첫 줄 + 규칙 제안 요약 + 데드맨 마지막 판정 + 정책표 class 별 연속 승인/문턱. **문턱 완화는 2주 연속 ①<10%(표본≥10)·②≥80%(표본≥5)·④≥80% 일 때만 '권고'**, 편집은 사람. 질문 최대 3개(규칙 제안·high 미닫힘·침묵 센서·needs_human 순). 지표가 비면 exit 1. `ledger/self-heal-retro.jsonl` 매주 1행 → 전주 ▲▼. 테스트 52/0, e2e 가드 등록. 첫 실행(9/5): ① 6/32=18% ② 표본 0 ③ 0.4h ④ 10/22=45% ⑤ 355/378=93% — 첫 정기 회고 9/7 12:00 | 회고 출력이 지표 없이 서술만이면 실패 → 코드가 exit 1 로 집행. 9/5 실행은 5개 전부 수치 ✅ |

### 5단계 — 대화형 자비스(나)의 반성

오늘 낮 사고의 방아쇠는 나였다. `DRY_RUN=true` 를 env 로 주고 스크립트가 그걸 읽는지 확인하지 않았다. 검증 시험용 shim 이 실제 Discord 경보를 보냈다. 코더 스냅샷이 내 편집을 삼켜 커밋 귀속이 틀어졌다.

| 실수 | 구조 수정 |
|---|---|
| 플래그 의미를 추정하고 실행 | 부작용 있는 스크립트는 실행 전 인자 파싱부(`for arg in "$@"`)를 읽는다 — 확인 못 하면 "— 미검증" 표기 후 dry 경로 먼저 |
| 테스트가 외부로 송출 | 1d `JARVIS_NO_EXTERNAL=1` |
| 남의 편집 스냅샷 | 1b worktree |
| 코더가 뭘 했는지 아침에야 앎 | 3a 리뷰 크론 + 2d 무결성 경보 |

## 3. "발전했다" 의 정의 — 지표 5개 (주간)

| 지표 | 현재(9/4) | 4주 목표 |
|---|---|---|
| 오탐 티켓 비율 (auditor mismatch + 코더 `오탐:` 결과) | 측정 경로 확보 (2a ✅) — 9/4 기준선 mismatch 16건, 코더 `오탐:` 0건(아직 표본 없음) | <10% |
| 코더 변경 리뷰 통과율 | 리뷰 없음 | 측정 시작, 반려 사유 분류 |
| 설정 변조 감지 시간 | 무한(감지 안 됨) | ≤24h (10:07 감사) |
| 사고 대비 구조 수정 닫힘률 | 원장 없음 | ≥80% |
| 크론 성공률 (SUCCESS/(SUCCESS+FAILED)) | 9/4: 143/168 = 85% | ≥95% |

자동 머지 클래스 확장·쿨다운 완화·코더 도구 확대는 **이 표의 수치로만** 결정한다.

## 4. 승인이 필요한 항목 (모아서)

1. 1a — 배치 경로에 차단형 훅 확장 (9/2 "차단형 제거" 결정과 충돌, 대화형은 불변).
2. 2b — 크론/LaunchAgent 삭제 목록 → `infra/scripts/self-heal-2bc-apply.sh` (dry-run 출력이 그 목록이다. 9/4 제출).
3. 2c — 죽은 자동화 비활성 목록 → 같은 적용기의 tasks.json 변경분.

(3c — 자동 머지 정책표 초안은 ✅ 9/5 d37f87f 로 이미 완료. 아래 목록에서 제외 — 09-09 council-insight 정정)

승인 없이 진행 가능한 것: 1b·1c·1d·2a·2d·2e·3a·3b·4a·4b·4d (전부 가역, 본체 크론 미변경).

## 5. 순서

D+0 밤: 1a 코드+테스트 작성(배선은 승인 후) · 2d 해시/백업 · 1d
D+1: 1b worktree · 1c fail-closed → 카나리아 티켓 1건으로 E2E
D+2~7: 2a·2e · 2b/2c 목록 제출
D+7~14: 3a·3b · 정책표 초안 → ✅ 9/4~9/5 에 3a·3b·3c·3d 전부 (D+1 에 완료)
D+14~28: 4a~4d · 첫 주간 회고(9/21 월) → ✅ 9/5 에 4a~4d 전부, 첫 정기 회고는 9/7 12:00(기준선 주)
