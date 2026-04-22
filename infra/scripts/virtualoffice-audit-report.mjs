#!/usr/bin/env node
/**
 * virtualoffice-audit-report.mjs — Phase 3
 *
 * observations.jsonl + inventory.json → 마크다운 리포트 생성.
 *
 * 출력:
 *   ~/.jarvis/ # ALLOW-DOTJARVISstate/virtualoffice-audit/reports/{YYYYMMDD}-{session}.md
 *
 * Usage:
 *   node virtualoffice-audit-report.mjs                        # 최신 세션
 *   node virtualoffice-audit-report.mjs --session 20260420-1500
 *   node virtualoffice-audit-report.mjs --stdout               # stdout 도 출력
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { homedir } from 'node:os';

const argv = process.argv.slice(2);
function flag(n)       { return argv.includes(`--${n}`); }
function opt(n, dflt)  { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : dflt; }

const SESSION_OPT = opt('session', null);
const STDOUT_ECHO = flag('stdout');

const STATE_DIR    = join(homedir(), '.jarvis', 'state', 'virtualoffice-audit');
const INVENTORY    = join(STATE_DIR, 'inventory.json');
const SESSIONS_DIR = join(STATE_DIR, 'sessions');
const REPORTS_DIR  = join(STATE_DIR, 'reports');

mkdirSync(REPORTS_DIR, { recursive: true });

if (!existsSync(INVENTORY)) {
  console.error('❌ inventory.json 없음. Phase 1 먼저 실행.');
  process.exit(1);
}

function latestSession() {
  if (!existsSync(SESSIONS_DIR)) return null;
  const dirs = readdirSync(SESSIONS_DIR).filter((n) => /^\d{8}-\d{4}$/.test(n));
  dirs.sort();
  return dirs.at(-1) || null;
}

const sessionName = SESSION_OPT || latestSession();
if (!sessionName) {
  console.error('❌ 세션 없음. Phase 2 먼저 실행.');
  process.exit(1);
}

const sessionDir = join(SESSIONS_DIR, sessionName);
const obsFile    = join(sessionDir, 'observations.jsonl');
const shotsDir   = join(sessionDir, 'screenshots');
const transcriptFile = join(sessionDir, 'transcript.log');

// ── 데이터 로드 ──────────────────────────────────────────────────────────
const inventory = JSON.parse(readFileSync(INVENTORY, 'utf-8'));

let observations = [];
if (existsSync(obsFile)) {
  const obsLines = readFileSync(obsFile, 'utf-8').split('\n').filter(Boolean);
  observations = obsLines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}

const transcript = existsSync(transcriptFile) ? readFileSync(transcriptFile, 'utf-8') : '';

if (observations.length === 0 && !transcript.trim()) {
  console.error(`❌ observations.jsonl·transcript.log 모두 비어있음: ${sessionDir}`);
  process.exit(1);
}

// ── 집계 ─────────────────────────────────────────────────────────────────
const total   = observations.length;
const okCnt   = observations.filter((o) => o.ok).length;
const failCnt = observations.filter((o) => !o.ok && !o.safe_mode_skipped).length;
const skipCnt = observations.filter((o) => o.safe_mode_skipped).length;
const overcookFromRun = observations.filter((o) => o.overcook_note).map((o) => ({ step_id: o.step_id, note: o.overcook_note }));
const overcookFromStatic = inventory.overcook_suspects || [];

// ── 마크다운 섹션 빌더 ──────────────────────────────────────────────────
const now = new Date();
const ymd = now.toISOString().slice(0, 10);
const outPath = join(REPORTS_DIR, `${ymd}-${sessionName}.md`);

function mdEscape(s) { return String(s).replace(/\|/g, '\\|'); }

function buildSummary() {
  return [
    `# VirtualOffice(자비스맵) 전수조사 리포트`,
    ``,
    `- **세션**: \`${sessionName}\``,
    `- **생성**: ${now.toISOString()}`,
    `- **대상**: ${inventory.board_root ?? '(unknown)'}`,
    `- **총 step**: ${total}`,
    `- **정상**: ${okCnt}`,
    `- **이상**: ${failCnt}`,
    `- **safe_mode 스킵**: ${skipCnt}`,
    `- **오버쿡 의심**: 정적 ${overcookFromStatic.length} + 실행 중 ${overcookFromRun.length} = **${overcookFromStatic.length + overcookFromRun.length}**`,
    ``,
  ].join('\n');
}

function buildAnomalies() {
  const failed = observations.filter((o) => !o.ok && !o.safe_mode_skipped);
  if (failed.length === 0) return `## ⚠️ 이상 동작\n\n*이상 없음.*\n`;
  const lines = [`## ⚠️ 이상 동작 (${failed.length}건)`, ''];
  for (const o of failed) {
    const shot = relative(REPORTS_DIR, o.screenshot || '');
    lines.push(`### \`${o.step_id}\` (${o.layer})`);
    lines.push(`- **컴포넌트**: ${o.component ?? '-'}`);
    lines.push(`- **수행**: ${o.action ?? '(응답 파싱 실패)'}`);
    lines.push(`- **관측**: ${o.observed ?? '-'}`);
    lines.push(`- **기대 일치**: ${o.matches_expected === false ? '❌ 불일치' : '(판정 없음)'}`);
    if (o.issues?.length) lines.push(`- **이슈**: ${o.issues.join(' / ')}`);
    if (o.claude_timed_out) lines.push(`- **상태**: Claude 타임아웃`);
    if (o.claude_exit && o.claude_exit !== 0) lines.push(`- **Claude exit**: ${o.claude_exit}`);
    if (o.screenshot && existsSync(o.screenshot)) lines.push(`- **스크린샷**: [${o.step_id}.png](${shot})`);
    lines.push('');
  }
  return lines.join('\n');
}

function buildOvercooks() {
  const lines = [`## 🔁 오버쿡 의심`, ''];
  if (overcookFromStatic.length) {
    lines.push(`### 정적 분석 (${overcookFromStatic.length}건)`, '');
    lines.push(`| 패턴 | 파일 | 심각도 |`);
    lines.push(`|---|---|---|`);
    for (const s of overcookFromStatic) {
      lines.push(`| ${mdEscape(s.pattern)} | ${(s.files || []).join(', ')} | ${s.severity ?? '-'} |`);
    }
    lines.push('');
  }
  if (overcookFromRun.length) {
    lines.push(`### 실행 중 감지 (${overcookFromRun.length}건)`, '');
    lines.push(`| Step | 노트 |`);
    lines.push(`|---|---|`);
    for (const r of overcookFromRun) lines.push(`| \`${r.step_id}\` | ${mdEscape(r.note)} |`);
    lines.push('');
  }
  if (overcookFromStatic.length === 0 && overcookFromRun.length === 0) lines.push('*감지된 항목 없음.*');
  return lines.join('\n');
}

function buildDevTasks() {
  // 이상 + overcook 묶어서 dev-tasks 등록 템플릿 생성
  const items = [];
  for (const o of observations.filter((o) => !o.ok && !o.safe_mode_skipped)) {
    items.push({
      title: `[자비스맵] ${o.step_id} 이상 동작`,
      body: `- step: \`${o.step_id}\` (${o.layer})\n- 수행: ${o.action ?? '-'}\n- 관측: ${o.observed ?? '-'}\n- 이슈: ${(o.issues || []).join(' / ') || '-'}\n- 세션: ${sessionName}`,
    });
  }
  for (const r of overcookFromRun) {
    items.push({
      title: `[자비스맵/오버쿡] ${r.step_id}`,
      body: `실행 중 감지된 중복/과도 기능.\n\n> ${r.note}\n\n세션: ${sessionName}`,
    });
  }
  for (const s of overcookFromStatic) {
    items.push({
      title: `[자비스맵/정적] ${s.pattern.slice(0, 60)}`,
      body: `정적 분석으로 발견된 중복 패턴.\n\n- 패턴: ${s.pattern}\n- 파일: ${(s.files || []).join(', ')}\n- 심각도: ${s.severity ?? '-'}`,
    });
  }
  if (items.length === 0) return `## 📌 dev-tasks 등록 권고\n\n*등록할 항목 없음.*\n`;
  const lines = [`## 📌 dev-tasks 등록 권고 (${items.length}건)`, '', '아래 블록은 복붙용 템플릿입니다.', ''];
  for (const it of items) {
    lines.push('```');
    lines.push(`title: ${it.title}`);
    lines.push('body: |');
    for (const ln of it.body.split('\n')) lines.push(`  ${ln}`);
    lines.push('```');
    lines.push('');
  }
  return lines.join('\n');
}

function buildGallery() {
  const lines = [`## 📸 스크린샷 갤러리`, ''];
  if (!existsSync(shotsDir)) return lines.concat(['*스크린샷 없음.*']).join('\n');
  const sorted = [...observations].sort((a, b) => a.step_id.localeCompare(b.step_id));
  for (const o of sorted) {
    if (!o.screenshot || !existsSync(o.screenshot)) continue;
    const rel = relative(REPORTS_DIR, o.screenshot);
    const icon = o.ok ? '✅' : (o.safe_mode_skipped ? '🚧' : '⚠️');
    lines.push(`### ${icon} \`${o.step_id}\``);
    lines.push(`![${o.step_id}](${rel})`);
    lines.push('');
  }
  return lines.join('\n');
}

function buildIntentReview() {
  const intent = inventory.project_intent;
  if (!intent) return '';
  const withIntent = observations.filter((o) => o.intent_fit);
  const lowFit   = withIntent.filter((o) => o.intent_fit === 'low');
  const unknown  = withIntent.filter((o) => o.intent_fit === 'unknown');
  const noJust   = observations.filter((o) => !o.justification);

  const lines = [
    `## 🎯 프로젝트 의도 부합 검토`,
    '',
    `**의도 SSoT**: \`${intent.source}\``,
    '',
    `**4기둥**:`,
    ...intent.pillars.map((p, i) => `${i + 1}. ${p}`),
    '',
  ];

  if (withIntent.length === 0) {
    lines.push('_이번 세션에서는 intent_fit 판정이 기록되지 않았습니다 (구버전 프롬프트로 실행된 경우)._', '');
  } else {
    // 분포 요약
    const dist = { high: 0, mid: 0, low: 0, unknown: 0 };
    for (const o of withIntent) dist[o.intent_fit] = (dist[o.intent_fit] || 0) + 1;
    lines.push(`### 부합도 분포`, '');
    lines.push(`| 수준 | 건수 | 비고 |`);
    lines.push(`|---|---:|---|`);
    lines.push(`| 🟢 high | ${dist.high || 0} | 4기둥에 직접 기여 |`);
    lines.push(`| 🟡 mid | ${dist.mid || 0} | 간접 기여·UX |`);
    lines.push(`| 🔴 low | ${dist.low || 0} | **무관·잡음 — 제거/재설계 후보** |`);
    lines.push(`| ⚪ unknown | ${dist.unknown || 0} | 판정 불가 |`);
    lines.push('');
  }

  if (lowFit.length > 0) {
    lines.push(`### 🔴 제거·재설계 후보 (intent_fit = low)`, '');
    for (const o of lowFit) {
      lines.push(`- \`${o.step_id}\` — ${o.observed ?? o.action ?? '(관측 기록 없음)'}`);
      if (o.justification) lines.push(`  - 기록된 존재 이유: "${o.justification}"`);
    }
    lines.push('');
  }

  if (noJust.length > 0) {
    lines.push(`### ❓ 존재 이유 불명 (justification = null)`, '');
    lines.push(`Claude 가 "이 기능이 왜 필요한가"에 한 문장으로도 답하지 못한 step. 기획 재검토 후보.`, '');
    for (const o of noJust.slice(0, 20)) {
      lines.push(`- \`${o.step_id}\` — ${o.action ?? '(조작 기록 없음)'}`);
    }
    if (noJust.length > 20) lines.push(`- …외 ${noJust.length - 20}건`);
    lines.push('');
  }

  if (lowFit.length === 0 && noJust.length === 0 && withIntent.length > 0) {
    lines.push('_제거·재설계 후보 없음 — 모든 감사 대상이 의도에 부합._', '');
  }

  return lines.join('\n');
}

function buildTranscriptSection() {
  if (!transcript.trim()) return '';
  // transcript.log 에서 STEP_RESULT 가 아닌 자유 텍스트·마크다운 요약을 추출
  const lines = transcript.split('\n');
  const nonResultLines = lines.filter((l) => l.trim() && !/^STEP_RESULT:/.test(l) && l.trim() !== 'AUDIT_DONE');
  if (nonResultLines.length === 0) return '';
  const body = nonResultLines.join('\n').trim();
  return [
    `## 📝 Claude 자유 형식 관찰 (transcript)`,
    '',
    `observations.jsonl 에 구조화되지 못했으나 Claude 가 남긴 자연어 요약·마크다운 표 등.`,
    `전수조사 품질·맥락 보강용.`,
    '',
    '```markdown',
    body.slice(0, 8000),  // 너무 길면 자름
    body.length > 8000 ? '\n… (잘림 — 원본은 transcript.log 참조)' : '',
    '```',
    '',
    `원본: \`${transcriptFile}\``,
    '',
  ].join('\n');
}

function buildScanSummary() {
  const rows = inventory.scan_summary || [];
  if (rows.length === 0) return '';
  const lines = [`## 🔍 정적 스캔 요약`, '', `| 컴포넌트 | 파일 | 줄 수 | onClick | <button> | role=button |`, `|---|---|---:|---:|---:|---:|`];
  for (const r of rows) {
    lines.push(`| ${r.component} | ${r.relPath} | ${r.lineCount} | ${r.onClickCount} | ${r.buttonCount} | ${r.roleButton} |`);
  }
  lines.push('');
  return lines.join('\n');
}

// ── 조립 ────────────────────────────────────────────────────────────────
const md = [
  buildSummary(),
  buildIntentReview(),
  buildAnomalies(),
  buildOvercooks(),
  buildDevTasks(),
  buildTranscriptSection(),
  buildScanSummary(),
  buildGallery(),
  '---',
  `_자동 생성 — 다시 만들려면:_ \`node virtualoffice-audit-report.mjs --session ${sessionName}\``,
].join('\n');

writeFileSync(outPath, md);

console.log(`✅ 리포트 저장: ${outPath}`);
console.log(`   세션: ${sessionName}  /  총 step: ${total}  /  정상: ${okCnt}  /  이상: ${failCnt}  /  스킵: ${skipCnt}`);

if (STDOUT_ECHO) { console.log('\n──\n'); console.log(md); }
