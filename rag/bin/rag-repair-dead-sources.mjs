#!/usr/bin/env node
/**
 * rag-repair-dead-sources.mjs — 회차8 이관으로 죽은 경로를 들고 있는 RAG 청크를 고친다.
 *
 * 배경(2026-09-13 실측): `rag-dedup-paths.mjs` 로 경로 중복 77,750청크를 접은 뒤에도
 *   활성 123,396 중 **27,974(22.7%)** 가 여전히 옛 경로를 source 로 들고 있었다.
 *   dedup 은 "같은 문서가 두 경로로 색인된 것"만 접는다 — 짝이 없는 것은 그대로 남는다.
 *
 * 둘로 갈린다. 처방이 다르다.
 *   ① 새 경로에 원문이 **있는** 것 → source 문자열만 고치면 `rag_get` 이 다시 열린다.
 *   ② 원문이 **없는** 것(고아) → 열 수 없다. 검색 결과 자리만 차지하는 소음이다.
 *      실측상 대부분은 같은 대화가 새 id 로 다시 수집된 **낡은 사본**이다
 *      (예: claude-cli-2026-08-06-e8352e29.md 는 사라지고 …-241bb231.md 가 같은 내용을 담고 있다).
 *
 * 안전:
 *   - 삭제는 전부 **soft-delete**(`deleted=true`)다. compact 전까지 되돌릴 수 있다.
 *   - 인덱서·compact 와 같은 write.lock 을 잡는다(2026-07-22 동시쓰기 사고).
 *   - `--dry-run` 이 기본 권장. 실제 변경은 명시 플래그가 있어야 한다.
 *   - 활성 0행이면 즉시 중단한다(경로 오인으로 빈 테이블을 건드리는 사고 방지).
 *
 * 사용:
 *   BOT_HOME=$HOME/.openclaw-data/runtime node rag-repair-dead-sources.mjs --dry-run
 *   BOT_HOME=$HOME/.openclaw-data/runtime node rag-repair-dead-sources.mjs --fix-paths
 *   BOT_HOME=$HOME/.openclaw-data/runtime node rag-repair-dead-sources.mjs --drop-orphans
 */
import { existsSync, openSync, writeFileSync, closeSync, unlinkSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const DRY_RUN = args.includes("--dry-run") || (!args.includes("--fix-paths") && !args.includes("--drop-orphans"));
const FIX_PATHS = args.includes("--fix-paths");
const DROP_ORPHANS = args.includes("--drop-orphans");

const HOME = homedir();
const RUNTIME = process.env.BOT_HOME || join(HOME, ".openclaw-data", "runtime");
const LANCEDB_PATH = join(RUNTIME, "rag", "lancedb");
const WRITE_LOCK = join(RUNTIME, "rag", "write.lock");

const log = (...a) => console.log(`[rag-repair] ${a.join(" ")}`);

// DO-NOT-REWRITE: 아래는 *접어야 할 옛 경로 목록*이지 참조가 아니다. 일괄 치환 금지.
const MAP = [
  [join(HOME, "jarvis", "runtime") + "/", join(HOME, ".openclaw-data", "runtime") + "/"],
  [join(HOME, ".openclaw-data", "jarvis", "runtime") + "/", join(HOME, ".openclaw-data", "runtime") + "/"],
  [join(HOME, "jarvis") + "/", join(HOME, "projects", "jarvis") + "/"],
  [join(HOME, ".openclaw-data", "jarvis") + "/", join(HOME, "projects", "jarvis") + "/"],
];
const DEAD_PREFIXES = [join(HOME, "jarvis") + "/", join(HOME, ".openclaw-data", "jarvis") + "/"];
const isDead = (s) => typeof s === "string" && DEAD_PREFIXES.some((p) => s.startsWith(p));
const toLive = (s) => {
  for (const [a, b] of MAP) if (s.startsWith(a)) return b + s.slice(a.length);
  return s;
};

const pidAlive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
async function acquireWriteLock(timeoutMs = 60_000, pollMs = 500) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const fd = openSync(WRITE_LOCK, "wx");
      writeFileSync(fd, String(process.pid)); closeSync(fd);
      return true;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      let holder = 0;
      try { holder = parseInt(readFileSync(WRITE_LOCK, "utf-8").trim(), 10); } catch { /* race ok */ }
      if (holder && !pidAlive(holder)) { try { unlinkSync(WRITE_LOCK); } catch {} continue; }
      if (Date.now() > deadline) return false;
      await new Promise((r) => setTimeout(r, pollMs));
    }
  }
}
const releaseWriteLock = () => { try { unlinkSync(WRITE_LOCK); } catch {} };

async function main() {
  log(`LANCEDB_PATH=${LANCEDB_PATH}`);
  if (!existsSync(LANCEDB_PATH)) { log("ERROR: lancedb 없음 — BOT_HOME 확인. 중단."); process.exit(2); }

  const ldb = await import("@lancedb/lancedb");
  const db = await ldb.connect(LANCEDB_PATH);
  const t = await db.openTable("documents").catch(() => null);
  if (!t) { log("ERROR: documents 테이블 없음"); process.exit(2); }

  if (!DRY_RUN) {
    const locked = await acquireWriteLock();
    if (!locked) { log("write.lock 획득 실패 — 다른 프로세스가 쓰기 중. 이번 실행 skip."); return; }
    process.on("exit", releaseWriteLock);
  }

  const rows = await t.query()
    .where("deleted IS NULL OR deleted = false")
    .select(["id", "source"])
    .toArray();
  if (rows.length === 0) { log("ERROR: 활성 0행 — 경로 의심. 중단."); process.exit(2); }

  const fixable = [];   // {id, from, to}
  const orphans = [];   // id
  const fixFiles = new Set();
  const orphanFiles = new Set();
  for (const r of rows) {
    const s = r.source;
    if (!isDead(s)) continue;
    const n = toLive(s);
    if (existsSync(n)) { fixable.push({ id: r.id, to: n }); fixFiles.add(n); }
    else { orphans.push(r.id); orphanFiles.add(s); }
  }

  log(`활성 ${rows.length} · 옛 경로 ${fixable.length + orphans.length}`);
  log(`  ├ 경로 교정 가능 : ${fixable.length}청크 / ${fixFiles.size}파일`);
  log(`  └ 고아(원문 없음): ${orphans.length}청크 / ${orphanFiles.size}파일`);

  if (DRY_RUN) { log("DRY-RUN — 아무것도 바꾸지 않았다."); return; }

  if (FIX_PATHS && fixable.length > 0) {
    // 같은 목적지끼리 묶어 한 번에 update — id 개별 update 는 2,946회 왕복이라 느리다.
    const byTarget = new Map();
    for (const f of fixable) {
      if (!byTarget.has(f.to)) byTarget.set(f.to, []);
      byTarget.get(f.to).push(f.id);
    }
    let done = 0, n = 0;
    for (const [to, ids] of byTarget) {
      for (let i = 0; i < ids.length; i += 500) {
        const batch = ids.slice(i, i + 500);
        const idList = batch.map((id) => `'${String(id).replace(/'/g, "''")}'`).join(", ");
        await t.update({ where: `id IN (${idList})`, values: { source: to } });
        done += batch.length;
      }
      if (++n % 50 === 0) log(`  경로 교정 진행: ${done}/${fixable.length}`);
    }
    log(`경로 교정 완료: ${done}청크 / ${byTarget.size}파일`);
  }

  if (DROP_ORPHANS && orphans.length > 0) {
    let done = 0;
    for (let i = 0; i < orphans.length; i += 1000) {
      const batch = orphans.slice(i, i + 1000);
      const idList = batch.map((id) => `'${String(id).replace(/'/g, "''")}'`).join(", ");
      await t.update({ where: `id IN (${idList})`, values: { deleted: true, deleted_at: Date.now() } });
      done += batch.length;
      if (i % 10000 === 0) log(`  고아 soft-delete 진행: ${done}/${orphans.length}`);
    }
    log(`고아 soft-delete 완료: ${done}청크 (compact 전까지 복구 가능)`);
  }

  const after = await t.query().where("deleted IS NULL OR deleted = false").select(["id"]).toArray();
  log(`정리 후 활성: ${after.length}`);
}

main().catch((e) => { console.error("[rag-repair] FATAL:", e.message); process.exit(1); });
