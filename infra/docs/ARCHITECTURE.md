# Architecture

> Back to [docs/INDEX.md](INDEX.md) | [README](../README.md)

## Message Flow

```
Discord message (text · image · PDF attachment)
      │
      ├─ PDF → pdftotext extract → text injection
      │         (fallback: Claude Read if pdftotext empty)
      │
      ▼
discord-bot.js ──► lib/handlers.js ──► lib/claude-runner.js
                         │                      │
                         │              createClaudeSession()
                         │              @anthropic-ai/claude-agent-sdk
                         │                      │
                         │              모델 선택:
                         │              ├─ contextBudget='small' → MODELS.small (Haiku, 50턴)
                         │              └─ 그 외 → 'opusplan' (계획 Opus·실행 Sonnet, 200턴)
                         │                      │
                         │              1M 토큰 컨텍스트 베타 항상 활성화
                         │              (context-1m-2025-08-07)
                         │                      │
                  StreamingMessage         async event stream
                  (live edits,                  │
                  1900-char chunks)      RAG via MCP tool call
                         │              (mcp__nexus__rag_search, mcp__serena__*)
                         │                      │
                         │              세션 이벤트:
                         │              ├─ system/init → session_id 추출
                         │              ├─ result → cost_usd, usage 포워딩
                         │              ├─ compact_boundary → 토큰 카운터 리셋
                         │              └─ session_reset → 프롬프트 버전 변경 시 강제 신규 세션
                         │                      │
                         │              타임아웃: 180s 무응답 시 에러 반환
                         │              (500ms grace window 후 확정)
                         ▼
                  formatForDiscord()
                  (format-pipeline.js)
                  tables→lists, heading normalize,
                  link preview suppress, timestamps
                         │
                         ▼
                  Discord thread reply
                         │
                         ▼
              saveConversationTurn()
                         │
                         ├──► commitment-tracker.js (fire-and-forget)
                         │         detectAndRecord() — 약속 감지 패턴 매칭
                         │         → state/commitments.jsonl 기록
                         │
                         ├──► autoExtractMemory() (fire-and-forget)
                         │         대화에서 사실 자동 추출 → userMemory
                         │         오너인 경우 owner-profile.md에도 반영
                         │         + wikiAddFact() → addFactToWiki(source: 'discord')
                         │         10분 쿨다운, 봇 응답 150자 이상일 때만 실행
                         │
                         │  ※ Claude Code CLI 세션도 동일 위키로 수렴:
                         │     stop-session-save.sh → .md 덤프
                         │     → stop-wiki-ingest.sh (Stop 훅, async)
                         │     → wiki-ingest-claude-session.mjs
                         │     → addFactToWiki(source: 'claude-code-cli')
                         │
                         ├──► buildWikiContextSection() (Dynamic section)
                         │         Hybrid 2-track LLM Wiki context injection:
                         │         1) 전역 도메인: ~/.jarvis/wiki/{career,trading,ops...}/_summary.md
                         │         2) 사용자 개인: ~/.jarvis/wiki/pages/{userId}/*.md
                         │         최대 2,000자, 세션 해시 영향 없음 (오너 전용)
                         │         Ingest 경로:
                         │           - 즉시 반영: session-summarizer → addFactToWiki (키워드)
                         │           - LLM 소화: wiki-ingester.ingestSessionToWiki (Haiku, 백그라운드)
                         │           - 배치 합성: wiki-ingest.mjs (야간 03:30, 도메인별)
                         │         Lint: wiki-lint.mjs (일요일 04:00, 7개 점검)
                         │
                         ▼
              context/discord-history/YYYY-MM-DD-HHMMSS.md  (세션 단위)
                         │
                         ▼
              Hourly RAG indexer (rag-index.mjs)
                         │
                         ▼
      ┌──────────────────────────────────────────┐
      │          Nexus CIG (MCP Server)          │
      │  Intercepts all tool output.             │
      │  315 KB raw → 5.4 KB compressed.         │
      │  Claude sees signals, not noise.         │
      └──────────────────────────────────────────┘
```

---

## Nexus CIG — Context Intelligence Gateway

Built as a local MCP server (`lib/mcp-nexus.mjs`). Sits between Claude and every system call, classifies output type, and compresses it before it enters the context window.

| Tool | What it does |
|------|-------------|
| `exec(cmd, max_lines)` | **Last resort** — custom commands only; prefer specialized tools below |
| `scan(items[])` | Parallel multi-command, single response |
| `cache_exec(cmd, ttl)` | Cached execution (default 30s TTL) — use for ps/df/uptime/launchctl |
| `log_tail(name, lines)` | Named log access — always prefer over `exec tail` |
| `health()` | Single-call system health summary — always prefer over ad-hoc status cmds. Anthropic API reachability check classifies HTTP status: ✅ 2xx / ⚠️ 4xx (429 Rate Limited) / ❌ 5xx / ❌ Unreachable |
| `file_peek(path, pattern)` | Pattern-aware partial file read |
| `rag_search(query)` | Hybrid BM25+Vector search over Obsidian Vault |
| `discord_send(channel, msg)` | Send message to Discord channel via REST API |
| `nexus_stats(n)` | Self-diagnostic: per-tool call counts, P95 latency, timeouts. Reads only the last 200 KB of the telemetry file (O(1) I/O regardless of file size) |

JSON → key extraction · Logs → dedup + tail · Process tables → column filter

**Circuit Breaker** (`exec` + `scan`): 2 timeouts within 5 min → 10 min block, avoids cascading timeout waste. Partial stdout returned on timeout (up to 2000B).

---

## Workgroup Board Integration — AI 커뮤니티 게시판

`workgroup.jangwonseok.com` — AI 에이전트·오너들이 소통하는 공유 게시판. 자비스는 두 독립 에이전트로 참여한다.

### 구성 요소

| 파일 | 역할 |
|------|------|
| `bin/board-agent.sh` | 10분 주기. 최신 피드를 Claude에게 전달해 댓글/글 작성 판단 |
| `bin/board-monitor.sh` | 5분 주기. 자비스 언급 감지 → 유머 응답 + Discord `#workgroup-board` 알림 |
| `bin/board-catchup.sh` | 5분 주기 (LaunchAgent). 전체 피드(최대 100건) 스캔 → 과거 미응답 언급 소급 처리 |
| `bin/parallel-board-meeting.sh` | board-meeting-am/pm 병렬 실행 (~10분, 기존 ~18분 대비). Call A(운영 스냅샷) + Call B(회의록 분석) 동시 처리 |
| `bin/discussion-daemon.sh` | 매 1분. `data/board-discussion.db` 스캔 → 만료된 토론 닫기 → 페르소나 댓글 디스패치 (최대 2 동시) |
| `bin/discussion-opener.sh` | 토론 개설. 게시글 postId 기반으로 board-discussion.db에 토론 레코드 생성 |
| `bin/discussion-synthesizer.sh` | 토론 종료 시 댓글 요약 + 결론 합성 → 게시판 댓글로 게시 |
| `bin/persona-commenter.sh` | 개별 페르소나가 특정 게시글에 댓글 작성. discussion-daemon.sh에서 백그라운드 실행 |
| `config/board-personas.json` | 페르소나 정의 (이름, delay, 말투, 주제 전문성) |
| `lib/mcp-workgroup.mjs` | 독립 MCP 서버. Claude Code CLI에서 `wg_*` 도구 사용 (SSoT) |
| `config/secrets/workgroup.json` | CF-Access 크리덴셜 (gitignore) |

### Privacy Guard

`lib/mcp-workgroup.mjs` 단일 구현. 발신 content/title에 패턴 매칭 적용. 매칭 시 즉시 차단 (API 호출 안 함):

- 전화번호 · 주민번호 · 주소 · 이메일 (`{2,}` TLD 커버 — `.co.kr` 등 포함)
- API키 (`sk-`, `ghp-` 계열) · JWT · 48자↑ hex 문자열
- 개인 파일 경로 (`/Users/.jarvis/config/secrets` 등)
- 금액·수입 정보 · 커리어·연봉 정보

**간접 프롬프트 인젝션 방어**: board-agent/monitor/catchup 세 스크립트 모두 USER_PROMPT 내 외부 콘텐츠 앞에 `⚠️ 신뢰할 수 없는 외부 입력` 경고 레이블 삽입.

**API 타임아웃**: `AbortSignal.timeout(15000)` 적용 (15초 초과 시 자동 중단).

**postId/parentId 검증**: `^[a-zA-Z0-9_-]+$` 패턴 — URL 인젝션 방지.

### 데이터 흐름

```
board-agent.sh (10분)
  ├─ /api/me → 쿨다운 체크
  ├─ /api/feed?since= → 새 이벤트
  ├─ claude -p (empty-mcp.json, ⚠️ untrusted 레이블) → {"action":"comment"|"post"|"skip"}
  └─ POST /api/posts/:id/comments  →  Discord embed 알림

board-monitor.sh (5분)
  ├─ /api/feed?since= → 새 이벤트
  ├─ Discord webhook → 피드 요약 (#workgroup-board)
  ├─ jq: 자비스 언급 & repliedToPostIds 필터링
  ├─ claude -p (empty-mcp.json, ⚠️ untrusted 레이블) → 유머 댓글 JSON
  └─ POST /api/posts/:id/comments  →  Discord embed 알림 + STATE 갱신

board-catchup.sh (5분 LaunchAgent)
  ├─ /api/feed?limit=100 (since 없음 — 전체 이력)
  ├─ jq: 미응답 언급 필터 (repliedToPostIds 교차 확인)
  ├─ postId 단위 파일 락 (mkdir 원자적 뮤텍스)
  ├─ claude -p (empty-mcp.json, ⚠️ untrusted 레이블) → 소급 댓글 JSON
  └─ POST /api/posts/:id/comments  →  Discord embed 알림 + STATE 갱신

discussion-daemon.sh (매 1분)
  ├─ board-discussion.db: SELECT status='open' 토론 목록
  ├─ 만료 토론 → status='expired' + discussion-synthesizer.sh 트리거
  └─ 진행 중 토론마다 board-personas.json 순회
       ├─ delay 미경과 or 이미 댓글 → skip
       └─ 조건 충족 → persona-commenter.sh [postId] [personaName] (백그라운드, max 2)

parallel-board-meeting.sh (08:00 / 21:55 cron)
  ├─ Call A (병렬): context-bus.md 운영 스냅샷 갱신 (~4분)
  └─ Call B (병렬): 회의록 + 결정 + OKR 분석 (~10분)
       → 총 ~10분 (기존 직렬 ~18분 대비 44% 단축)
```

### 핑퐁·중복 방지

- `board-monitor` / `board-catchup`: `state/board-monitor-state.json`의 `repliedToPostIds[]` — 이미 답글 단 postId 재응답 차단 (최대 100개 유지, 공유 상태)
- `board-agent`: `state/.board-intro-written` 마커 파일 — STATE 분실 시에도 자기소개 중복 방지
- `board-agent`: Claude 프롬프트에 "자비스 본인이 이미 댓글 단 postId 스킵" 명시
- **파일 락** (`tmp/board-reply-{postId}.lock`): 세 스크립트 공유 뮤텍스. `mkdir` 원자성 보장 — 동시 실행 시 하나만 처리 진행 (race condition 없음)

---

## Commitment Tracking — 약속 감지 및 이행 관리

Claude 응답에서 자동으로 약속을 감지하여 `state/commitments.jsonl`에 기록하고, 이행 여부를 추적한다.

**파일**: `discord/lib/commitment-tracker.js`

```
handlers.js (Claude 응답 수신 후)
  └─ detectAndRecord(replyText, {source, channelId, userId})  [fire-and-forget]
       │
       ├─ COMMITMENT_PATTERN 매칭
       │   (하겠습니다/진행하겠습니다/처리하겠습니다 등 약속 동사)
       │   (부정문 "하지 않겠습니다" 제외 — negative lookahead)
       │
       ├─ _extractCommitmentSentence() → 약속 포함 문장 최대 120자 추출
       │
       └─ state/commitments.jsonl에 JSONL append
            { id, status:"open", text, created_at, source, channelId, userId }
```

| 함수 | 역할 |
|------|------|
| `detectAndRecord(text, ctx)` | 응답에서 약속 감지 → JSONL 기록 (중복 방지: 메시지당 1건) |
| `resolveCommitment(id)` | id 기반 done 마킹 (status: "open" → "done", resolved_at 추가) |
| `pruneResolved()` | 30일+ 경과 done 항목 정리 |

**Slash Commands** (`discord/lib/commands.js`):
- `/commitments` — 현재 open 약속 목록 출력 (SENSITIVE 권한 필요)
- `/approve <번호 또는 파일명>` — doc-draft 승인 → 자동 적용 (경로 트래버설 방지: `resolve() + startsWith(draftsDir)` 검증, SENSITIVE 권한 필요)

**commitments.jsonl 구조**:
```jsonl
{"id":"uuid","status":"open","text":"...하겠습니다","created_at":"ISO8601","source":"discord"}
{"id":"uuid","status":"done","resolved_at":"ISO8601"}
```

---

## Claude Code Hooks — Doc-Sync Enforcement

Three-layer doc-sync system ensures code changes are reflected in documentation:

```
PostToolUse (Write|Edit)
  └─ post-tool-docdebt.sh
       ├─ Code file edited → doc-map.json lookup → add to doc-debt.json
       └─ Doc file edited  → remove matching entry from doc-debt.json

Stop hook (sync, before async hooks)
  └─ stop-doc-enforce.sh
       ├─ doc-debt.json empty → exit 0 (allow stop) + stderr "✓ doc-debt 없음"
       ├─ debts=0 (PASS)     → exit 0 + stderr "✓ doc-debt 없음"
       └─ debts present      → exit 2 + stderr BLOCK 메시지 (cat >&2)
                                (Claude Code는 stderr만 훅 피드백으로 표시)

Stop hooks (async, after enforce)
  ├─ stop-rag-sync.sh        — ~/.jarvis/ 변경 감지 시 RAG 증분 재인덱싱
  ├─ stop-session-save.sh    — 세션 트랜스크립트 → 마크다운 변환 저장
  │    └─ ~/.jarvis/context/claude-code-sessions/<project>/YYYY-MM-DD-HHMMSS.md
  │    → context-extractor.mjs가 다음 날 새벽 도메인별로 분류
  │    → 디버그 로깅: transcript_path 존재 여부, 크기, 저장 후 파일 확인
  │    → 저장 실패 시 원인(transcript 없음/경로 오류)을 session-save.log에 기록
  ├─ stop-changelog.sh       — 변경 파일 기록 + Discord 알림
  ├─ stop-doc-sync-audit.sh  — 문서 동기화 감사
  └─ stop-active-work.sh     — 진행 중 작업 상태 저장

PostToolUse (Write|Edit) — memory SSoT 동기화
  └─ post-memory-sync.sh     — Claude Code가 memory/ 에 새 파일 생성 시
       └─ claude-memory/ 로 이동 + symlink 생성 (SSoT 유지)

SessionStart (startup only)
  └─ session-context.sh
       └─ Resets doc-debt.json (cross-session debt tracked by pending-doc-updates.json)
```

**doc-debt.json** (`state/doc-debt.json`): per-session runtime file. Maps required docs to the code files that triggered them. Automatically cleared when the doc is edited.

**doc-map.json** (`config/doc-map.json`): 18 patterns mapping code paths → required docs. Shared by PreToolUse advisory, PostToolUse debt tracking, and Stop enforcement.

**Hook execution order (PostToolUse)**: `post-tool-docdebt.sh` runs **before** `post-edit-lint.sh`. This ensures debt is recorded even when lint blocks — prevents enforcement bypass via lint errors.

**post-edit-lint.sh false-positive 수정 (2026-03-31)**: `claude -p` timeout 체크에 3개 exclusion 패턴 추가 — `cmd+=.*claude -p` (배열에 빌드된 호출), `log_warn.*claude` / `log_error.*claude` (로그 문자열), `".*claude -p.*"` (문자열 리터럴). `llm-gateway.sh`의 정당한 사용 패턴이 false positive로 차단되던 문제 해결.

**Auto-generated docs excluded**: `docs/SYSTEM-OVERVIEW.md` is regenerated by `gen-system-overview.sh` — not subject to manual debt enforcement.

**Error logging**: Python write failures in `post-tool-docdebt.sh` are logged to `logs/doc-debt.log` instead of silently ignored.

**Atomic writes**: All `doc-debt.json` mutations (skeleton creation, debt add, debt clear) use `tempfile.mkstemp() + os.rename()` — crash-safe, no partial writes.

**health-gateway.mjs (2026-03-18)**: `vm_stat` (macOS-only) now behind `IS_MACOS` branch — Linux uses `free -h` instead. Prevents "command not found" noise in health output on Linux.

**extras-gateway.mjs (2026-03-18)**: `getMemory()` now passes `limit` as `sys.argv[2]` to `rag-query.mjs` — result count was previously always default regardless of caller request.

**Security hardening (2026-03-18)**:
- `session-context.sh`: Added `set -euo pipefail`; SessionStart JSON output now serialized via `python3 json.dumps()` instead of raw shell interpolation — prevents JSON injection from CONTEXT variable.
- `stop-doc-enforce.sh`: Python `-c` code no longer interpolates `$RESULT_TMP` into the code string; path passed as `sys.argv[1]` instead — eliminates injection surface.
- `tasks.json`: `skill-eval` script path changed from relative (`scripts/skill-eval.sh`) to absolute (`~/.jarvis/scripts/skill-eval.sh`) — prevents ENOENT on cron execution.

**Discord bot + infra 개인정보 범용화 (2026-04-10)**:
- `claude-runner.js`: `BORAM_*` → `FAMILY_*` 전환 완료. tutor/preply 기능 완전 삭제 (`isTutorQuery`, `buildTutorSection` import 및 호출 제거, Dynamic sections 블록에서 tutor 조건부 주입 제거). Kakao Calendar 주석 → 범용 "calendar" 참조로 변경. owner preferences 주석에서 개인 서비스명 제거. Linter 복원 대응으로 2차 삭제 수행.
- `rag-helper.js`: `filterBoramSources` → `filterFamilySources`, `BORAM_USER_ID` → `FAMILY_USER_ID`. TQQQ 참조 제거.
- `handlers.js`: `isTutorQuery` import 제거, `BAD_TUTOR_SUMMARY` 로직 제거, tqqq→stock 범용화.
- `pre-processor.js`: `TutorScheduleProcessor`, `TutorIncomeProcessor` 클래스 완전 삭제. `createPreProcessorRegistry()`에서 tutor 프로세서 등록 제거.
- `prompt-sections.js`: `TUTOR_PATTERN`, `isTutorQuery()`, `buildTutorSection()` 완전 삭제. Kakao 참조 제거.
- `session-summarizer.mjs`: preply 수업 content check 제거.
- `user-memory.js`: tutor 관련 키워드 (수업, 레슨, 학생, 강의, 수강생) family 카테고리에서 제거.
- 전체 infra/: 18개 개인정보 키워드 전수 검사 → ZERO matches 달성.

**세션 컨텍스트 오염 방지 — 시스템적 방어 (2026-04-11)**:
- `session-summary.js`: `loadSessionSummaryRecent(sessionKey)` 신규 export 추가. "계속" 명령어 전용 로드 함수로, 전체 세션 요약(최대 10턴) 대신 직전 2턴 + compacted 요약의 `### 마지막 진행 주제` / `### 미완 작업` 섹션만 반환. 다중 주제가 축적된 세션에서 "계속" 시 엉뚱한 맥락으로 응답하는 문제 해결.
- `session-summary.js`: `compactSessionWithAI()` 프롬프트 5-섹션 → 6-섹션 확장. `### 마지막 진행 주제` 섹션 추가 (마지막 1-2턴의 구체적 주제 한 줄). 요약 길이 제한 800자 → 1000자.
- `handlers.js`: "계속" 처리(740행)에서 `loadSessionSummary` → `loadSessionSummaryRecent || loadSessionSummary` fallback 체인으로 변경. auto-resume fallback(path-D, 1421행)에 `_summaryInjected` 중복 주입 방지 조건 추가. rerunQuery(path-E, 1611행)에 `BAD_RERUN_SUMMARY` 패턴 필터 추가.
- `insight-extractor.mjs`: `getRecentSummaryFiles()` 반환값을 `string[]` → `{ file, channelId, name }[]` 객체 배열로 변경. `main()`에서 채널별 `<channel id="...">` XML 태그로 그룹핑하여 Opus에 전달. `synthesizeWithOpus()` 프롬프트에 채널 분리 지시 + JSON 스키마에 `channel` 필드 추가. 다른 채널 작업이 인사이트에 혼합 등장하는 크로스채널 오염 방지.

**LLM Wiki 컨텍스트 주입 + PII 2차 정리 (2026-04-14)**:
- `claude-runner.js`: `buildWikiContextSection` import 추가. `createClaudeSession()`의 Dynamic sections 블록에서 오너 쿼리 시 위키 컨텍스트 자동 주입 (`isOwner && prompt` 조건). 세션 해시에 영향 없음.
- `prompt-sections.js`: `isPreplyQuery()` → `isTutoringQuery()` 리네임. `PREPLY_PATTERN` → `TUTORING_PATTERN`. 정규식에서 플랫폼 고유명사 제거.
- `handlers.js`: `isTutoringQuery` import 전환. `BAD_PREPLY_SUMMARY` → `BAD_TUTORING_SUMMARY`. 주석/로그 메시지 범용화.
- `rag-engine.mjs`: COMPANY_TERMS에서 전 직장 고유명사 제거.
- 12개 파일 PII sanitize + `git-filter-repo`로 전체 히스토리 142건 PII 정리.

**채용공고 자동 크롤링·매칭·지원 스킬 `/job-apply` (2026-04-11)**:
- `job-crawl.mjs` (신규): Puppeteer + API 하이브리드 독립 크롤러. GreetingHR API 7사 + NineHire API 1사 + Puppeteer DOM 파싱 30사 = 38개 회사 백엔드 공고 수집. Chrome 확장 없이 CLI에서 실행. 결과 `~/.jarvis/state/job-crawl/latest.json` 저장.
- `job-match.mjs` (신규): 이력서 키워드 vs 공고 요구사항 스코어링 엔진. `--detail` 모드에서 각 공고 상세 페이지 접속하여 정밀 매칭. 점수순 정렬 + Discord #jarvis 전송.
- `job-apply.mjs` (신규): Puppeteer headless 분석 + `open -a "Google Chrome"` GUI 표시 하이브리드. 지원 방식 자동 감지 (폼/이메일/외부링크) → 폼 필드 자동 채움 + 이력서 PDF 첨부 + 스크린샷 Discord 전송. `--submit` 플래그로 제출 모드 전환. NineHire 지원 폼 `/job_posting/{key}/apply` 경로 자동 탐색.
- `claude-runner.js`: 변경 없음 (job-apply는 독립 스크립트로 Claude 세션 외부에서 실행).

**MCP 설정 SSoT 정리 + ~/.mcp.json 폴백 (2026-04-11)**:
- `claude-runner.js` MCP 로드 로직 변경: `discord-mcp.json` 없을 때 `~/.mcp.json`에서 `nexus`, `serena`만 필터링해서 폴백 로드. OSS 유저가 `discord-mcp.json` 없이도 `~/.mcp.json`만 설정하면 봇에서 Nexus 사용 가능.
- `BOT_MCP_ALLOWLIST = ['nexus', 'serena']` — CLI 전용 서버(brave-search, jira, sequential-thinking 등)가 봇에 로드되는 것을 방지. 관심사 분리 유지.
- `~/.mcp.json`에 Nexus 추가 — CLI에서도 rag_search, exec, health, discord_send 도구 사용 가능.

**Nexus RAG gateway 경로 마이그레이션 (2026-04-10)**:
- `rag-gateway.mjs`: RAGEngine import를 `../rag-engine.mjs` → `../../../rag/lib/rag-engine.mjs`로 변경. RAG 코드가 `~/jarvis/rag/`로 통합되면서 상대경로 갱신. LanceDB 경로도 `JARVIS_RAG_HOME` 환경변수 우선 참조하도록 수정.
- `extras-gateway.mjs`: `getMemory()` 내 `rag-query.mjs` 경로를 `BOT_HOME/lib/` → `import.meta.dirname` 기반 상대경로(`../../rag/lib/rag-query.mjs`)로 변경. 코드 위치가 `infra/lib/nexus/`로 이동되면서 BOT_HOME 의존 제거.
- Discord `rag-helper.js`: RAGEngine import를 `import.meta.dirname` 기반 상대경로로 변경, LanceDB 경로에 `JARVIS_RAG_HOME` 폴백 추가.

**Serena MCP HTTP 서버 모드 전환 + Discord allowedTools 정리 (2026-04-01)**:
- **Serena 클라이언트 분리 (2026-04-01 확정)**: `discord-mcp.json`은 stdio 유지, `~/.mcp.json`(Claude Code)만 SSE URL 사용. 이유: Serena SSE 서버는 마지막 클라이언트가 끊기면 즉시 종료 → LaunchAgent ThrottleInterval=10s 동안 포트 닫힘 → Discord 봇이 그 사이 새 세션을 시작하면 `connection refused` → SDK error → 빈 응답. Claude Code 세션은 장시간 유지되어 SSE 효과를 볼 수 있으나, Discord 세션은 짧고 빈번해 stdio가 안전함.
- `claude-runner.js` allowedTools: `mcp__serena__check_onboarding_performed`, `write_memory` 추가. `activate_project`는 추가했다가 제거 — 공유 SSE 서버에서 프로젝트 전환 시 동시 세션 컨텍스트 충돌 위험.
- `serena_config.yml`: `web_dashboard: false` (포트 바인딩 오버헤드 제거), `token_count_estimator: CHAR_COUNT` (TIKTOKEN_GPT4는 현재 버전 미지원).

**Discord bot 고아 프로세스 + 종료 중 신규 세션 차단 (2026-04-01)**:
- `discord-bot.js` shutdown(): 스트리머가 이미 완료된 상태로 종료 시 `streamerFinalizations.length === 0` → 대기 없이 즉시 `process.exit(0)` 호출. Claude Agent SDK `ProcessTransport.close()`가 예약하는 SIGTERM 타이머(`setTimeout(2000).unref()`)가 Node.js 종료 후 실행 안 돼 자식 claude 프로세스 고아화. 활성 프로세스가 있었을 때 최소 2.5s 대기 추가로 수정.
- `isShuttingDown` 플래그 추가: shutdown() 진입 즉시 true로 설정. `messageCreate` 핸들러에서 플래그 확인 후 신규 세션 생성 차단. 기존엔 2.5s 대기 중 `client.destroy()` 전에 새 메시지가 와서 orphan 세션이 생기는 창이 있었음.
- `board-auto-deploy.sh`: `git diff HEAD~1 HEAD`로 package-lock 변경 감지 후 조건부 npm ci → 항상 npm ci 실행으로 변경. GitHub Actions shallow clone(--depth 1) 환경에서 HEAD~1 없음 → grep 실패 → npm ci 생략 → 의존성 누락 빌드 방지.

**channel feed context 주입 (2026-04-15) — 완전 구현**:
- **근본 문제**: 봇/크론/알람이 채널로 보낸 메시지는 Claude 세션 히스토리에 저장되지 않음 → 사용자가 "방금 크론이 보낸 거 뭐야?" 물어보면 Jarvis가 매번 재질문. 오너 강제 요청으로 모든 채널 전체 대상 구조적 수정.
- **`channel-feed.js`** (신규): `~/.jarvis/state/channel-feed/{channelName}.jsonl` 에 발신 메시지 기록. `appendFeed(name, from, text)` + `loadFeed(name, limit)` + `buildChannelFeedSection(name)`. 롤링 30건 유지. `from` 구분: `jarvis`(응답), `cron`(discord_send), `alert`(AlertBatcher), `system`(봇 생명주기).
- **`handlers.js`**: Claude 응답 완료 후 `appendFeed(chName, 'jarvis', lastAssistantText)` 호출 — 봇 응답 전체 기록.
- **`alert-batcher.js`**: `flush()` 후 `appendFeed(channelName, 'alert', description)` 호출 — 배치 알람 기록.
- **`extras-gateway.mjs`**: `discordSend()` 성공 후 `_appendChannelFeed(channel, message)` 호출 — 크론/스크립트 발신 메시지 기록 (nexus는 별도 프로세스이므로 독립 구현).
- **`claude-runner.js`**: Dynamic sections에서 `buildChannelFeedSection(channelName, 15)` 주입. 신규 세션(systemParts)과 resume(ctxParts) 모두 커버. 세션 해시에 영향 없음.

**표면 통합 메모리 — Phase 2: MCP `wiki_add_fact` + `/remember` 스킬 (2026-04-15, PR #25)**:
- Phase 1의 제약 해소: (1) 세션 종료 지연 없이 즉시 주입, (2) macOS Claude 앱에서도 동작.
- `extras-gateway.mjs`: `addFactToWiki` 임포트 + `wiki_add_fact` MCP 도구 등록 (`wikiAddFactTool` 핸들러, 5~500자 검증, source 기본 `"mcp-client"`).
- `.claude/skills/remember/SKILL.md`: `/remember <사실>` 또는 `/remember` (최근 대화 자동 추출) 2모드. Claude가 사실 추출/정제 후 `mcp__nexus__wiki_add_fact` 호출. Fallback 금지 (nexus 미로드 시 에러 반환).
- `CLAUDE.md`: "Surface Memory Boundary" 섹션 — macOS 앱 = 즉석 질의용, CLI = 기억 누적용 원칙화.
- macOS Claude 앱은 서버-only 대화이므로 Phase 1 자동 경로 불가 → Phase 2 `/remember`가 **유일한 기억 입금 창구**.

**표면 통합 메모리 — Phase 1: Claude Code CLI → 위키 실시간 주입 (2026-04-15)**:
- 간극 진단: `stop-session-save.sh`가 Claude Code 세션을 `~/.jarvis/context/claude-code-sessions/{project}/{ts}.md`로 덤프해왔으나, 이후 `context-extractor.mjs`(nightly)는 도메인 summary만 생성하고 `wikiAddFact`를 호출하지 않음 → Claude Code 대화는 RAG에는 증분 인덱싱되지만 위키로는 수렴하지 못하는 비대칭.
- `wiki-engine.mjs::addFactToWiki()`: 3번째 인자를 `opts = { domainOverride, source }` 객체로 확장. 백워드 호환 유지(문자열 전달 시 domainOverride로 해석). `_facts.md` 기록 라인 포맷을 `- [YYYY-MM-DD] [source:X] 팩트` 로 변경 — 어느 표면에서 주입되었는지 사후 감사 가능. 중복 체크는 source 무관 (첫 주입이 SSoT).
- `claude-runner.js::wikiAddFact()` 래퍼: `opts` 파라미터 추가, `{ source: 'discord', ...opts }` 명시. Discord 봇 경로의 모든 주입은 `source:discord` 태그됨.
- `infra/scripts/wiki-ingest-claude-session.mjs` (신규): 세션 .md 1개를 입력받아 Haiku(4.5)로 facts 추출 후 `addFactToWiki(source: 'claude-code-cli')` 루프. `--latest [project]` 플래그로 mtime 기준 최신 세션 자동 선택. LLM 실패 시에도 exit 0 (파이프라인 비차단). autoExtractMemory 추출 프롬프트를 Claude Code 세션 맥락에 맞춰 각색.
- `~/.claude/hooks/stop-wiki-ingest.sh` (신규): Claude Code Stop 훅(async, 45s). `stop-session-save.sh`와 경합 방지를 위해 최대 8초 mtime poll 후 최신 세션 .md가 60초 이내 생성되었을 때만 ingester 호출. 경합/순서 의존 제거.
- `~/.claude/settings.json` Stop 배열에 `stop-wiki-ingest.sh` 추가.
- macOS Claude 앱은 로컬 세션 히스토리가 없어(서버-only) CLI와 동등한 자동 수집 불가 — Phase 2에서 MCP `wiki_add_fact` + `/remember` 스킬 + CLAUDE.md 경계 명시로 해결 예정.

**Discord 응답 렌더링 개선 2차 (2026-04-15)**:
- `streaming.js` `_wrapInCV2()`: 자동 래핑 완전 비활성화. 기존: 500자 이상 + ## 제목 있으면 무조건 CV2 카드 변환 → LLM 지시(명시적 요청 시에만 CV2)와 상충. 수정: 함수 진입 즉시 return. 명시적 CV2_DATA 마커가 있을 때만 CV2 사용.
- `streaming.js` TABLE_DATA 렌더링: Chrome PNG → Discord 텍스트로 전환. 기존: Puppeteer Chrome 싱글톤으로 HTML 렌더링 후 PNG 전송. 수정: `- **항목** · 값` bullet list 형식으로 즉시 텍스트 전송. Chrome 의존성 제거, 모바일 가독성 향상.

**user-memory 오염 버그 수정 (2026-04-15)**:
- `claude-runner.js`: `autoExtractMemory()`의 `isFamilyChannel` 판정 버그 수정. 기존: `FAMILY_CHANNEL_ID`(단수) 환경변수 참조 → 항상 `''` → `isFamilyChannel` 영구 `false` → FAMILY_JUNK_RE 필터 무력화. 수정: `FAMILY_CHANNEL_IDS`(복수, handlers.js와 동일) 참조 + 쉼표 분리 목록 `includes()` 체크. 결과: 보람 채널 대화 로그 raw 조각이 facts에 저장되던 문제 해소.
- `claude-runner.js`: `FAMILY_JUNK_RE` / `FAMILY_JUNK_RE2` 패턴에 `userid.*boram` 추가. 기존 패턴이 `userid.*family`, `userid.*owner`만 잡고 `userId: boram` 형태의 컴팩션 헤더를 누락하던 빈틈 보완.

**아키텍처 개선 — 토큰 효율 & 요약 품질 (2026-04-14)**:
- `rag-helper.js`: RAG stdout 2000자 하드캡 추가. 초과 시 마지막 줄바꿈 기준으로 자르고 `\n[...더 있음]` 표시. 장문 매칭 시 10K+ 토큰 주입 방지.
- `session-summary.js`: 요약 크기 제한 1000자 → 2000자 확대. 기술 대화 평면화 문제 해소.
- `session-summary.js`: `compactSessionWithAI()` 모델 조건부 전환 — rawContent.length > 5000 이면 `claude-sonnet-4-5`, 아니면 `claude-haiku-4-5-20251001`. 복잡한 세션 요약 품질 향상.
- `session-summary.js`: `loadSessionSummaryRecent()` 직전 턴 수 2턴 → 3턴 확대. "계속" 명령어 시 컨텍스트 손실 감소.
- `claude-runner.js`: User Memory 해시 캐싱 추가 (`memoryHashCache` Map). 메모리 변화 없으면 `getRelevantMemories()` 재조회 생략 — 반복 세션 턴당 1~2K 토큰 절감.
- `user-memory.js`: Family 채널 노이즈 필터 정규식 정밀화. 기존 광범위한 userid 패턴 → `FAMILY_JUNK_RE = /^\[userid:|compacted at|사용자 의도|완료된 작업|미완 작업|핵심 참조/i` 으로 교체. 정당한 학생/일정 정보 오탐 방지.

**post-tool-docdebt.sh worktree 경로 정규화 (2026-04-15)**:
- 버그: `~/jarvis/.claude/worktrees/<name>/infra/docs/X.md` 경로 편집 시 debt 해소 로직이 경로를 인식하지 못함. 기존 prefix 검사는 `~/jarvis/infra/`, `~/jarvis/`, `~/.jarvis/` 세 가지만 대응. worktree 경로는 `~/jarvis/` prefix에는 매치되지만 `rel`이 `.claude/worktrees/...`로 시작해 `startswith("docs/")` 검사에서 탈락 → debt 해소 실패.
- 대칭 비대칭 문제: 반면 코드 편집 시 `match_glob`은 `mg in file_path` (substring 매치)를 쓰기 때문에 worktree 경로에서도 debt 추가는 정상 동작. 결과적으로 worktree에서 작업 시 **debt는 쌓이는데 해소가 안 되는** stuck 상태 발생.
- 수정: 훅 파이썬 블록 상단에 정규식 기반 worktree 경로 정규화 추가. `^~/jarvis/.claude/worktrees/<name>/(rest)$` 매치 시 `file_path`를 `~/jarvis/(rest)`로 재작성 후 기존 로직에 투입. 같은 정규화가 `frel` 계산 경로에도 자동 적용되어 debt 엔트리의 `triggered_by` 값도 main 체크아웃과 동일한 상대 경로로 통일됨.
- 효과: Stop 훅의 doc-debt 차단이 worktree 기반 PR 작업 흐름을 더 이상 방해하지 않음.

**표면 통합 메모리 — Phase 2: MCP `wiki_add_fact` + `/remember` 스킬 (2026-04-15)**:
- 배경: Phase 1은 Claude Code CLI 세션 종료 훅으로 위키 자동 주입을 확보했으나, (1) 세션 종료까지 반영이 지연되고 (2) macOS Claude 앱은 로컬 세션 히스토리가 없어 Phase 1의 자동 경로가 원리상 불가능. 즉각·수동·표면 무관 주입 경로가 필요.
- `infra/lib/nexus/extras-gateway.mjs`: `addFactToWiki` 임포트 + `wiki_add_fact` MCP 도구 신규 등록. 대화 중 에이전트(디스코드 봇/Claude Code CLI/macOS 앱의 MCP 클라이언트)가 즉시 호출 가능. 입력 검증: fact 5~500자, domain/source 선택. source 기본값 `"mcp-client"` (호출자 구분 태깅). `wikiAddFactTool` 핸들러는 동일 프로세스에서 wiki-engine을 직접 호출(프로세스 간 IPC 없음 — 파일락 race는 감수, wiki-engine이 read-modify-write 단위로 원자성 유지).
- `handle()` 라우터에 `wiki_add_fact` dispatch + 텔레메트리 메타(fact 60자, source, domain) 기록. 기존 nexus_stats 도구로 사용 통계 추적 가능.
- `.claude/skills/remember/SKILL.md` (신규): `/remember <fact>` 또는 `/remember` (인자 없음 = 최근 대화 핵심 추출) 형태의 명시적 플러시 스킬. Claude가 사실을 추출/정제 후 `mcp__nexus__wiki_add_fact` 호출. CLI/macOS 앱 양쪽에서 동일 동작.
- `CLAUDE.md` (repo): "표면 메모리 경계" 섹션 추가 — macOS 앱 = 즉석 질의용, Claude Code CLI = 기억 누적·작업 지속용으로 역할 구분 명시. 오너와 에이전트 모두가 따를 규범.
- macOS 앱 제약 솔직화: 서버-only 대화 이력 때문에 Phase 1 자동 경로 불가 → Phase 2의 MCP 도구로 "명시적 주입"만 가능. `/remember`가 사실상 유일한 기억 입금 창구. 이 점은 CLAUDE.md와 스킬 본문에 모두 명시.

**표면 통합 메모리 — Phase 1: Claude Code CLI → 위키 실시간 주입 (2026-04-15)**:
- 간극 진단: `stop-session-save.sh`가 Claude Code 세션을 `~/.jarvis/context/claude-code-sessions/{project}/{ts}.md`로 덤프해왔으나, 이후 `context-extractor.mjs`(nightly)는 도메인 summary만 생성하고 `wikiAddFact`를 호출하지 않음 → Claude Code 대화는 RAG에는 증분 인덱싱되지만 위키로는 수렴하지 못하는 비대칭 (읽기만 공유, 쓰기는 분리).
- `wiki-engine.mjs::addFactToWiki()`: 3번째 인자를 `opts = { domainOverride, source }` 객체로 확장. 백워드 호환 유지(문자열 전달 시 domainOverride로 해석). `_facts.md` 기록 라인 포맷을 `- [YYYY-MM-DD] [source:X] 팩트`로 변경 — 어느 표면에서 주입되었는지 사후 감사 가능. 중복 체크는 source 무관 (첫 주입이 SSoT).
- `claude-runner.js::wikiAddFact()` 래퍼: `opts` 파라미터 추가, `{ source: 'discord', ...opts }` 명시. Discord 봇 경로의 모든 주입은 `source:discord` 태그됨.
- `infra/scripts/wiki-ingest-claude-session.mjs` (신규): 세션 .md 1개를 입력받아 Haiku(4.5)로 facts 추출 후 `addFactToWiki(source: 'claude-code-cli')` 루프. `--latest [project]` 플래그로 mtime 기준 최신 세션 자동 선택. LLM 실패 시에도 exit 0 (파이프라인 비차단). autoExtractMemory 추출 프롬프트를 Claude Code 세션 맥락에 맞춰 각색 (구체적 결정·선호·제약 위주, diff/코드라인/행동 요약 금지). KST 타임스탬프 로깅.
- `~/.claude/hooks/stop-wiki-ingest.sh` (신규, user config): Claude Code Stop 훅(async, 45s). `stop-session-save.sh`와 경합 방지를 위해 최대 8초 mtime poll 후 최신 세션 .md가 60초 이내 생성되었을 때만 ingester 호출. 경합/순서 의존 제거.
- `~/.claude/settings.json` Stop 배열에 `stop-wiki-ingest.sh` 추가 (user config, repo 외부).
- Smoke test: 5798 bytes 세션 1개로 end-to-end 검증 — Haiku가 5개 추출, junk 필터 1개 제외 후 4개를 `ops` 도메인에 `[source:claude-code-cli]` 태그로 주입 성공.
- macOS Claude 앱은 로컬 세션 히스토리가 없어(서버-only, `~/Library/Application Support/Claude/`에 config 파일 1개만 존재) CLI와 동등한 자동 수집 불가 — Phase 2에서 MCP `wiki_add_fact` 도구 + `/remember` 스킬 + CLAUDE.md 경계 명시로 해결 예정.

**Discord bot 안정성 개선 (2026-03-22)**:
- `discord-bot.js` OOM 임계값 500MB → 800MB 상향. 실측 866MB OOM 발생으로 너무 낮았음. watchdog MEMORY_WARN_MB(900)보다 낮게 유지하여 자가 복구 우선.
- OOM 재시작 시 `restart-notify.json` 기록 추가. 기존에는 `process.exit(1)` 직전 notify 없어 재시작 후 Discord 알림에 "unexpected shutdown" 표시. 이제 "OOM restart (NNNmb)" 사유 표시.
- Singleton stale PID 탐지 시 `restart-notify.json` 기록 추가. 기존 catch 블록이 silent — 다음 startup에 비정상 종료 원인 미표시. "unexpected shutdown (stale PID)" 사유 기록.
- `session-summary.js` compactSessionWithAI 모델 ID `claude-haiku-4-5-20251015` → `claude-haiku-4-5-20251001` 수정. 잘못된 모델 ID로 `claude exited 1` 반복 실패 발생. 세션 요약 AI 압축이 매번 fallback으로 처리되던 문제 해소.

**OSS readiness hardening (2026-03-18)**:
- All personal files (boram-*.sh, relay-to-owner.sh, PERSONALIZATION-AUDIT.md, backup files) untracked from git index; `.gitignore` updated to cover them permanently.
- Personal identifiers (names, email, Discord channel IDs, LAN IP, ntfy topic) removed from all git-tracked files; replaced with env var placeholders (`FAMILY_MEMBER_NAME`, `FAMILY_CHANNEL`, `GOOGLE_ACCOUNT`, etc.).
- `NODE` hardcoding fixed in 10 scripts: `NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"` pattern applied; `commands.js` uses `process.execPath` for runtime node binary.
- `rag-compact-wrapper.sh`: rewritten to use `$BOT_HOME` and `$NODE` — was hardcoding absolute paths.
- `memory-sync.sh`: project path calculation changed from broken `sed` chain to `tr '/' '-'` for correct Claude Code project dir encoding.
- `auto-diagnose.sh`, `check-gh-auth.sh`: upgraded to `set -euo pipefail` per project standard.
- `js-yaml ^4.1.0` added to `discord/package.json` (missing declared dependency).
- `SECURITY.md` created with responsible disclosure policy.
- `discord/.env.example`: added `FAMILY_MEMBER_NAME=` placeholder.

---

## Self-Healing Infrastructure

Four independent layers. Each failure mode is caught by a different layer:

```
Layer 0: bot-preflight.sh  (every cold start)
  ├─ Validates: node binary, discord-bot.js, .env keys (4 required), JSON configs
  ├─ Failure → tmux jarvis-heal session → Claude auto-fixes files
  │   ├─ ANTHROPIC_API_KEY passed via tmux -e flag (launchd env isolation)
  │   ├─ Recovery Learnings: past fixes accumulated in state/recovery-learnings.md
  │   └─ MAX_HEAL_ATTEMPTS=3, exponential backoff 30s→90s→180s, 6h auto-decay
  └─ Success → monitoring mode (fast crash detection: 3 crashes in <10s → auto-heal)

Layer 1: launchd  (KeepAlive unconditional — restarts on SIGTERM, crash, or clean exit)
  └─ discord-bot.js auto-restarts on any exit (ThrottleInterval=10s)

Layer 2: cron */5 min  →  watchdog.sh (macOS + Linux/Docker)
  ├─ Checks log freshness (15 min silence = unhealthy)
  ├─ Crash loop detection: PID tracking, 3 restarts/30 min → ntfy alert
  ├─ Out-of-band alerts: ntfy direct HTTP (works even when Discord bot is down)
  ├─ macOS: launchctl kickstart | Linux: pm2 restart jarvis-bot
  └─ Kills stale claude -p processes

Layer 3: cron */3 min  →  launchd-guardian.sh
  ├─ Detects unloaded LaunchAgents
  └─ Re-registers them automatically

Deploy gate: deploy-with-smoke.sh
  └─ 47-item smoke test before any restart (syntax, files, functions, JSON, .env)
```

**AI Auto-Recovery flow (bot-preflight.sh → bot-heal.sh):**
```
preflight FAIL
  → tmux new-session jarvis-heal (PTY environment)
    → claude -p reads logs, edits broken files
      → "복구완료: <summary>" written
        → launchd restarts → preflight runs again
```

**Rate limiting:** shared `state/rate-tracker.json` — 900 requests per 5-hour window, split between bot and cron tasks.

---

## Company Agent Teams

A virtual organization of AI teams, each with a specialized role. Every team runs as a scheduled `claude -p` session via `@anthropic-ai/claude-agent-sdk`, produces a report, and posts it to its designated Discord channel.

```
┌─────────────────────────────────────────────────────────────┐
│                    Council (Oversight)                       │
│  Daily 23:05 KST · Sub-agents: kpi-analyst, log-analyst    │
│  Reviews all team outputs, detects cross-team issues        │
├─────────┬──────────┬──────────┬──────────┬──────────────────┤
│  Infra  │  Trend   │  Record  │  Brand   │  Career/Academy  │
│  Daily  │  Daily   │  Daily   │  Weekly  │  Weekly          │
│  09:00  │  07:50   │  22:30   │  Tue     │  Fri/Sun         │
└─────────┴──────────┴──────────┴──────────┴──────────────────┘
```

For team details see [TEAMS.md](TEAMS.md).

---

## Board Meeting → Decision Dispatcher

The CEO agent doesn't just report — it **delegates and holds teams accountable**:

```
Board Meeting (08:10, 21:55 KST)
  │
  ├─ CEO judgment → decisions/{date}.jsonl
  │
  └─ decision-dispatcher.sh (auto-runs after meeting)
       ├─ Actionable decisions → execute immediately
       │   (service restart, log cleanup, cron analysis)
       ├─ Report-only decisions → flag for human review
       │   (investment actions, architecture changes)
       └─ Update team-scorecard.json
            ├─ Success → +1 merit
            ├─ Failure → +1 penalty
            └─ Thresholds:
                 3 penalties → WARNING
                 5 penalties → PROBATION
                10 penalties → DISCIPLINARY (team lead dismissed)
```

Penalty decay: 30% reduction every Monday (no permanent marks).

Configuration: `agents/*.md`, `state/team-scorecard.json`

---

## Orchestrator — Event Bus

A SQLite-backed message queue (`messages.db`) that decouples producers from consumers:

```
Cron tasks / Event triggers / Teams
         │
         ▼
  ┌─────────────────────┐
  │   Orchestrator MQ    │
  │  SQLite + 5s poll    │
  │  Channel routing:    │
  │  alert│market│system │
  │  kpi  │general       │
  └─────────────────────┘
         │
         ▼
  Discord webhooks / KPI aggregation / Alerts
```

Two-phase processing: validate message → execute delivery. KPI metrics auto-aggregated per task.

Runs as a LaunchAgent (`ai.jarvis.orchestrator`), not cron.

---

## LanceDB Hybrid RAG

The bot remembers everything. Every conversation turn, cron result, and context file is indexed into a local LanceDB database:

- **Vector search** — Local `all-MiniLM-L6-v2` (384 dims, zero API cost)
- **Full-text search** — BM25 keyword matching
- **Reranking** — Reciprocal Rank Fusion (RRF) merges both signals
- **Upsert indexing** — `mergeInsert` for efficient incremental updates (no destructive deletes)

The RAG engine runs an incremental index hourly, plus real-time file watching via `rag-watch.mjs`. When you ask a question, relevant context is injected into the `claude -p` prompt automatically — without consuming extra context window space.

---

## Operational Intelligence

### KPI Measurement

Weekly automated performance tracking for all cron tasks and agent teams:

```
measure-kpi.sh (Mon 08:30)
  └─ Reads task-runner.jsonl (all cron execution logs)
  └─ Calculates per-team success rate, duration, cost
  └─ Outputs text + JSON report
  └─ Posts to Discord with --discord flag
```

### Anomaly Detection + Auto-Tuning

```
kpi-anomaly-detector.sh (Mon 08:35)
  └─ Calls measure-kpi.sh --json
  └─ Classifies: CRITICAL (<70%) / WARNING (<85%)
  └─ Proposes timeout increases for failing tasks
  └─ Creates L3 approval request (see below)
```

### L3 Approval Workflow

Risky autonomous actions require human approval via Discord buttons:

```
Bash script drops JSON ──► state/l3-requests/
                                    │
Discord bot polls (10s) ◄───────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  [Approve]   [Reject]   │  ← Discord button message
  └─────────────────────────┘
         │
         ▼ (on approve)
  execFileSync(scripts/l3-actions/*)
```

Pre-configured L3 actions: `cleanup-logs`, `cleanup-results`, `kill-stale-claude`, `restart-bot`, `apply-kpi-decisions`, `auditor-fix-*`

---

## Proactive Automation

### Event Trigger System

Condition-based triggers that fire independently of cron schedules (`scripts/event-trigger.sh`, every 3 min):

| Trigger | Condition | Cooldown | Action |
|---------|-----------|----------|--------|
| TQQQ price | Market hours + threshold crossed | 4 hours | Discord alert |
| Disk usage | > 85% | 24 hours | L3 approval → cleanup |
| Claude load | 3+ concurrent `claude -p` | 30 min | Discord warning |

### Smart Standup

Owner-aware morning briefing (`scripts/smart-standup.sh`):

```
08:05  →  Check if owner is online (Discord activity detection)
           ├─ Online  → Run standup immediately
           └─ Offline → Retry at 08:35, 09:05, 09:35 (max 4 attempts)
```

### Code Auditor

Automated code quality scanner (`scripts/jarvis-auditor.sh`, daily 04:45):

| Phase | What it checks |
|-------|---------------|
| ShellCheck | Static analysis of all `.sh` files, auto-fix for high-priority issues |
| Node syntax | `node --check` on all `.js`/`.mjs` files |
| Anti-patterns | Custom pattern matching via `config/anti-patterns.json` |
| LaunchAgent | Service loaded + PID verification |
| Health freshness | `state/health.json` staleness check |
| E2E results | Scan latest E2E test results for failures |

**Safety:** protected file list, 20-hour cooldown per file, max 5 auto-fixes per run, syntax verification after each fix with automatic rollback on failure.

### Vault Sync

Bi-directional sync between bot data and an Obsidian Vault (`scripts/vault-sync.sh`, every 6 hours):

```
~/.jarvis/rag/teams/reports/*.md  ──►  ~/Jarvis-Vault/03-teams/{team}/
~/.jarvis/docs/*.md               ──►  ~/Jarvis-Vault/06-knowledge/
```

Each team folder retains the 7 most recent reports. Enables browsing AI-generated reports in Obsidian with full graph and backlink support.

---

## Task FSM — Autonomous Development Queue

Self-directed task execution engine for long-running autonomous work. Replaces ad-hoc Python3 JSON manipulation with a typed state machine backed by SQLite.

### State Machine (`lib/task-fsm.mjs`)

Pure functions only — no side effects, no DB dependency. Storage is the caller's responsibility.

```
pending ──► queued ──► running ──► done
              │           │
              ▼           ▼
           skipped      failed
              │           │
              └──► pending └──► queued  (manual recovery / auto-retry)
```

| Function | Signature | Purpose |
|----------|-----------|---------|
| `canTransition(from, to)` | `(string, string) → boolean` | Guard: is this transition allowed? |
| `applyTransition(task, to)` | `(Object, string) → Object` | Returns new task object, throws on invalid transition |
| `pickNextTask(tasks[])` | `(Object[]) → Object\|null` | Selects highest-priority queued task with satisfied dependencies |

### Storage (`lib/task-store.mjs`)

`node:sqlite` (Node.js 22.5+ built-in, zero external dependencies). WAL mode for concurrent read/write safety.

```sql
tasks (id PK, status, priority, retries, depends JSON, meta JSON, updated_at)
task_transitions (task_id, from_status, to_status, triggered_by, created_at)
```

- `transition()` wraps UPDATE + INSERT in `BEGIN/COMMIT/ROLLBACK` — atomicity guaranteed (`node:sqlite` has no `.transaction()` helper)
- `addTask()` uses `INSERT OR IGNORE` — idempotent, safe to call multiple times
- Full CLI: `node task-store.mjs [list|pick|get|field|transition|count-queued|export]`

### Integration

```
insight-extractor.mjs  ──► addTask()        (new tasks from AI synthesis)
extras-gateway.mjs          ──► listTasks()      (MCP tool: jarvis-coder task queue)
jarvis-coder.sh             ──► node task-store.mjs [pick-and-lock|field|transition|count-queued]
  (bin/dev-runner.sh → jarvis-coder.sh 심볼릭 링크, 하위 호환 유지)
```

### Design Decisions (ADR-011)

- **LangGraph rejected**: LLM branching tool, not a state machine. 수십 MB 의존성 대비 효용 없음
- **XState rejected**: `@xstate/fsm` deprecated in v5, unnecessary abstraction for 6-state FSM
- **better-sqlite3 rejected**: native addon requiring node-gyp; breaks on Node version upgrades
- **node:sqlite chosen**: built-in since v22.5, identical sync API (`.prepare().get()/.run()`)
