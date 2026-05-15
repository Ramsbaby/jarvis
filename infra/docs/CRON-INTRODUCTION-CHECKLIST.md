# 📋 신규 Cron 도입 체크리스트

> 자비스에 새 자동화(cron / LaunchAgent) 추가 전 의무 검토.
> Over-engineering 방지 + DRYRUN 일관 적용 + 사람 게이트.

---

## 1️⃣ 도입 전 자문 (3개 모두 통과)

- [ ] **Why**: 이 cron이 막아주는 사고 / 만들어내는 가치를 1줄로 표현 가능한가?
- [ ] **Existing**: 기존 cron이나 사전 문서로 해결 안 되는가? (DRY 위반?)
- [ ] **Frequency**: 빈도가 정말 자주여야 하나? (매시간 → 매일 → 매주 다운그레이드 검토)

3개 중 하나라도 NO → 도입 보류.

## 2️⃣ 작성 시 의무

- [ ] `~/jarvis/infra/scripts/SCRIPT-SKELETON.sh` template 사용
- [ ] `set -uo pipefail` 또는 `set -euo pipefail`
- [ ] `DRYRUN` 환경변수 default 1 (실제 액션은 production 활성화 후)
- [ ] `discord-route.sh` source 사용 (severity 분류 — `critical` / `info` / `retro`)
- [ ] ledger 작성 (`runtime/state/{NAME}-ledger.jsonl`)
- [ ] log 작성 (`runtime/logs/{NAME}.log`)

## 3️⃣ LaunchAgent 의무

- [ ] plist `Label = ai.jarvis.{NAME}`
- [ ] `StandardOutPath` + `StandardErrorPath` 명시
- [ ] `EnvironmentVariables.PATH` 명시 (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`)
- [ ] 시간 충돌 회피 (5분 시차 확인 — `LAUNCHAGENT-CATALOG.md` 검토)
- [ ] `RunAtLoad: false` (calendar 기반만)

## 4️⃣ 검증 의무 (단계별)

- [ ] 1) `chmod +x` 권한 부여
- [ ] 2) `launchctl unload` → `launchctl load -w` 순서로 등록
- [ ] 3) `plutil -lint` OK 확인
- [ ] 4) `launchctl list | grep` exit=0 확인
- [ ] 5) `launchctl print` schedule 정확성 확인
- [ ] 6) **즉시 1회 수동 실행** + 결과 ledger 인용
- [ ] 7) DRYRUN 모드 ledger 확인 (`{NAME}-ledger.jsonl` 마지막 줄)

## 5️⃣ 문서 갱신

- [ ] `LAUNCHAGENT-CATALOG.md` 자동 재생성 (`bash ~/jarvis/infra/scripts/gen-launchagent-catalog.mjs` 또는 다음 cron 자동)
- [ ] `JARVIS-RUNBOOK.md` 영향 시 갱신

## 6️⃣ Production 활성화 (1주 시뮬 후)

- [ ] 7일간 DRYRUN ledger 분석 (가짜 양성 < 10%, 에러 = 0)
- [ ] `skill-dryrun-auto-activate` 패턴 모방하여 자동 또는 수동 활성화
- [ ] 활성화 후 첫 24시간 모니터링

---

## 🚫 도입 거부 신호

다음 중 하나라도 해당하면 **도입 거부**:

- 기존 cron / 사전 문서로 같은 가치 가능
- "혹시 모르니까" 빈도 (필요 없는데 매시간)
- DRYRUN 가드 없는 즉시 production
- 알림 채널 미명시 (default `jarvis-system` 폭격)
- ledger / log 없음 (사후 추적 불가)
- 사람 검토 없는 자동 머지 / 자동 push

---

## 🔄 기존 cron의 discord-route 마이그 절차 (B5 fix · 2026-05-08)

신규 cron은 의무, **기존 19개 cron은 점진적**:

### 마이그 패턴
```bash
# Before
node ~/.jarvis/scripts/discord-visual.mjs --type stats --data "$PAYLOAD" --channel jarvis-system

# After
source ~/jarvis/infra/lib/discord-route.sh
discord_route info "title" "key=val,key2=val2"   # 일반 알림
discord_route critical "title" "key=val"         # 즉시 대응
discord_route retro "title" "key=val"            # 자가 회고
```

### 마이그 우선순위
1. **신규 cron**: 처음부터 `discord-route` 사용 (의무)
2. **기존 weekly audit**: meta-audit 다음 sprint에 마이그 (`audit-dashboard`, `model-version-audit` 등)
3. **기존 daily cron**: 가치 검증 후 점진 (`personal-snapshot`, `external-detect` 등)
4. **외부 다운 알림 (resilience-guard)**: critical 엄격 — 우선순위 1

### Severity 매핑 가이드

| Severity | 채널 (현재 → 향후) | 사용 케이스 |
|---|---|---|
| `critical` | jarvis-system → jarvis-critical | 외부 다운, AUTH_ERROR 다발, cap 초과, supervisor critical |
| `info` | jarvis-system → jarvis-info | 주간 audit 카드, 사전 갱신, 일상 스냅샷 |
| `retro` | jarvis-system → jarvis-retro | 자가 회고, 반복 패턴 감지, dead skill archive |

새 채널 신설 시 `discord-route.sh` 본문 수정 → 모든 cron 자동 분산.

---

## 📚 참조

- 작성 template: `~/jarvis/infra/scripts/SCRIPT-SKELETON.sh`
- 채널 라우팅: `~/jarvis/infra/lib/discord-route.sh`
- 운영 가이드: `~/jarvis/infra/docs/JARVIS-RUNBOOK.md`
- LaunchAgent 카탈로그: `~/jarvis/infra/docs/LAUNCHAGENT-CATALOG.md`
- SSoT 예외 카테고리: `~/jarvis/infra/docs/CRON-ORCHESTRATION-SSOT.md` Section 0
- 사고 사례: `~/jarvis/runtime/wiki/meta/learned-mistakes.md`
