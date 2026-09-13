#!/usr/bin/env bash
# self-heal-2bc-apply.sh — SELF-HEAL-PLAN 2b(이중 스케줄 제거)·2c(죽은 층 비활성) 적용기
#
# 왜 스크립트인가: 크론 삭제·plist 해제는 자동 모드 분류기가 막는 영역이라 주인님이 직접 실행한다.
#   그래서 "무엇을·왜·어떻게 되돌리나"를 한 파일에 고정하고, 기본은 --dry-run 으로 변경 예정만 보인다.
#
# 사용법:
#   bash infra/scripts/self-heal-2bc-apply.sh            # dry-run: 변경 예정 목록만 출력
#   bash infra/scripts/self-heal-2bc-apply.sh --apply    # 실제 적용 (백업 → 적용 → 검증)
#
# 되돌리기 (백업 위치는 실행 시 출력):
#   crontab  ~/backup/jarvis-topology/crontab-<ts>.txt
#   tasks.json  ~/backup/jarvis-topology/tasks-json/tasks.json.pre-2bc-<ts>
#   plist    ~/backup/jarvis-topology/plists-2bc-<ts>/*.plist  → cp 후 launchctl bootstrap gui/$(id -u) <plist>
#
# 근거 (2026-09-04 실측, 각 항목의 evidence 는 아래 배열 주석):
#   - tasks.json 을 스케줄링하는 별도 실행기는 없다. cron-sync.sh(15 * * * *) 가 enabled 태스크마다
#     com.jarvis.<id>.plist 를 만들고 그 plist 가 bot-cron.sh <id> 를 부른다. 따라서 tasks.json 태스크가
#     crontab 에도 있으면 그것이 이중 실행이다 (validate-tasks.mjs SSoT 경고 7건과 같은 기준).
set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

JARVIS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOT_HOME="${BOT_HOME:-${JARVIS_ROOT}/runtime}"
TASKS_FILE="${BOT_HOME}/config/tasks.json"
LA_DIR="${HOME}/Library/LaunchAgents"
BACKUP_ROOT="${HOME}/backup/jarvis-topology"
TS="$(date +%Y%m%d-%H%M%S)"
MODE="${1:---dry-run}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

[[ "$MODE" == "--dry-run" || "$MODE" == "--apply" ]] || die "인자는 --dry-run(기본) 또는 --apply"
[[ -f "$TASKS_FILE" ]] || die "tasks.json 없음: $TASKS_FILE"
command -v jq >/dev/null || die "jq 필요"

# ── 1. crontab 에서 제거할 줄 (패턴은 한 줄에만 맞아야 한다 — 적용 전 개수를 검증) ──────────
#   news-briefing        : com.jarvis.news-briefing plist(06:00, bot-cron) 로드 중. 9/4 06:00 cron.log 에
#                          "SKIPPED — already running (lock dir exists)" — 둘이 동시에 뜬 흔적.
#   cost-cap-audit       : plist 05:55(bot-cron) + crontab 06:03(직접) → 하루 2회.
#   cron-master-smoke    : plist 월 09:15(bot-cron) + crontab 월 09:15(직접) → 같은 시각 2회.
#   disk-alert           : plist 매시 :10(직접 스크립트, 2026-05-19 산) + crontab 매시 :10(bot-cron) → 2회.
#   update-claude-md-meta: tasks.json/plist 는 infra/scripts 판(월 05:05), crontab 은 jarvis/scripts 판(일 03:40)
#                          — 같은 일을 하는 구현 2개. tasks.json 판이 정본.
#   cron-completion-hook : 2c 로 비활성(아래). crontab */15 + @reboot monitor(무한 sleep 데몬) 둘 다 제거.
#   monitoring-pre-check : crontab 단독 실행(04:55) → tasks.json schedule 로 이관(아래 jq). cron-sync 가
#                          다음 :15 에 plist 를 만든다. 04:55 까지 5시간 이상 여유.
CRON_PATTERNS=(
  'bot-cron.sh news-briefing'
  '/infra/bin/cost-cap-audit.sh'
  '/.jarvis/bin/cron-master-smoke.sh'
  'bot-cron.sh disk-alert'
  '/jarvis/scripts/update-claude-md-meta.sh'
  'bot-cron.sh cron-completion-hook'
  'cron-completion-hook.sh monitor'
  '/monitoring-pre-check.sh'
)

# ── 2. bootout 할 plist ───────────────────────────────────────────────────────────────
#   com.jarvis.cron-completion-hook : /Users/ramsbaby/orca/workspaces/jarvis/main 의 7/27 사본을 직접 실행
#                                     (본체 아님). 태스크 자체를 2c 로 비활성.
#   com.jarvis.skill-loop-nightly   : 2c 비활성 태스크. bot-cron 이 SKIPPED 처리하지만 plist 도 내린다.
#   com.jarvis.skill-synthesis-verify: 위와 동일.
#   com.jarvis.mistake-promoter     : 9/4 13:15 코더 세션이 승인 없이 만든 plist(tasks.json 미등재).
#                                     실제 실행기는 crontab 04:10 줄이며 그것은 유지.
#   com.jarvis.disk-alert           : 2026-05-19 산, bot-cron 을 거치지 않아 tasks.db 에 기록이 없다(감사 db:none).
#                                     내리면 cron-sync 가 다음 :15 에 bot-cron 경유 plist 로 재생성한다.
BOOTOUT_LABELS=(
  com.jarvis.cron-completion-hook
  com.jarvis.skill-loop-nightly
  com.jarvis.skill-synthesis-verify
  com.jarvis.mistake-promoter
  com.jarvis.disk-alert
)

# ── 3. tasks.json 변경 (jq) ───────────────────────────────────────────────────────────
JQ_PROGRAM='
  (.tasks[] | select(.id=="cron-completion-hook")) |= (. + {
    "enabled": false,
    "_disabled_reason": "2026-09-04 (SELF-HEAL-PLAN 2c): 죽은 층. 인자 없이 15분마다 돌며 task=unknown 메트릭만 쌓았고(state/cron-metrics/, 소비자 0 — bot-cron·auditor 어디서도 호출하지 않음), crontab(*/15 + @reboot monitor)과 plist(orca 워크스페이스 사본)까지 하루 192회 이중 실행. 7/22~9/4 stale-watcher 오탐 1위(37건/일). 되살리려면 bot-cron 완료 지점에서 <task> <ms> <exit> 인자로 호출하도록 배선부터."
  }) |
  (.tasks[] | select(.id=="skill-loop-nightly")) |= (. + {
    "enabled": false,
    "_disabled_reason": "2026-09-04 (SELF-HEAL-PLAN 2c): 7/19 이후 47일 연속 선별 0건(state/skill-drafts/selected-*.jsonl 0바이트 30개 연속). 점수 임계 7+ 를 넘는 세션이 없어 추출·카드 전부 생략되는데 매일 stats 카드만 송출. 재가동 조건: 임계 하향(6) 또는 세션 채점 기준 재설계 후 DRYRUN 1주."
  }) |
  (.tasks[] | select(.id=="skill-synthesis-verify")) |= (. + {
    "enabled": false,
    "_disabled_reason": "2026-09-04 (SELF-HEAL-PLAN 2c): skill-loop-nightly 산출(오늘 생성된 Skill)이 입력인데 그 산출이 47일째 0건이라 매일 \"오늘 Skill 없음 — 검증 생략\" 만 남김. skill-loop-nightly 재가동과 함께 되살린다."
  }) |
  (.tasks[] | select(.id=="monitoring-pre-check")) |= (. + {
    "schedule": "55 4 * * *",
    "_comment": ((._comment // "") + " | 2026-09-04: crontab(55 4 * * *) 단독 실행이던 것을 tasks.json 으로 이관(SSoT). 05:00 e2e-cron 직전 점검. launchd 라벨·PID grep 오탐 4건은 스크립트에서 수정.")
  }) |
  if any(.tasks[]; .id=="runaway-process-guard") then . else .tasks += [{
    "id": "runaway-process-guard",
    "name": "개별 프로세스 CPU 폭주 감지·재시작",
    "schedule": "*/30 * * * *",
    "timeout": 120,
    "script": "~/projects/jarvis/infra/scripts/runaway-process-guard.sh",
    "allowedTools": "Bash",
    "output": ["file"],
    "retry": {"max": 1, "backoff": "fixed"},
    "maxBudget": "0.00",
    "priority": "low",
    "depends": [],
    "resultRetention": 7,
    "resultMaxChars": 500,
    "allowEmptyResult": true,
    "addedAt": "2026-09-04",
    "note": "2026-07-27 부터 com.jarvis.runaway-process-guard.plist 단독으로 돌던 가드(avconferenced 17일 CPU 38% 사고 계기)를 tasks.json 에 등재 — 실행 방식은 그대로(plist 는 스크립트 직접 호출), 등재 목적은 SSoT 추적·감사 orphan 해소."
  }] end
'

# ── 사전 점검 ─────────────────────────────────────────────────────────────────────────
CRON_NOW="$(crontab -l 2>/dev/null || true)"
[[ -n "$CRON_NOW" ]] || die "crontab 이 비어 있다 — 예상과 다르므로 중단"

echo "══ 2b/2c 적용기 ($MODE) ══"
echo
echo "── crontab 제거 예정 (${#CRON_PATTERNS[@]}줄) ──"
CRON_NEW="$CRON_NOW"
for pat in "${CRON_PATTERNS[@]}"; do
  n=$(printf '%s\n' "$CRON_NOW" | grep -cF -- "$pat" || true)
  if [[ "$n" -ne 1 ]]; then
    die "패턴 '$pat' 이 crontab 에서 ${n}줄 매칭 — 정확히 1줄이어야 한다. 손으로 확인 후 재실행"
  fi
  printf '%s\n' "$CRON_NOW" | grep -F -- "$pat" | cut -c1-140 | sed 's/^/  - /'
  CRON_NEW="$(printf '%s\n' "$CRON_NEW" | grep -vF -- "$pat")"
done
echo
echo "── plist bootout 예정 (${#BOOTOUT_LABELS[@]}개) ──"
for l in "${BOOTOUT_LABELS[@]}"; do
  state="파일 없음"
  [[ -f "$LA_DIR/$l.plist" ]] && state="파일 있음"
  launchctl list 2>/dev/null | awk -F'\t' -v l="$l" '$3==l{found=1} END{exit !found}' && state="$state, 로드됨" || state="$state, 미로드"
  echo "  - $l ($state)"
done
echo
echo "── tasks.json 변경 예정 ──"
TASKS_NEW="$(jq --indent 2 "$JQ_PROGRAM" "$TASKS_FILE")"
diff <(jq -c '.tasks[] | {id, enabled, schedule}' "$TASKS_FILE") <(printf '%s\n' "$TASKS_NEW" | jq -c '.tasks[] | {id, enabled, schedule}') | grep '^[<>]' | sed 's/^/  /' || true
echo "  태스크 수: $(jq '.tasks|length' "$TASKS_FILE") → $(printf '%s\n' "$TASKS_NEW" | jq '.tasks|length')"
echo

if [[ "$MODE" == "--dry-run" ]]; then
  echo "dry-run — 아무것도 바꾸지 않았다. 적용: bash $0 --apply"
  exit 0
fi

# ── 적용 ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$BACKUP_ROOT/tasks-json" "$BACKUP_ROOT/plists-2bc-$TS"
printf '%s\n' "$CRON_NOW" > "$BACKUP_ROOT/crontab-$TS.txt"
cp -p "$TASKS_FILE" "$BACKUP_ROOT/tasks-json/tasks.json.pre-2bc-$TS"
log "백업: $BACKUP_ROOT/crontab-$TS.txt, $BACKUP_ROOT/tasks-json/tasks.json.pre-2bc-$TS"

# tasks.json — 임시 파일에 쓰고 검증 통과 후 원자 교체
TMP_TASKS="$(mktemp "${TMPDIR:-/tmp}/tasks.2bc.XXXXXX")"
trap 'rm -f "$TMP_TASKS"' EXIT
printf '%s\n' "$TASKS_NEW" > "$TMP_TASKS"
jq -e '.tasks|length>0' "$TMP_TASKS" >/dev/null || die "생성된 tasks.json 이 비정상 — 중단(원본 무변경)"
mv "$TMP_TASKS" "$TASKS_FILE"
log "tasks.json 갱신"
( cd "$JARVIS_ROOT" && node infra/scripts/gen-tasks-index.mjs >/dev/null 2>&1 ) && log "gen-tasks-index 재생성" || log "[WARN] gen-tasks-index 실패 — 수동: node infra/scripts/gen-tasks-index.mjs"

# crontab
printf '%s\n' "$CRON_NEW" | crontab - && log "crontab 설치 ($(printf '%s\n' "$CRON_NOW" | wc -l | tr -d ' ') → $(crontab -l | wc -l | tr -d ' ')줄)"

# @reboot 로 떠 있던 monitor 데몬 (while true; sleep 60) 종료
if pgrep -f 'cron-completion-hook.sh monitor' >/dev/null 2>&1; then
  pkill -f 'cron-completion-hook.sh monitor' && log "cron-completion-hook monitor 데몬 종료"
fi

# plist bootout + 백업 이동
for l in "${BOOTOUT_LABELS[@]}"; do
  p="$LA_DIR/$l.plist"
  launchctl bootout "gui/$(id -u)/$l" 2>/dev/null && log "bootout $l" || log "bootout $l — 이미 미로드"
  if [[ -f "$p" ]]; then
    mv "$p" "$BACKUP_ROOT/plists-2bc-$TS/" && log "plist 이동 $l → plists-2bc-$TS/"
  fi
done

# ── 사후 검증 ─────────────────────────────────────────────────────────────────────────
echo
echo "── 검증 ──"
( cd "$JARVIS_ROOT" && node infra/scripts/validate-tasks.mjs 2>&1 | grep -E 'SSoT|PASS|FAIL' | head -5 )
for l in "${BOOTOUT_LABELS[@]}"; do
  launchctl list 2>/dev/null | awk -F'\t' -v l="$l" '$3==l{found=1} END{exit !found}' && echo "  ✗ $l 아직 로드됨" || echo "  ✓ $l 해제"
done
echo "  crontab 잔여 매칭: $(crontab -l | grep -cE 'bot-cron.sh (news-briefing|disk-alert|cron-completion-hook)|cost-cap-audit.sh|cron-master-smoke.sh|jarvis/scripts/update-claude-md-meta.sh|monitoring-pre-check.sh|cron-completion-hook.sh monitor' || true) (0 이어야 함)"
echo "  다음 cron-sync(매시 :15)가 com.jarvis.monitoring-pre-check / com.jarvis.disk-alert 를 bot-cron 경유로 생성한다."
echo "  확인: ls ~/Library/LaunchAgents | grep -E 'monitoring-pre-check|disk-alert'"
