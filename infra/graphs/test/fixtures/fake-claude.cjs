// fake-claude.cjs — 시험용 가짜 claude. 실제 모델을 부르지 않는다.
// helpers.fakeClaude() 가 만든 실행 파일(#!node, 셸 없음)이 require 해서 부른다 — 셸이 끼면 PWD·SHLVL 이 더해져 환경 시험이 흐려진다.
// 받은 인자·환경·입력·작업 폴더를 log 에 적고, mode(ok | fable | fail)에 따라 답한다.
const fs = require("node:fs");

module.exports = function fake(log, mode) {
  const env = { ...process.env };
  const input = fs.readFileSync(0, "utf8");
  fs.appendFileSync(log, `${JSON.stringify({ args: process.argv.slice(2), env, cwd: process.cwd(), input })}\n`);
  if (mode === "fail") {
    process.stderr.write("가짜 실패: 인증 오류 흉내\n");
    process.exit(1);
  }
  const model = mode === "fable" ? "claude-fable-5-1" : "claude-haiku-4-5-20251001";
  const body = JSON.stringify({
    type: "result", subtype: "success", is_error: false, result: mode === "split" ? "한글이 조각 경계에 걸린다" : "가짜 요약 문장",
    modelUsage: { [model]: { inputTokens: 1, outputTokens: 1 } }, total_cost_usd: 0, duration_ms: 1,
  });
  if (mode === "split") { // '글' 의 3바이트 한가운데서 끊어 두 번에 나눠 보낸다
    const buf = Buffer.from(body);
    const cut = buf.indexOf(Buffer.from("글")) + 1;
    fs.writeSync(1, buf.subarray(0, cut));
    setTimeout(() => fs.writeSync(1, buf.subarray(cut)), 150);
    return;
  }
  process.stdout.write(body);
};
