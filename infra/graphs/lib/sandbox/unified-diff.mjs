// unified-diff.mjs — 통합 diff(diff -u·diff -ruN·git diff) 해석. patch-allowlist·coverage-check 가 함께 쓴다.
// 덩어리(hunk)는 머리(@@ -a,b +c,d @@)의 줄 수만큼 읽는다 — 지운 줄 내용이 '-- x' 이면 본문에 '--- x' 로 보이므로
// '---' 를 보고 새 파일로 넘어가면 틀린다.
const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

const cleanPath = (p) => {
  const s = p.replace(/\t.*$/, "").trim(); // diff -u 는 경로 뒤에 탭 + 시각을 붙인다
  if (s === "/dev/null") return null;
  return s.replace(/^[ab]\//, "");
};

// → [{ path, oldPath, newPath, status: added|deleted|modified, hunks: [{ oldStart, oldLines, newStart, newLines, lines: [{ t, s, oldNo, newNo }] }] }]
export function parseUnifiedDiff(text) {
  const lines = String(text ?? "").split("\n");
  const files = [];
  let i = 0;
  while (i < lines.length) {
    if (!(lines[i].startsWith("--- ") && lines[i + 1]?.startsWith("+++ "))) { i++; continue; }
    const oldPath = cleanPath(lines[i].slice(4));
    const newPath = cleanPath(lines[i + 1].slice(4));
    const f = { oldPath, newPath, path: newPath ?? oldPath, status: oldPath === null ? "added" : newPath === null ? "deleted" : "modified", hunks: [] };
    files.push(f);
    i += 2;
    for (;;) {
      const m = HUNK.exec(lines[i] ?? "");
      if (!m) break;
      const h = { oldStart: Number(m[1]), oldLines: m[2] === undefined ? 1 : Number(m[2]), newStart: Number(m[3]), newLines: m[4] === undefined ? 1 : Number(m[4]), lines: [] };
      f.hunks.push(h);
      i++;
      let o = h.oldStart, n = h.newStart, oLeft = h.oldLines, nLeft = h.newLines;
      while ((oLeft > 0 || nLeft > 0) && i < lines.length) {
        const l = lines[i];
        if (l.startsWith("\\")) { i++; continue; } // \ No newline at end of file
        const t = l[0] ?? " ";
        // 머리의 줄 수를 넘는 줄은 이 덩어리 것이 아니다(잘못된 패치) — 다음 파일 머리를 본문으로 먹지 않게 멈춘다
        if ((t === "-" && oLeft <= 0) || (t === "+" && nLeft <= 0) || (t !== "-" && t !== "+" && (oLeft <= 0 || nLeft <= 0))) break;
        if (t === "+") { h.lines.push({ t, s: l.slice(1), oldNo: null, newNo: n++ }); nLeft--; }
        else if (t === "-") { h.lines.push({ t, s: l.slice(1), oldNo: o++, newNo: null }); oLeft--; }
        else { h.lines.push({ t: " ", s: l.slice(1), oldNo: o++, newNo: n++ }); oLeft--; nLeft--; }
        i++;
      }
      while (lines[i]?.startsWith("\\")) i++;
    }
  }
  return files;
}
