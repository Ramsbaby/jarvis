// effects.mjs — 부수효과는 effect(key, kind, fn) 하나로만 낸다(S10). 원장은 추가 전용 effects.jsonl.
// - 그림자 모드: {key, kind, wouldRun} 만 적고 fn 을 부르지 않는다. 단 보고성 종류(REPORT_KINDS)는 그림자에서도 실제로 낸다 —
//   그림자가 막는 것은 코드 변경·배포이지 발견을 알리는 일이 아니다(10-06: QA 발견 9건이 '했을 일'로만 남아 수리 목록에 0건).
// - 실제 모드: 같은 key 가 성공(ok)으로 적혀 있으면 다시 부르지 않는다. 시작(started)만 있고 끝이 없으면(도중에 죽음)
//   결과를 모르니 다시 부르지 않고 보류한다 — verify() 를 주면 그것으로 실제로 일어났는지 확인해 이어 간다.
// - 같은 key 를 두 프로세스가 동시에 내지 않게 key 별 잠금(폴더 만들기 — 원자적)을 쓴다. 죽은 주인의 잠금만 넘겨받는다.
// lib/run.mjs 는 허용 목록에서 effect:true 로 표시된 명령을 이 함수 안(fn 실행 중)에서만 돌린다(AsyncLocalStorage 로 확인).
import { AsyncLocalStorage } from "node:async_hooks";
import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { iso } from "./config.mjs";
import { pidAlive, procStart } from "./store.mjs";
import { readJsonl } from "./metrics.mjs";

export const effectScope = new AsyncLocalStorage();
// metrics(30일 보존)에는 key 원문 대신 지문만 — 원문은 부수효과 원장(effects.jsonl)에만 둔다(S4)
const keyHash = (key) => createHash("sha1").update(key).digest("hex").slice(0, 12);

// 보고성 부수효과 — 우리 쪽 글(지시함 한 줄)만. 실제 모드와 같은 길(잠금·started/ok·같은 key 한 번)로 낸다.
// 당직 장부(duty.ledger_append)는 공사 동결이라 넣지 않는다(PLAN §13 D1 결재 뒤).
export const REPORT_KINDS = new Set(["orders_append"]);
// 실제로 일어난 기록(started·ok·failed·cleared) — 그림자 '했을 일'(would_run)은 실행을 막지 않는다
const isReal = (r) => r.status !== "would_run";

const KEY_RE = /^[^\n\r]{1,200}$/;
const KIND_RE = /^[a-z][a-z0-9_.-]{0,40}$/;

export class EffectHeld extends Error {
  constructor(msg) { super(msg); this.name = "EffectHeld"; this.held = true; this.holdReason = "effect_unknown"; }
}

const MY_START = procStart(process.pid);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// key 별 잠금: <locks>/<sha1(key)>/owner.json. 이미 있으면 주인이 살아 있는지 보고, 죽었으면 무덤 이름으로 옮긴 뒤(원자적) 다시 만든다.
async function lockKey(dir, waitMs = 10_000) {
  fs.mkdirSync(path.dirname(dir), { recursive: true, mode: 0o700 });
  const end = Date.now() + waitMs;
  for (;;) {
    try {
      fs.mkdirSync(dir, { mode: 0o700 });
      fs.writeFileSync(path.join(dir, "owner.json"), JSON.stringify({ pid: process.pid, pstart: MY_START }), { mode: 0o600 });
      return () => fs.rmSync(dir, { recursive: true, force: true });
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
    }
    let owner = null;
    try { owner = JSON.parse(fs.readFileSync(path.join(dir, "owner.json"), "utf8")); } catch { /* 막 만들어지는 중이거나 깨짐 */ }
    // 주인이 죽었을 때만 넘겨받는다. 시작 시각을 못 읽으면(ps 실패) 살아 있다고 본다(S1 과 같게)
    let dead = false;
    if (owner) {
      if (!pidAlive(owner.pid)) dead = true;
      else if (owner.pstart) { const cur = procStart(owner.pid); dead = cur != null && cur !== owner.pstart; }
    }
    const orphan = !owner && Date.now() - (fs.statSync(dir, { throwIfNoEntry: false })?.mtimeMs ?? Date.now()) > 30_000;
    if (dead || orphan) {
      try { fs.renameSync(dir, `${dir}.dead-${randomUUID()}`); } catch { /* 다른 쪽이 먼저 옮김 */ }
      continue;
    }
    if (Date.now() > end) throw Object.assign(new Error("같은 부수효과 key 를 다른 프로세스가 내는 중 — 다음 틱에"), { pending: true });
    await sleep(100);
  }
}

function keyRecords(file, key) {
  return readJsonl(file).filter((r) => r.key === key);
}

// 스레드 하나에 묶인 effect(). mode 는 스레드 시작 때 고정한 값이다.
export function createEffect({ cfg, now, thread, mode, metric, nodeRef = () => null }) {
  const file = cfg.effectsPath;
  const append = (rec) => {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const t = now();
    fs.appendFileSync(file, `${JSON.stringify({ ts: iso(t), t, thread, node: nodeRef(), mode, ...rec })}\n`, { mode: 0o600 });
  };
  return async function effect(key, kind, fn, { verify } = {}) {
    if (typeof key !== "string" || !KEY_RE.test(key)) throw new TypeError(`effect key 는 줄바꿈 없는 1~200자 글자: ${JSON.stringify(key)}`);
    if (typeof kind !== "string" || !KIND_RE.test(kind)) throw new TypeError(`effect kind 는 소문자 낱말: ${JSON.stringify(kind)}`);
    if (typeof fn !== "function") throw new TypeError("effect 의 세 번째 인자는 함수");
    const report = mode !== "live" && REPORT_KINDS.has(kind); // 그림자 스레드의 보고성 부수효과 — 실제로 낸다
    if (mode !== "live" && !report) {
      // 그림자: 했을 일만 적는다. 같은 key 를 다시 만나면(재시도·재개) 줄을 더하지 않는다.
      const seen = keyRecords(file, key).some((r) => r.status === "would_run");
      if (!seen) append({ key, kind, status: "would_run", wouldRun: true });
      metric?.("effect", { thread, key: keyHash(key), kind, mode, outcome: seen ? "would_run_dup" : "would_run" });
      return { ran: false, shadow: true };
    }
    // 실제 길(실제 모드 또는 보고성). 그림자 스레드의 보고성 기록에는 report:true 를 붙인다 — 원장·기록에서 그림자 실행을 가려 볼 수 있게
    const tag = report ? { report: true } : {};
    const put = (rec) => append({ ...rec, ...tag });
    const note = (outcome) => metric?.("effect", { thread, key: keyHash(key), kind, mode, outcome, ...tag });
    const lockDir = path.join(cfg.stateDir, "effect-locks", createHash("sha1").update(key).digest("hex"));
    const unlock = await lockKey(lockDir);
    try {
      // 같은 key 의 실제 기록이면 모드를 가리지 않는다 — 그림자 스레드가 이미 올린 지시함 줄을 실제 스레드가 다시 올리지 않게
      const recs = keyRecords(file, key).filter(isReal);
      const last = recs.at(-1);
      if (recs.some((r) => r.status === "ok")) {
        note("dedup");
        return { ran: false, dedup: true, ...tag };
      }
      if (last?.status === "started") {
        // 시작만 적히고 끝이 없다 — 일어났는지 모른다. 다시 내면 두 번 일어날 수 있다.
        const done = verify ? await verify() : undefined;
        if (done === true) {
          put({ key, kind, status: "ok", recovered: true });
          note("recovered");
          return { ran: false, recovered: true, ...tag };
        }
        if (done !== false) {
          note("unknown");
          throw new EffectHeld(`부수효과 ${kind} '${key}' 가 시작만 되고 결과가 없다 — 실제로 일어났는지 확인 전에는 다시 내지 않는다`);
        }
        put({ key, kind, status: "cleared", verified: false }); // verify 가 '안 일어났다'고 확인 — 다음 시작은 정당한 재실행(M3 가 중복으로 세지 않게)
      }
      put({ key, kind, status: "started" });
      let value;
      try {
        value = await effectScope.run({ key, kind, thread }, fn);
      } catch (e) {
        put({ key, kind, status: "failed", error: String(e?.message ?? e).split("\n")[0].slice(0, 200) });
        note("failed");
        throw e;
      }
      put({ key, kind, status: "ok" });
      note("ran");
      return { ran: true, value, ...tag };
    } finally {
      unlock();
    }
  };
}
