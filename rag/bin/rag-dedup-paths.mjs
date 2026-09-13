#!/usr/bin/env node
/**
 * rag-dedup-paths.mjs — 심볼릭 링크 경로 형태 중복 제거 (2026-06-25 [H3])
 *
 * 문제: ~/.jarvis → ~/.openclaw-data/runtime 심볼릭 링크 때문에 같은 물리 파일이
 *   '.jarvis'형 경로와 'runtime'형 경로 두 source 로 각각 인덱싱됨.
 *   rag-repair.mjs 는 source 문자열 literal 비교라 이 중복을 못 잡는다.
 *
 * 동작: source 를 정규화(.jarvis → runtime)한 뒤 같은 (정규화source, chunk_index)
 *   그룹에서 runtime형 1개를 보존하고 나머지를 soft-delete.
 *   soft-delete(deleted=true)라 compact 전까지 복구 가능 + 사전 백업 권장.
 *
 * Usage:
 *   BOT_HOME=$HOME/.openclaw-data/runtime JARVIS_RAG_HOME=$HOME/.openclaw-data/runtime/rag \
 *     node rag-dedup-paths.mjs [--dry-run] [--compact]
 *   --dry-run  : 삭제 없이 현황만
 *   --compact  : soft-delete 후 물리 compact (비가역, 검증 후 사용)
 */
import { readFileSync, writeFileSync, openSync, closeSync, unlinkSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { LANCEDB_PATH, RAG_HOME, RAG_WRITE_LOCK } from '../lib/paths.mjs';

const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const DO_COMPACT = args.includes('--compact');
const log = (...a) => console.log(`[rag-dedup-paths] ${a.join(' ')}`);

// 하드코딩 user-path 금지 + 토폴로지 가드 준수: homedir() 기반 조합
//
// 2026-09-10 개정 — 별칭이 둘에서 셋으로 늘었다.
//   오픈클로 이관으로 정본이 `~/.openclaw-data/runtime` 이 되면서
//   `~/.jarvis` · `~/.openclaw-data/runtime`(호환 심링크) · 정본, 세 표기가 같은 파일을 가리킨다.
//   전에는 `.jarvis` → `~/.openclaw-data/runtime` 한 방향만 접었기 때문에, 이관 뒤에는
//   호환 경로로 접어 놓고 정본형 사본을 중복으로 남기게 된다.
//   그래서 문자열 치환 대신 realpath 로 접는다 — 별칭이 몇 개로 늘든 한 곳으로 모인다.
const RUNTIME_REAL = (() => {
  // [회차8 2026-09-12] 런타임이 트리 밖으로 나갔다.
  try { return realpathSync(join(homedir(), '.openclaw-data', 'runtime')) + '/'; }
  catch { return join(homedir(), '.openclaw-data', 'runtime') + '/'; }
})();
const _normCache = new Map();
const norm = (s) => {
  if (typeof s !== 'string') return '';
  const hit = _normCache.get(s);
  if (hit !== undefined) return hit;
  let out = s;
  try {
    // 파일이 남아 있으면 realpath 가 정답이다.
    out = realpathSync(s);
  } catch {
    // 이미 지워진 파일은 realpath 가 안 된다 — 알려진 별칭 접두만 문자열로 접는다.
    // [회차8 2026-09-13] 죽은 경로 둘이 빠져 있었다. 실측 — 색인 11,419 중 7,468(65%)이
    //   옛 경로이고 그중 4,072 가 `~/jarvis/runtime/`, 3,387 이 `~/.openclaw-data/jarvis/runtime/` 다.
    //   두 자리 모두 지금은 **장벽 파일**이라 realpath 가 실패하고, 별칭 목록에 없으면
    //   접히지 않아 같은 문서가 옛/새 경로로 두 번 검색된다(실측: rag_search 1·2위가 동일 문서).
    //   DO-NOT-REWRITE: 아래는 *접어야 할 옛 경로 목록*이지 참조가 아니다. 일괄 치환 금지.
    for (const alias of [
      join(homedir(), ".jarvis") + "/",
      join(homedir(), "projects/jarvis", "runtime") + "/",
      join(homedir(), "jarvis", "runtime") + "/", //                  2026-09-10 폐기
      join(homedir(), ".openclaw-data", "jarvis", "runtime") + "/", // 2026-09-12 폐기
    ]) {
      if (s.startsWith(alias)) { out = RUNTIME_REAL + s.slice(alias.length); break; }
    }
  }
  _normCache.set(s, out);
  return out;
};

// [2026-07-22] write.lock 획득 — 인덱서(rag-index)·compact와 동시쓰기 충돌 방지.
//   배경: rag-system.md(RAG DB 2회 파기 이력) + 2026-07-22 dedup이 락 우회로 16:30 크론과 충돌한 사고.
//   soft-delete뿐이라 파기는 없었으나(LanceDB MVCC), 재발 방지로 인덱서와 동일 락 메커니즘 채택.
const _pidAlive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };
async function acquireWriteLock(timeoutMs = 60_000, pollMs = 500) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const fd = openSync(RAG_WRITE_LOCK, 'wx'); // 배타적 생성
      writeFileSync(fd, String(process.pid)); closeSync(fd);
      return true;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      let holder = 0;
      try { holder = parseInt(readFileSync(RAG_WRITE_LOCK, 'utf-8').trim(), 10); } catch { /* race ok */ }
      if (holder && !_pidAlive(holder)) { try { unlinkSync(RAG_WRITE_LOCK); } catch {} continue; } // stale 제거
      if (Date.now() > deadline) return false; // 살아있는 다른 writer — 타임아웃
      await new Promise((r) => setTimeout(r, pollMs));
    }
  }
}
const releaseWriteLock = () => { try { unlinkSync(RAG_WRITE_LOCK); } catch {} };

async function main() {
  log(`RAG_HOME=${RAG_HOME}`);
  log(`LANCEDB_PATH=${LANCEDB_PATH}`);
  const ldb = await import('@lancedb/lancedb');
  const db = await ldb.connect(LANCEDB_PATH);
  const t = await db.openTable('documents').catch(() => null);
  if (!t) { log('ERROR: documents 테이블 없음'); process.exit(1); }

  // [2026-07-22] 쓰기 전 write.lock 획득(dry-run 제외) — 인덱서와 직렬화. 실패 시 skip(충돌 방지).
  if (!DRY_RUN) {
    const locked = await acquireWriteLock();
    if (!locked) { log('write.lock 획득 실패 — 다른 프로세스가 쓰기 중(인덱서/compact). 이번 실행 skip.'); return; }
    process.on('exit', releaseWriteLock); // 정상·조기return·오류 어느 경로든 자동 해제
  }

  const total = await t.countRows();
  // 안전 가드: 경로 오인으로 빈 테이블을 건드리는 사고 방지
  if (total === 0) { log('ERROR: 활성 0행 — LANCEDB_PATH 의심(환경변수 BOT_HOME 확인). 중단.'); process.exit(1); }

  const rows = await t.query()
    .where('deleted IS NULL OR deleted = false')
    .select(['id', 'source', 'chunk_index'])
    .toArray();
  log(`전체 ${total}, 활성 ${rows.length}`);

  // 정규화 그룹: key → [{id, isJarvis}]
  const grp = new Map();
  for (const r of rows) {
    const s = typeof r.source === 'string' ? r.source : '';
    const n = norm(s);
    const k = n + '#' + Number(r.chunk_index);
    if (!grp.has(k)) grp.set(k, []);
    // 2026-09-10: 보존 기준을 '별칭 이름'이 아니라 '이미 정본형인가'로 바꿨다.
    //   전에는 `.jarvis` 포함 여부만 봤는데, 별칭이 셋이 되면서 그 판정으로는
    //   호환 경로(`~/.openclaw-data/runtime/...`)형을 정본으로 오인해 남긴다.
    grp.get(k).push({ id: r.id, isAlias: s !== n });
  }

  // 각 그룹: 정본형 1개 보존, 별칭형은 soft-delete 대상
  const toDelete = [];
  for (const [, arr] of grp) {
    if (arr.length <= 1) continue;
    arr.sort((a, b) => (a.isAlias ? 1 : 0) - (b.isAlias ? 1 : 0)); // 정본형 먼저(보존)
    for (const x of arr.slice(1)) toDelete.push(x.id);
  }
  log(`정규화 후 고유 청크 ${grp.size}, 제거 대상(중복) ${toDelete.length}`);

  if (DRY_RUN) { log('DRY-RUN — 삭제 없음'); return; }
  // 제거 대상 0이어도 --compact 면 물리 회수는 진행(이미 soft-delete 된 행 정리용)
  if (toDelete.length === 0 && !DO_COMPACT) { log('제거할 중복 없음'); return; }

  // 배치 soft-delete (id IN 절 1000개씩)
  let done = 0;
  for (let i = 0; i < toDelete.length; i += 1000) {
    const batch = toDelete.slice(i, i + 1000);
    const idList = batch.map((id) => `'${String(id).replace(/'/g, "''")}'`).join(', ');
    await t.update({ where: `id IN (${idList})`, values: { deleted: true, deleted_at: Date.now() } });
    done += batch.length;
    if (i % 10000 === 0) log(`  soft-delete 진행: ${done}/${toDelete.length}`);
  }
  log(`soft-delete 완료: ${done}개`);

  const afterActive = (await t.countRows()) - await t.countRows('deleted = true').catch(() => 0);
  log(`정리 후 활성: ${afterActive}`);

  if (DO_COMPACT) {
    log('compact 실행(물리 회수, 비가역)...');
    const { RAGEngine } = await import('../lib/rag-engine.mjs');
    const engine = new RAGEngine();
    await engine.init();
    await engine.compact();
    await engine.close();
    log('compact 완료');
  } else {
    log('compact 미실행(soft-delete 상태) — 검증 후 --compact 로 물리 회수 권장');
  }
}
main().catch((e) => { console.error('[rag-dedup-paths] FATAL:', e.message); process.exit(1); });
