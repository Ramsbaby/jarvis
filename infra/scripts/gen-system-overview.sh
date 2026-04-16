#!/usr/bin/env bash
# gen-system-overview.sh — Jarvis 시스템 개요 문서 자동 생성
# 트리거: 매일 04:05 크론 (tasks.json) + git post-commit 훅
# 출력:   ~/.jarvis/docs/SYSTEM-OVERVIEW.md
#
# 수정 방법: 이 스크립트를 편집하고 저장 → 커밋 시 자동 재생성
# 주의: docs/SYSTEM-OVERVIEW.md 는 자동 생성 파일 — 직접 편집 금지

set -euo pipefail

# BOT_HOME 우선순위: 명시적 지정 > 실제 존재하는 경로 > 기본값
if [[ -z "${BOT_HOME:-}" ]]; then
  if [[ -d "${HOME}/.jarvis" ]]; then
    BOT_HOME="${HOME}/.jarvis"
  else
    BOT_HOME="${HOME}/.jarvis"
  fi
fi
source "${BOT_HOME}/lib/compat.sh" 2>/dev/null || {
  IS_MACOS=false; IS_LINUX=false
  case "$(uname -s)" in Darwin) IS_MACOS=true ;; Linux) IS_LINUX=true ;; esac
}
OUTPUT="$BOT_HOME/docs/SYSTEM-OVERVIEW.md"
LOG="$BOT_HOME/logs/gen-system-overview.log"
export BOT_HOME

# 출력 디렉토리 자동 생성
mkdir -p "$(dirname "$OUTPUT")" "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] gen-system-overview: $*" >> "$LOG" 2>&1 || true; }
log "시작"

# 임시파일 + EXIT trap: 실패 시 빈 파일 생성 방지 & 에러 로그 보장
TMP_OUTPUT=$(mktemp)
trap 'EC=$?; rm -f "$TMP_OUTPUT" 2>/dev/null; if [[ $EC -ne 0 ]]; then log "실패 (exit $EC)"; fi' EXIT

# PATH 보정 (크론 환경)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

# ── 동적 데이터 수집 ──────────────────────────────────────────────────────────

GEN_AT="$(date '+%Y-%m-%d %H:%M:%S')"
GIT_HASH=$(cd "$BOT_HOME" && git rev-parse --short HEAD 2>/dev/null || echo "N/A")
GIT_BRANCH=$(cd "$BOT_HOME" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# 태스크 표 (tasks.json)
TASK_TABLE=$(python3 - <<'PY' 2>/dev/null || echo "_(태스크 없음)_"
import json, os
B = os.environ.get('BOT_HOME', os.path.expanduser('~/.jarvis'))
data = json.load(open(f'{B}/config/tasks.json'))
tasks = data.get('tasks', data) if isinstance(data, dict) else data
en  = [t for t in tasks if t.get('enabled', True)]
dis = [t for t in tasks if not t.get('enabled', True)]
rows = ['| 태스크 ID | 스케줄 | 채널 | 설명 |',
        '|-----------|--------|------|------|']
for t in sorted(en, key=lambda x: x.get('schedule') or 'z'):
    sched = t.get('schedule') or '(event/manual)'
    ch    = t.get('discordChannel') or t.get('channel') or '-'
    desc  = str(t.get('description') or t.get('name') or '')[:52]
    rows.append(f"| `{t.get('id','?')}` | `{sched}` | {ch} | {desc} |")
print(f"> ✅ 활성 **{len(en)}개** / 비활성 {len(dis)}개\n")
print('\n'.join(rows))
if dis:
    ids = ', '.join(f"`{t['id']}`" for t in dis)
    print(f"\n> ⚠️ 비활성: {ids}")
PY
)

# Nexus 도구 표
NEXUS_TABLE=$(python3 - <<'PY' 2>/dev/null || echo "_(도구 목록 없음)_"
import re, os, glob
B = os.environ.get('BOT_HOME', os.path.expanduser('~/.jarvis'))
DESCS = {
    'exec':         '커스텀 bash — 전용 도구 없을 때만 (마지막 수단)',
    'scan':         '다중 명령 병렬 실행',
    'cache_exec':   'TTL 캐시 실행 (ps/df/uptime 등 반복 명령)',
    'log_tail':     '로그 파일 전용 읽기 (tail/cat 대체)',
    'file_peek':    '파일 패턴 검색 (grep 대체)',
    'rag_search':   'Obsidian 장기기억 하이브리드 검색 (BM25+Vector)',
    'health':       '시스템 전체 상태 단일 조회',
    'discord_send': 'Discord 채널 메시지 전송',
    'run_cron':     '크론 잡 즉시 트리거',
    'get_memory':   'RAG 검색 (외부 클라이언트용)',
    'list_crons':   '크론 잡 목록 조회',
    'dev_queue':    '개발 태스크 큐 조회',
    'context_bus':  '팀 공용 게시판 read/append',
    'emit_event':   '이벤트 발행 (event-watcher 트리거)',
    'usage_stats':  'Claude API 토큰 사용량 통계',
    'nexus_stats':  'Nexus 도구 사용 통계 (자기진단)',
}
tools = []
for f in sorted(glob.glob(f'{B}/lib/nexus/*-gateway.mjs')):
    gw = os.path.basename(f).replace('-gateway.mjs', '')
    for n in re.findall(r"name:\s*'([^']+)'", open(f).read()):
        tools.append((gw, n))
print(f"> ✅ **{len(tools)}개 MCP 도구** (4개 게이트웨이)\n")
print("| 게이트웨이 | 도구명 | 용도 |")
print("|-----------|--------|------|")
for gw, n in tools:
    print(f"| `{gw}` | `{n}` | {DESCS.get(n, '-')} |")
PY
)

# 주요 파일 크기 표
FILE_TABLE=$(
  printf "| 파일 | 줄 수 | 역할 |\n|------|-------|------|\n"
  _r() {
    [[ -f "$BOT_HOME/$1" ]] || return 0
    printf "| \`%s\` | %s | %s |\n" "$1" "$(wc -l < "$BOT_HOME/$1" | tr -d ' ')" "$2"
  }
  _r "discord/discord-bot.js"          "Discord 봇 메인"
  _r "lib/mcp-nexus.mjs"               "Nexus MCP 오케스트레이터"
  _r "lib/nexus/exec-gateway.mjs"      "exec 게이트웨이 + Circuit Breaker"
  _r "lib/nexus/extras-gateway.mjs"    "extras 게이트웨이 (discord/cron/stats)"
  _r "lib/nexus/rag-gateway.mjs"       "RAG 게이트웨이"
  _r "lib/nexus/health-gateway.mjs"    "헬스 게이트웨이"
  _r "lib/rag-engine.mjs"              "RAG 하이브리드 검색 엔진"
  _r "bin/ask-claude.sh"               "claude -p 래퍼 (크론 진입점)"
  _r "bin/jarvis-cron.sh"              "크론 실행 엔진"
  _r "config/tasks.json"               "크론 태스크 설정"
  _r "discord/personas.json"           "채널 페르소나 설정"
  _r "scripts/system-doctor.sh"        "자동 시스템 점검 (매일 06:00)"
  _r "scripts/gen-system-overview.sh"  "이 문서 생성 스크립트"
)

# 서비스 상태
if $IS_MACOS; then
  LAUNCHD_TABLE=$(
    printf "| 서비스 | 상태 | PID |\n|--------|------|-----|\n"
    launchctl list 2>/dev/null \
      | awk '/ai\.jarvis\./ {
          status = ($1 ~ /^[0-9]+$/ && $1+0 > 0) ? "🟢 실행중" : "🔴 중지"
          printf "| %s | %s | %s |\n", $3, status, $1
        }' || printf "| (launchctl 조회 실패) | - | - |\n"
  )
else
  LAUNCHD_TABLE=$(
    printf "| 서비스 | 상태 | PID |\n|--------|------|-----|\n"
    if command -v pm2 &>/dev/null; then
      pm2 jlist 2>/dev/null | python3 -c "
import json,sys
try:
  for p in json.load(sys.stdin):
    s='🟢 실행중' if p['pm2_env']['status']=='online' else '🔴 중지'
    print(f\"| {p['name']} | {s} | {p.get('pid','N/A')} |\")
except: print('| (pm2 조회 실패) | - | - |')
" 2>/dev/null
    else
      printf "| (pm2 미설치) | - | - |\n"
    fi
  )
fi

# 최근 git 커밋
RECENT_GIT=$(
  cd "$BOT_HOME" && git log --oneline -10 --no-merges 2>/dev/null \
    | awk '{printf "- `%s` %s\n", $1, substr($0, index($0,$2))}' \
    || echo "_(변경 이력 없음)_"
)

# ── 문서 생성 (Python 템플릿 치환) ─────────────────────────────────────────────

export GEN_AT GIT_HASH GIT_BRANCH TASK_TABLE NEXUS_TABLE FILE_TABLE LAUNCHD_TABLE RECENT_GIT

python3 - <<'PYEOF' > "$OUTPUT"
import os

def e(k, default='_(없음)_'):
    return os.environ.get(k, default)

doc = """\
# Jarvis 시스템 개요

> 🤖 **자동 생성 문서** — 직접 편집 금지
> Generated: {{GEN_AT}} | Commit: `{{GIT_HASH}}` (`{{GIT_BRANCH}}`)
> 업데이트: `scripts/gen-system-overview.sh` (매일 04:05 + git commit 시)

---

## 1. 한 줄 요약

> **"Claude AI를 두뇌로 쓰는 완전 자율 AI 회사. 매일 알아서 돌아간다."**

| 항목 | 내용 |
|------|------|
| 오너 | ${JARVIS_OWNER_NAME:-Your Name} |
| 인프라 | Mac Mini (macOS, 24/7 무중단) |
| 비용 | 월 ~$20 (Claude Max 구독) — API 직접 대비 90% 절약 |
| 자율화율 | 일상 루틴 100% 자동, 장애 복구 95% 자동 |
| 핵심 기술 | claude -p + LanceDB RAG + Nexus MCP + LaunchAgent |

---

## 2. 5층 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│  5층  Discord Bot           discord-bot.js                      │ ← 사람이 말 거는 창구
├─────────────────────────────────────────────────────────────────┤
│  4층  크론 자동화 엔진       jarvis-cron.sh + tasks.json         │ ← 매일 자동 실행
├─────────────────────────────────────────────────────────────────┤
│  3층  AI 두뇌                claude -p (ask-claude.sh)          │ ← 실제 생각하는 곳
│       7팀 페르소나 시스템     RAG 컨텍스트 자동 주입              │
├─────────────────────────────────────────────────────────────────┤
│  2층  장기기억                RAG Engine (LanceDB)              │ ← 과거 기억 검색
│       BM25 + Vector 하이브리드  Obsidian Vault 실시간 인덱싱     │
├─────────────────────────────────────────────────────────────────┤
│  1층  인프라                  Nexus MCP + macOS LaunchAgent     │ ← 서버, 파일, 명령
│       launchd 자동재시작       Circuit Breaker 보호              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 핵심 컴포넌트 상세

### 3.1 Discord Bot (`discord/discord-bot.js`)

사람이 자비스와 대화하는 유일한 창구.

```
사용자 메시지 (텍스트 / 이미지 / PDF)
  ↓
discord-bot.js  → 채널명으로 페르소나 선택 (personas.json)
  ↓
claude-runner.js → RAG 컨텍스트 자동 주입 (Nexus rag_search)
  ↓
claude -p "페르소나 + 기억 + 질문"
  ↓
스트리밍 응답 → Discord 스레드 (1900자 단위 청크)
```

| 기능 | 설명 |
|------|------|
| 채널별 페르소나 | jarvis-ceo → CEO, jarvis-infra → 인프라 담당 |
| PDF 첨부 처리 | pdftotext 추출 → 컨텍스트 주입 |
| 스트리밍 | 긴 응답도 라이브 편집으로 자연스럽게 |
| 자동 복구 | 15분 침묵 → bot-watchdog.sh 재시작 |
| 메모리 보호 | `pendingNext` 패턴으로 90s 타임아웃 경계 응답 유실 방지 |

### 3.2 크론 자동화 (`bin/jarvis-cron.sh`)

tasks.json 기반 스케줄 실행 엔진.

```
crontab → jarvis-cron.sh → tasks.json 파싱
                          ↓
             script 필드? → bash 직접 실행
             prompt 필드? → ask-claude.sh 경유 (claude -p)
```

**현재 등록된 태스크:**

{{TASK_TABLE}}

### 3.3 AI 두뇌 (`bin/ask-claude.sh`)

`claude -p`의 래퍼. 모든 크론 태스크와 Discord 대화의 실제 두뇌.

**컨텍스트 조립 순서:**
```
1. 시스템 페르소나   (채널/태스크별 역할 정의)
2. RAG 장기기억      (관련 Obsidian 노트 자동 검색)
3. Cross-team        (depends 필드 태스크의 최근 결과 자동 주입)
4. 현재 프롬프트     (질문 또는 태스크 지시)
```

**팀 페르소나 시스템:**

| 파일 | 역할 |
|------|------|
| `discord/personas.json` | 채널ID → 페르소나 매핑 |
| `agents/*.md` | CEO, 인프라팀장, 전략고문 등 에이전트 정의 |
| `teams/*.yaml` | YAML 기반 팀 설정 (`{{VAR}}` 템플릿 지원) |

### 3.4 RAG 장기기억 (`lib/rag-engine.mjs`)

Obsidian Vault의 모든 노트를 검색 가능한 장기기억으로 변환.

```
Obsidian Vault (${VAULT_DIR:-$HOME/vault}/)
  ↓ rag-watch.mjs (chokidar 실시간 감시)
LanceDB (rag/lancedb/)
  ├── Vector Index  (text-embedding-3-small)
  └── FTS Index     (BM25 전문검색)
  ↓ 하이브리드 검색 (1순위 BM25 + 보조 Vector)
결과 → Jina 리랭킹 → claude -p 컨텍스트 주입
```

| 특성 | 내용 |
|------|------|
| 인덱싱 | 변경 즉시 (chokidar) + 매시간 증분 |
| 중복 방지 | `mergeInsert()` upsert 방식 |
| 검색 방식 | BM25 키워드 우선 + Vector 의미 보조 |

### 3.5 Nexus MCP Gateway (`lib/mcp-nexus.mjs`)

Claude Code와 자비스 시스템을 연결하는 MCP 도구 허브.

{{NEXUS_TABLE}}

**보안 모델:**

| 방어 레이어 | 내용 |
|------------|------|
| `validateCommand()` | 15개 위험 패턴 차단 (rm -rf, killall, .env 접근 등) |
| `validatePath()` | BOT_HOME, /tmp/ 밖 파일 접근 차단 |
| Circuit Breaker | 5분 내 동일 명령 2회 타임아웃 → 10분 자동 차단 |
| Timeout 복구 | 타임아웃 시 수집된 부분 출력 반환 (전체 폐기 없음) |

**MCP Resources (읽기 전용):**
- `jarvis://health` — 실시간 헬스 상태
- `jarvis://logs` — 최근 로그
- `jarvis://cache/stats` — exec 캐시 통계

---

## 4. 7팀 AI 회사

```
         ┌─────────────────────────────────────────────────┐
         │   Board Meeting  (08:10 아침 / 21:55 저녁)      │
         │   CEO(Claude)가 전팀 보고 수집 → 의사결정       │
         │   → context-bus.md 전체 공유                    │
         └──────────────────┬──────────────────────────────┘
                            │ 모든 팀이 읽음
         ┌──────────────────┼──────────────────┐
         │                  │                  │
      전략팀             성장팀             기록팀
     (council)          (career)           (record)
         │                                     │
      브랜드팀                              학술팀
      (brand)                             (academy)

              인프라팀(infra) → 모든 팀에 데이터 공급
```

**팀 간 정보 흐름:**

```
각 팀 결과물 → rag/teams/reports/{team}-*.md (RAG 인덱싱)
council       → shared-inbox/            (긴급 브로드캐스트)
depends 필드  → Cross-team Context 자동 주입
```

**Board Meeting 산출물 4종:**

| 파일 | 내용 |
|------|------|
| `state/context-bus.md` | 전체 요약 (모든 크론이 읽음) |
| `state/board-minutes/{날짜}.md` | 회의록 |
| `state/decisions/{날짜}.jsonl` | 의사결정 감사 로그 |
| `config/goals.json` | OKR KR 진척도 자동 갱신 |

---

## 5. 자기복구 메커니즘 (5단계 방어선)

```
① LaunchAgent KeepAlive=true
  → OS 레벨 1차 재시작 (launchd)

② Watchdog (180초 주기, ai.jarvis.watchdog)
  → 로그 freshness 감시, 봇 침묵 15분 시 재시작

③ launchd-guardian.sh (cron */3)
  → LaunchAgent 언로드 감지 → 자동 재등록

④ pre-cron-auth-check.sh (매일 07:00)
  → 아침 크론 전 Claude 인증 확인
  → 만료 시 ntfy 푸시 + Discord 즉시 알림

⑤ system-doctor.sh (매일 06:00)
  → 전체 8개 항목 점검 → Discord jarvis-system 리포트
```

**알림 경로:**

| 채널 | 용도 |
|------|------|
| Discord `jarvis-system` | 상세 리포트, WARN/FAIL 항목 |
| ntfy (Galaxy 폰) | 긴급 알림 (인증 만료, 네트워크 오류) |

---

## 6. 특장점

### 💰 비용 효율 (~$20/월)
```
Claude Max 구독으로 Opus급 무제한 사용
API 직접 방식이면 월 $200~400 예상 → 실질 90% 절약
현재 rate limit 17% 수준 사용 (여유 있음)
```

### 🧠 장기기억이 진짜로 작동
```
"저번에 말했던 투자 얘기" → Obsidian에서 실제로 찾아냄
BM25(키워드 정확도) + Vector(의미 유사도) 하이브리드
Jina 리랭킹으로 결과 정확도 추가 향상
```

### 🔄 완전 자동 복구
```
5단계 방어선으로 사람 개입 없이 대부분 자가복구
장애 시 Galaxy 폰 ntfy 알림으로 즉시 인지
```

### 🏢 멀티팀 컨텍스트 공유
```
7개 AI 팀이 context-bus.md를 통해 간접 협업
팀 간 직접 통신 없이도 CEO(Claude)가 전체 조율
Cross-team Context로 의존 태스크 결과 자동 주입
```

### 🛡️ 보안 샌드박스 (Nexus)
```
15개 위험 명령 패턴 자동 차단
BOT_HOME 밖 파일 접근 원천 차단
Circuit Breaker로 반복 타임아웃 자동 차단
```

### 📊 자기진단 (`nexus_stats`)
```
넥서스 도구 사용 패턴 실시간 분석
타임아웃 명령어 추적 (cmd 필드 기록)
"쁨뻥이짓" 탐지 → exec 독점 경고
```

---

## 7. 한계점

| 한계 | 원인 | 현황 |
|------|------|------|
| Claude 구독 의존 | claude -p 기반 구조 | pre-cron-auth-check 감시 중 |
| Obsidian Vault → Mac Mini 종속 | 로컬 파일 기반 | iCloud 동기화 미구현 |
| Galaxy 직접 편집 불가 | SSH/Discord 명령만 가능 | 운영 불편 수준 |
| rate limit (아침 클러스터) | claude -p 동시 실행 제한 | 현재 여유 있음, 병렬 증가 시 위험 |
| 외부 공개 불가 | 구독 claude -p 재배포 금지 | 오픈소스화 시 API 버전 분리 필요 |

---

## 8. 로드맵

### 단기 (1~2개월)
- [ ] exec 독점 해소 확인 — `nexus_stats`로 주기적 모니터링
- [ ] Claude 토큰 자동갱신 — 현재 수동 `claude login` 의존
- [ ] Circuit Breaker 통계 Discord 리포트 — slow_cmds 패턴 주기 알림
- [ ] Agent Teams 병렬 실행 재시도 — 현재 10분+ 소요 해결

### 중기 (3~6개월)
- [ ] Multi-provider LLM 폴백 — Claude 만료 시 Gemini/GPT 자동 전환
- [ ] Vault → iCloud/GitHub 백업 — Mac Mini 단일 장애점 해소
- [ ] 이벤트 드리븐 전환 — 크론 → `emit_event` 기반 (조건 충족 시 즉시 실행)
- [ ] 오픈소스 공개 준비 — API 버전 분리, jarvis init 설치 스크립트

### 장기 (6개월+)
- [ ] 진짜 멀티에이전트 — 팀별 독립 프로세스 + 메시지 큐
- [ ] 모바일 네이티브 클라이언트 — Galaxy용 Jarvis 앱
- [ ] 자기개선 루프 — 실패 패턴 → 자동 프롬프트 최적화
- [ ] GitHub 2K~5K stars — "AI Company-in-a-Box" 포지셔닝

---

## 9. 주요 파일 맵

{{FILE_TABLE}}

**디렉토리 구조:**
```
~/.jarvis/
├── bin/           크론 진입점 (ask-claude.sh, jarvis-cron.sh, route-result.sh)
├── config/        tasks.json, monitoring.json, goals.json
├── discord/       봇 코드, personas.json, node_modules/
├── lib/           RAG 엔진, Nexus MCP, LLM Gateway, 팀 로더
│   └── nexus/     4개 게이트웨이 (exec / rag / health / extras)
├── logs/          모든 서비스 로그 (cron.log, nexus-telemetry.jsonl 등)
├── rag/           LanceDB 데이터 + 팀 보고서
├── scripts/       자동화 스크립트 (watchdog, doctor, sync, gen-overview 등)
├── state/         context-bus.md, health.json, board-minutes/, decisions/
├── agents/        팀 에이전트 프로필 (*.md)
├── teams/         팀 YAML 정의 (*.yaml)
├── adr/           Architecture Decision Records (ADR-001~010)
└── docs/          아키텍처 문서 (이 파일 포함)
```

---

## 10. 현재 서비스 상태

{{LAUNCHD_TABLE}}

> 마지막 확인: {{GEN_AT}}

---

## 11. 최근 변경

{{RECENT_GIT}}

---

*🤖 Generated by [`scripts/gen-system-overview.sh`](../scripts/gen-system-overview.sh) |
[Documentation Index](INDEX.md) | [ADR Index](../adr/ADR-INDEX.md)*
"""

# 플레이스홀더 치환
doc = doc.replace('{{GEN_AT}}',        e('GEN_AT'))
doc = doc.replace('{{GIT_HASH}}',      e('GIT_HASH'))
doc = doc.replace('{{GIT_BRANCH}}',    e('GIT_BRANCH'))
doc = doc.replace('{{TASK_TABLE}}',    e('TASK_TABLE'))
doc = doc.replace('{{NEXUS_TABLE}}',   e('NEXUS_TABLE'))
doc = doc.replace('{{FILE_TABLE}}',    e('FILE_TABLE'))
doc = doc.replace('{{LAUNCHD_TABLE}}', e('LAUNCHD_TABLE'))
doc = doc.replace('{{RECENT_GIT}}',    e('RECENT_GIT'))

print(doc, end='')
PYEOF

log "완료 → $OUTPUT ($(wc -l < "$OUTPUT")줄)"
echo "✅ SYSTEM-OVERVIEW.md 생성: $(wc -l < "$OUTPUT")줄"
