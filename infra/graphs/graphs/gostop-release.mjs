// gostop-release.mjs — 고스톱 출시(설계 §5.3). **실제 모드 전용** — 그림자는 '했을 일'만 적고 끝난다.
//   preflight(모드·기대 지문) → cert_check(APK 서명 인증서 SHA-256 을 기대값과 대조 — 다르면 여기서 멈춘다) → fad(effect: 테스터 배포)
// 지금 판(1b 통합)은 '서명 지문이 다르면 배포 정지'까지다. 버전 올리기·APK 빌드·설치·에뮬레이터 연기는 다음 판(설계 §5.3 2·3·5·6).
// 기대 지문은 LG_RELEASE_CERT_SHA256(공개 인증서 지문 — 비밀 아님). 키·비밀번호는 읽지 않는다(keytool -printcert 는 APK 안 공개 인증서만 본다).
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";

export const meta = { name: "gostop-release", description: "고스톱 출시(실제 전용) — 서명 지문 대조 뒤 테스터 배포", serial: true };

const last = (a, b) => (b === undefined ? a : b);
const State = Annotation.Root({
  apk: Annotation(),
  version: Annotation(),
  mode: Annotation({ reducer: last, default: () => "shadow" }),
  expected: Annotation({ reducer: last, default: () => null }),
  actual: Annotation({ reducer: last, default: () => null }),
  status: Annotation({ reducer: last, default: () => null }),
  log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }),
});

const FP_RE = /^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/;
export const normFp = (s) => String(s ?? "").trim().toUpperCase().replace(/[^0-9A-F]/g, "").replace(/(..)(?!$)/g, "$1:");
// keytool -printcert 출력의 SHA256 지문들(서명자가 여럿이면 전부)
export function certFingerprints(text) {
  return [...String(text ?? "").matchAll(/SHA-?256:\s*([0-9A-Fa-f:]{64,95})/g)].map((m) => normFp(m[1])).filter((f) => FP_RE.test(f));
}

export function input(flags) {
  const apk = String(flags.apk ?? "");
  const version = String(flags.version ?? "");
  if (!/^\/.+\.apk$/.test(apk) || !/^[0-9]{1,6}$/.test(version)) throw new Error("gostop-release 시작에는 --apk=<절대경로.apk> 와 --version=<versionCode> 가 필요하다");
  return { apk, version };
}
export const summarize = (v) => `${v.status ?? "?"} · v${v.version ?? "?"}${v.actual && v.status === "signing_mismatch" ? ` · 지문 ${v.actual.slice(0, 11)}…` : ""}`;

export function build({ checkpointer, tools }) {
  function preflight(s) {
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
    const r = await tools.run("apk.cert-fingerprint", { apk: s.apk });
    const fps = r.code === 0 ? certFingerprints(r.stdout) : [];
    if (!fps.length) return { status: "cert_unreadable", log: [`지문을 읽지 못함(코드 ${r.code})`] };
    // 서명자가 여럿이면 전부 기대값이어야 한다
    if (fps.some((f) => f !== s.expected)) return { actual: fps.find((f) => f !== s.expected), status: "signing_mismatch", log: ["서명 지문 불일치 — 배포 정지"] };
    return { actual: fps[0], log: ["서명 지문 일치"] };
  }
  async function fad(s) {
    const app = String(process.env.LG_FAD_APP_ID ?? "");
    await tools.effect(`gostop-fad:${s.version}`, "fad_distribute", async () => {
      const r = await tools.run("fad.distribute", { apk: s.apk, app, groups: process.env.LG_FAD_GROUPS || "testers" });
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
