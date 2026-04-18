# Proposal: Claude Routines Cold-Standby Migration — **REJECTED**

- **제안일**: 2026-04-18 (KST)
- **출처**: 뉴스 브리핑 인사이트 (2026-04-18 인계)
- **결정**: ❌ Drop (이전 보류)
- **재평가 조건**: 아래 "Re-evaluation Triggers" 섹션 참조

---

## 1. 원 제안 요약

> Claude Routines (클라우드 스케줄링) 로 Jarvis 크론 태스크 일부를 이전하여
> 로컬 launchd 복잡도 감소 + Mac Mini 의존도 분산.

## 2. 검토 결과

### 2.1 현황 팩트
| 항목 | 수치 |
|---|---|
| 전체 크론 태스크 | **94개** (`runtime/config/tasks.json`) |
| LaunchAgent 가동 수 | 28개 |
| 태스크 스키마 | `prompt` + `allowedTools` + `schedule` (이미 Claude Code SDK 구조) |
| 순수 WebSearch-only 후보 | **1개** (`news-briefing`, 06:00 매일) |
| WebSearch 포함 + 로컬 도구 병용 | 2개 (`morning-standup`, `macro-briefing`) |

### 2.2 Drop 근거

#### (a) Cold-standby 후보가 1개뿐 — ROI 부족
- Routines 미러 인프라 구축 비용(설정·인증·원장 확장·모니터링) vs 이전 대상 **단 1건** 보호.
- 인프라 단위당 커버리지가 너무 낮아 "선별 이전" 전략 자체가 의미 소실.

#### (b) Jarvis 크론의 구조적 특성이 "로컬 우선" 설계
- `morning-standup` 조차 `df -h`, `uptime`, `gog calendar list`, `gog tasks list` 등
  **로컬 프로세스 의존** 명령이 프롬프트 안에 박혀 있음.
- Claude Routines는 클라우드 실행 환경 → 로컬 Bash/AppleScript/개인 CLI 호출 불가.
- 즉 "이전 가능"과 "이전 후 동일 기능 보존"은 별개.

#### (c) 이중 관리 비용이 안정성 이득을 초과
- 현재 가드레일: `token-ledger-audit`, 영구 실패 분류기, 서킷브레이커, 주간 감사
  — 모두 **로컬 파일 JSONL 원장 기반**.
- Routines 미러 시 원장·감사 로직을 클라우드/로컬 양쪽에 복제해야 함 → SSoT 위반.
- Mac Mini 다운타임은 **실제 incident로 올라온 적 없음** (최근 1개월 기준).

### 2.3 하지 않기로 한 것 (명시)
- ❌ Routines 계정·워크스페이스 생성
- ❌ `tasks.json` → Routines 포맷 변환기 작성
- ❌ 이중 실행 감지기 구축 (동일 크론이 로컬/클라우드 양쪽 발화 방지)

---

## 3. Re-evaluation Triggers (재평가 조건)

다음 중 **하나라도** 발생 시 본 제안 재검토:

1. **Claude Routines가 로컬 Bash/Read 원격 실행을 지원**하게 되면
   (→ Jarvis 로컬 도구 전부 그대로 호출 가능 → 이전 장벽 소멸).
2. **Mac Mini 장기 다운타임 incident** 발생 시 (연간 2회 이상 또는 24h+ 중단).
3. `tasks.json` 내 **순수 WebSearch/API-only 태스크가 5개 이상**으로 증가 시.
4. Anthropic이 Routines를 **Claude Code SDK와 완전 호환 형태**로 릴리스 시
   (현재 `tasks.json` 스키마 그대로 업로드 가능 수준).

---

## 4. 감사 메타

- 검토자: Claude Code (CLI 세션, worktree: `ecstatic-allen`)
- 검토 소요: 약 15분 (tasks.json 스키마 조사 + allowedTools 필터링)
- 관련 규칙: `CLAUDE.md` → "땜질식 대처 & 습관적 사과 금지", Surface Memory Boundary
- 이 문서의 목적: 재평가 조건이 트리거될 때 **검토 근거·수치·판단 재활용**을 위한 SSoT.
