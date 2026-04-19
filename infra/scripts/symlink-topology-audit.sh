#!/usr/bin/env bash
# symlink-topology-audit.sh
#
# ~/.jarvis 하위 토폴로지 정합성 감사 + 자동 복구.
#
# Check:
#   1. ~/jarvis/runtime/{infra,bin,lib,scripts} 가 심링크인가 (실제 디렉토리로 변했으면 파괴)
#   2. 그 심링크들이 SSoT(~/jarvis/infra/*)를 가리키는가
#   3. ~/.jarvis 하위 다른 절대 심링크가 SSoT 외부를 가리키는가
#   4. .bak-* / .ghost-* 잔해
#
# Auto-recovery: Check 1·2 위반은 즉시 자동 복구 (파일 백업 후 심링크 재생성).
#   복구 로그는 원장 + Discord 알림.
#
# Discord 알림 스로틀: 같은 (code, path)로 24시간 내 반복 알림 차단.
#
# 2026-04-16 2차 장애 이후 auto-recovery + 스로틀 추가.
set -euo pipefail

DOT_JARVIS="${HOME}/jarvis/runtime"
SSOT="${HOME}/jarvis/infra"
LEDGER_DIR="${DOT_JARVIS}/state"
LEDGER="${LEDGER_DIR}/symlink-audit.jsonl"
THROTTLE_DIR="${LEDGER_DIR}/audit-throttle"
BACKUP_DIR="${HOME}/backup/jarvis-topology/auto-recovery"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
EPOCH="$(date +%s)"

mkdir -p "$LEDGER_DIR" "$THROTTLE_DIR" "$BACKUP_DIR"

# Canonical symlink mapping (bash 3.2 호환 — 평행 배열)
EXPECTED_LINK_PATHS=(
  "${DOT_JARVIS}/infra"
  "${DOT_JARVIS}/bin"
  "${DOT_JARVIS}/lib"
  "${DOT_JARVIS}/scripts"
)
EXPECTED_LINK_TARGETS=(
  "${SSOT}"
  "${SSOT}/bin"
  "${SSOT}/lib"
  "${SSOT}/scripts"
)

# Ledger emitter
emit() {
  local level="$1" code="$2" path="$3" detail="$4"
  printf '{"ts":"%s","level":"%s","code":"%s","path":"%s","detail":"%s"}\n' \
    "$TS" "$level" "$code" "$path" "$detail" >> "$LEDGER"
}

# Discord alert with 24h throttle per (code,path)
alert_throttled() {
  local code="$1" path="$2" title="$3" detail="$4"
  local key
  key="$(printf '%s|%s' "$code" "$path" | shasum -a 1 | awk '{print $1}')"
  local marker="${THROTTLE_DIR}/${key}"
  if [[ -f "$marker" ]]; then
    local last
    last=$(cat "$marker" 2>/dev/null || echo 0)
    if (( EPOCH - last < 86400 )); then
      return 0
    fi
  fi
  if [[ -x "${HOME}/jarvis/runtime/scripts/discord-visual.mjs" || -f "${HOME}/jarvis/runtime/scripts/discord-visual.mjs" ]]; then
    /opt/homebrew/bin/node "${HOME}/jarvis/runtime/scripts/discord-visual.mjs" \
      --type stats \
      --data "{\"title\":\"${title}\",\"data\":{\"path\":\"${path}\",\"detail\":\"${detail}\",\"ledger\":\"${LEDGER}\"},\"timestamp\":\"${TS}\"}" \
      --channel jarvis-system 2>/dev/null || true
  fi
  echo "$EPOCH" > "$marker"
}

# Auto-recovery: 심링크가 깨졌거나 디렉토리로 변한 경우 복구
recover_link() {
  local link_path="$1" expected_target="$2"
  local recovery_stash
  recovery_stash="${BACKUP_DIR}/$(date +%Y%m%d-%H%M%S)-$(basename "$link_path")"

  if [[ -L "$link_path" ]]; then
    local current_target
    current_target="$(readlink "$link_path" 2>/dev/null || echo '')"
    if [[ "$current_target" == "$expected_target" ]]; then
      return 0  # 정상
    fi
    # 잘못된 타겟을 가리키는 심링크 → 교체
    rm -f "$link_path"
    ln -s "$expected_target" "$link_path"
    emit "info" "recovered-wrong-target" "$link_path" "was=${current_target} now=${expected_target}"
    alert_throttled "recovered-wrong-target" "$link_path" "🔧 심링크 자동 복구" "was=${current_target} → now=${expected_target}"
    return 1  # 복구 발생
  fi

  if [[ -d "$link_path" && ! -L "$link_path" ]]; then
    # 실제 디렉토리로 변했음 → 백업 후 제거 + 심링크 재생성
    mv "$link_path" "$recovery_stash"
    ln -s "$expected_target" "$link_path"
    local file_count
    file_count=$(find "$recovery_stash" -maxdepth 3 | wc -l | tr -d ' ')
    emit "error" "recovered-ghost-dir" "$link_path" "stashed=${recovery_stash} files=${file_count}"
    alert_throttled "recovered-ghost-dir" "$link_path" "🚨 유령 디렉토리 자동 복구" "stashed at ${recovery_stash} (files: ${file_count})"
    return 1
  fi

  if [[ ! -e "$link_path" ]]; then
    # 심링크도 없음 → 생성
    ln -s "$expected_target" "$link_path"
    emit "warn" "recovered-missing" "$link_path" "created symlink to ${expected_target}"
    alert_throttled "recovered-missing" "$link_path" "🔧 누락 심링크 복구" "created → ${expected_target}"
    return 1
  fi

  return 0
}

violations=0
recoveries=0

# Check 1·2 (+ auto-recovery): 정규 심링크 검증/복구
idx=0
while (( idx < ${#EXPECTED_LINK_PATHS[@]} )); do
  link_path="${EXPECTED_LINK_PATHS[$idx]}"
  expected="${EXPECTED_LINK_TARGETS[$idx]}"
  if ! recover_link "$link_path" "$expected"; then
    recoveries=$((recoveries + 1))
  fi
  idx=$((idx + 1))
done

# Check 3: SSoT 외부를 가리키는 절대 심링크 (find 에러는 fatal)
while IFS= read -r link; do
  case "$link" in
    *.bak*|*backup*) continue ;;
  esac
  target="$(readlink "$link" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then continue; fi
  if [[ "$target" != /* ]]; then continue; fi
  if [[ "$target" == "${DOT_JARVIS}"/* ]]; then continue; fi
  if [[ "$target" == "${SSOT}"* ]]; then continue; fi
  if [[ "$target" == "${HOME}/jarvis"* ]]; then continue; fi
  if [[ "$target" == "${HOME}/jarvis-board"* ]]; then continue; fi
  if [[ "$target" == "${HOME}/.jarvis"* ]]; then continue; fi  # ~/.jarvis는 jarvis/runtime 심링크 — 허용
  emit "warn" "off-ssot-target" "$link" "target=${target}"
  alert_throttled "off-ssot-target" "$link" "⚠️ SSoT 외부 심링크" "target=${target}"
  violations=$((violations + 1))
done < <(find "$DOT_JARVIS" -type l ! -path '*.bak*' ! -path '*node_modules*')

# Check 4: 잔해
while IFS= read -r stale; do
  emit "warn" "stale-backup" "$stale" "leftover backup dir — archive and remove"
  violations=$((violations + 1))
done < <(find "$DOT_JARVIS" -maxdepth 2 -type d \( -name '*.bak-*' -o -name '*.ghost-*' -o -name '*.bak' \))

# 원장 rotation: 10MB 초과 시 gzip 압축 후 새 파일 시작
if [[ -f "$LEDGER" ]]; then
  size=$(stat -f "%z" "$LEDGER" 2>/dev/null || echo 0)
  if (( size > 10485760 )); then
    gzip -c "$LEDGER" > "${LEDGER%.jsonl}-$(date +%Y%m%d).jsonl.gz"
    : > "$LEDGER"
    emit "info" "rotated" "$LEDGER" "previous logs archived"
  fi
fi

# 결과
if [[ $recoveries -gt 0 ]]; then
  echo "🔧 auto-recovered ${recoveries} topology violation(s)"
  emit "info" "audit-complete" "$DOT_JARVIS" "recoveries=${recoveries} violations=${violations}"
fi
if [[ $violations -eq 0 ]]; then
  if [[ $recoveries -eq 0 ]]; then emit "info" "ok" "$DOT_JARVIS" "topology clean"; fi
  echo "✅ symlink topology audit: OK (${violations} un-recovered violations, ${recoveries} auto-recovered)"
  exit 0
else
  echo "⚠️  ${violations} un-recovered violations (see ${LEDGER})"
  exit 1
fi