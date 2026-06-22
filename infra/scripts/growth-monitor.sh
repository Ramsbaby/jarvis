#!/usr/bin/env bash
set -euo pipefail

# growth-monitor.sh — 자비스 전 영역 비대화 통합 감시 (2026-06-22 신설)
# 목적: 디스크 100% 반복 사고 재발 방지. "조용히 쌓이는 것"을 한 곳에서 추세 기록 + 임계 경고.
# 통합: B(추세 ledger 기록) + C(영역별 임계 digest 경고) + D(자가진단 역설 가드 — 디스크 위험 시 ntfy 직접).
# DRY: RAG 비대 경고는 기존 lancedb-alert.sh 재사용.
# cron: 매일 1회. digest(직전 경고와 동일하면 skip)로 알림 폭주 차단(proactive 노이즈 교훈).

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER="${BOT_HOME}/state/growth-ledger.jsonl"
LAST_WARN="${BOT_HOME}/state/growth-last-warn.txt"
NTFY_TOPIC="openclaw-f101e56cb98a"
mkdir -p "$(dirname "$LEDGER")"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── 영역별 측정 ──
disk_free_gb=$(df -g / 2>/dev/null | awk 'NR==2{print $4+0}')
rag_mb=$(du -sm "${HOME}/.jarvis/rag/lancedb" 2>/dev/null | cut -f1 || echo 0)
rag_frag=$(ls -1 "${HOME}/.jarvis/rag/lancedb/documents.lance/data/" 2>/dev/null | wc -l | tr -d ' ')
logs_mb=$(du -smc "${HOME}/.jarvis/logs" "${HOME}/jarvis/runtime/logs" 2>/dev/null | tail -1 | cut -f1 || echo 0)
backup_mb=$(du -sm "${HOME}/backup" 2>/dev/null | cut -f1 || echo 0)
state_mb=$(du -sm "${HOME}/jarvis/runtime/state" 2>/dev/null | cut -f1 || echo 0)
bak_count=$(find "${HOME}/.jarvis" "${HOME}/jarvis/runtime" \( -name '*.bak' -o -name '*.tmp' -o -name '*.old' \) -not -path '*/backups/*' 2>/dev/null | wc -l | tr -d ' ')
# 통제 신호: 유명무실(정의는 있으나 실행 흔적 0) 태스크 수 — task-effectiveness-scan 최신 결과 재사용
orphan_n=$(grep -c 'ORPHAN' "$BOT_HOME/logs/task-effectiveness-scan.log" 2>/dev/null || echo 0)

# 기본값 보정 (측정 실패 시 0)
disk_free_gb=${disk_free_gb:-0}; rag_mb=${rag_mb:-0}; rag_frag=${rag_frag:-0}
logs_mb=${logs_mb:-0}; backup_mb=${backup_mb:-0}; state_mb=${state_mb:-0}; bak_count=${bak_count:-0}
orphan_n=${orphan_n:-0}

# ── B: 추세 ledger 1줄 기록 ──
jq -cn --arg ts "$ts" \
  --argjson disk "$disk_free_gb" --argjson rag "$rag_mb" --argjson frag "$rag_frag" \
  --argjson logs "$logs_mb" --argjson backup "$backup_mb" --argjson state "$state_mb" --argjson bak "$bak_count" \
  '{ts:$ts,disk_free_gb:$disk,rag_mb:$rag,rag_frag:$frag,logs_mb:$logs,backup_mb:$backup,state_mb:$state,bak_count:$bak}' \
  >> "$LEDGER"

# ── C: 영역별 임계 비교 ──
WARN=""
(( disk_free_gb < 10 ))   && WARN="${WARN}디스크여유 ${disk_free_gb}GB(<10); "
(( rag_frag > 5000 ))     && WARN="${WARN}RAG조각 ${rag_frag}개(>5000); "
(( rag_mb > 25000 ))      && WARN="${WARN}RAG ${rag_mb}MB(>25GB); "
(( logs_mb > 500 ))       && WARN="${WARN}로그 ${logs_mb}MB(>500); "
(( backup_mb > 18000 ))   && WARN="${WARN}백업 ${backup_mb}MB(>18GB); "
(( bak_count > 100 ))     && WARN="${WARN}임시파일 ${bak_count}개(>100); "

# ── D: 자가진단 역설 가드 — 디스크 위험 시 임시파일 없이 ntfy 직접 발신 ──
# (node/discord-visual은 임시파일이 필요해 디스크 0이면 실패. ntfy는 curl 한 방이라 디스크 무관)
if (( disk_free_gb < 3 )); then
  curl -s --max-time 5 -d "🔴 자비스 디스크 위험: ${disk_free_gb}GB 남음 (growth-monitor)" "ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 || true
fi

# ── C: digest 경고 (직전과 동일하면 skip — 노이즈 억제) ──
if [ -n "$WARN" ]; then
  prev=$(cat "$LAST_WARN" 2>/dev/null || echo "")
  if [ "$WARN" != "$prev" ]; then
    echo "$WARN" > "$LAST_WARN"
    # RAG 비대면 기존 lancedb-alert.sh 재사용 (DRY)
    if (( rag_mb > 25000 )); then
      BOT_HOME="$BOT_HOME" bash "${BOT_HOME}/scripts/lancedb-alert.sh" "$rag_mb" >/dev/null 2>&1 || true
    fi
    # 통합 경고 카드 (디스크 여유 있을 때만 — node는 임시파일 필요)
    if (( disk_free_gb >= 3 )); then
      cd "$HOME" && node "${HOME}/.jarvis/scripts/discord-visual.mjs" --type stats \
        --data "{\"title\":\"⚠️ 자비스 비대 경고\",\"data\":{\"경고\":\"${WARN}\",\"디스크여유\":\"${disk_free_gb}GB\",\"RAG\":\"${rag_mb}MB/${rag_frag}조각\",\"백업\":\"${backup_mb}MB\"},\"timestamp\":\"$(date '+%Y-%m-%d %H:%M KST')\"}" \
        --channel jarvis-system >/dev/null 2>&1 || true
    fi
    echo "[growth-monitor] 경고 송출: $WARN"
  else
    echo "[growth-monitor] 경고 동일 — digest skip: $WARN"
  fi
else
  rm -f "$LAST_WARN" 2>/dev/null || true  # 정상 복귀 시 경고 상태 리셋
  echo "[growth-monitor] 정상 — 임계 초과 없음"
fi

echo "[growth-monitor] 기록 완료: disk=${disk_free_gb}GB rag=${rag_mb}MB(${rag_frag}조각) logs=${logs_mb}MB backup=${backup_mb}MB state=${state_mb}MB bak=${bak_count}"
