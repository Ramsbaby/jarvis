#!/usr/bin/env node
// Privacy Guard Scanner — Phase 1
//
// Modes:
//   --staged          git staged 파일만 스캔 (pre-commit)
//   --diff=BASE..HEAD 두 ref 사이 변경 파일만 (CI)
//   --all             tracked 전체 (감사)
//
// 사용:
//   node scripts/privacy/scan.mjs --staged
//   node scripts/privacy/scan.mjs --all
//   node scripts/privacy/scan.mjs --diff=origin/main..HEAD
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

function scan(files, blocklist, mode) {
  const violations = [];
  const compiled = blocklist.rules
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

  for (const f of files) {
    if (pathMatchesAny(f, blocklist.globalIgnore)) continue;
    if (isBinaryByExt(f)) continue;
    const content = readFileSafe(f, mode);
    if (content === null) continue;

    const lines = content.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!line) continue;

      // 인라인 예외 수집
      const inlineAllow = new Set();
      const inlineMatches = line.matchAll(/(?:#|\/\/)\s*privacy:allow\s+([a-z0-9,_-]+)/gi);
      for (const m of inlineMatches) {
        for (const id of m[1].split(",")) inlineAllow.add(id.trim());
      }

      for (const rule of compiled) {
        if (inlineAllow.has(rule.id)) continue;
        if (pathMatchesAny(f, rule.allow_paths)) continue;
        const m = rule.re.exec(line);
        if (!m) continue;
        // context_allow: 같은 라인에 허용 패턴이 있으면 skip
        if (rule.contextRe.some((cr) => cr.test(line))) continue;

        const preview = line.length > 80 ? line.slice(0, 77) + "..." : line;
        violations.push({
          file: f,
          line: i + 1,
          ruleId: rule.id,
          severity: rule.severity || "medium",
          match: m[0],
          preview: preview.trim(),
        });
      }
    }
  }
  return violations;
}

// ───────────────────────── CLI ─────────────────────────
function parseArgs(argv) {
  for (const a of argv) {
    if (a === "--staged") return { kind: "staged" };
    if (a === "--all") return { kind: "all" };
    if (a.startsWith("--diff=")) return { kind: "diff", range: a.slice(7) };
  }
  return null;
}

function main() {
  const mode = parseArgs(process.argv.slice(2));
  if (!mode) {
    console.error("Usage: scan.mjs --staged | --all | --diff=BASE..HEAD");
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

  const files = getFiles(mode);
  const violations = scan(files, blocklist, mode);

  if (violations.length === 0) {
    console.log(`✅ Privacy scan clean (mode=${mode.kind}, files=${files.length}, rules=${blocklist.rules.length})`);
    process.exit(0);
  }

  // 출력
  const sevOrder = { critical: 0, high: 1, medium: 2, low: 3 };
  violations.sort((a, b) => (sevOrder[a.severity] ?? 9) - (sevOrder[b.severity] ?? 9));

  const bySev = {};
  for (const v of violations) bySev[v.severity] = (bySev[v.severity] || 0) + 1;

  console.log(`🚨 Privacy violations: ${violations.length}`);
  console.log(`   by severity:`, bySev);
  console.log("");
  for (const v of violations) {
    console.log(`  ${v.file}:${v.line}  [${v.severity}/${v.ruleId}]  ${v.match}`);
    console.log(`    ${v.preview}`);
  }
  console.log("");
  console.log("ℹ️  Bypass options:");
  console.log("   • 같은 라인 끝에 `# privacy:allow <rule-id>` 주석");
  console.log("   • PRIVACY_BYPASS_REASON='<사유>' git commit ... (pre-commit only)");
  process.exit(1);
}

main();
