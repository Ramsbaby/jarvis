#!/usr/bin/env bash
# test-age-mem-discard-guard.sh — RAG 고아 정리가 대량 삭제를 막는지, inbox 30일 삭제가 되살아나지 않았는지 (2026-10-08)
#   사고: 10-04 system-cleanup 이 inbox 대화 기록 2,499개를 지움 → 10-08 age-mem-discard 가 그 청크 약 7.1만(65%)을 고아로 지움.
#   진짜 DB·HOME 을 건드리지 않게 임시 HOME 에 가짜 LanceDB 를 만들어 돈다.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_HOME="$HOME"
NODE="${NODE:-$(command -v node || echo /opt/homebrew/bin/node)}"
NM="$REPO/rag/node_modules"
[[ -d "$NM" ]] || NM="$REAL_HOME/projects/jarvis/rag/node_modules"   # 작업 폴더(worktree)엔 node_modules 가 없다
[[ -d "$NM" ]] || { echo "FAIL: rag/node_modules 없음"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/projects/jarvis/rag" "$TMP/projects/jarvis/infra/scripts" "$TMP/rt/rag" "$TMP/rt/state" "$TMP/rt/logs" "$TMP/.jarvis/state"
cp -R "$REPO/rag/lib" "$TMP/projects/jarvis/rag/lib"
ln -s "$NM" "$TMP/projects/jarvis/rag/node_modules"
cp "$REPO/infra/scripts/age-mem-discard.mjs" "$TMP/projects/jarvis/infra/scripts/"
echo "keep" > "$TMP/keep.md"

seed() {   # 고아 5개(없는 파일) + 살아 있는 1개
  rm -rf "$TMP/rt/rag/lancedb"
  HOME="$TMP" BOT_HOME="$TMP/rt" "$NODE" --input-type=module -e "
    const { RAGEngine } = await import('$TMP/projects/jarvis/rag/lib/rag-engine.mjs');
    const e = new RAGEngine('$TMP/rt/rag/lancedb'); await e.init();
    const dim = (await e.table.schema()).fields.find(f => f.name === 'vector').type.listSize;
    const srcs = ['a','b','c','d','e'].map(x => '$TMP/gone/' + x + '.md').concat(['$TMP/keep.md']);
    await e.table.add(srcs.map((s, i) => ({ id: 'r' + i, text: 't' + i, vector: Array(dim).fill(0.1), source: s,
      chunk_index: 0, header_path: '', modified_at: 0, importance: 0, entities: '', topics: '',
      deleted: false, deleted_at: 0, is_latest: true, expires_at: 0, chunk_type: 'text' })));
  " >/dev/null 2>&1
}
live_rows() {
  HOME="$TMP" BOT_HOME="$TMP/rt" "$NODE" --input-type=module -e "
    const { RAGEngine } = await import('$TMP/projects/jarvis/rag/lib/rag-engine.mjs');
    const e = new RAGEngine('$TMP/rt/rag/lancedb'); await e.init();
    console.log((await e.getAllSources()).length);
  " 2>/dev/null | tail -1
}
run_discard() {
  HOME="$TMP" BOT_HOME="$TMP/rt" "$@" "$NODE" "$TMP/projects/jarvis/infra/scripts/age-mem-discard.mjs" 2>&1
}

echo "[1] 고아가 한도를 넘으면 지우지 않는다"
seed
[[ "$(live_rows)" == "6" ]] && ok "가짜 DB 소스 6개" || bad "가짜 DB 준비 실패($(live_rows))"
out="$(run_discard env AGEMEM_MAX_DELETE=3)"
if grep -q "rag-index 또는 rag-compact 실행 중" <<<"$out"; then echo "SKIP: 실제 색인기가 도는 중 — 나중에 다시"; exit 1; fi
grep -q "대량 삭제 차단" <<<"$out" && ok "⚠️ 차단 문구" || bad "차단 문구 없음: $out"
[[ "$(live_rows)" == "6" ]] && ok "6개 그대로" || bad "지워짐 — 남은 소스 $(live_rows)"

echo "[2] 한도 안이면 예전처럼 고아만 지운다"
out="$(run_discard env AGEMEM_MAX_DELETE=10)"
grep -q "배치 soft-delete 완료: 5/5" <<<"$out" && ok "고아 5개 삭제" || bad "삭제 안 됨: $out"
[[ "$(live_rows)" == "1" ]] && ok "살아 있는 원본 1개만 남음" || bad "남은 소스 $(live_rows)"

echo "[3] system-cleanup 이 inbox 를 지우지 않는다"
bash -n "$REPO/infra/scripts/system-cleanup.sh" && ok "문법" || bad "문법 오류"
if grep -nE 'inbox.*-delete|-delete.*inbox' "$REPO/infra/scripts/system-cleanup.sh"; then bad "inbox 삭제 줄이 있다"; else ok "inbox 삭제 줄 없음"; fi

echo "결과: 통과 $PASS · 실패 $FAIL"
[[ $FAIL -eq 0 ]]
