// gostop-release.mjs — 고스톱 출시(설계 §5.3). **실제 모드 전용** — 그림자는 '했을 일'만 적고 끝난다.
//   preflight(모드·기대 지문) → cert_check(APK 를 상태 폴더 비공개 복사본으로 옮겨 지문 고정 → apksigner 로 서명 검증·서명자 SHA-256 대조 —
//   다르면 여기서 멈춘다) → fad(effect: 복사본 해시를 다시 보고 같을 때만 테스터 배포)
// 지금 판(1b 통합)은 '서명 지문이 다르면 배포 정지'까지다. 버전 올리기·APK 빌드·설치·에뮬레이터 연기는 다음 판(설계 §5.3 2·3·5·6).
// 기대 지문은 LG_RELEASE_CERT_SHA256(공개 인증서 지문 — 비밀 아님). 키·비밀번호는 읽지 않는다(apksigner --print-certs 는 APK 안 공개 인증서만 본다).
// 독립 검토(H10 중8): 확인과 배포 사이에 원본 APK 가 바뀌어도 배포되는 것은 확인한 복사본(해시 고정)뿐이다. keytool 은 v1 서명만 봐서 apksigner 로 바꿨다.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";
import { runDir, mkdirp, copyNoFollow, readNoFollow } from "./gostop-common.mjs";

export const meta = { name: "gostop-release", description: "고스톱 출시(실제 전용) — 서명 지문 대조 뒤 테스터 배포", serial: true };

const last = (a, b) => (b === undefined ? a : b);
const State = Annotation.Root({
  apk: Annotation(),
  version: Annotation(),
  mode: Annotation({ reducer: last, default: () => "shadow" }),
  expected: Annotation({ reducer: last, default: () => null }),
  actual: Annotation({ reducer: last, default: () => null }),
  copy: Annotation({ reducer: last, default: () => null }),
  sha: Annotation({ reducer: last, default: () => null }),
  status: Annotation({ reducer: last, default: () => null }),
  log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }),
});

const FP_RE = /^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/;
export const normFp = (s) => String(s ?? "").trim().toUpperCase().replace(/[^0-9A-F]/g, "").replace(/(..)(?!$)/g, "$1:");
// apksigner verify --print-certs 출력의 서명자 SHA-256 지문들(서명자가 여럿이면 전부)
export function certFingerprints(text) {
  return [...String(text ?? "").matchAll(/Signer #\d+ certificate SHA-256 digest:\s*([0-9A-Fa-f:]{64,95})/g)].map((m) => normFp(m[1])).filter((f) => FP_RE.test(f));
}
const sha256 = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

export function input(flags) {
  const apk = String(flags.apk ?? "");
  const version = String(flags.version ?? "");
  if (!/^\/.+\.apk$/.test(apk) || !/^[0-9]{1,6}$/.test(version)) throw new Error("gostop-release 시작에는 --apk=<절대경로.apk> 와 --version=<versionCode> 가 필요하다");
  return { apk, version };
}
export const summarize = (v) => `${v.status ?? "?"} · v${v.version ?? "?"}${v.actual && v.status === "signing_mismatch" ? ` · 지문 ${v.actual.slice(0, 11)}…` : ""}`;

export function build({ checkpointer, tools }) {
  function preflight() {
    const expected = normFp(process.env.LG_RELEASE_CERT_SHA256);
    if (tools.mode !== "live") return { mode: tools.mode, status: "shadow", log: ["preflight 그림자 — 했을 일만"] };
    if (!FP_RE.test(expected)) return { mode: tools.mode, status: "no_expected_fingerprint", log: ["기대 지문(LG_RELEASE_CERT_SHA256) 없음 — 멈춤"] };
    return { mode: tools.mode, expected, log: ["preflight 실제"] };
  }
  // 그림자: 배포를 했을 일로만 적는다(effect 는 그림자에서 fn 을 부르지 않는다)
  async function shadowNote(s) {
    await tools.effect(`gostop-fad:${s.version}`, "fad_distribute", async () => { throw new Error("그림자에서는 불리지 않는다"); });
    return { log: ["fad 그림자 — would_run"] };
  }
  async function certCheck(s) {
    // 비공개 복사본(상태 폴더, 600) — 이후 확인·배포는 이것만
    const dir = mkdirp(runDir(tools.stateDir, `release-${s.version}`));
    const copy = copyNoFollow(s.apk, dir, "app.apk");
    const sha = sha256(readNoFollow(copy, 2 << 30) ?? Buffer.alloc(0));
    const r = await tools.run("apk.cert-fingerprint", { apk: copy });
    const fps = r.code === 0 ? certFingerprints(r.stdout) : [];
    if (!fps.length) return { copy, sha, status: "cert_unreadable", log: [`서명 검증 실패·지문 없음(코드 ${r.code})`] };
    // 서명자가 여럿이면 전부 기대값이어야 한다
    if (fps.some((f) => f !== s.expected)) return { copy, sha, actual: fps.find((f) => f !== s.expected), status: "signing_mismatch", log: ["서명 지문 불일치 — 배포 정지"] };
    return { copy, sha, actual: fps[0], log: ["서명 지문 일치"] };
  }
  async function fad(s) {
    const app = String(process.env.LG_FAD_APP_ID ?? "");
    const now = sha256(readNoFollow(s.copy, 2 << 30) ?? Buffer.alloc(0));
    if (now !== s.sha) return { status: "apk_changed", log: ["확인 뒤 복사본이 바뀜 — 배포 정지"] };
    await tools.effect(`gostop-fad:${s.version}`, "fad_distribute", async () => {
      const r = await tools.run("fad.distribute", { apk: s.copy, app, groups: process.env.LG_FAD_GROUPS || "testers" });
      if (r.code !== 0) throw new Error(`FAD 배포 실패(코드 ${r.code}): ${String(r.stderr).slice(0, 200)}`);
    });
    return { status: "distributed", log: ["fad 배포"] };
  }
  return new StateGraph(State)
    .addNode("preflight", preflight)
    .addNode("shadow_note", shadowNote)
    .addNode("cert_check", certCheck)
    .addNode("fad", fad)
    .addEdge(START, "preflight")
    .addConditionalEdges("preflight", (s) => (s.status === "shadow" ? "shadow_note" : s.status ? END : "cert_check"), ["shadow_note", "cert_check", END])
    .addEdge("shadow_note", END)
    .addConditionalEdges("cert_check", (s) => (s.status ? END : "fad"), ["fad", END])
    .addEdge("fad", END)
    .compile({ checkpointer });
}
