// smoke.mjs — 연기 시험 그래프: collect → think → approve(interrupt) → finalize
// 실행기·저장·고장 뒤 재개·승인 대기·기한 만료가 실제로 도는지 보는 용도다. 운영 작업은 하지 않는다.
// 규칙: interrupt 가 든 노드(approve)는 동기·순수다 — 재개 때 처음부터 다시 돌기 때문(위험 5). scripts/check-interrupt-nodes.mjs 가 검사한다.
import fs from "node:fs";
import { StateGraph, Annotation, START, END, interrupt } from "@langchain/langgraph";

export const meta = { name: "smoke", description: "실행 뼈대 연기 시험(LLM 은 --llm 일 때만 haiku 1회)" };

const State = Annotation.Root({
  topic: Annotation(),
  useLlm: Annotation(),
  items: Annotation(),
  draft: Annotation(),
  decision: Annotation(),
  result: Annotation(),
  log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }),
});

// start 인자 → 첫 상태
export function input(flags) {
  return { topic: String(flags.topic ?? "연기 시험").slice(0, 200), useLlm: flags.llm === true };
}

export const summarize = (values) => String(values.result ?? "");

// 시험용 관찰·고장 주입 — 시험 모드(LG_TEST_MODE=1)에서만, 변수가 있을 때만 움직인다
const testMode = process.env.LG_TEST_MODE === "1";
function trace(node) {
  const f = testMode && process.env.LG_SMOKE_TRACE;
  if (f) fs.appendFileSync(f, `${process.pid} ${node}\n`);
}
function crashOnce() {
  const marker = testMode && process.env.LG_SMOKE_CRASH_ONCE;
  if (marker && !fs.existsSync(marker)) { fs.writeFileSync(marker, "x"); process.exit(Number(process.env.LG_SMOKE_CRASH_CODE ?? 1)); }
}

export function build({ checkpointer, llm }) {
  return new StateGraph(State)
    .addNode("collect", (s) => {
      trace("collect");
      return { items: [`${s.topic}-1`, `${s.topic}-2`], log: ["collect"] };
    })
    .addNode("think", async (s) => {
      trace("think");
      crashOnce();
      const draft = s.useLlm
        ? (await llm.ask(`다음 두 항목을 한국어 한 문장으로 요약하라. 요약문만 답하라: ${s.items.join(", ")}`, { model: "haiku", node: "think" })).text
        : `요약: ${s.items.join(", ")}`;
      return { draft: String(draft).trim().slice(0, 500), log: ["think"] };
    })
    .addNode("approve", (s) => {
      const decision = interrupt({ question: "이 초안으로 마무리할까요?", draft: s.draft });
      return { decision, log: [`approve:${decision}`] };
    })
    .addNode("finalize", (s) => {
      trace("finalize");
      return { result: s.decision === "approved" ? `완료 — ${s.draft}` : "반려됨", log: ["finalize"] };
    })
    .addEdge(START, "collect")
    .addEdge("collect", "think")
    .addEdge("think", "approve")
    .addEdge("approve", "finalize")
    .addEdge("finalize", END)
    .compile({ checkpointer });
}
