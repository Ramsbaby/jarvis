#!/usr/bin/env node
// patch-allowlist.mjs — 패치가 건드린 파일을 '허용'(규칙 처리 — 설계 §4①)과 '승인 사유'로 나눈다(§5.2⑤⑩).
//
//   node patch-allowlist.mjs --patch <패치 파일> [--clean <내보내기>] [--copy <사본>] [--ai-check pass|fail|unavailable] [--frozen <경로>]…
//   → JSON 한 줄 {ok, allowed:[…], reasons:[{path, reason, detail}], byReason:{…}}. 승인 사유가 하나라도 있으면 ok:false(종료 3).
//
// 허용 목록 방식이다 — 결제·외부 송출 파일을 하나하나 이름으로 맞히지 않아도 목록 밖은 전부 승인 대상이 된다(L 중5).
// 사유 이름은 승인 질문을 읽기 쉽게 하려는 꼬리표다. 판정 자체는 '허용에 들었나'로 끝난다.
// 고스톱 실제 구조(10-03 d1a2557, 읽기만)로 정했다:
//   · AI: lib/domain/ai/**(ai_player·mcts·coach·persona·난이도 조정) + lib/core/constants.dart 의 class MCTSConstants
//   · 결제: lib/data/services/{iap,season_pass,vip_point,card_skin}_service.dart · lib/domain/{monetization,economy}/** · 스킨 상점 화면
//   · 송출: bug_report(디스코드 웹훅)·analytics·crashlytics·push·share·leaderboard·network·deep_link·version_checker·app_review·admob
//   · 생성 코드: lib/data/models/*.g.dart 등 · 골든: test/goldens/*.png · integration_test/golden_images/*.png
//   · 번역: 지금은 없다(arb·l10n 0개) — 생기면 잡히게 일반 경로를 넣었다.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseUnifiedDiff } from "./unified-diff.mjs";

// 허용(§4①). 조건부: §4② AI 판정('같은 상태, 같은 결정')을 통과해야 허용. turn_manager.dart 는 lib/domain/game/ 아래라 이미 허용.
export const ALLOW_PREFIXES = ["lib/domain/game/", "test/"];
export const CONDITIONAL = new Set(["lib/presentation/providers/game_provider.dart", "lib/presentation/providers/bomb_handler.dart"]);
export const MCTS_FILE = "lib/core/constants.dart";

// 앞에서부터 처음 맞는 사유 하나를 붙인다. 허용 경로 안이라도 여기 걸리면 승인 사유다(test/goldens/*.png, test/**/*.g.dart 등).
export const REASON_RULES = [
  ["ai_boundary", (p) => p.startsWith("lib/domain/ai/")],
  ["generated", (p) => /\.(g|freezed|gr|mocks|config|pb|pbenum|pbjson|pbserver|chopper|reflectable)\.dart$/.test(p) || p.startsWith("lib/generated/")],
  ["golden", (p) => /(^|\/)(goldens?|golden_images)\//.test(p) || /(^|\/)failures\/.*\.png$/.test(p)],
  ["pubspec", (p) => /^(pubspec\.(yaml|lock)|pubspec_overrides\.yaml)$/.test(p)],
  // 시험·분석 관문의 설정. 바꾸면 검사가 약해진다(규칙 끄기·시험 건너뛰기).
  ["gate_config", (p) => /^(analysis_options\.yaml|quality_gates\.yaml|dart_test\.yaml|build\.yaml|\.gitattributes|\.gitignore|\.github\/|scripts\/|tools\/)/.test(p) || /(^|\/)flutter_test_config\.dart$/.test(p)],
  ["platform", (p) => /^(android|ios|macos|web|linux|windows)\//.test(p) || /^(firebase\.json|\.firebaserc|google-services\.json)$/.test(p)],
  ["payment", (p) => /^lib\/data\/services\/(iap|season_pass|vip_point|card_skin)_service\.dart$/.test(p) || /^lib\/domain\/(monetization|economy)\//.test(p)
    || /^lib\/presentation\/screens\/(shop|skin|store|pass|vip|iap)\//.test(p) || /(iap|purchase|billing|paywall|monetiz|top_up|season_pass|vip_point)/i.test(p)],
  ["external_send", (p) => /^lib\/(data|core)\/services\/(bug_report|analytics|crashlytics|push_notification|share|leaderboard|network|deep_link|version_checker|app_review|admob)_service\.dart$/.test(p)
    || /(webhook|discord|mailer|smtp|telemetry|crashlytics|analytics|remote_config|push_notif)/i.test(p)],
  ["l10n", (p) => /(^|\/)l10n(\/|\.yaml$)/.test(p) || /\.arb$/.test(p) || /^assets\/(translations|i18n|lang|locales?)\//.test(p)],
  ["assets", (p) => /^(assets|fonts)\//.test(p) || /\.(png|jpe?g|gif|webp|svg|ttf|otf|mp3|wav|ogg|m4a|riv|flr)$/i.test(p)],
];
// 내용으로 보는 사유(파일 경로로 못 맞히는 것). 패치 전·후 파일 중 하나라도 맞으면.
export const CONTENT_RULES = [
  ["payment", /package:in_app_purchase|InAppPurchase\b|purchaseStream|buyConsumable|buyNonConsumable/],
  ["external_send", /package:(http|dio|url_launcher|share_plus|firebase_messaging|mailer|web_socket_channel)\/|\bHttpClient\s*\(|discord(app)?\.com\/api\/webhooks|\bmailto:/],
];

// MCTSConstants 클래스가 차지하는 줄 범위(1부터). 괄호 짝으로 끝을 찾는다(문자열·주석 속 괄호는 드물어 무시 — 틀려도 넓게 잡힐 뿐).
export function classRange(text, name) {
  const lines = text.split("\n");
  const start = lines.findIndex((l) => new RegExp(`^\\s*(abstract\\s+)?class\\s+${name}\\b`).test(l));
  if (start < 0) return null;
  let depth = 0, seen = false;
  for (let i = start; i < lines.length; i++) {
    for (const ch of lines[i]) {
      if (ch === "{") { depth++; seen = true; } else if (ch === "}") depth--;
    }
    if (seen && depth <= 0) return [start + 1, i + 1];
  }
  return [start + 1, lines.length];
}

const readIf = (dir, rel) => {
  if (!dir || !rel) return null;
  try {
    const p = path.join(dir, rel);
    return fs.lstatSync(p).isFile() ? fs.readFileSync(p, "utf8") : null; // 바로가기는 따라가지 않는다
  } catch { return null; }
};

// files: parseUnifiedDiff 결과. aiCheck: §4② 결과(pass·fail·unavailable). frozen: 이번 수정이 건드리면 안 되는 경로(예: ⑦이 쓴 재현 시험).
export function classifyPatch(files, { clean, copy, aiCheck = "unavailable", frozen = [] } = {}) {
  const allowed = [];
  const reasons = [];
  const add = (p, reason, detail) => reasons.push({ path: p, reason, detail });
  if (aiCheck === "fail") add("*", "ai_decision_changed", "같은 상태에서 AI 결정이 바뀌었다(§4②)");
  for (const f of files) {
    const p = f.path;
    const before = readIf(clean, f.oldPath);
    const after = readIf(copy, f.newPath);
    const changed = f.hunks.flatMap((h) => h.lines.filter((l) => l.t !== " "));
    let r = null;
    if (frozen.some((z) => (z.endsWith("/") ? p.startsWith(z) : p === z))) r = ["frozen", "이 단계에서 바꾸면 안 되는 파일(앞 단계가 쓴 시험 등)"];
    if (!r && changed.some((l) => /\bMCTSConstants\b/.test(l.s))) r = ["ai_boundary", "MCTSConstants 를 바꾸거나 쓰는 줄"];
    if (!r && p === MCTS_FILE) {
      const range = before ? classRange(before, "MCTSConstants") : null;
      const touches = !range || changed.some((l) => l.oldNo !== null && l.oldNo >= range[0] && l.oldNo <= range[1])
        || f.hunks.some((h) => h.oldStart <= range[1] && h.oldStart + Math.max(h.oldLines, 1) - 1 >= range[0] && h.lines.some((l) => l.t === "+"));
      if (touches) r = ["ai_boundary", range ? `MCTSConstants(${range[0]}~${range[1]}줄)` : "constants.dart(내보내기를 못 읽어 넓게 본다)"];
    }
    if (!r) for (const [name, test] of REASON_RULES) if (test(p)) { r = [name, "경로"]; break; }
    if (!r) for (const [name, re] of CONTENT_RULES) if ((before && re.test(before)) || (after && re.test(after))) { r = [name, "내용"]; break; }
    if (!r && f.status === "deleted" && p.startsWith("test/")) r = ["test_removed", "기존 시험 파일 삭제"];
    if (!r && CONDITIONAL.has(p)) {
      if (aiCheck !== "pass") r = ["ai_check_unavailable", "규칙 처리부지만 AI 판정(§4②)을 통과하지 않았다"];
    }
    if (!r && !CONDITIONAL.has(p) && !ALLOW_PREFIXES.some((a) => p.startsWith(a))) r = ["outside_allowlist", "허용 목록 밖"];
    if (r) add(p, r[0], r[1]);
    else allowed.push(p);
  }
  const byReason = {};
  for (const x of reasons) (byReason[x.reason] ??= []).push(x.path);
  return { ok: reasons.length === 0, allowed, reasons, byReason };
}

export function classifyPatchText(patchText, opts) { return classifyPatch(parseUnifiedDiff(patchText), opts); }

function main(argv) {
  const o = { frozen: [] };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--frozen") o.frozen.push(argv[++i]);
    else if (["--patch", "--clean", "--copy", "--ai-check"].includes(k)) o[k.slice(2)] = argv[++i];
    else { process.stderr.write(`모르는 인자: ${k}\n`); process.exit(2); }
  }
  if (!o.patch) { process.stderr.write("--patch 가 있어야 한다\n"); process.exit(2); }
  if (o["ai-check"] && !["pass", "fail", "unavailable"].includes(o["ai-check"])) { process.stderr.write("--ai-check 는 pass·fail·unavailable\n"); process.exit(2); }
  const r = classifyPatchText(fs.readFileSync(o.patch, "utf8"), { clean: o.clean, copy: o.copy, aiCheck: o["ai-check"] ?? "unavailable", frozen: o.frozen });
  process.stdout.write(`${JSON.stringify(r)}\n`);
  process.exit(r.ok ? 0 : 3);
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
