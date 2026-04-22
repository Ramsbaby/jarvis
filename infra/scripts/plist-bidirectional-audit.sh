#!/usr/bin/env bash
# plist-bidirectional-audit.sh — tasks.json ↔ LaunchAgents plist 양방향 감사 (4층 방어막)
#
# Why: 기존 감시는 plist 편집 이벤트 기반 → 장부(tasks.json) 자체와의
#      불일치는 잡히지 않음. 주간 1회 양방향 교차 대조로 3가지 상태 적발:
#
#   1. orphan_plist     — plist 는 있으나 tasks.json 에 엔트리 없음 (고아)
#   2. missing_plist    — tasks.json enabled:true 인데 plist 없음 (누락)
#   3. spec_mismatch    — 양쪽 존재하나 ProgramArguments 불일치 (스펙 어긋남)
#
# 2026-04-22 BYPASS 사건: tasks.json 상 output:discord 인데 plist ProgramArguments 가
# bot-cron.sh 우회 → 이 케이스가 spec_mismatch 로 분류되어 주간 주기 안에 반드시 적발.
#
# 실행: 주 1회 (tasks.json 에 schedule: "0 5 * * 0" 로 등록 예정)
# 출력: ~/jarvis/runtime/ledger/plist-bidirectional-audit.jsonl + Discord 리포트

# -u 제거: bash 3.2 + 빈 배열 `${ARR[@]}` 참조가 unbound 로 실패하는 버그 회피.
# 이 스크립트는 변수 초기화가 모두 명시적이므로 -u 없어도 안전.
set -eo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LA_DIR="${HOME}/Library/LaunchAgents"
LEDGER_DIR="${BOT_HOME}/ledger"
LEDGER="${LEDGER_DIR}/plist-bidirectional-audit.jsonl"
EFF_TASKS="${BOT_HOME}/config/effective-tasks.json"
TASKS_FILE="${BOT_HOME}/config/tasks.json"
MONITORING="${BOT_HOME}/config/monitoring.json"

mkdir -p "$LEDGER_DIR"

TS=$(TZ=Asia/Seoul date +"%Y-%m-%dT%H:%M:%S%z")

[[ -f "$EFF_TASKS" ]] || EFF_TASKS="$TASKS_FILE"
if [[ ! -f "$EFF_TASKS" ]]; then
  echo "[audit4] FATAL: tasks file 없음: $EFF_TASKS" >&2
  exit 1
fi

log_ledger() {
  local action="$1" task="$2" detail="$3"
  printf '{"ts":"%s","action":"%s","task":"%s","detail":%s}\n' \
    "$TS" "$action" "$task" "$detail" >> "$LEDGER"
}

# ── 1) tasks.json 에서 enabled + 스케줄 있는 태스크 목록 추출 ──
# enabled != false && schedule != "(manual)" && schedule 존재
# bash 3.2 호환: readarray 대신 while read
ENABLED_TASKS=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  ENABLED_TASKS+=("$line")
done < <(
  jq -r '.tasks[]?
    | select((.enabled // true) != false)
    | select((.schedule // .cron // "") as $s
             | $s != "" and $s != "(manual)")
    | .id' "$EFF_TASKS" 2>/dev/null
)

# ── 2) LaunchAgents 디렉토리의 com.jarvis.*.plist 목록 ──
PRESENT_PLISTS=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  PRESENT_PLISTS+=("$line")
done < <(
  ls -1 "$LA_DIR"/com.jarvis.*.plist 2>/dev/null \
    | xargs -n1 basename \
    | sed 's/^com\.jarvis\.//;s/\.plist$//' \
    | sort
)

# ── 3) 분류 ──
declare -a ORPHANS MISSING MISMATCH
ORPHANS=()
MISSING=()
MISMATCH=()

# tasks 를 연관배열 대용으로 임시 파일에 dump
TASKS_SET=$(mktemp /tmp/audit4-tasks-XXXXXX)
printf '%s\n' "${ENABLED_TASKS[@]}" | sort -u > "$TASKS_SET"

PLISTS_SET=$(mktemp /tmp/audit4-plists-XXXXXX)
printf '%s\n' "${PRESENT_PLISTS[@]}" | sort -u > "$PLISTS_SET"

trap 'rm -f "$TASKS_SET" "$PLISTS_SET"' EXIT

# orphan = plist 有 + tasks 無
while IFS= read -r tid; do
  [[ -z "$tid" ]] && continue
  ORPHANS+=("$tid")
done < <(comm -23 "$PLISTS_SET" "$TASKS_SET")

# missing = tasks 有 + plist 無
while IFS= read -r tid; do
  [[ -z "$tid" ]] && continue
  MISSING+=("$tid")
done < <(comm -13 "$PLISTS_SET" "$TASKS_SET")

# spec_mismatch = 양쪽 有 인데 ProgramArguments 가 어긋남
# 현재 검증: output:discord 인데 ProgramArguments 에 bot-cron.sh 없음 (2026-04-22 BYPASS 케이스)
#
# 최적화: jq 를 태스크마다 호출하면 60회 * ~300ms = 18s. 한 번에 output:discord id
# 목록만 뽑아 set 파일에 저장하고 grep 으로 O(1) 조회.
DISCORD_TASKS_SET=$(mktemp /tmp/audit4-discord-XXXXXX)
jq -r '.tasks[]?
  | select((.output // []) as $out
           | ($out | map(tostring) | map(select(contains("discord"))) | length) > 0)
  | .id' "$EFF_TASKS" 2>/dev/null | sort -u > "$DISCORD_TASKS_SET"

# 기존 trap 에 이 파일도 포함되게 trap 재설정
trap 'rm -f "$TASKS_SET" "$PLISTS_SET" "$DISCORD_TASKS_SET"' EXIT

while IFS= read -r tid; do
  [[ -z "$tid" ]] && continue
  plist_path="$LA_DIR/com.jarvis.${tid}.plist"
  [[ -f "$plist_path" ]] || continue

  # output 에 "discord" 포함 태스크인지 O(1) grep
  grep -qx "$tid" "$DISCORD_TASKS_SET" || continue

  if ! grep -q 'bot-cron\.sh' "$plist_path" 2>/dev/null; then
    MISMATCH+=("$tid")
  fi
done < <(comm -12 "$PLISTS_SET" "$TASKS_SET")

# ── 4) ledger 기록 ──
for tid in "${ORPHANS[@]}"; do
  log_ledger "orphan_plist" "$tid" "{\"plist\":\"com.jarvis.${tid}.plist\",\"suggest\":\"unload+remove_or_register\"}"
done
for tid in "${MISSING[@]}"; do
  log_ledger "missing_plist" "$tid" "{\"suggest\":\"run_cron_sync\"}"
done
for tid in "${MISMATCH[@]}"; do
  log_ledger "spec_mismatch" "$tid" "{\"reason\":\"discord_task_bypasses_bot_cron\",\"suggest\":\"plist-bypass-autofix\"}"
done

# 요약 기록
SUMMARY_JSON=$(printf '{"orphans":%d,"missing":%d,"mismatch":%d,"tasks_total":%d,"plists_total":%d}' \
  "${#ORPHANS[@]}" "${#MISSING[@]}" "${#MISMATCH[@]}" \
  "${#ENABLED_TASKS[@]}" "${#PRESENT_PLISTS[@]}")
printf '{"ts":"%s","action":"summary","detail":%s}\n' "$TS" "$SUMMARY_JSON" >> "$LEDGER"

# ── 5) Discord 리포트 ──
# stdout 은 bot-cron.sh route-result.sh 경유 시 자동 Discord 전송됨.
# 스크립트 자체 curl 호출 없이 stdout 만 출력.

total_issues=$(( ${#ORPHANS[@]} + ${#MISSING[@]} + ${#MISMATCH[@]} ))

if [[ "$total_issues" -eq 0 ]]; then
  cat <<EOF
> 🛡 **plist 양방향 감사 · $(TZ=Asia/Seoul date +"%m/%d %H:%M KST")**

### ✅ 정합성 OK

- 📋 태스크 ${#ENABLED_TASKS[@]}개 ↔ plist ${#PRESENT_PLISTS[@]}개
- 🟢 고아 plist 0건 · 누락 plist 0건 · 스펙 불일치 0건

-# 다음 실행: 다음 주 일요일 05:00 KST
EOF
  exit 0
fi

# 이슈 있음 — 상세 리포트
{
  echo "> 🛡 **plist 양방향 감사 · $(TZ=Asia/Seoul date +"%m/%d %H:%M KST")**"
  echo ""
  echo "### ⚠️ 정합성 이슈 ${total_issues}건"
  echo ""
  echo "- 📋 태스크 ${#ENABLED_TASKS[@]}개 ↔ plist ${#PRESENT_PLISTS[@]}개"
  echo ""

  if [[ "${#ORPHANS[@]}" -gt 0 ]]; then
    echo "### 🔸 고아 plist ${#ORPHANS[@]}건 (tasks.json 엔트리 없음)"
    for t in "${ORPHANS[@]}"; do echo "- \`com.jarvis.${t}.plist\` → unload + 삭제 권고"; done
    echo ""
  fi

  if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "### 🔸 누락 plist ${#MISSING[@]}건 (enabled:true 인데 파일 없음)"
    for t in "${MISSING[@]}"; do echo "- \`${t}\` → cron-sync.sh 재실행 필요"; done
    echo ""
  fi

  if [[ "${#MISMATCH[@]}" -gt 0 ]]; then
    echo "### 🚨 스펙 불일치 ${#MISMATCH[@]}건 (output:discord 인데 bot-cron.sh 미경유)"
    for t in "${MISMATCH[@]}"; do echo "- \`${t}\` → plist-bypass-autofix 복구 대기"; done
    echo ""
  fi

  echo "-# ledger: \`~/jarvis/runtime/ledger/plist-bidirectional-audit.jsonl\` · 다음 실행: 다음 주 일요일 05:00 KST"
}

# ledger 의 summary 항목을 참조하면 cron-master 등에서 최근 주간 결과 picking 가능
