// lg-report M7 — 주인님이 먼저 찾은 루프 고장을 당직 장부에서 센다(10-05: 손으로 세던 정의가 graphs.* 를 빠뜨렸다).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { sandbox, ROOT, NODE } from "./helpers.mjs";

test("M7: lg.·graphs. 키의 주인님 발견만, 같은 날·같은 키는 한 사건, 범위 밖·당직 발견·다른 키는 빼고, 장부가 없으면 오류 칸", (t) => {
  const sb = sandbox(t);
  const ledger = path.join(sb.dir, "ledger.jsonl");
  const rows = [
    { ts: "2026-10-05T10:50:52+09:00", key: "graphs.gostop-qa.disk_hold", found_by: "owner", item: "QA 디스크 보류" },
    { ts: "2026-10-05T11:09:36+09:00", key: "graphs.gostop-qa.disk_hold", found_by: "owner", item: "원인 규명" },
    { ts: "2026-10-05T12:00:00+09:00", key: "lg.tick", found_by: "owner", item: "틱 고장" },
    { ts: "2026-10-05T13:00:00+09:00", key: "graphs.x", found_by: "jarvis", item: "자가 발견" },
    { ts: "2026-10-05T14:00:00+09:00", key: "disk.policy", found_by: "owner", item: "다른 영역" },
    { ts: "2026-09-30T09:00:00+09:00", key: "lg.old", found_by: "owner", item: "범위 밖" },
  ];
  fs.writeFileSync(ledger, `${rows.map((r) => JSON.stringify(r)).join("\n")}\n{깨진 줄\n`);
  const rep = (env, extra = []) => JSON.parse(spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--json", ...extra], { env: { ...sb.env, ...env }, encoding: "utf8" }).stdout).m7;
  const m7 = rep({ LG_LEDGER: ledger }, ["--since", "2026-10-04"]);
  assert.equal(m7.lines, 3);
  assert.deepEqual(m7.incidents.map((x) => x.key), ["graphs.gostop-qa.disk_hold", "lg.tick"]);
  assert.equal(rep({ LG_LEDGER: ledger }).incidents.length, 3, "범위를 안 주면 옛 사건도 센다");
  assert.match(rep({ LG_LEDGER: path.join(sb.dir, "none.jsonl") }).error, /장부를 못 읽음/);
});
