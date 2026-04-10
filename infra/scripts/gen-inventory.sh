#!/usr/bin/env bash
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/.local/share/jarvis}}/lib/compat.sh" 2>/dev/null || true
set -euo pipefail

# ============================================================
# gen-inventory.sh — Generated Inventory 시스템
# "거짓말할 수 없는 문서" 자동 생성
#
# 출력:
#   ${VAULT_DIR:-$HOME/vault}/01-system/cron-catalog.md
#   ${VAULT_DIR:-$HOME/vault}/01-system/launchd-manifest.md
#   ${VAULT_DIR:-$HOME/vault}/01-system/webhook-registry.md
#
# crontab 등록: 30 4 * * * ~/.jarvis/scripts/gen-inventory.sh >> ~/.jarvis/logs/gen-inventory.log 2>&1
# ============================================================

TASKS_JSON="$HOME/.jarvis/config/tasks.json"
MONITORING_JSON="$HOME/.jarvis/config/monitoring.json"
OUT_DIR="${VAULT_DIR:-$HOME/vault}/01-system"
TODAY="$(date +%Y-%m-%d)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
GENERATED=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ----------------------------------------------------------
# 사전 검사
# ----------------------------------------------------------
if ! command -v jq &>/dev/null; then
  log "ERROR: jq 미설치. brew install jq 실행 후 재시도."
  exit 1
fi

mkdir -p "$OUT_DIR"

# ==========================================================
# 1. cron-catalog.md
# ==========================================================
generate_cron_catalog() {
  local outfile="$OUT_DIR/cron-catalog.md"
  log "Generating cron-catalog.md ..."

  # --- tasks.json 파싱 ---
  local task_count
  task_count="$(jq '[.tasks[] | select(.schedule != null and .schedule != "")] | length' "$TASKS_JSON")"

  local task_table=""
  task_table="$(jq -r '
    .tasks[] |
    [
      .id,
      .name,
      (.schedule // "manual"),
      (.model // "default"),
      ((.depends // []) | join(", ") | if . == "" then "-" else . end),
      ((.output // []) | join(", ")),
      (.maxBudget // "-")
    ] | "| " + join(" | ") + " |"
  ' "$TASKS_JSON")"

  # --- crontab 직접 등록 (bot-cron.sh 경유가 아닌 것들) ---
  local cron_lines=""
  local cron_count=0
  while IFS= read -r line; do
    # 빈 줄, 주석, bot-cron.sh 경유 라인 제외
    if [[ -z "$line" ]] || [[ "$line" == \#* ]]; then
      continue
    fi
    if [[ "$line" == *"bot-cron.sh"* ]]; then
      continue
    fi
    # 크론 필드 5개 + 명령어 분리
    local sched cmd
    sched="$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')"
    cmd="$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')"
    # 명령어 요약: >> 이후 제거, 경로에서 스크립트 파일명 추출
    local cmd_short
    cmd_short="$(echo "$cmd" | sed 's| >>.*||; s| 2>&1||')"
    # /bin/bash /path/to/script.sh → script.sh
    cmd_short="$(echo "$cmd_short" | sed 's|.*/bin/bash ||; s|.*/usr/local/bin/node ||; s|.*/||')"
    cron_lines="${cron_lines}| ${sched} | ${cmd_short} |
"
    cron_count=$((cron_count + 1))
  done < <(crontab -l 2>/dev/null)

  cat > "$outfile" <<EOF
---
title: "Cron Catalog (Auto-Generated)"
tags: [area/system, type/inventory, auto-generated]
created: ${TODAY}
updated: ${TODAY}
---

# Cron Catalog

> 이 문서는 gen-inventory.sh에 의해 자동 생성됩니다. 수동 편집 금지.
> 최종 갱신: ${TIMESTAMP}

## tasks.json 태스크 (${task_count}개)

| ID | 이름 | 주기 | 모델 | 의존성 | 출력 채널 | Budget |
|----|------|------|------|--------|-----------|--------|
${task_table}

## crontab 직접 등록 (${cron_count}개)

| 주기 | 명령어 (요약) |
|------|--------------|
${cron_lines}
EOF

  log "  -> ${outfile} (tasks: ${task_count}, direct cron: ${cron_count})"
  GENERATED=$((GENERATED + 1))
}

# ==========================================================
# 2. launchd-manifest.md
# ==========================================================
generate_launchd_manifest() {
  $IS_MACOS || { log "SKIP: launchd-manifest (non-macOS)"; return; }
  local outfile="$OUT_DIR/launchd-manifest.md"
  log "Generating launchd-manifest.md ..."

  local table_rows=""
  local agent_count=0
  local plist_dir="$HOME/Library/LaunchAgents"

  while IFS=$'\t' read -r pid status label; do
    # 공백 정리
    pid="$(echo "$pid" | xargs)"
    status="$(echo "$status" | xargs)"
    label="$(echo "$label" | xargs)"

    # plist 경로 탐색
    local plist_path="-"
    if [[ -f "${plist_dir}/${label}.plist" ]]; then
      plist_path="${plist_dir}/${label}.plist"
    fi

    # PID 표시
    local pid_display
    if [[ "$pid" == "-" ]]; then
      pid_display="-"
    else
      pid_display="$pid"
    fi

    # Status 해석
    local status_display
    if [[ "$status" == "0" ]]; then
      status_display="Running (0)"
    else
      status_display="Exit ($status)"
    fi

    table_rows="${table_rows}| ${label} | ${pid_display} | ${status_display} | ${plist_path} |
"
    agent_count=$((agent_count + 1))
  done < <(launchctl list 2>/dev/null | grep -E 'jarvis|glances' | awk '{print $1"\t"$2"\t"$3}')

  cat > "$outfile" <<EOF
---
title: "LaunchAgent Manifest (Auto-Generated)"
tags: [area/system, type/inventory, auto-generated]
created: ${TODAY}
updated: ${TODAY}
---

# LaunchAgent Manifest

> 이 문서는 gen-inventory.sh에 의해 자동 생성됩니다.
> 최종 갱신: ${TIMESTAMP}

## 활성 에이전트 (${agent_count}개)

| Label | PID | Status | plist 경로 |
|-------|-----|--------|-----------|
${table_rows}
EOF

  log "  -> ${outfile} (agents: ${agent_count})"
  GENERATED=$((GENERATED + 1))
}

# ==========================================================
# 3. webhook-registry.md
# ==========================================================
generate_webhook_registry() {
  local outfile="$OUT_DIR/webhook-registry.md"
  log "Generating webhook-registry.md ..."

  if [[ ! -f "$MONITORING_JSON" ]]; then
    log "  WARNING: ${MONITORING_JSON} 없음. webhook-registry 건너뜀."
    return
  fi

  # webhooks 객체에서 키/값 추출
  local table_rows=""
  local wh_count=0

  while IFS=$'\t' read -r name url; do
    # URL 마스킹: 앞 30자 + ***
    local masked
    if [[ ${#url} -gt 30 ]]; then
      masked="${url:0:30}***"
    else
      masked="$url"
    fi

    # 채널 이름 = 키 이름
    local channel="$name"

    # 용도 추정
    local purpose
    case "$name" in
      jarvis)        purpose="일반 알림/브리핑" ;;
      jarvis-system) purpose="시스템 알림" ;;
      jarvis-market) purpose="시장/투자 알림" ;;
      jarvis-blog)   purpose="블로그 알림" ;;
      jarvis-ceo)    purpose="CEO/경영 보고" ;;
      *)             purpose="-" ;;
    esac

    table_rows="${table_rows}| ${name} | #${channel} | ${masked} | ${purpose} |
"
    wh_count=$((wh_count + 1))
  done < <(jq -r '.webhooks | to_entries[] | [.key, .value] | @tsv' "$MONITORING_JSON")

  # ntfy 정보 추가
  local ntfy_enabled ntfy_topic ntfy_server
  ntfy_enabled="$(jq -r '.ntfy.enabled // false' "$MONITORING_JSON")"
  ntfy_server="$(jq -r '.ntfy.server // "-"' "$MONITORING_JSON")"
  ntfy_topic="$(jq -r '.ntfy.topic // "-"' "$MONITORING_JSON")"

  cat > "$outfile" <<EOF
---
title: "Webhook Registry (Auto-Generated)"
tags: [area/system, type/inventory, auto-generated]
created: ${TODAY}
updated: ${TODAY}
---

# Webhook Registry

> 이 문서는 gen-inventory.sh에 의해 자동 생성됩니다.
> 최종 갱신: ${TIMESTAMP}

## Discord Webhooks (${wh_count}개)

| 이름 | 채널 | URL (마스킹) | 용도 |
|------|------|-------------|------|
${table_rows}

## ntfy Push (모바일)

| 항목 | 값 |
|------|-----|
| Enabled | ${ntfy_enabled} |
| Server | ${ntfy_server} |
| Topic | ${ntfy_topic} |
EOF

  log "  -> ${outfile} (webhooks: ${wh_count})"
  GENERATED=$((GENERATED + 1))
}

# ==========================================================
# 실행
# ==========================================================
log "=== gen-inventory.sh 시작 ==="

generate_cron_catalog
generate_launchd_manifest
generate_webhook_registry

log "=== 완료: ${GENERATED}개 파일 생성 ==="
