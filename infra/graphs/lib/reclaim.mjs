// reclaim.mjs — 디스크 관문 자가 회복(10-05). 틱이 디스크 관문에 막히고 기다리는 일이 있을 때만 부른다.
// 치우는 일은 워크스페이스의 scripts/disk-reclaim.sh 하나가 한다 — 당직(disk.*)도 같은 도구를 쓴다(두 벌이 갈리지 않게).
//   다시 만들어지는 것만(flutter 빌드 산출물·옛 QA APK·uv/npm 캐시·랭그래프 시험 임시), 대화 작업·돌던 flutter 는 건너뛴다.
//   명령은 허용 목록 입구(run(cmdId))로만 — graphs.disk-reclaim (S10).
export function lastJson(text) {
  const lines = String(text ?? "").trim().split("\n");
  for (let i = lines.length - 1; i >= 0; i--) { try { return JSON.parse(lines[i]); } catch { /* 앞 줄로 */ } }
  return null;
}

export async function reclaimDisk(run) {
  try {
    const r = await run("graphs.disk-reclaim", {});
    const j = lastJson(r.stdout);
    return { ran: r.code === 0 && !!j?.ok && !j?.busy, code: r.code ?? null, busy: !!j?.busy,
      free_before: j?.free_before ?? null, free_after: j?.free_after ?? null, steps: j?.steps ?? [] };
  } catch (e) { // 허용 목록에 없거나 스크립트가 없음 — 틱은 멈추지 않고 기록만
    return { ran: false, error: String(e?.message ?? e).split("\n")[0].slice(0, 200) };
  }
}
