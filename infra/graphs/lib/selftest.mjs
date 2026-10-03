// selftest.mjs — 네이티브 저장 부품(better-sqlite3)이 실제로 뜨는지 메모리 DB 로 확인한다.
// 설치 스크립트가 건너뛰어지면 설치는 성공(코드 0)인데 실행 때 bindings 오류로 죽는다(위험 6). 조용히 죽지 않게 원인을 이름 붙여 돌려준다.
// hookLeak: 사용자 훅 로그에 graphs 쪽 claude 호출 흔적(작업 폴더 경로)이 0 줄인지 본다(S6) — 클로드 판이 오르며 --restricted 의
//   '설정·훅 무시'가 바뀌면 훅이 다시 돌아 위키·RAG 를 더럽힌다(위험 8). 줄이 있으면 사람이 볼 때까지 틱을 멈춘다.
import fs from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

function hintFor(msg) {
  if (/NODE_MODULE_VERSION|compiled against a different Node/i.test(msg))
    return "Node 주 버전이 바뀌었다 — 고정 Node 로 실행하거나 그 Node 로 npm rebuild better-sqlite3";
  if (/bindings file|Cannot find module|MODULE_NOT_FOUND/i.test(msg))
    return "설치 스크립트가 건너뛰어졌다 — npm install-scripts approve better-sqlite3 후 npm rebuild better-sqlite3 (또는 install.sh)";
  return "install.sh 를 다시 돌린다";
}

export function selftest() {
  try {
    const Database = require("better-sqlite3");
    const db = new Database(":memory:");
    const sqlite = db.prepare("select sqlite_version() as v").get().v;
    db.pragma("secure_delete=ON");
    const secureDelete = db.pragma("secure_delete", { simple: true });
    db.close();
    if (secureDelete !== 1) return { ok: false, what: "secure_delete 를 켜지 못함", msg: String(secureDelete), hint: "SQLite 빌드를 확인한다" };
    return { ok: true, sqlite, node: process.version };
  } catch (e) {
    const msg = String(e?.message ?? e).split("\n")[0].slice(0, 240);
    return { ok: false, what: "better-sqlite3 적재 실패", msg, hint: hintFor(String(e?.message ?? e)) };
  }
}

// 훅 로그 끝(512KB)에서 graphs 의 claude 작업 폴더 표식을 찾는다. 표식: 기본 작업 폴더 이름(lg-claude-cwd)·상태 폴더 경로·고스톱 사본 자리.
const MARKS = (cfg) => ["lg-claude-cwd", cfg.stateDir, "/graphs/gostop/sandbox/"];
export function hookLeak(cfg) {
  let checked = 0;
  for (const f of cfg.hookLogs ?? []) {
    let fd;
    try { fd = fs.openSync(f, "r"); } catch { continue; } // 없는 로그는 건너뛴다(훅이 없으면 로그도 없다)
    try {
      checked++;
      const size = fs.fstatSync(fd).size;
      const len = Math.min(size, 512 * 1024);
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, size - len);
      const hits = buf.toString("utf8").split("\n").filter((l) => MARKS(cfg).some((m) => m && l.includes(m)));
      if (hits.length) {
        return { ok: false, checked, msg: `사용자 훅 로그 ${f} 에 graphs 쪽 claude 호출 흔적 ${hits.length}줄 — 훅이 되살아났다(클로드 판 변경?). 격리 플래그를 다시 실측하기 전에는 틱을 돌리지 않는다: ${hits[0].slice(0, 160)}` };
      }
    } finally { fs.closeSync(fd); }
  }
  return { ok: true, checked };
}
