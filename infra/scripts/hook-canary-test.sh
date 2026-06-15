#!/usr/bin/env bash
# hook-canary-test.sh — 독립 감사 관문(Stop 훅) 심장박동 검사
#
# Why 1줄: 관문의 "침묵"이 ① 고장(죽은 침묵)인지 ② 정상 통과(일하는 침묵)인지 외부에서
#          구분 불가 — 주 1회 합성 위반을 들이밀어 발동을 강제 확인, 안 울리면 그게 경보.
#          (2026-06-12 주인님 질문 "실전에서 침묵이면 쓸모없는 거 아님?"의 구조적 답)
# LLM 0회 · 부작용: 임시 transcript 파일만 (trap 정리)
set -euo pipefail

HOOK="${HOME}/.claude/hooks/stop-question-pattern-guard.sh"
LEDGER="${HOME}/jarvis/runtime/ledger/hook-canary.jsonl"
ALERT="${HOME}/jarvis/infra/scripts/alert-send.sh"
mkdir -p "$(dirname "$LEDGER")"

tmp=$(mktemp /tmp/hook-canary-XXXX.jsonl)
trap 'rm -f "$tmp"' EXIT

fail_reasons=()

# 케이스 1 — 발동해야 함: 코드 수정 + 완료 선언 + 감사 흔적 없음
cat > "$tmp" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/canary.js","old_string":"a","new_string":"b"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"수리 완료했습니다."}]}}
EOF
out1=$(echo "{\"transcript_path\":\"$tmp\",\"cwd\":\"/tmp\"}" | bash "$HOOK" 2>&1 || true)
echo "$out1" | grep -q "독립 감사 관문" || fail_reasons+=("케이스1: 위반 상황인데 관문 미발동 (죽은 침묵)")

# 케이스 2 — 침묵해야 함: 감사 흔적 포함
cat > "$tmp" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/canary.js","old_string":"a","new_string":"b"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"적대 감사","prompt":"이 작업을 적대적으로 감사하라"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"수리 완료했습니다."}]}}
EOF
out2=$(echo "{\"transcript_path\":\"$tmp\",\"cwd\":\"/tmp\"}" | bash "$HOOK" 2>&1 || true)
if echo "$out2" | grep -q "독립 감사 관문"; then fail_reasons+=("케이스2: 감사 흔적 있는데 오발동 (오탐)"); fi

status="alive"
[[ ${#fail_reasons[@]} -gt 0 ]] && status="DEAD"

jq -cn \
  --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg status "$status" \
  --argjson fails "$(printf '%s\n' "${fail_reasons[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')" \
  '{ts:$ts, status:$status, fails:$fails}' >> "$LEDGER"

if [[ "$status" == "DEAD" ]]; then
  echo "🚨 관문 카나리 실패: ${fail_reasons[*]}" >&2
  bash "$ALERT" critical jarvis-system "독립 감사 관문 카나리" \
    "🚨 관문이 죽었습니다 — 합성 위반에 미발동/오발동: ${fail_reasons[*]}" || true
  exit 1
fi
echo "💓 관문 카나리: 발동·침묵 양방향 정상 (검증된 침묵)"
