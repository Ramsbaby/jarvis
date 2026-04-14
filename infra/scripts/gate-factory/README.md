# Gate Factory — 해시 캐시 게이트 재사용 패턴

**목적**: LLM 호출 전 입력 해시 비교로 동일 결과 재생성을 스킵하는 **재사용 가능한 패턴**.

첫 구현체인 `infra/scripts/github-monitor-gate.sh` 가 이 패턴의 기준 레퍼런스다.
주간 감사(`token-ledger-audit.sh`)가 `gate-candidates.json` 큐에 dedup 후보를 자동 수집하며,
오너는 월 1회 배치 리뷰로 새 게이트를 작성할지 결정한다.

---

## 언제 게이트를 만드는가

한 태스크가 아래 3가지를 **모두 만족**할 때 적용 대상:

1. **프롬프트가 외부 데이터를 요약/포맷하는 경우** (순수 reasoning이 아닌)
2. **외부 데이터 자체가 N시간 이상 변하지 않는 경우** (fetch 가능)
3. **주간 감사가 `dedup_candidates` 리스트에 N회 이상 올린 경우** (`token-ledger-audit.sh` 출력)

> **금지**: 매번 다른 결과가 필요한 태스크 (news-briefing 등)에 게이트 적용 금지 — 오히려 품질 저하.

---

## 게이트 3-step 구조

모든 게이트 스크립트는 아래 구조를 따른다 (github-monitor-gate.sh 기준):

### Step 1: 입력 fetch
외부 데이터 소스를 직접 호출한다 (gh api, curl, bash script 등).
LLM 없이 순수 데이터만 가져옴.

```bash
notifications=""
if command -v gh >/dev/null 2>&1; then
    if notifications=$(gh api notifications --jq '.[] | .subject.title' 2>/dev/null); then
        :
    else
        notifications=""
    fi
fi
```

### Step 2: 해시 비교 + 캐시 hit 결정
이전 해시와 비교해 동일하면 LLM 호출 skip.

```bash
current_hash=$(printf '%s' "$notifications" | shasum -a 256 | cut -c1-16)
prev_hash=""
if [[ -f "$HASH_FILE" ]]; then
    prev_hash=$(cat "$HASH_FILE" 2>/dev/null || echo "")
fi

if [[ -n "$prev_hash" && "$current_hash" == "$prev_hash" && -s "$CACHE_RESULT_FILE" ]]; then
    # Cache hit: 캐시된 결과 재사용
    cat "$CACHE_RESULT_FILE"
    # Ledger에 cache_hit 기록 (cost=0)
    exit 0
fi
```

### Step 3: Cache miss → ask-claude.sh 위임
해시가 다르면 새 해시 저장 + LLM 호출. **데이터는 프롬프트에 embed**해서
LLM이 Bash tool 없이도 포맷할 수 있게 한다 (Read tool만 허용).

```bash
printf '%s' "$current_hash" > "$HASH_FILE"
prompt="데이터: $notifications\n\n요약하라."
result=$(bash "$ASK_CLAUDE" "$TASK_ID" "$prompt" "Read" 60 "$max_budget")
printf '%s' "$result" > "$CACHE_RESULT_FILE"
printf '%s' "$result"
```

---

## 새 게이트 작성 체크리스트

1. `infra/scripts/<task-id>-gate.sh` 신규 작성 (github-monitor-gate.sh 복사 후 수정)
2. `#!/usr/bin/env bash` + `set -euo pipefail` 필수
3. 안티패턴 금지: `[[ cond ]] && cmd` → `if [[ cond ]]; then cmd; fi`
4. Step 1 fetch 실패 시 empty string으로 graceful fallback
5. Step 2에서 cache hit 시 ledger에 `model="cache", status="cache_hit", cost_usd=0` 기록
6. Step 3에서 ask-claude.sh 경로 탐색 (BOT_HOME → repo fallback)
7. `~/.jarvis/config/tasks.json` 해당 태스크에 `script: ~/jarvis/infra/scripts/<task>-gate.sh` 필드 추가
8. `allowedTools` 제거 (script 모드에서는 미사용)
9. `plugin-loader.sh` 실행하여 `effective-tasks.json` 재생성
10. 수동 테스트: 첫 실행(cache miss) → 두 번째 실행(cache hit) 검증

---

## 상태 파일 위치 (정규화)

각 게이트는 아래 경로를 사용한다 (충돌 방지):

| 파일 | 용도 |
|---|---|
| `~/.jarvis/state/<task-id>-last.hash` | 마지막 입력 해시 |
| `~/.jarvis/state/<task-id>-last-result.md` | 마지막 포맷 결과 (cache hit 시 재사용) |
| `~/.jarvis/results/<task-id>/` | bot-cron.sh가 관리하는 result 디렉토리 (retention 적용) |

---

## 관련 구조

- **SSoT 원장**: `~/.jarvis/state/token-ledger.jsonl` (모든 게이트 cache_hit 기록)
- **주간 감사**: `infra/scripts/token-ledger-audit.sh` — 큐에 후보 자동 수집
- **후보 큐**: `~/.jarvis/state/gate-candidates.json` (아래 참조)
- **Tier 로드맵**: `infra/docs/OPERATIONS.md` Token Ledger 섹션

---

## 후보 큐 (gate-candidates.json)

주간 감사가 `result_hash` 5회+ 반복되는 태스크를 자동으로 이 큐에 append한다.
오너는 월 1회 리뷰하고, 실제 게이트 스크립트를 작성할지 결정한다.

**스키마**:
```json
{
  "candidates": [
    {
      "detected_at": "2026-04-14T00:00:00Z",
      "task": "some-task-id",
      "result_hash": "abc123def456",
      "repeat_count": 12,
      "model": "claude-haiku-4-5-20251001",
      "status": "pending|implemented|rejected",
      "notes": ""
    }
  ],
  "last_audit_run": "2026-04-14T00:00:00Z"
}
```

**상태 값**:
- `pending`: 신규 감지, 오너 리뷰 대기
- `implemented`: 게이트 스크립트 작성 완료
- `rejected`: 오너가 게이트 부적합 판정 (notes에 사유)

---

## 금지 사항

- ❌ 자동 게이트 생성 금지 (안전성 검증 불가)
- ❌ 모든 dedup 후보를 자동으로 구현 금지 (품질 저하 위험)
- ❌ 게이트가 외부 데이터 fetch 실패 시 "가짜 결과"를 만들어내는 fallback 금지

---

## 성공 기준

- 게이트 적용 후 해당 태스크의 `token-ledger.jsonl` 에서 `status=cache_hit` 비율이 80% 이상
- 주간 감사 리포트의 "캐시 효율" 섹션에서 `hit_rate` 추적 가능
- 오너가 수동 재실행 없이 원본 결과와 동일한 품질을 보장받음
