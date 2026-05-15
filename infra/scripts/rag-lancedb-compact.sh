#!/usr/bin/env bash
# rag-lancedb-compact.sh — LanceDB 주간 컴팩트 + prune
#
# 배경 (2026-05-07 오답노트 등재):
#   LanceDB는 증분 인덱싱 시 fragment를 누적하고 MVCC 버전을 보존한다.
#   주기 컴팩트가 없으면 fragment 200+개 / version 169+개로 누적되어
#   디스크 7.7GB까지 부풀어 오르는 사고 발생. 검색 속도도 1.7s까지 저하.
#
# 동작:
#   1. write.lock 생성 (rag-index-cron이 진행 중이면 충돌 방지)
#   2. _versions + _transactions 백업 (롤백 안전판)
#   3. compact + prune 2사이클 실행
#   4. 결과 통계 출력 + lock 해제
#
# 호출처:
#   ~/jarvis/runtime/config/tasks.json → id=rag-lancedb-compact, schedule="15 4 * * 0"
#
# 안전:
#   - 실패해도 lock은 trap으로 반드시 해제
#   - 백업 보관 (수동 복구 시 _versions / _transactions 복사로 직전 상태 복원)
#   - 백업 14일 보관 후 retention 크론이 정리

set -euo pipefail

LANCEDB_DIR="${HOME}/.jarvis/rag/lancedb/documents.lance"
LOCK="${HOME}/.jarvis/rag/write.lock"
BACKUP_ROOT="${HOME}/.jarvis/rag/backups"
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"
NODE_PATH="${HOME}/.jarvis/discord/node_modules"

if [[ ! -d "$LANCEDB_DIR" ]]; then
  echo "[lancedb-compact] FATAL: $LANCEDB_DIR not found" >&2
  exit 127
fi

# 1. lock 충돌 검사 — 이미 인덱싱 중이면 SKIP (재발 방지)
if [[ -f "$LOCK" ]]; then
  age_sec=$(( $(date +%s) - $(stat -f %m "$LOCK") ))
  if (( age_sec < 3600 )); then
    echo "[lancedb-compact] SKIP: write.lock fresh (${age_sec}s) — 인덱싱 진행 중"
    exit 0
  fi
  echo "[lancedb-compact] WARN: stale lock (${age_sec}s) — overriding"
fi

# 2. lock 잡기 + trap으로 반드시 해제
echo "$$ rag-lancedb-compact-$(date +%s)" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

# 3. 백업 (작은 메타만)
BACKUP_DIR="${BACKUP_ROOT}/pre-compact-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -R "$LANCEDB_DIR/_versions" "$BACKUP_DIR/" 2>/dev/null || true
cp -R "$LANCEDB_DIR/_transactions" "$BACKUP_DIR/" 2>/dev/null || true
echo "[lancedb-compact] backup: $BACKUP_DIR"

# 4. compact + prune 2사이클
NODE_PATH="$NODE_PATH" "$NODE_BIN" --input-type=module <<'EOF'
import ldb from '/Users/ramsbaby/.jarvis/discord/node_modules/@lancedb/lancedb/dist/index.js';
const t0 = Date.now();
const db = await ldb.connect(process.env.HOME+'/.jarvis/rag/lancedb');
const tbl = await db.openTable('documents');

const before = await tbl.countRows();
console.log('[before] countRows:', before);

// cycle 1: compact (7일 이전 버전 prune 동시)
console.log('--- cycle 1: compact + prune (7d) ---');
let s1 = await tbl.optimize({ cleanupOlderThan: new Date(Date.now() - 7*86400*1000) });
console.log(JSON.stringify(s1));

// cycle 2: aggressive prune (방금 compact 결과 정리)
console.log('--- cycle 2: aggressive prune (30s) ---');
let s2 = await tbl.optimize({ cleanupOlderThan: new Date(Date.now() - 30*1000) });
console.log(JSON.stringify(s2));

const after = await tbl.countRows();
console.log('[after] countRows:', after);

if (before !== after) {
  console.error('[FATAL] countRows mismatch — data loss suspected');
  process.exit(2);
}

console.log('[done] elapsed_ms:', Date.now()-t0);
EOF

# 5. 백업 14일 retention (오래된 pre-compact-* 정리)
find "$BACKUP_ROOT" -maxdepth 1 -name "pre-compact-*" -type d -mtime +14 -exec rm -rf {} \; 2>/dev/null || true
find "$BACKUP_ROOT" -maxdepth 1 -name "pre-optimize-*" -type d -mtime +14 -exec rm -rf {} \; 2>/dev/null || true

echo "[lancedb-compact] DONE"
