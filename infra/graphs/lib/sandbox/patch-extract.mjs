#!/usr/bin/env node
// patch-extract.mjs — 사본에서 정본 패치를 뽑는다(설계 §2 · §5.2⑨ · L2 위험 A). git 을 쓰지 않는다.
//
//   node patch-extract.mjs --clean <깨끗한 내보내기> --copy <사본> [--out <패치 파일>] [--max-bytes N] [--max-files N]
//   → 표준 출력에 JSON 한 줄: {ok, reason?, detail?, files:[{path,status,added,removed}], bytes, sha256}
//     (--out 이 있으면 패치 본문은 그 파일에, 없으면 JSON 의 patch 칸에). ok:false 면 종료 코드 3, 사용 오류는 2.
//
// 왜 git 이 아니라 diff 인가: 격리 안 코드가 사본 .git/config 에 fsmonitor·훅을 심으면 밖에서 도는 git 이 그걸 실행한다(L2 실증).
// 왜 'diff -ruN 내보내기 사본' 한 방이 아니라 파일 단위인가(10-03 실측): 맥 diff -r 은 바로가기를 따라가 밖 파일 내용을 패치에 넣는다
//   (사본 안 `x -> ~/.ssh/id_rsa` 면 비밀이 패치로 샌다). 또 -x 는 아무 깊이의 같은 이름을 다 빼서 lib/**/build/ 의 변경을 숨긴다.
//   그래서 나무를 lstat 으로 직접 훑어(따라가지 않음) 바뀐 일반 파일만 고르고, 그 파일들만 `diff -u` 로 비교해 이어 붙인다.
//   결과 형식은 diff -ruN 과 같다(파일마다 `diff -ruN a/… b/…` 머리 + `--- a/…` `+++ b/…`, 새 파일·지운 파일은 /dev/null).
//
// 얼리기(기본 켬): 추출하는 동안 사본 폴더 이름을 잠시 바꾼다. 격리 규칙은 경로 기준이라, 시험이 몰래 남겨 둔 프로세스가
//   있어도 그 순간부터 사본에 쓰지 못한다(실측: 절대·상대 경로 모두 막힘) — 훑은 뒤 파일을 바로가기로 바꿔치기하는 경쟁을 막는다.
//   그 사이 옛 이름에 폴더가 다시 생기면 남은 프로세스가 있다는 증거다 → lingering_writer 로 거부하고 그 폴더는 옆으로 치운다.
//
// 거부(ok:false, 패치 없음): symlink(바로가기 추가·변경·삭제) · special_file(FIFO·소켓·장치) · hardlink · bad_path(.git 경로 성분·
//   제어 문자·역슬래시) · binary(NUL 바이트) · too_large(파일·패치 크기) · too_many_files · lingering_writer · diff_failed.
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const DIFF = "/usr/bin/diff";
// 맨 위에서만 늘 뺀다(양쪽 다). 더 깊은 같은 이름은 빼지 않는다 — 변경을 숨기는 통로가 된다.
export const SKIP_TOP = new Set([".git", "build", ".dart_tool"]);
// flutter pub get·시험이 만드는 파일. 내보내기에 **없을 때만**(새로 생긴 것) 무시한다. 내보내기에 있는 파일이 바뀌면 그대로 보고한다.
// 10-03 고스톱 사본 실측(pub get + test + analyze 뒤 내보내기에 없던 것) + 같은 계열(linux·windows) + 골든 실패 출력.
export const GENERATED_IF_NEW = [
  ".flutter-plugins", ".flutter-plugins-dependencies", ".packages",
  "android/local.properties", "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
  "ios/Flutter/Generated.xcconfig", "ios/Flutter/flutter_export_environment.sh", "ios/Flutter/ephemeral/",
  "ios/Runner/GeneratedPluginRegistrant.h", "ios/Runner/GeneratedPluginRegistrant.m",
  "macos/Flutter/ephemeral/", "linux/flutter/ephemeral/", "windows/flutter/ephemeral/",
  "coverage/", // 고스톱은 coverage/ 를 추적한다 — 바뀌면 보고, 새로 생긴 것만 무시
];
const GOLDEN_FAILURES = /^test\/(.+\/)?failures\//; // 골든 불일치 때 flutter 가 남기는 그림(새로 생긴 것만 무시)
export const DEFAULT_LIMITS = { maxPatchBytes: 256 * 1024, maxFiles: 40, maxFileBytes: 1024 * 1024 };

const fail = (reason, detail, extra = {}) => ({ ok: false, reason, detail, files: [], bytes: 0, ...extra });
const isGeneratedNew = (rel) => GOLDEN_FAILURES.test(rel) || GENERATED_IF_NEW.some((g) => (g.endsWith("/") ? rel.startsWith(g) : rel === g));
// 경로 성분에 .git(대소문자 무관 — APFS 는 대소문자를 가리지 않는다), 제어 문자, 역슬래시가 있으면 패치 형식·적용이 위험하다.
export const badPath = (rel) => rel.split("/").some((c) => c.toLowerCase() === ".git") || /[\u0000-\u001f\u007f\\]/.test(rel);

// 따라가지 않고 훑는다. 폴더는 기록하지 않고(빈 폴더는 diff -ruN 도 무시), 파일·바로가기·특수 파일만.
export function scanTree(root) {
  const out = new Map();
  const walk = (dirAbs, rel) => {
    for (const name of fs.readdirSync(dirAbs)) {
      if (!rel && SKIP_TOP.has(name)) continue;
      const r = rel ? `${rel}/${name}` : name;
      const abs = path.join(dirAbs, name);
      const st = fs.lstatSync(abs);
      if (st.isDirectory()) walk(abs, r);
      else if (st.isSymbolicLink()) out.set(r, { type: "symlink", target: fs.readlinkSync(abs) });
      else if (st.isFile()) out.set(r, { type: "file", size: st.size, nlink: st.nlink, abs });
      else out.set(r, { type: "other" });
    }
  };
  walk(root, "");
  return out;
}

const sameBytes = (a, b) => a.size === b.size && fs.readFileSync(a.abs).equals(fs.readFileSync(b.abs));

function diffOne(rel, oldAbs, newAbs) {
  const r = spawnSync(DIFF, ["-u", oldAbs ?? "/dev/null", newAbs ?? "/dev/null"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  // 0 = 내용이 같다. 한쪽이 없는데 같다면 빈 파일의 추가·삭제다 — 통합 diff 로는 나타낼 수 없어 패치에 담지 않는다(메모만).
  if (r.status === 0 && (!oldAbs || !newAbs)) return { empty: true };
  if (r.status !== 1) return { error: `diff ${rel}: 종료 코드 ${r.status} ${String(r.stderr).slice(0, 200)}` }; // 1 = 다름(정상)
  const body = r.stdout;
  if (/^Binary files /m.test(body)) return { binary: true };
  const lines = body.split("\n");
  if (!lines[0].startsWith("--- ") || !lines[1].startsWith("+++ ")) return { error: `diff ${rel}: 머리 형식이 다르다` };
  lines[0] = oldAbs ? `--- a/${rel}` : "--- /dev/null";
  lines[1] = newAbs ? `+++ b/${rel}` : "+++ /dev/null";
  let added = 0, removed = 0;
  for (const l of lines.slice(2)) { if (l.startsWith("+")) added++; else if (l.startsWith("-")) removed++; }
  return { text: `diff -ruN a/${rel} b/${rel}\n${lines.join("\n")}`, added, removed };
}

// 사본을 잠시 다른 이름으로 옮겨 놓고 fn(얼린 경로)을 부른다. 끝나면 되돌린다.
function withFrozen(copy, fn, onFrozen) {
  const frozen = `${copy}.lg-freeze-${crypto.randomBytes(4).toString("hex")}`;
  fs.renameSync(copy, frozen);
  let res, intruder = null;
  try { onFrozen?.(frozen); res = fn(frozen); } finally {
    if (fs.existsSync(copy)) { // 얼린 사이 옛 이름에 무언가 생겼다 — 남은 격리 프로세스
      intruder = `${copy}.lg-intruder-${crypto.randomBytes(4).toString("hex")}`;
      fs.renameSync(copy, intruder);
    }
    fs.renameSync(frozen, copy);
  }
  if (intruder) return fail("lingering_writer", `추출하는 동안 사본 자리에 무언가 다시 생겼다(격리 안 프로세스가 남아 있다) — 옮겨 둠: ${intruder}`);
  return res;
}

// onFrozen: 시험 전용 — 얼린 직후 불린다(남은 프로세스가 옛 자리에 폴더를 다시 만드는 상황을 흉내 낸다).
export function extractPatch({ clean, copy, limits = {}, freeze = true, onFrozen } = {}) {
  const lim = { ...DEFAULT_LIMITS, ...limits };
  let c, s;
  try { c = fs.realpathSync(clean); s = fs.realpathSync(copy); } catch (e) { return fail("bad_dir", `폴더가 없다: ${e.path ?? e.message}`); }
  if (c === s || c.startsWith(`${s}/`) || s.startsWith(`${c}/`)) return fail("bad_dir", "내보내기와 사본이 겹친다");
  if (!fs.statSync(c).isDirectory() || !fs.statSync(s).isDirectory()) return fail("bad_dir", "폴더가 아니다");
  return freeze ? withFrozen(s, (frozen) => extractFrom(c, frozen, lim), onFrozen) : extractFrom(c, s, lim);
}

function extractFrom(cleanDir, copyDir, lim) {
  const A = scanTree(cleanDir);
  const B = scanTree(copyDir);
  const changed = [];
  for (const rel of [...new Set([...A.keys(), ...B.keys()])].sort()) {
    const a = A.get(rel), b = B.get(rel);
    if (!a && isGeneratedNew(rel)) continue;
    if (badPath(rel)) return fail("bad_path", `허용하지 않는 경로: ${JSON.stringify(rel)}`);
    if (a?.type === "other" || b?.type === "other") return fail("special_file", `일반 파일이 아니다(FIFO·소켓·장치): ${rel}`);
    if (a?.type === "symlink" || b?.type === "symlink") {
      if (a?.type === "symlink" && b?.type === "symlink" && a.target === b.target) continue; // 내보내기에 원래 있던 바로가기 그대로
      return fail("symlink", `바로가기 추가·변경·삭제는 받지 않는다: ${rel}`);
    }
    if (b && b.nlink > 1) return fail("hardlink", `하드링크된 파일: ${rel}`);
    if (a && b && sameBytes(a, b)) continue;
    changed.push({ rel, a, b, status: !a ? "added" : !b ? "deleted" : "modified" });
  }
  if (changed.length > lim.maxFiles) return fail("too_many_files", `바뀐 파일 ${changed.length}개 > ${lim.maxFiles}`, { count: changed.length });
  const parts = [];
  const files = [];
  const notes = [];
  let bytes = 0;
  for (const ch of changed) {
    for (const side of [ch.a, ch.b]) {
      if (!side) continue;
      if (side.size > lim.maxFileBytes) return fail("too_large", `파일이 크다(${side.size}B > ${lim.maxFileBytes}): ${ch.rel}`);
      if (fs.readFileSync(side.abs).includes(0)) return fail("binary", `이진 파일: ${ch.rel}`);
    }
    const d = diffOne(ch.rel, ch.a?.abs, ch.b?.abs);
    if (d.binary) return fail("binary", `이진 파일: ${ch.rel}`);
    if (d.error) return fail("diff_failed", d.error);
    if (d.empty) { notes.push(`빈 파일 ${ch.status === "added" ? "추가" : "삭제"}는 패치에 담지 않았다: ${ch.rel}`); continue; }
    bytes += Buffer.byteLength(d.text) + 1;
    if (bytes > lim.maxPatchBytes) return fail("too_large", `패치가 크다(> ${lim.maxPatchBytes}B, ${ch.rel} 에서 넘음)`);
    parts.push(d.text);
    files.push({ path: ch.rel, status: ch.status, added: d.added, removed: d.removed });
  }
  const patch = parts.length ? `${parts.join("\n")}\n` : "";
  return { ok: true, files, notes, bytes: Buffer.byteLength(patch), sha256: crypto.createHash("sha256").update(patch).digest("hex"), patch };
}

function main(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (["--clean", "--copy", "--out", "--max-bytes", "--max-files"].includes(k)) o[k.slice(2)] = argv[++i];
    else if (k === "--no-freeze") o.noFreeze = true;
    else { process.stderr.write(`모르는 인자: ${k}\n`); process.exit(2); }
  }
  if (!o.clean || !o.copy) { process.stderr.write("--clean·--copy 가 있어야 한다\n"); process.exit(2); }
  const limits = {};
  if (o["max-bytes"]) limits.maxPatchBytes = Number(o["max-bytes"]);
  if (o["max-files"]) limits.maxFiles = Number(o["max-files"]);
  const r = extractPatch({ clean: o.clean, copy: o.copy, limits, freeze: !o.noFreeze });
  if (r.ok && o.out) {
    const tmp = `${o.out}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, r.patch, { mode: 0o600 });
    fs.renameSync(tmp, o.out);
    delete r.patch;
    r.out = o.out;
  }
  process.stdout.write(`${JSON.stringify(r)}\n`);
  process.exit(r.ok ? 0 : 3);
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
