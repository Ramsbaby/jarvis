#!/usr/bin/env bash
# decision-note.sh — 능동 결정·대기 원장 (전략2, 2026-06-12)
#
# 기존 commitments.jsonl을 재활용한다 (새 원장 신설 금지 — 전략1 반-비대화 원칙).
# 차이: commitment-tracker.js는 "~하겠습니다" 정규식 자동감지(오탐 多) → Discord 전용.
#       이 헬퍼는 자비스/주인님이 "진짜 결정·열린 약속"을 의도적으로 기록 (CLI 경로, FP 0).
# 세션 시작 시 session-context.sh가 open 항목 내용을 브리핑한다.
#
# 사용법:
#   decision-note.sh add "사람인 API 승인 대기" [--due 2026-06-15]
#   decision-note.sh done <id>
#   decision-note.sh list            # 열린 항목만
set -euo pipefail

LEDGER="${HOME}/.jarvis/state/commitments.jsonl"
mkdir -p "$(dirname "$LEDGER")"
cmd="${1:-list}"

case "$cmd" in
  add)
    text="${2:?사용법: decision-note.sh add \"내용\" [--due YYYY-MM-DD]}"
    due=""
    # set -e 안전: [[ ]] && 단문은 조건 거짓 시 비-0 반환→조기종료. if 블록으로 감쌈.
    if [[ "${3:-}" == "--due" ]]; then due="${4:-}"; fi
    id=$(python3 -c "import uuid;print(uuid.uuid4().hex[:8])")
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 - "$LEDGER" "$id" "$ts" "$text" "$due" <<'PY'
import json, sys
ledger, id, ts, text, due = sys.argv[1:6]
rec = {"id": id, "status": "open", "text": text, "created_at": ts, "source": "cli-deliberate"}
if due:
    rec["due"] = due
# 압축 JSON (공백 없음) — 기존 commitments.jsonl 규약 + session-context grep '"status":"open"' 호환
with open(ledger, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
    echo "✅ 결정·대기 등록: [$id] $text${due:+ (마감 $due)}"
    ;;
  done)
    id="${2:?사용법: decision-note.sh done <id>}"
    python3 - "$LEDGER" "$id" <<'PY'
import json, sys, datetime
ledger, target = sys.argv[1:3]
out, hit = [], False
for l in open(ledger, encoding="utf-8"):
    s = l.strip()
    if not s:
        continue
    if not s.startswith("{"):
        out.append(s); continue          # 과거 FP 비-JSON 줄은 보존
    try:
        d = json.loads(s)
    except Exception:
        out.append(s); continue
    if d.get("id") == target and d.get("status") == "open":
        d["status"] = "done"
        d["resolved_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        hit = True
    out.append(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
with open(ledger, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
print(("✅ 이행 완료: " if hit else "⚠️ 해당 open 결정 없음: ") + target)
PY
    ;;
  list|*)
    python3 - "$LEDGER" <<'PY'
import json, sys, os
ledger = sys.argv[1]
if not os.path.exists(ledger):
    print("(원장 없음)"); sys.exit()
opens = []
for l in open(ledger, encoding="utf-8"):
    s = l.strip()
    if s.startswith("{"):
        try:
            d = json.loads(s)
            if d.get("status") == "open":
                opens.append(d)
        except Exception:
            pass
print(f"열린 결정·대기 {len(opens)}건:")
for d in opens:
    due = f" [마감 {d['due']}]" if d.get("due") else ""
    print(f"  [{d.get('id','?')}] {d.get('text','')}{due}")
PY
    ;;
esac
