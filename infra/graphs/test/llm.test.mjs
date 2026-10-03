// llm.test.mjs — 실제 claude(haiku) 1회 호출. 기본은 건너뛴다. RUN_LLM=1 일 때만 돈다(구독 한도를 쓴다).
// 상태는 임시 폴더, claude 는 이 맥의 로그인(진짜 홈)으로 뜬다 — 키·토큰은 다루지 않는다.
import { test } from "node:test";
import assert from "node:assert/strict";
import { sandbox, run, counts, statusJson } from "./helpers.mjs";

test("실제 haiku 1회: think 가 LLM 초안을 만들고 승인 뒤 끝난다", { skip: process.env.RUN_LLM !== "1" && "RUN_LLM=1 일 때만 돈다" }, (t) => {
  const sb = sandbox(t);
  const r = run(sb.env, ["start", "smoke", "llm1", "--llm", "--topic", "랭그래프 실행기 연기 시험"], { timeout: 180_000 });
  assert.equal(r.code, 0, r.out + r.err);
  assert.match(r.first, /^WAITING llm1 .*초안: \S/);
  assert.equal(statusJson(sb).llm.today, 1, "LLM 은 정확히 1회");
  const done = run(sb.env, ["resume", "llm1", "approved"]);
  assert.equal(done.code, 0, done.out + done.err);
  assert.match(done.first, /^DONE llm1 완료 — \S/);
  assert.deepEqual(counts(sb), { collect: 1, think: 1, finalize: 1 }, "재개는 LLM 을 다시 부르지 않는다");
  t.diagnostic(r.first);
});
