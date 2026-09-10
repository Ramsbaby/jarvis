#!/usr/bin/env node
// Privacy Guard Scanner — Phase 1
//
// Modes:
//   --staged             git staged 파일만 스캔 (pre-commit)
//   --diff=BASE..HEAD    그 구간에서 변경된 파일의 **최종 상태**만 (CI)
//   --history=BASE..HEAD 그 구간 커밋들이 **추가한 라인** 전체 (pre-push)
//   --all                tracked 전체 (감사)
//
// 왜 --history 가 따로 있나 (2026-09-10):
//   --diff 는 변경된 파일의 현재 내용만 읽는다. 한 커밋이 민감한 줄을 넣고 다음 커밋이
//   그것을 지우면 최종 상태는 깨끗해서 통과한다 — 그러나 push 하면 그 줄은 커밋 diff 로
//   그대로 공개된다. 실제 사례: 2d9647b 가 career-narratives 규칙에 걸리는 줄을 넣고
//   0f2143b 가 뺐는데 --diff 스캔은 clean 을 냈다. 저장소가 PUBLIC 이면 이건 노출이다.
//   정본을 고친 것과 히스토리를 고친 것은 다르다.
//
// 사용:
//   node scripts/privacy/scan.mjs --staged
//   node scripts/privacy/scan.mjs --all
//   node scripts/privacy/scan.mjs --diff=origin/main..HEAD
//   node scripts/privacy/scan.mjs --history=origin/main..HEAD
//
// 정책: 외부 의존 0. YAML은 sub-set 정규식 파서로 처리.
// 종료코드: 위반 0 → exit 0, 1+ → exit 1.

import { readFileSync, statSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { join, resolve, relative } from "node:path";

const ROOT = execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim();
const BLOCKLIST = join(ROOT, ".privacy-blocklist.yml");

// ───────────────────────── YAML mini-parser ─────────────────────────
// .privacy-blocklist.yml 전용. 들여쓰기 2-space, scalar/list만 지원.
function parseBlocklist(text) {
  const lines = text.split(/\r?\n/);
  const rules = [];
  const globalIgnore = [];
  let mode = null; // "rules" | "global"
  let cur = null;
  let curList = null; // {key, indent}

  const stripComment = (s) => {
    // # 앞에 quote가 없는 경우만 주석으로 본다 (간단 휴리스틱)
    let inS = false, inD = false;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (c === "'" && !inD) inS = !inS;
      else if (c === '"' && !inS) inD = !inD;
      else if (c === "#" && !inS && !inD) return s.slice(0, i);
    }
    return s;
  };
  const unquote = (v) => {
    v = v.trim();
    if (v.startsWith('"') && v.endsWith('"')) {
      // YAML double-quoted: \\ → \, \" → ", \n → newline 등 최소 처리
      return v.slice(1, -1).replace(/\\(.)/g, (_, c) => {
        if (c === "n") return "\n";
        if (c === "t") return "\t";
        if (c === "r") return "\r";
        return c; // \\ → \, \" → ", 그 외 escape는 다음 char 그대로
      });
    }
    if (v.startsWith("'") && v.endsWith("'")) {
      // YAML single-quoted: '' → ' 만 처리
      return v.slice(1, -1).replace(/''/g, "'");
    }
    return v;
  };

  for (const rawOrig of lines) {
    const raw = stripComment(rawOrig);
    if (!raw.trim()) continue;
    const indent = raw.match(/^ */)[0].length;
    const line = raw.slice(indent);

    if (indent === 0) {
      if (line.startsWith("rules:")) { mode = "rules"; cur = null; curList = null; continue; }
      if (line.startsWith("global_ignore:")) { mode = "global"; cur = null; curList = null; continue; }
      mode = null; continue;
    }

    if (mode === "global") {
      const m = line.match(/^-\s*(.+)$/);
      if (m) globalIgnore.push(unquote(m[1]));
      continue;
    }

    if (mode !== "rules") continue;

    // 새 룰 시작: "  - id: foo"
    const newRule = line.match(/^-\s*([a-z_][\w-]*)\s*:\s*(.*)$/);
    if (indent === 2 && newRule) {
      cur = {};
      rules.push(cur);
      cur[newRule[1]] = unquote(newRule[2]);
      curList = null;
      continue;
    }

    if (!cur) continue;

    // 리스트 항목
    const listItem = line.match(/^-\s*(.+)$/);
    if (listItem && curList && indent > curList.indent) {
      cur[curList.key].push(unquote(listItem[1]));
      continue;
    }

    // key: value 또는 key: (리스트 시작)
    const kv = line.match(/^([a-z_][\w-]*)\s*:\s*(.*)$/);
    if (kv) {
      const k = kv[1], v = kv[2];
      if (v === "") {
        cur[k] = [];
        curList = { key: k, indent };
      } else {
        cur[k] = unquote(v);
        curList = null;
      }
    }
  }

  return { rules, globalIgnore };
}

// ───────────────────────── glob → regex ─────────────────────────
function globToRegex(glob) {
  let re = "^";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") { re += ".*"; i++; if (glob[i + 1] === "/") i++; }
      else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else if (".+^$()|{}[]\\".includes(c)) re += "\\" + c;
    else re += c;
  }
  re += "$";
  return new RegExp(re);
}

function pathMatchesAny(path, globs) {
  if (!globs || globs.length === 0) return false;
  // 파일명만으로 매치되는 경우도 허용 (e.g. "*.md" → "foo/bar.md")
  for (const g of globs) {
    const re = globToRegex(g);
    if (re.test(path)) return true;
    const base = path.split("/").pop();
    if (re.test(base)) return true;
  }
  return false;
}

// ───────────────────────── 파일 목록 수집 ─────────────────────────
function getFiles(mode) {
  if (mode.kind === "staged") {
    const out = execSync("git diff --cached --name-only --diff-filter=ACM", { encoding: "utf8" });
    return out.split("\n").filter(Boolean);
  }
  if (mode.kind === "diff") {
    const out = execSync(`git diff --name-only --diff-filter=ACM ${mode.range}`, { encoding: "utf8" });
    return out.split("\n").filter(Boolean);
  }
  // all
  const out = execSync("git ls-files", { encoding: "utf8" });
  return out.split("\n").filter(Boolean);
}

function readFileSafe(path, mode) {
  // staged 모드는 인덱스의 내용을 읽음 (working tree 변경 무시)
  if (mode.kind === "staged") {
    try { return execSync(`git show :${path}`, { encoding: "utf8" }); }
    catch { return null; }
  }
  const abs = join(ROOT, path);
  try {
    const st = statSync(abs);
    if (!st.isFile()) return null;
    if (st.size > 2_000_000) return null; // 2MB 초과 skip
    return readFileSync(abs, "utf8");
  } catch { return null; }
}

// 바이너리 추정
const SKIP_EXT = new Set([
  "png","jpg","jpeg","gif","ico","webp","pdf","zip","tar","gz","bz2","xz",
  "woff","woff2","ttf","otf","eot","mp3","mp4","mov","wav","lock","map",
  "sqlite","db","lance","bin","class","jar","wasm",
]);
function isBinaryByExt(p) {
  const m = p.match(/\.([a-z0-9]+)$/i);
  return m && SKIP_EXT.has(m[1].toLowerCase());
}

// ───────────────────────── 스캔 본체 ─────────────────────────
// pattern_file: YAML 의 pattern 대신 private 파일에서 regex 로드.
// 파일 부재 시: pattern fallback → 둘 다 없으면 rule skip (silent).
// 목적: owner-specific 목록(회사명 등)을 공개 저장소에서 분리.
function resolvePattern(rule) {
  if (rule.pattern_file) {
    const abs = join(ROOT, rule.pattern_file);
    if (existsSync(abs)) {
      try {
        const raw = readFileSync(abs, "utf8").trim();
        if (raw) return raw;
      } catch { /* fall through */ }
    }
  }
  return rule.pattern || null;
}

function compileRules(blocklist) {
  return blocklist.rules
    .map((r) => {
      const pattern = resolvePattern(r);
      if (!pattern) return null; // 패턴 미가용 → skip
      return {
        ...r,
        re: new RegExp(pattern),
        contextRe: (r.context_allow || []).map((p) => new RegExp(p)),
      };
    })
    .filter(Boolean);
}

// 한 줄을 규칙에 걸어 위반을 만든다. 파일 스캔과 히스토리 스캔이 같은 판정을 쓰도록 공용화한다.
function matchLine({ line, path, lineNo, compiled, blocklist, extra }) {
  const found = [];
  if (!line) return found;

  // 인라인 예외 수집
  const inlineAllow = new Set();
  const inlineMatches = line.matchAll(/(?:#|\/\/)\s*privacy:allow\s+([a-z0-9,_-]+)/gi);
  for (const m of inlineMatches) {
    for (const id of m[1].split(",")) inlineAllow.add(id.trim());
  }

  for (const rule of compiled) {
    if (inlineAllow.has(rule.id)) continue;
    if (pathMatchesAny(path, rule.allow_paths)) continue;
    const m = rule.re.exec(line);
    if (!m) continue;
    if (rule.contextRe.some((cr) => cr.test(line))) continue;

    const preview = line.length > 80 ? line.slice(0, 77) + "..." : line;
    found.push({
      file: path,
      line: lineNo,
      ruleId: rule.id,
      severity: rule.severity || "medium",
      match: m[0],
      preview: preview.trim(),
      ...(extra || {}),
    });
  }
  return found;
}

// 커밋들이 추가한 라인을 스캔한다. diff 헤더로 파일 경로를 추적해
// globalIgnore·allow_paths 가 파일 스캔과 동일하게 적용되도록 한다.
function scanHistory(range, blocklist) {
  const compiled = compileRules(blocklist);
  const violations = [];

  let shas;
  try {
    shas = execSync(`git log --format=%H ${range}`, { encoding: "utf8" })
      .split("\n").filter(Boolean);
  } catch {
    console.error(`❌ history 범위를 읽지 못했습니다: ${range}`);
    process.exit(2);
  }

  for (const sha of shas) {
    let diff;
    try {
      diff = execSync(
        `git show ${sha} --format=%x00%h%x00%s --unified=0 --no-color`,
        { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
      );
    } catch { continue; }

    let short = sha.slice(0, 7);
    let subject = "";
    let curPath = null;
    let lineNo = 0;

    for (const line of diff.split(/\r?\n/)) {
      if (line.startsWith(" ")) {
        const parts = line.split(" ");
        short = parts[1] || short;
        subject = parts[2] || "";
        continue;
      }
      if (line.startsWith("+++ ")) {
        const p = line.slice(4).trim();
        curPath = p === "/dev/null" ? null : p.replace(/^b\//, "");
        lineNo = 0;
        continue;
      }
      if (line.startsWith("--- ") || line.startsWith("diff --git ")) continue;
      if (line.startsWith("@@")) {
        const m = /^@@ -\d+(?:,\d+)? \+(\d+)/.exec(line);
        lineNo = m ? Number(m[1]) : 0;
        continue;
      }
      if (!line.startsWith("+")) continue;

      const added = line.slice(1);
      lineNo += 1;
      if (!curPath) continue;
      if (pathMatchesAny(curPath, blocklist.globalIgnore)) continue;
      if (isBinaryByExt(curPath)) continue;

      violations.push(
        ...matchLine({
          line: added,
          path: curPath,
          lineNo,
          compiled,
          blocklist,
          extra: { commit: short, subject },
        }),
      );
    }
  }
  return violations;
}

function scan(files, blocklist, mode) {
  const violations = [];
  const compiled = compileRules(blocklist);

  for (const f of files) {
    if (pathMatchesAny(f, blocklist.globalIgnore)) continue;
    if (isBinaryByExt(f)) continue;
    const content = readFileSafe(f, mode);
    if (content === null) continue;

    const lines = content.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      violations.push(
        ...matchLine({
          line: lines[i],
          path: f,
          lineNo: i + 1,
          compiled,
          blocklist,
        }),
      );
    }
  }
  return violations;
}

// ───────────────────────── CLI ─────────────────────────
const SEV_ORDER = { critical: 0, high: 1, medium: 2, low: 3 };

function parseArgs(argv) {
  let mode = null;
  let minSeverity = "low"; // 기본: 모든 severity 차단
  for (const a of argv) {
    if (a === "--staged") mode = { kind: "staged" };
    else if (a === "--all") mode = { kind: "all" };
    else if (a.startsWith("--diff=")) mode = { kind: "diff", range: a.slice(7) };
    else if (a.startsWith("--history=")) mode = { kind: "history", range: a.slice(10) };
    else if (a.startsWith("--min-severity=")) minSeverity = a.slice(15);
  }
  return mode ? { ...mode, minSeverity } : null;
}

function main() {
  const mode = parseArgs(process.argv.slice(2));
  if (!mode) {
    console.error("Usage: scan.mjs --staged | --all | --diff=BASE..HEAD | --history=BASE..HEAD [--min-severity=high]");
    process.exit(2);
  }
  if (!existsSync(BLOCKLIST)) {
    console.error(`❌ blocklist not found: ${BLOCKLIST}`);
    process.exit(2);
  }

  const blocklist = parseBlocklist(readFileSync(BLOCKLIST, "utf8"));
  if (blocklist.rules.length === 0) {
    console.error("⚠️  blocklist parsed 0 rules — check YAML format");
    process.exit(2);
  }

  let files = [];
  let violations;
  if (mode.kind === "history") {
    violations = scanHistory(mode.range, blocklist);
  } else {
    files = getFiles(mode);
    violations = scan(files, blocklist, mode);
  }

  if (violations.length === 0) {
    const scope = mode.kind === "history" ? `range=${mode.range}` : `files=${files.length}`;
    console.log(`✅ Privacy scan clean (mode=${mode.kind}, ${scope}, rules=${blocklist.rules.length})`);
    process.exit(0);
  }

  // 출력
  violations.sort((a, b) => (SEV_ORDER[a.severity] ?? 9) - (SEV_ORDER[b.severity] ?? 9));

  const bySev = {};
  for (const v of violations) bySev[v.severity] = (bySev[v.severity] || 0) + 1;

  // min-severity 기준으로 blocking/warning 분리
  const minSevLevel = SEV_ORDER[mode.minSeverity] ?? 3;
  const blocking = violations.filter(v => (SEV_ORDER[v.severity] ?? 9) <= minSevLevel);
  const warnings = violations.filter(v => (SEV_ORDER[v.severity] ?? 9) > minSevLevel);

  if (blocking.length > 0) {
    console.log(`🚨 Privacy violations (BLOCKING): ${blocking.length} / total: ${violations.length}`);
    console.log(`   by severity:`, bySev);
    console.log("");
    for (const v of blocking) {
      console.log(`  ${v.file}:${v.line}  [${v.severity}/${v.ruleId}]  ${v.match}`);
      console.log(`    ${v.preview}`);
    }
  }
  if (warnings.length > 0) {
    console.log(`⚠️  Privacy warnings (non-blocking, min-severity=${mode.minSeverity}): ${warnings.length}`);
    for (const v of warnings) {
      console.log(`  ${v.file}:${v.line}  [${v.severity}/${v.ruleId}]  ${v.match}`);
    }
  }
  console.log("");
  console.log("ℹ️  Bypass options:");
  console.log("   • 같은 라인 끝에 `# privacy:allow <rule-id>` 주석");
  console.log("   • PRIVACY_BYPASS_REASON='<사유>' git commit ... (pre-commit only)");

  if (blocking.length > 0) {
    process.exit(1);
  } else {
    // warnings only — 보고는 하지만 CI 차단 없음
    process.exit(0);
  }
}

main();
