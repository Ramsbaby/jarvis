// sandbox.test.mjs — 1b 실행 격리 합격 시험(설계 §3 · §9 · L2 위험 A~D). **맥 전용**(sandbox-exec + flutter SDK — 없으면 건너뛴다).
// 음성 7종이 모두 실패해야 통과: ① 공인 IP ② 막은 로컬 포트 ③ 사본 밖 쓰기 ④ .git 쓰기 ⑤ 본 저장소 읽기 ⑥ ~/keys 읽기 ⑦ git·security 실행.
// 함정: 사본 .git/config 에 fsmonitor·훅·필터를 심어도(밖에서 git 을 돌리면 터지는 것을 대조군으로 확인) 패치 추출 뒤 표식이 안 생긴다.
// 그 밖: 바로가기 유출 · 대조군(사본·임시 쓰기, 새 루프백) · 환경변수 허용 목록 · 경로 검사 · 운영 점검(canary) ·
// 실제 고스톱 사본에서 flutter test 오프라인 초록(격리 안 시험 코드 자신도 막히는지 포함 — LG_SANDBOX_FLUTTER=0 이면 건너뜀).
// 막힘은 '권한 없음'(EPERM — 격리가 막았다)이어야 센다. 대상이 없어서 실패한 것(ENOENT)·연결 거부는 격리의 증거가 아니다.
import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import * as sbx from "../lib/sandbox/sandboxed-run.mjs";
import { extractPatch } from "../lib/sandbox/patch-extract.mjs";
import { classifyPatchText } from "../lib/sandbox/patch-allowlist.mjs";

const H = os.userInfo().homedir; // 진짜 홈(시험은 임시 HOME 으로 돌지만 격리 규칙은 진짜 홈 기준이어야 한다)
let FLUTTER = null;
try { FLUTTER = sbx.locateFlutter(); } catch { /* 없음 */ }
const SKIP = process.platform !== "darwin" ? "맥 전용(sandbox-exec)" : !fs.existsSync(sbx.SANDBOX_EXEC) ? "sandbox-exec 없음" : !FLUTTER ? "flutter SDK 없음" : false;
const GOSTOP = path.join(H, "projects", "gostop_app");
const GIT_ENV = { PATH: "/usr/bin:/bin", HOME: "/nonexistent", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" };
const git = (cwd, ...args) => spawnSync("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=lg", "-c", "user.email=lg@local", ...args], { cwd, env: GIT_ENV, encoding: "utf8" });
const EPERM = /Operation not permitted/;
const sha = (f) => crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex");

// /private/tmp 아래(정해진 뿌리)에 사본·임시·미끼를 만든다. 사본은 git init + 첫 커밋(§2), 깨끗한 내보내기는 그 복제.
function world(t) {
  const root = fs.mkdtempSync("/private/tmp/lg-sbx-");
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const copy = path.join(root, "copy"), tmp = path.join(root, "tmp"), clean = path.join(root, "clean"), decoy = path.join(root, "decoy");
  for (const d of [path.join(copy, "lib"), tmp, path.join(decoy, "projects/gostop_app"), path.join(decoy, "keys")]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(copy, "lib/a.dart"), "int a() => 1;\n");
  fs.writeFileSync(path.join(copy, "pubspec.yaml"), "name: lg_sbx\n");
  fs.cpSync(copy, clean, { recursive: true });
  assert.equal(git(copy, "init", "-q").status, 0);
  assert.equal(git(copy, "add", "-A").status, 0);
  assert.equal(git(copy, "commit", "-qm", "sandbox-init").status, 0);
  fs.writeFileSync(path.join(decoy, "projects/gostop_app/pubspec.yaml"), "name: decoy-main-repo\n");
  fs.writeFileSync(path.join(decoy, "keys/k.pem"), "DECOY-KEY-MATERIAL\n");
  return { root, copy, tmp, clean, decoy };
}
const probe = (w, ops) => sbx.runProbes({ copy: w.copy, tmp: w.tmp }, ops);
function assertDenied(results, label) {
  for (const r of results) assert.ok(!r.ok && EPERM.test(r.err ?? ""), `${label}: ${r.op} ${r.a.join(" ")} → ${r.ok ? "됐다(격리 실패)" : r.err}`);
}
const existing = (...ps) => ps.filter((p) => fs.existsSync(p));

test("대조군: 사본·임시 폴더 쓰기, 사본 읽기, 새 루프백 포트(flutter test 가 쓰는 길)는 된다", { skip: SKIP }, async (t) => {
  const w = world(t);
  const r = await probe(w, [
    { op: "write", a: [path.join(w.copy, "lib/new.dart")] },
    { op: "write", a: [path.join(w.tmp, "x.txt")] },
    { op: "read", a: [path.join(w.copy, "lib/a.dart")] },
    { op: "loopback", a: [] },
  ]);
  for (const x of r) assert.equal(x.ok, true, `${x.op} ${x.a.join(" ")}: ${x.err}`);
});

test("음성 ① 공인 IP 연결(IPv4·IPv6)과 DNS 가 막힌다", { skip: SKIP }, async (t) => {
  const w = world(t);
  const r = await probe(w, [
    { op: "net", a: ["1.1.1.1", "443"] }, { op: "net", a: ["8.8.8.8", "53"] }, { op: "net", a: ["2606:4700:4700::1111", "443"] },
  ]);
  assertDenied(r, "공인 IP");
  const [dns] = await probe(w, [{ op: "dns", a: ["example.com"] }]);
  assert.equal(dns.ok, false, "이름 풀이도 안 돼야 한다(mDNSResponder 막힘)");
});

test("음성 ② 막은 로컬 포트: 고정 5종(18789·9222·5037·11434·3100, IPv4·::1)과 실행 직전에 열려 있던 포트", { skip: SKIP }, async (t) => {
  const w = world(t);
  const srv = net.createServer().listen(0, "127.0.0.1");
  await new Promise((res) => srv.once("listening", res));
  t.after(() => srv.close());
  const dyn = srv.address().port;
  assert.ok(sbx.listeningPorts().includes(dyn), "netstat 으로 이 시험의 포트가 보여야 한다");
  const ops = sbx.FIXED_DENY_PORTS.flatMap((p) => [{ op: "net", a: ["127.0.0.1", String(p)] }, { op: "net", a: ["::1", String(p)] }]);
  ops.push({ op: "net", a: ["127.0.0.1", String(dyn)] });
  // 받는 쪽도: 그 포트에 대신 리슨해 밖 프로그램을 가로채기(독립 검토 중1 — * 바인드 서비스는 127.0.0.1, 127.0.0.1 전용은 ::1 로)
  for (const p of [...sbx.FIXED_DENY_PORTS, dyn]) ops.push({ op: "bind", a: ["127.0.0.1", String(p)] }, { op: "bind", a: ["::1", String(p)] });
  assertDenied(await probe(w, ops), "로컬 포트");
  // 막는 줄은 프로필에 실제로 들어간다(고정은 틀에, 그 밖은 덧붙임)
  const profile = sbx.buildProfile({ ports: [dyn, 18789] });
  for (const p of [...sbx.FIXED_DENY_PORTS, dyn]) {
    for (const f of [`remote ip "localhost:${p}"`, `local ip "localhost:${p}"`]) assert.ok(profile.includes(`(${f})`), `${f} 가 프로필에 없다`);
  }
  const appended = profile.slice(profile.indexOf(";; 실행 직전에 열려 있던 포트"));
  assert.ok(appended.includes(`localhost:${dyn}`));
  assert.equal(appended.includes("localhost:18789"), false, "고정 포트는 덧붙이는 쪽에 다시 넣지 않는다");
});

test("LAN 리슨 감시: 0.0.0.0 에 TCP 리슨·UDP 바인드하면(격리 규칙으로는 못 막음 — 실측) 즉시 나무째 끄고 violation", { skip: SKIP }, async (t) => {
  const w = world(t);
  const tmp = fs.realpathSync(w.tmp);
  fs.writeFileSync(path.join(tmp, "tcp.dart"), "import 'dart:io'; Future<void> main() async { final s = await ServerSocket.bind(InternetAddress.anyIPv4, 0); await Future.delayed(const Duration(seconds: 20)); await s.close(); }\n");
  fs.writeFileSync(path.join(tmp, "udp.dart"), "import 'dart:io'; Future<void> main() async { final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0); await Future.delayed(const Duration(seconds: 20)); s.close(); }\n");
  for (const f of ["tcp.dart", "udp.dart"]) {
    const r = await sbx.runSandboxed(sbx.sandboxCommand({ copy: w.copy, tmp: w.tmp, tool: "dart", args: [path.join(tmp, f)], ports: [] }), { timeoutMs: 30_000 });
    assert.match(r.violation ?? "", /^nonloopback_listen .*@\*\.\d+/, `${f}: ${r.violation}`);
    assert.ok(r.ms < 15_000, `${f}: ${r.ms}ms — 20초 대기 전에 꺼야 한다`);
  }
  // 대조군: 루프백 리슨은 감시에 안 걸린다(flutter test 가 쓰는 길)
  fs.writeFileSync(path.join(tmp, "lo.dart"), "import 'dart:io'; Future<void> main() async { final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0); await Future.delayed(const Duration(seconds: 2)); await s.close(); }\n");
  const lo = await sbx.runSandboxed(sbx.sandboxCommand({ copy: w.copy, tmp: w.tmp, tool: "dart", args: [path.join(tmp, "lo.dart")], ports: [] }), { timeoutMs: 30_000 });
  assert.equal(lo.violation, null);
  assert.equal(lo.code, 0, lo.stderr);
});

test("음성 ③ 사본·임시 밖 쓰기: 진짜 홈 · 다른 /tmp 폴더 · 사본 옆 · 미끼 덮어쓰기 — 아무것도 생기거나 바뀌지 않는다", { skip: SKIP }, async (t) => {
  const w = world(t);
  const tag = crypto.randomBytes(4).toString("hex");
  const targets = [path.join(H, `.lg-sbx-${tag}`), `/private/tmp/lg-sbx-out-${tag}`, path.join(w.root, `outside-${tag}.txt`)];
  const decoyFile = path.join(w.decoy, "keys/k.pem");
  const before = sha(decoyFile);
  t.after(() => { for (const f of targets) try { fs.unlinkSync(f); } catch { /* 없음 */ } });
  assertDenied(await probe(w, [...targets.map((f) => ({ op: "write", a: [f] })), { op: "append", a: [decoyFile] }, { op: "mkdir", a: [path.join(H, `.lg-sbx-dir-${tag}`)] }]), "밖 쓰기");
  for (const f of targets) assert.equal(fs.existsSync(f), false, `${f} 가 생겼다`);
  assert.equal(fs.existsSync(path.join(H, `.lg-sbx-dir-${tag}`)), false);
  assert.equal(sha(decoyFile), before);
});

test("음성 ④ 사본 .git 쓰기: config 덧붙이기·훅 만들기·폴더 만들기·.GIT 별칭·이름 바꾸기 — 전부 막히고 .git 은 그대로", { skip: SKIP }, async (t) => {
  const w = world(t);
  const g = path.join(w.copy, ".git");
  const before = sha(path.join(g, "config"));
  const hooksBefore = fs.readdirSync(path.join(g, "hooks")).sort();
  assertDenied(await probe(w, [
    { op: "append", a: [path.join(g, "config")] },
    { op: "write", a: [path.join(g, "hooks/pre-commit")] },
    { op: "mkdir", a: [path.join(g, "hooks/lg")] },
    { op: "write", a: [path.join(w.copy, ".GIT/config")] },
    { op: "write", a: [path.join(w.copy, "lib/../.git/info/exclude")] },
    { op: "rename", a: [g, path.join(w.copy, ".git2")] },
    { op: "delete", a: [path.join(g, "HEAD")] },
  ]), ".git 쓰기");
  assert.equal(sha(path.join(g, "config")), before);
  assert.deepEqual(fs.readdirSync(path.join(g, "hooks")).sort(), hooksBefore);
  assert.equal(fs.existsSync(path.join(g, "HEAD")), true);
});

test("음성 ⑤ 본 저장소 읽기(정답 누수 — L2 위험 B): 진짜 ~/projects/gostop_app(있으면)과 미끼", { skip: SKIP }, async (t) => {
  const w = world(t);
  const targets = [path.join(w.decoy, "projects/gostop_app/pubspec.yaml"), path.join(w.decoy, "projects/gostop_app"),
    ...existing(path.join(GOSTOP, "pubspec.yaml"), path.join(GOSTOP, ".git/HEAD"), GOSTOP)];
  if (!fs.existsSync(GOSTOP)) t.diagnostic("진짜 고스톱 저장소가 없어 미끼로만 본다");
  assertDenied(await probe(w, targets.map((p) => ({ op: "read", a: [p] }))), "본 저장소 읽기");
});

test("음성 ⑥ 비밀 읽기: ~/keys(있으면)·미끼 키 · 그 밖 홈 비밀 자리(.ssh·셸 기록·.openclaw·.claude — 있는 것만)", { skip: SKIP }, async (t) => {
  const w = world(t);
  const real = existing(path.join(H, "keys"), path.join(H, ".ssh"), path.join(H, ".zsh_history"), path.join(H, ".openclaw"), path.join(H, ".claude"), path.join(H, ".config"), H);
  if (!fs.existsSync(path.join(H, "keys"))) t.diagnostic("진짜 ~/keys 가 없어 미끼로 본다");
  assertDenied(await probe(w, [path.join(w.decoy, "keys/k.pem"), path.join(w.decoy, "keys"), ...real].map((p) => ({ op: "read", a: [p] }))), "비밀 읽기");
});

test("음성 ⑦ 실행 허용 목록 밖: git·security·curl·셸·osascript·python — 프로세스를 띄우지도 못한다", { skip: SKIP }, async (t) => {
  const w = world(t);
  assertDenied(await probe(w, [
    { op: "exec", a: ["/usr/bin/git", "--version"] },
    { op: "exec", a: ["/usr/bin/security", "list-keychains"] },
    { op: "exec", a: ["/usr/bin/curl", "--version"] },
    { op: "exec", a: ["/bin/sh", "-c", "true"] },
    { op: "exec", a: ["/usr/bin/osascript", "-e", "1"] },
    { op: "exec", a: ["/usr/bin/python3", "--version"] },
  ]), "실행");
});

test("그 밖 우회로: 밖 파일 하드링크 · 밖을 가리키는 바로가기로 읽기 · 유닉스 소켓(mDNSResponder)", { skip: SKIP }, async (t) => {
  const w = world(t);
  const r = await probe(w, [
    { op: "hardlink", a: [path.join(w.decoy, "keys/k.pem"), path.join(w.copy, "lib/hl.dart")] },
    { op: "symlink-read", a: [path.join(w.decoy, "keys/k.pem"), path.join(w.copy, "lib/sl.dart")] },
    { op: "unix", a: ["/private/var/run/mDNSResponder"] },
  ]);
  for (const x of r) assert.equal(x.ok, false, `${x.op}: 됐다(격리 실패)`);
  assert.equal(fs.existsSync(path.join(w.copy, "lib/hl.dart")), false);
  // 홈 아래는 있는지·크기(메타데이터)도 안 보인다 — 본 저장소 파일 이름 짐작으로 정답을 캐는 길을 막는다. 허용 경로(pub 캐시)는 보인다
  const pubReadme = path.join(H, ".pub-cache", "README.md");
  const metas = existing(path.join(GOSTOP, "pubspec.yaml"), path.join(H, ".zshrc"), path.join(H, ".gitconfig"));
  if (metas.length) assertDenied(await probe(w, metas.map((p) => ({ op: "stat", a: [p] }))), "홈 메타데이터");
  if (fs.existsSync(pubReadme)) assert.equal((await probe(w, [{ op: "stat", a: [pubReadme] }]))[0].ok, true, "pub 캐시는 보여야 한다");
});

test("함정: 사본 .git 에 fsmonitor·훅·필터를 심어도 패치 추출(git 안 씀) 뒤 표식이 생기지 않는다 — 밖에서 git 을 돌리면 터지는 것을 대조군으로 확인", { skip: SKIP }, async (t) => {
  const w = world(t);
  const marker = path.join(w.root, "ESCAPE-MARKER");
  const script = path.join(w.root, "trap.sh");
  fs.writeFileSync(script, `#!/bin/sh\necho "$0 $*" >> '${marker}'\ncat\n`, { mode: 0o755 });
  const hooks = path.join(w.root, "hooks");
  fs.mkdirSync(hooks);
  for (const h of ["pre-commit", "post-checkout", "post-index-change", "reference-transaction", "pre-auto-gc", "post-merge"]) fs.copyFileSync(script, path.join(hooks, h));
  fs.chmodSync(hooks, 0o755);
  for (const h of fs.readdirSync(hooks)) fs.chmodSync(path.join(hooks, h), 0o755);
  // 1) 격리 안 코드가 심으려 하면 막힌다
  assertDenied(await probe(w, [{ op: "append", a: [path.join(w.copy, ".git/config")] }]), "함정 심기");
  // 2) 최악(격리가 뚫려 심어졌다고 가정): 밖에서 직접 심는다
  fs.appendFileSync(path.join(w.copy, ".git/config"), `[core]\n\tfsmonitor = ${script}\n\thooksPath = ${hooks}\n\tpager = ${script}\n[filter "lg"]\n\tclean = ${script}\n\tsmudge = ${script}\n[diff]\n\texternal = ${script}\n`);
  fs.writeFileSync(path.join(w.copy, ".gitattributes"), "* filter=lg\n");
  // 대조군: 밖에서 (보호 옵션 없이) git 을 돌리면 함정이 터진다 — 심은 것이 진짜 작동한다는 증거
  for (const args of [["status"], ["add", "-A"]]) spawnSync("/usr/bin/git", args, { cwd: w.copy, env: GIT_ENV, encoding: "utf8" });
  assert.equal(fs.existsSync(marker), true, "대조군: git 이 함정을 실행해야 한다");
  fs.unlinkSync(marker);
  // 3) 격리 안에서 시험 코드가 lib 를 고친 뒤 패치를 뽑는다 — git 을 안 쓰니 표식이 안 생긴다
  assert.equal((await probe(w, [{ op: "append", a: [path.join(w.copy, "lib/a.dart")] }]))[0].ok, true);
  const r = extractPatch({ clean: w.clean, copy: w.copy });
  assert.equal(fs.existsSync(marker), false, "패치 추출이 함정을 실행했다(git 을 썼다)");
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.deepEqual(r.files.map((f) => [f.path, f.status]), [[".gitattributes", "added"], ["lib/a.dart", "modified"]]);
  assert.doesNotMatch(r.patch, /fsmonitor|hooksPath/, ".git 안 내용은 패치에 없다");
  // 4) 허용 목록이 .gitattributes(필터 배선)를 관문 설정 변경으로 잡는다
  const cls = classifyPatchText(r.patch);
  assert.deepEqual(cls.byReason.gate_config, [".gitattributes"]);
});

test("바로가기 유출: 격리 안 코드가 사본에 밖 비밀을 가리키는 바로가기를 만들어도 추출이 거부하고 비밀은 안 나온다", { skip: SKIP }, async (t) => {
  const w = world(t);
  const [r] = await probe(w, [{ op: "symlink-read", a: [path.join(w.decoy, "keys/k.pem"), path.join(w.copy, "lib/leak.dart")] }]);
  assert.equal(r.ok, false, "격리 안에서 읽기는 막힌다");
  assert.equal(fs.lstatSync(path.join(w.copy, "lib/leak.dart")).isSymbolicLink(), true, "바로가기 만들기 자체는 된다(사본 쓰기) — 그래서 추출이 막아야 한다");
  const x = extractPatch({ clean: w.clean, copy: w.copy });
  assert.equal(x.ok, false);
  assert.equal(x.reason, "symlink");
  assert.doesNotMatch(JSON.stringify(x), /DECOY-KEY-MATERIAL/);
});

test("환경변수: 허용 목록만(토큰류 0) — 부모에 비밀이 있어도 격리 안에는 안 들어간다. HOME·TMPDIR 는 임시 폴더", { skip: SKIP }, async (t) => {
  const w = world(t);
  const env = { ...process.env, ANTHROPIC_API_KEY: "sk-x", GITHUB_TOKEN: "ghp_x", OPENCLAW_GATEWAY_TOKEN: "x", SSH_AUTH_SOCK: "/tmp/x" };
  const cmd = sbx.sandboxCommand({ copy: w.copy, tmp: w.tmp, tool: "dart", args: ["--version"], env });
  assert.deepEqual(Object.keys(cmd.env).sort(), ["FLUTTER_ALREADY_LOCKED", "FLUTTER_ROOT", "FLUTTER_SUPPRESS_ANALYTICS", "HOME", "LANG", "PATH", "PUB_CACHE", "TMPDIR"]);
  assert.ok(cmd.env.HOME.startsWith(fs.realpathSync(w.tmp)));
  const [e] = await probe(w, [{ op: "env", a: [] }]);
  const keys = e.info.split(",");
  for (const k of keys) assert.match(k, /^(FLUTTER_ALREADY_LOCKED|FLUTTER_ROOT|FLUTTER_SUPPRESS_ANALYTICS|HOME|LANG|PATH|PUB_CACHE|TMPDIR|__CF_USER_TEXT_ENCODING)$/, `격리 안 환경변수 ${k}`);
});

test("명령 모양: flutter 는 셸 진입점 대신 dart + 스냅숏, --no-pub·분석/버전 확인 끔, pub 은 거부, --coverage 는 임시 폴더로", { skip: SKIP }, (t) => {
  const w = world(t);
  const cmd = sbx.sandboxCommand({ copy: w.copy, tmp: w.tmp, tool: "flutter", args: ["test", "--coverage", "test/a_test.dart"], ports: [] });
  const i = cmd.argv.indexOf(FLUTTER.dart);
  assert.ok(i > 0);
  assert.deepEqual(cmd.argv.slice(i + 2, i + 7), [FLUTTER.snapshot, "--suppress-analytics", "--no-version-check", "test", "--no-pub"]);
  assert.ok(cmd.argv.includes(`--coverage-path=${path.join(fs.realpathSync(w.tmp), "coverage", "lcov.info")}`));
  assert.equal(cmd.argv[0], "-p");
  assert.ok(cmd.argv.includes(`COPY=${fs.realpathSync(w.copy)}`));
  assert.throws(() => sbx.sandboxCommand({ copy: w.copy, tmp: w.tmp, tool: "flutter", args: ["pub", "get"] }), /허용 목록 밖/);
  assert.throws(() => sbx.sandboxCommand({ copy: w.copy, tmp: w.tmp, tool: "git", args: [] }), /flutter·dart 만/);
});

test("경로 검사: 뿌리 밖(본 저장소)·뿌리 자체·홈을 품음·SDK 안·사본과 임시가 겹침·.git 바로가기 → 띄우기 전에 거부", { skip: SKIP }, (t) => {
  const w = world(t);
  const bad = (opts, re) => assert.throws(() => sbx.sandboxCommand({ tool: "dart", args: [], ports: [], ...opts }), re);
  if (fs.existsSync(GOSTOP)) bad({ copy: GOSTOP, tmp: w.tmp }, /정해진 뿌리/);
  bad({ copy: "/private/tmp", tmp: w.tmp }, /정해진 뿌리/);
  bad({ copy: w.copy, tmp: path.join(w.copy, "lib") }, /겹친다/);
  bad({ copy: w.root, tmp: w.tmp }, /겹친다/);
  bad({ copy: H, tmp: w.tmp, roots: [path.dirname(H), "/private/tmp"] }, /홈을\(를\) 품는다/); // 뿌리를 넓혀도 홈 통째는 안 된다
  bad({ copy: w.copy, tmp: FLUTTER.root, roots: ["/opt", "/private/tmp", path.dirname(FLUTTER.root)] }, /flutter SDK/);
  bad({ copy: "relative/path", tmp: w.tmp }, /절대경로/);
  const c2 = path.join(w.root, "c2");
  fs.mkdirSync(c2);
  fs.symlinkSync(w.tmp, path.join(c2, ".git"));
  bad({ copy: c2, tmp: path.join(w.root, "decoy") }, /\.git 이 폴더가 아니다/);
});

test("운영 점검(canary): 이 기기에서 격리가 실제로 막는지 1초 안팎 — ok", { skip: SKIP }, async (t) => {
  const w = world(t);
  const r = await sbx.canary({ copy: w.copy, tmp: w.tmp });
  assert.equal(r.ok, true, r.failures.join(" / "));
  assert.deepEqual(fs.readdirSync(path.join(fs.realpathSync(w.tmp), "t")).filter((n) => n.startsWith("lg-canary-")), [], "대조군 파일은 치운다");
});

test("시간 초과: 격리 안 프로세스를 나무째 끄고 124 에 해당하는 timedOut", { skip: SKIP }, async (t) => {
  const w = world(t);
  fs.writeFileSync(path.join(w.tmp, "spin.dart"), "import 'dart:io'; Future<void> main() async { await Future.delayed(const Duration(minutes: 5)); exit(0); }\n");
  const cmd = sbx.sandboxCommand({ copy: w.copy, tmp: w.tmp, tool: "dart", args: [path.join(fs.realpathSync(w.tmp), "spin.dart")], ports: [] });
  const r = await sbx.runSandboxed(cmd, { timeoutMs: 3000 });
  assert.equal(r.timedOut, true);
  assert.ok(r.ms < 30_000);
});

const FLUTTER_SKIP = SKIP || (process.env.LG_SANDBOX_FLUTTER === "0" ? "LG_SANDBOX_FLUTTER=0" : !fs.existsSync(path.join(GOSTOP, ".git")) ? "고스톱 저장소 없음" : false);

test("flutter 오프라인 초록: 고스톱 HEAD 를 git archive 로 푼 새 사본(셰이더 컴파일부터)에서 격리 안 flutter test — 시험 코드 자신도 밖에 못 닿는다", { skip: FLUTTER_SKIP, timeout: 600_000 }, async (t) => {
  const root = fs.mkdtempSync("/private/tmp/lg-sbx-fl-");
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const copy = path.join(root, "copy"), tmp = path.join(root, "tmp");
  fs.mkdirSync(copy); fs.mkdirSync(tmp);
  // 본 저장소는 읽기만(git archive). 1a 사본 단계와 같은 제외 목록.
  const tar = path.join(root, "src.tar");
  const a = spawnSync("/usr/bin/git", ["-C", GOSTOP, "archive", "--format=tar", "-o", tar, "HEAD"], { env: GIT_ENV, encoding: "utf8" });
  assert.equal(a.status, 0, a.stderr);
  const x = spawnSync("/usr/bin/tar", ["-xf", tar, "-C", copy, "--exclude", ".claude", "--exclude", ".mcp.json", "--exclude", "android/key.properties", "--exclude", "*.jks", "--exclude", "*.keystore"], { encoding: "utf8" });
  assert.equal(x.status, 0, x.stderr);
  // 오프라인 의존성 준비는 격리 밖(1a 사본 단계와 같다 — 아직 LLM 이 손대기 전). 격리 안에서는 안 된다:
  // pub 이 새 사본 경로를 pub 캐시 active_roots 에 적으려다 막혀 66 으로 끝난다(10-03 실측 — pub 캐시는 격리에서 읽기 전용).
  const pubEnv = { PATH: "/usr/bin:/bin", HOME: path.join(tmp, "home"), FLUTTER_ROOT: FLUTTER.root, PUB_CACHE: path.join(H, ".pub-cache"), FLUTTER_SUPPRESS_ANALYTICS: "true" };
  fs.mkdirSync(pubEnv.HOME);
  const pub = spawnSync(FLUTTER.dart, ["pub", "get", "--offline"], { cwd: copy, env: pubEnv, encoding: "utf8", timeout: 180_000 });
  assert.equal(pub.status, 0, `${String(pub.stdout).slice(-400)}\n${String(pub.stderr).slice(-400)}`);
  // 격리 안에서 다시 하면 pub 캐시 쓰기가 막힌다(설계대로) — 막힘이 '권한 없음'인지까지 본다
  fs.renameSync(path.join(copy, ".dart_tool"), path.join(root, "dart_tool.bak"));
  const inside = await sbx.runSandboxed(sbx.sandboxCommand({ copy, tmp, tool: "dart", args: ["pub", "get", "--offline"] }), { timeoutMs: 180_000 });
  fs.rmSync(path.join(copy, ".dart_tool"), { recursive: true, force: true });
  fs.renameSync(path.join(root, "dart_tool.bak"), path.join(copy, ".dart_tool"));
  if (inside.code !== 0) assert.match(inside.stdout + inside.stderr, /pub-cache[^\n]*Operation not permitted/);
  // 격리 안 flutter_tester 에서 도는 시험 코드 자신도 밖에 못 닿는지(막혀야 이 시험이 초록)
  fs.writeFileSync(path.join(copy, "test/lg_sandbox_probe_test.dart"), `
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
bool eperm(Object e) => (e is SocketException && e.osError?.errorCode == 1) || (e is FileSystemException && e.osError?.errorCode == 1) || (e is ProcessException && e.errorCode == 1);
void main() {
  test('격리: 공인 IP·게이트웨이 포트 연결이 막힌다', () async {
    for (final (h, p) in [('1.1.1.1', 443), ('127.0.0.1', 18789)]) {
      Object? err;
      try { (await Socket.connect(h, p, timeout: const Duration(seconds: 4))).destroy(); } catch (e) { err = e; }
      expect(err != null && eperm(err), isTrue, reason: '\$h:\$p → \$err');
    }
  });
  test('격리: 홈 목록·본 저장소 읽기, git 실행이 막힌다', () {
    for (final f in <void Function()>[
      () => Directory(${JSON.stringify(H)}).listSync(),
      () => File(${JSON.stringify(path.join(GOSTOP, "pubspec.yaml"))}).readAsStringSync(),
      () => Process.runSync('/usr/bin/git', ['--version']),
    ]) {
      Object? err;
      try { f(); } catch (e) { err = e; }
      expect(err != null && eperm(err), isTrue, reason: '\$err');
    }
  });
}
`);
  const tests = ["test/domain/game/bomb_rules_test.dart", "test/domain/game/self_qa_regressions_test.dart", "test/lg_sandbox_probe_test.dart"];
  const r = await sbx.runSandboxed(sbx.sandboxCommand({ copy, tmp, tool: "flutter", args: ["test", "-r", "expanded", ...tests] }), { timeoutMs: 480_000 });
  const tail = `${r.stdout.slice(-1500)}\n${r.stderr.slice(-800)}`;
  assert.equal(r.code, 0, tail);
  assert.equal(r.violation, null, "flutter 자신의 소켓은 루프백뿐이어야 한다(감시 오탐 없음)");
  assert.match(r.stdout, /All tests passed!/, tail);
  assert.match(r.stdout, /격리: 홈 목록·본 저장소 읽기, git 실행이 막힌다/);
  t.diagnostic(`flutter test(격리) ${Math.round(r.ms / 1000)}초`);
});
