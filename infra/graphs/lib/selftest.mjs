// selftest.mjs — 네이티브 저장 부품(better-sqlite3)이 실제로 뜨는지 메모리 DB 로 확인한다.
// 설치 스크립트가 건너뛰어지면 설치는 성공(코드 0)인데 실행 때 bindings 오류로 죽는다(위험 6). 조용히 죽지 않게 원인을 이름 붙여 돌려준다.
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
