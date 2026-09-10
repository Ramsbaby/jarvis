#!/usr/bin/env bash
# pre-commit hook — tasks.json 변경 시 비용 캡 가드
#
# 2026-04-28 신설: 비용 캡 일괄 적용(37건 보수) 후 재발 방지용 하네스.
# tasks.json 변경 staged 시 cost-cap-audit + validate-tasks 실행.
# 결과 status != OK 면 commit 차단.
#
# 설치:
#   ln -sf ~/.openclaw-data/jarvis/infra/hooks/pre-commit-cost-cap.sh \
#     ~/.openclaw-data/jarvis/.git/hooks/pre-commit
#   (또는 cp + chmod +x)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/jarvis/runtime}"

# 1. tasks.json staged 여부 확인
if ! git diff --cached --name-only | grep -qE '(runtime|infra)/config/tasks\.json$'; then
  exit 0  # tasks.json 무관 commit — 패스
fi

echo "[pre-commit] tasks.json 변경 감지 — 비용 캡 가드 실행"

# 2. validate-tasks (schema 검증, maxBudget required + pattern)
VALIDATOR="${REPO_ROOT}/infra/scripts/validate-tasks.mjs"
if [[ -f "$VALIDATOR" ]]; then
  if ! node "$VALIDATOR" 2>&1; then
    echo "[pre-commit] ❌ validate-tasks 실패 — commit 차단"
    echo "  → maxBudget 필수 / pattern 위반 task 점검 필요"
    exit 1
  fi
fi

# 3. cost-cap-audit (캡 부재/0 + 화이트리스트 검증)
AUDIT="${REPO_ROOT}/infra/bin/cost-cap-audit.sh"
if [[ -x "$AUDIT" ]]; then
  if ! bash "$AUDIT" >/dev/null 2>&1; then
    echo "[pre-commit] ⚠️ cost-cap-audit 실행 실패 (비차단)"
  fi
  AUDIT_RESULT="${BOT_HOME}/state/cost-cap-audit.json"
  if [[ -f "$AUDIT_RESULT" ]]; then
    STATUS=$(jq -r '.status' "$AUDIT_RESULT" 2>/dev/null)
    if [[ "$STATUS" != "OK" ]]; then
      echo "[pre-commit] 🔴 cost-cap-audit status=$STATUS — commit 차단"
      jq -r '"  - 캡 부재: \(.no_cap) / 캡=0(non-script): \(.zero_cap) / 저캡(70%+): \(.low_cap_count)"' "$AUDIT_RESULT"
      [[ -n "$(jq -r '.no_cap_ids // empty' "$AUDIT_RESULT")" ]] && \
        echo "  부재 ID: $(jq -r '.no_cap_ids' "$AUDIT_RESULT" | head -c 200)"
      [[ -n "$(jq -r '.zero_cap_ids // empty' "$AUDIT_RESULT")" ]] && \
        echo "  zero ID: $(jq -r '.zero_cap_ids' "$AUDIT_RESULT" | head -c 200)"
      echo ""
      echo "  → 우회: git commit --no-verify (긴급 시만)"
      exit 1
    fi
  fi
fi

echo "[pre-commit] ✅ 비용 캡 가드 통과"
exit 0
