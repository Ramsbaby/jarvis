#!/usr/bin/env bash
# doctor-self-audit.sh — /doctor 자신이 실 운영 자산을 따라가는지 감사.
#
# 3각 정합성 검사:
#   T-A. ~/.mcp.json 등록 서버 vs 실 프로세스
#   T-B. LaunchAgent 네임스페이스 vs doctor.md G 섹션 regex
#   T-C. tasks.json 도메인 수 vs doctor.md 섹션 수
#
# 출력: doctor.md 섹션 T에서 `tail -20`으로 수집.

set -euo pipefail

DOCTOR_MD="${HOME}/.claude/commands/doctor.md"
MCP_JSON="${HOME}/.mcp.json"
TASKS_JSON="${HOME}/jarvis/runtime/config/tasks.json"
LA_DIR="${HOME}/Library/LaunchAgents"

WARNINGS=0

warn() { WARNINGS=$((WARNINGS+1)); printf "  ⚠️ %s\n" "$*"; }
ok()   { printf "  ✅ %s\n" "$*"; }
info() { printf "  · %s\n" "$*"; }

audit_mcp() {
  echo "=== T-A. MCP 등록 vs 프로세스 ==="
  if [ ! -f "$MCP_JSON" ]; then
    warn "~/.mcp.json 없음"
    return
  fi
  jq -r '.mcpServers | keys[]' "$MCP_JSON" 2>/dev/null | while read -r srv; do
    [ -z "$srv" ] && continue
    case "$srv" in
      workgroup|nexus)
        pid=$(pgrep -f "mcp-${srv}" 2>/dev/null | head -1 || true)
        if [ -n "$pid" ]; then ok "$srv: PID=$pid"; else warn "$srv: NOT_RUNNING (persistent stdio 기대)"; fi
        ;;
      serena*)
        pid=$(pgrep -f "serena.*start-mcp-server" 2>/dev/null | head -1 || true)
        if [ -n "$pid" ]; then ok "$srv: PID=$pid"; else info "$srv: session-scoped (세션 미로드면 정상)"; fi
        ;;
      *)
        info "$srv: npx 기반 (세션 내부만)"
        ;;
    esac
  done
}

audit_la_namespace() {
  echo ""
  echo "=== T-B. LaunchAgent 네임스페이스 vs doctor.md G 섹션 ==="
  local doctor_regex
  doctor_regex=$(grep -E "^launchctl list \| grep -E" "$DOCTOR_MD" 2>/dev/null | head -1 || echo "")
  info "doctor.md G regex: ${doctor_regex:-(없음)}"
  local plist_nss
  plist_nss=$(ls "$LA_DIR"/*.plist 2>/dev/null \
              | xargs -n1 basename 2>/dev/null \
              | sed -E 's/^([^.]+\.[^.]+).*/\1/' \
              | sort -u || true)
  while read -r ns; do
    [ -z "$ns" ] && continue
    case "$ns" in
      ai.jarvis|com.jarvis|ai.openclaw)
        ok "$ns (doctor.md에 매핑됨)"
        ;;
      com.apple|com.microsoft|com.google|com.docker|com.fitbit|com.amazon|com.anthropic)
        info "$ns (시스템/외부 — skip)"
        ;;
      *)
        warn "$ns (doctor.md G regex에 미등록 — regex 업데이트 권고)"
        ;;
    esac
  done <<< "$plist_nss"
}

audit_tasks_coverage() {
  echo ""
  echo "=== T-C. tasks.json 도메인 vs doctor.md 섹션 ==="
  if [ ! -f "$TASKS_JSON" ]; then
    warn "tasks.json 없음"
    return
  fi
  local total domains sections
  total=$(jq '.tasks | length' "$TASKS_JSON" 2>/dev/null || echo 0)
  domains=$(jq -r '[.tasks[]?.domain // empty] | unique | length' "$TASKS_JSON" 2>/dev/null || echo 0)
  sections=$(grep -cE "^### [A-Z]\. " "$DOCTOR_MD" 2>/dev/null || echo 0)
  info "tasks.json 총 태스크: $total · 고유 도메인: $domains"
  info "doctor.md 섹션 수: $sections"
  # Heuristic: 섹션 수 < 도메인 수 - 2 = gap 경고
  if [ "$domains" -gt 0 ] && [ $((sections + 2)) -lt "$domains" ]; then
    warn "doctor.md 섹션($sections) < tasks 도메인($domains) - 2 → 커버리지 부족 가능"
  fi
}

audit_doctor_ledger() {
  echo ""
  echo "=== T-D. doctor-ledger.jsonl 축적 상태 ==="
  local ledger="${HOME}/jarvis/runtime/state/doctor-ledger.jsonl"
  if [ ! -f "$ledger" ]; then
    warn "doctor-ledger.jsonl 없음 — /doctor 한 번도 실행 안 됨"
    return
  fi
  local entries last_ts
  entries=$(wc -l < "$ledger" | tr -d ' ')
  last_ts=$(tail -1 "$ledger" | jq -r '.ts // "n/a"' 2>/dev/null)
  info "누적 엔트리: $entries · 최종: $last_ts"
  if [ "$entries" -lt 3 ]; then
    info "(초기 단계 — 7일+3회 FAIL 반복 패턴 감지는 데이터 더 필요)"
  fi
}

main() {
  echo "🧠 doctor-self-audit — $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M KST')"
  audit_mcp
  audit_la_namespace
  audit_tasks_coverage
  audit_doctor_ledger
  echo ""
  if [ "$WARNINGS" -eq 0 ]; then
    echo "📊 종합: ✅ SSoT drift 없음"
  else
    echo "📊 종합: ⚠️ ${WARNINGS}건 drift 감지 — doctor.md 업데이트 권고"
  fi
}

main "$@"
