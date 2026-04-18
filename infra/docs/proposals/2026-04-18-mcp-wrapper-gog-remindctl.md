# Proposal: MCP Wrapper for `gog` + `remindctl` — **APPROVED (PoC)**

- **제안일**: 2026-04-18 (KST)
- **출처**: 뉴스 브리핑 인사이트 (2026-04-18 인계, 원 제안의 3번 항목 재검토)
- **결정**: ✅ Proceed (PoC 범위)
- **관련 문서**: `2026-04-18-routines-cold-standby-rejected.md`, `CLAUDE.md` → Surface Memory Boundary

---

## 1. 목표 (Why)

Jarvis 3표면(Claude Code CLI / Discord 봇 / Claude macOS 앱) 에서 **동일한 인터페이스로**
개인 생산성 CLI를 호출 가능하게 한다. 현재는 각 표면이 Bash 래퍼·프롬프트·AppleScript로
제각각 접근 → **SSoT 위반 + 표면별 동작 drift** 위험.

### 큰 틀 (Zoom-out)
- 현재 `~/.mcp.json`에 8개 MCP 서버 가동 (brave-search, github, jira, nexus,
  sequential-thinking, serena, serena-board, workgroup).
- Jarvis 개인 CLI (`gog`, `remindctl`) 는 MCP 미등록 → Bash 도구로만 호출 가능.
- macOS 앱은 Bash 도구 접근 제한 → 실질적으로 기능 단절.
- **MCP 래퍼로 통일** 시 표면 경계 원칙(CLAUDE.md Surface Memory Boundary) 과 정합.

---

## 2. 범위

### 2.1 포함 (In-Scope)

| CLI | MCP 서버 이름(안) | 노출 도구 (PoC) |
|---|---|---|
| `gog calendar` | `mcp__gog__*` | `calendar_list`, `calendar_add` |
| `gog tasks` | `mcp__gog__*` | `tasks_lists`, `tasks_list`, `tasks_add`, `tasks_done` |
| `remindctl` | `mcp__remindctl__*` | `lists`, `list`, `add`, `complete` |

**총 10개 도구** (PoC 1차 목표).

### 2.2 제외 (Out-of-Scope)

#### `memo` CLI — **영구 제외**
- 사유: upstream이 **2025-07-27 deprecated** (brew info memo 확인, "disabled" 상태).
- 대체 경로 검토:
  - Apple Notes AppleScript 직접 호출 → 유지보수 부담 큼, PoC 차원 과잉.
  - `shortcuts` CLI → macOS 단축어 기반 Notes 접근 가능, 후속 과제로 분리.
- 결정: 이번 PoC에서는 **Apple Notes 연동 제외**. 필요 시 별도 제안서로.

#### `gog` CLI 리스크 명시
- `/opt/homebrew/bin/gog` 는 Go v0.9.0 바이너리, **brew formula 아님** (개인 빌드).
- 업스트림 주체·버전 정책 불명 → MCP 래퍼가 **하위 호환 깨짐에 취약**.
- 완화책: 래퍼 내부에서 `gog --version` 체크 + 예상 버전 범위 assert → 드리프트 감지.

---

## 3. 구현 스펙

### 3.1 위치 및 언어
- 신규 경로: `~/jarvis/infra/mcp/gog-remindctl/` (단일 서버로 2 CLI 합침, 운영 단순화)
  - 대안: 2개 분리 서버 — 장점: 격리, 단점: `.mcp.json` 항목 2개 증가.
  - **PoC 권장: 단일 서버**. 분리 필요성이 실제로 발견되면 그때 쪼갠다.
- 언어: **TypeScript + `@modelcontextprotocol/sdk`** (Jarvis 생태계 기본).
- 실행: `node dist/server.js` 또는 `tsx src/server.ts`.

### 3.2 도구 스키마 (예시 2종)

```typescript
// gog_calendar_list
{
  name: "gog_calendar_list",
  description: "Google Calendar 일정 조회 (KST)",
  inputSchema: {
    from: { type: "string", description: "YYYY-MM-DD or 'today'" },
    to:   { type: "string", description: "YYYY-MM-DD or 'today'" },
    account: { type: "string", description: "Google account email (optional)" }
  }
}

// remindctl_add
{
  name: "remindctl_add",
  description: "Apple Reminders 항목 추가",
  inputSchema: {
    list: { type: "string", description: "목록명 (optional)" },
    title: { type: "string", description: "항목 제목" },
    due:   { type: "string", description: "YYYY-MM-DD HH:MM (optional)" }
  }
}
```

### 3.3 실행 흐름

```
Claude (any surface)
   │
   ▼
MCP call: gog_calendar_list({from:"today", to:"today"})
   │
   ▼
server.ts: spawn("gog", ["calendar", "list", "--from", "today", ...])
   │
   ▼
stdout 파싱 → JSON 변환 → MCP response
```

### 3.4 `~/.mcp.json` 추가

```json
{
  "mcpServers": {
    "gog-remindctl": {
      "command": "node",
      "args": ["/Users/ramsbaby/jarvis/infra/mcp/gog-remindctl/dist/server.js"],
      "env": {}
    }
  }
}
```

---

## 4. 테스트 계획

### 4.1 단계별 검증
| 단계 | 대상 | 성공 기준 |
|---|---|---|
| 1 | `gog_calendar_list` read-only | 오늘 일정을 JSON으로 반환 (Claude Code CLI) |
| 2 | `remindctl_lists` read-only | 목록 배열 반환 |
| 3 | `gog_tasks_add` write | 테스트 항목 1건 추가 → `gog tasks list` 로 확인 → 수동 삭제 |
| 4 | 디스코드 봇에서 호출 | 동일 도구 호출 시 동일 결과 (표면 동치성) |
| 5 | macOS 앱에서 호출 | ★ 핵심 가치 검증 — Bash 도구 없이 접근 성공 |

### 4.2 실패 시 롤백
- `.mcp.json` 에서 해당 블록 제거 → Claude Code 재시작 → 기존 상태 복귀.
- Bash 직접 호출 경로는 그대로 유지 (우회 가능).

---

## 5. 작업량 추정

| 항목 | 소요 |
|---|---|
| MCP 서버 골격 + package.json | 1h |
| `gog` 도구 4종 래핑 + 출력 파싱 | 2h |
| `remindctl` 도구 4종 래핑 | 1.5h |
| 테스트 (5단계) + 디버깅 | 2h |
| 문서화 (README, `.mcp.json` 가이드) | 0.5h |
| **합계** | **~7h (1 working day)** |

---

## 6. 재발 방지 구조 (Recurrence Guard)

- **버전 드리프트 감지**: 래퍼 기동 시 `gog --version` 확인 → 기대 버전 대역 이탈 시
  stderr 경고 + MCP 도구 호출 실패로 fail-fast.
- **실패 원장**: MCP 호출 실패를 `~/.jarvis/logs/mcp-gog-remindctl.jsonl` 에 append
  → 주간 감사(`weekly-report`)에 편입 검토.
- **표면 동치성 테스트**: `infra/tests/mcp-surface-parity.sh` 에 3표면 호출 결과
  diff 체크 크론 추가 (주 1회).

---

## 7. dev-queue 적재

### 적재 형식
```json
{
  "id": "mcp-wrapper-gog-remindctl-20260418",
  "type": "feature_poc",
  "title": "MCP 래퍼 PoC: gog + remindctl",
  "description": "proposals/2026-04-18-mcp-wrapper-gog-remindctl.md 참조",
  "severity": "normal",
  "created_at": "2026-04-18",
  "status": "queued",
  "metadata": {
    "estimated_hours": 7,
    "spec_doc": "infra/docs/proposals/2026-04-18-mcp-wrapper-gog-remindctl.md",
    "surfaces": ["claude-code-cli", "discord-bot", "macos-app"]
  }
}
```

### 적재 경로
- **현재 세션(worktree)**: 적재 금지 (worktree-isolation 원칙).
- **병합 후**: 메인 세션에서 `~/jarvis/runtime/state/dev-queue.json` 에 append
  (`jq '. += [{...}]'` 또는 헬퍼 스크립트).

---

## 8. 감사 메타

- 검토자: Claude Code (CLI 세션, worktree: `ecstatic-allen`)
- 관련 규칙: `CLAUDE.md` → Surface Memory Boundary, `integrations.md`
- 이 문서의 목적: PoC 착수 전 범위·리스크·재발 방지 구조를 확정하여 **실행 단계의 드리프트 차단**.
