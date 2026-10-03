#!/usr/bin/env bash
# file-state-dev-queue-bridge 의 개발 큐 관문 시험(2026-10-03): 큐 꺼짐 → propose 안 부름, 켜짐 → 부름.
# 진짜 tasks.db 를 건드리지 않게 임시 BOT_HOME 에 가짜 task-store.mjs 를 둔다.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib"
cp "$here/lib/file-state-dev-queue-bridge.sh" "$here/lib/task-queue-guard.mjs" "$tmp/lib/"
cat > "$tmp/lib/task-store.mjs" <<'JS'
import { appendFileSync } from 'node:fs';
appendFileSync(process.env.FAKE_MARK, process.argv.slice(2).join(' ') + '\n');
console.log(JSON.stringify({ action: 'proposed' }));
JS
pass=0; fail=0
check() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3 (got $1, want $2)"; fi; }
run() {
  export BOT_HOME="$tmp" FAKE_MARK="$tmp/mark-$1" JARVIS_TASK_QUEUE_ENABLED="$1"
  : > "$FAKE_MARK"
  ( source "$tmp/lib/file-state-dev-queue-bridge.sh"; enqueue_file_state_contradiction_task "orig-1" "시험 모순" "WARN" ) 2>"$tmp/err-$1"
}
run 0; check "$?" "0" "꺼짐: 함수 종료코드 0"
check "$(wc -l < "$tmp/mark-0" | tr -d ' ')" "0" "꺼짐: propose 호출 없음"
check "$(grep -c '생략 — 개발 큐 꺼짐' "$tmp/err-0" || true)" "1" "꺼짐: 생략 로그"
run 1; check "$?" "0" "켜짐: 함수 종료코드 0"
check "$(grep -c 'propose' "$tmp/mark-1" || true)" "1" "켜짐: propose 1회"
echo "PASS $pass / FAIL $fail"
[ "$fail" = "0" ]
