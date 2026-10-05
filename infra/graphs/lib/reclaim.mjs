// reclaim.mjs — 디스크 관문 자가 회복(10-05). 틱이 디스크 관문에 막히고 기다리는 일이 있을 때만 부른다.
// 다시 만들 수 있는 것만, 그 도구 자신의 정리 명령으로 치운다 — flutter 저장소의 build/ 를 `flutter clean` 으로.
//   왜 trash 가 아닌가: 휴지통은 같은 디스크라 공간이 생기지 않는다. 정리 명령은 그 도구가 다음 빌드에서 다시 만드는 것만 지운다.
//   건너뛰는 때: 대화 작업 표식(.jarvis-busy)이 있거나 어디서든 flutter 가 돌고 있으면(빌드·시험 도중 산출물을 지우지 않게).
//   명령은 허용 목록 입구(run(cmdId))로만 — graphs.flutter-running · graphs.flutter-clean (S10).
import fs from "node:fs";
import path from "node:path";

export async function reclaimDisk(g, run) {
  const dirs = [];
  for (const dir of g.reclaimFlutterDirs ?? []) {
    if (!fs.existsSync(path.join(dir, "build"))) continue;
    if (fs.existsSync(path.join(dir, ".jarvis-busy"))) { dirs.push({ dir, skip: "busy" }); continue; }
    try {
      if ((await run("graphs.flutter-running", {})).code === 0) { dirs.push({ dir, skip: "flutter_running" }); continue; }
      const r = await run("graphs.flutter-clean", { repo: dir });
      dirs.push({ dir, ok: r.code === 0, code: r.code ?? null });
    } catch (e) { // 허용 목록에 없거나 경로 검사에 걸림 — 틱은 멈추지 않고 기록만
      dirs.push({ dir, skip: "error", error: String(e?.message ?? e).split("\n")[0].slice(0, 200) });
    }
  }
  return { ran: dirs.some((x) => x.ok), dirs };
}
