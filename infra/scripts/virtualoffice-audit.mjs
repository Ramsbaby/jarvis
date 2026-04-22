#!/usr/bin/env node
/**
 * virtualoffice-audit.mjs — Phase 2 (v4: 1-step-per-spawn)
 *
 * 자비스맵(VirtualOffice) UI 요소 전수조사 실행기.
 *
 * v4 설계 근거:
 *   - v2 (메가 프롬프트·단일 세션) 에서 Claude 가 여러 step 중 마지막 1개만 상세 감사하는
 *     구조적 편향이 확인됨 (4번 실험 재현).
 *   - v4 = 각 step 마다 claude --chrome 1회 spawn. 단일 step 프롬프트로 Claude 가
 *     통합 판단할 여지를 없앰 → 전수 감사 보장.
 *   - Chrome 탭은 재사용 (focusChromeTab) → 인증·로드 중복 없음.
 *
 * 출력:
 *   ~/.jarvis/ # ALLOW-DOTJARVISstate/virtualoffice-audit/sessions/{YYYYMMDD-HHmm}/
 *     ├── checkpoint.json
 *     ├── observations.jsonl
 *     ├── transcript.log
 *     └── screenshots/{step_id}.png
 *
 * Usage:
 *   node virtualoffice-audit.mjs                       # 전체 (safe_mode=true 기본)
 *   node virtualoffice-audit.mjs --limit 3             # 스모크 (3 step)
 *   node virtualoffice-audit.mjs --scope popups        # DOM 팝업만
 *   node virtualoffice-audit.mjs --scope canvas        # 캔버스만
 *   node virtualoffice-audit.mjs --resume              # 최신 세션 이어서
 *   node virtualoffice-audit.mjs --session 20260420-1500
 *   node virtualoffice-audit.mjs --no-discord          # Discord 알림 생략
 *   node virtualoffice-audit.mjs --unsafe              # destructive 액션 실제 수행
 *   node virtualoffice-audit.mjs --dry-run             # 프롬프트만 출력, Claude 호출 X
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, appendFileSync, createWriteStream } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { openInChrome, focusChrome, focusChromeTab, captureViewport, runClaudeChromeStream, sleep } from '../lib/chrome-automate.mjs';

// ── 인수 파싱 ────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
function flag(n)       { return argv.includes(`--${n}`); }
function opt(n, dflt)  { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : dflt; }

const LIMIT       = Number(opt('limit', '0')) || 0;
const SCOPE       = opt('scope', 'all');
const SESSION_OPT = opt('session', null);
const RESUME      = flag('resume');
const NO_DISCORD  = flag('no-discord');
const DRY_RUN     = flag('dry-run');
const UNSAFE      = flag('unsafe');

// ── 경로 ─────────────────────────────────────────────────────────────────
const STATE_DIR    = join(homedir(), '.jarvis', 'state', 'virtualoffice-audit');
const CONFIG_PATH  = join(homedir(), '.jarvis', 'config', 'virtualoffice-audit.json');
const INVENTORY    = join(STATE_DIR, 'inventory.json');
const SESSIONS_DIR = join(STATE_DIR, 'sessions');

mkdirSync(SESSIONS_DIR, { recursive: true });

if (!existsSync(CONFIG_PATH)) { console.error(`❌ 설정 없음: ${CONFIG_PATH}`); process.exit(1); }
if (!existsSync(INVENTORY))   { console.error(`❌ inventory.json 없음. Phase 1 먼저.`); process.exit(1); }

const config    = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
const inventory = JSON.parse(readFileSync(INVENTORY, 'utf-8'));
const SAFE_MODE = UNSAFE ? false : !!config.safe_mode;
const TARGET_URL = (config.board_url || 'https://board.ramsbaby.com') + (config.map_path || '/company'); // privacy:allow personal-domain

// ── 세션 결정 ───────────────────────────────────────────────────────────
function nowStamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}
function latestSession() {
  if (!existsSync(SESSIONS_DIR)) return null;
  const dirs = readdirSync(SESSIONS_DIR).filter((n) => /^\d{8}-\d{4}$/.test(n));
  dirs.sort();
  return dirs.at(-1) || null;
}

let sessionName;
if (SESSION_OPT) sessionName = SESSION_OPT;
else if (RESUME)  sessionName = latestSession() || nowStamp();
else              sessionName = nowStamp();

const SESSION_DIR    = join(SESSIONS_DIR, sessionName);
const SCREENSHOT_DIR = join(SESSION_DIR, 'screenshots');
const OBS_FILE       = join(SESSION_DIR, 'observations.jsonl');
const CHECKPOINT     = join(SESSION_DIR, 'checkpoint.json');
const TRANSCRIPT     = join(SESSION_DIR, 'transcript.log');

mkdirSync(SCREENSHOT_DIR, { recursive: true });

let completed = new Set();
if (existsSync(CHECKPOINT)) {
  try { completed = new Set(JSON.parse(readFileSync(CHECKPOINT, 'utf-8')).completed || []); } catch {}
}

// ── step 목록 구성 ──────────────────────────────────────────────────────
function buildSteps() {
  const canvas = inventory.canvas_elements || [];
  const dom    = inventory.dom_popups || [];
  let steps = [];
  if (SCOPE === 'canvas') steps = canvas;
  else if (SCOPE === 'popups') steps = dom;
  else steps = [...canvas, ...dom];
  steps = steps.filter((s) => !completed.has(s.step_id));
  if (LIMIT > 0) steps = steps.slice(0, LIMIT);
  return steps;
}

// ── Discord 알림 ───────────────────────────────────────────────────────
async function notifyDiscord(text) {
  if (NO_DISCORD) return;
  try {
    const mod = await import('../lib/discord-notify.mjs');
    if (mod.discordSend) await mod.discordSend(text, { channel: config.discord?.channel || 'jarvis-system' });
  } catch {}
}

// ── 단일 step 프롬프트 ──────────────────────────────────────────────────
function buildSingleStepPrompt(step, idx, total, isFirst) {
  const intent = inventory.project_intent;
  const intentBlock = intent ? `
# 🎯 프로젝트 의도 (판정 기준)
**자비스맵 4기둥** (SSoT: ${intent.source}):
${intent.pillars.map((p, i) => `${i + 1}. ${p}`).join('\n')}
` : '';

  const authBlock = isFirst && config.auth?.hint ? `
# 🔐 최초 진입 인증 (이 step 에서만 수행)
${config.auth.hint}
` : '';

  const safetyNote = SAFE_MODE && step.destructive
    ? '⚠️ SAFE_MODE + destructive → **실제 클릭 금지**. 버튼 위치·상태만 시각 확인하고 "safe_mode 로 클릭 생략" 이라고 관측 기록.'
    : '정상 조작 1회 수행.';

  return `너는 지금 Chrome 활성 탭에서 ${TARGET_URL} (자비스보드의 자비스맵) 을 보고 있다.
43 step 전수조사 중 ${idx + 1}번째 / ${total}.
${authBlock}${intentBlock}
# 🎯 이번 1개 step 만 수행
- **step_id**: ${step.step_id}
- **레이어**: ${step.layer} (${step.layer === 'canvas' ? 'Canvas 픽셀' : 'DOM 팝업'})
- **컴포넌트**: ${step.component || 'VirtualOffice'}
- **설명**: ${step.description}
- **힌트**: ${step.hint || step.description}
- **기대 동작**: ${step.expected || '(명시 없음)'}
- **destructive**: ${!!step.destructive}

# 지침
1. 위 step 만 집중 수행. 다른 요소·이전 step 은 건드리지 마라.
2. ${safetyNote}
3. 조작 후 1~2초 기다려 화면 변화 확인.
4. 불필요한 탐색 금지. 이 step 대상만 찾아 조작하고 즉시 응답.

# 🚨 응답 형식 (강제 — 위반 시 전체 step 실패로 기록됨)

**반드시** 응답 마지막에 아래 형식 한 줄을 포함해야 한다. 한 줄이 없으면 파싱 실패·재시도 대상.

STEP_RESULT: {"step_id":"${step.step_id}","ok":true|false,"action":"1~2문장","observed":"1~3문장","matches_expected":true|false,"overcook_note":null|"1문장","intent_fit":"high|mid|low|unknown","justification":"왜 존재하는가 한 문장, 불명이면 null","issues":[]}

체크리스트 (응답 보내기 직전 자기검열):
- [ ] 응답 **마지막 라인**이 \`STEP_RESULT: {...}\` 로 시작하는가?
- [ ] JSON이 한 줄인가? (줄바꿈 금지)
- [ ] step_id가 "${step.step_id}" 와 정확히 일치하는가?

필드 정의:
- **intent_fit**: 위 4기둥 중 하나에 직접 기여(high) / 간접·UX(mid) / 무관(low) / 판정 불가(unknown)
- **justification**: 이 기능이 왜 필요한가 한 문장. 답 못 하면 null (= 존재 이유 의심)
- **overcook_note**: 같은 기능이 다른 경로에도 있는 중복·과도한 기능이면 1문장, 없으면 null
- **issues**: UX·버그·오버쿡 이슈 배열. 없으면 []`;
}

// ── observations 기록 ──────────────────────────────────────────────────
function recordObservation(entry) {
  appendFileSync(OBS_FILE, JSON.stringify(entry) + '\n');
}
function saveCheckpoint() {
  writeFileSync(CHECKPOINT, JSON.stringify({
    session: sessionName,
    completed: [...completed],
    updated_at: new Date().toISOString(),
  }, null, 2));
}
function parseStepResult(line) {
  const m = line.match(/^STEP_RESULT:\s*(\{.+\})\s*$/);
  if (!m) return null;
  try { return JSON.parse(m[1]); } catch { return null; }
}

// ── 메인 실행 ───────────────────────────────────────────────────────────
async function main() {
  const steps = buildSteps();
  const totalAll = (SCOPE === 'canvas' ? inventory.canvas_elements : SCOPE === 'popups' ? inventory.dom_popups : [...inventory.canvas_elements, ...inventory.dom_popups]).length;

  console.log('━'.repeat(60));
  console.log(`🎯 VirtualOffice Audit v4 (1-step-per-spawn) — ${sessionName}`);
  console.log(`   URL        : ${TARGET_URL}`);
  console.log(`   Scope      : ${SCOPE}`);
  console.log(`   Safe mode  : ${SAFE_MODE ? 'ON' : 'OFF'}`);
  console.log(`   Dry run    : ${DRY_RUN ? 'YES' : 'no'}`);
  console.log(`   Steps      : ${steps.length} (already completed: ${completed.size}, total scope: ${totalAll})`);
  console.log(`   step TO    : ${((config.timeouts?.step_ms ?? 180000) / 1000).toFixed(0)}초`);
  console.log('━'.repeat(60));

  if (steps.length === 0) { console.log('⏭️  실행할 step 없음.'); return; }

  if (DRY_RUN) {
    const p = buildSingleStepPrompt(steps[0], 0, steps.length, true);
    console.log(`📄 첫 step 프롬프트 (${p.length} 바이트) 미리보기:\n`);
    console.log(p.slice(0, 1200));
    console.log('\n... (이하 생략)');
    return;
  }

  await notifyDiscord(
    `🗺️ **VirtualOffice 전수조사 v4 시작**\n세션: ${sessionName}\nScope: ${SCOPE}, Steps: ${steps.length}, Safe: ${SAFE_MODE}`,
  );

  // 최초 1회 탭 열기
  console.log(`\n🖥️  Chrome 에서 ${TARGET_URL} 열기…`);
  openInChrome(TARGET_URL);
  await sleep(config.timeouts?.page_load_ms ?? 6000);

  const startMs = Date.now();
  const notifyEvery = config.discord?.notify_every_pct ?? 25;
  const notifiedMarks = new Set();
  const transcriptOut = createWriteStream(TRANSCRIPT, { flags: 'a' });

  let okCount = 0, failCount = 0, timeoutCount = 0;

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    const idxLabel = `[${i + 1}/${steps.length}]`;
    const elapsedMin = ((Date.now() - startMs) / 60000).toFixed(1);
    console.log(`\n${idxLabel} ${step.step_id}  (경과 ${elapsedMin}분)`);

    // Chrome 탭 재사용 (두 번째 이후)
    if (i === 0) {
      focusChrome();
    } else {
      focusChromeTab(TARGET_URL);
      await sleep(500);
    }

    const prompt = buildSingleStepPrompt(step, i, steps.length, i === 0);
    transcriptOut.write(`\n\n===== [${i + 1}/${steps.length}] ${step.step_id} =====\n`);

    // 2026-04-21: 타임아웃·파싱 실패 시 1회 자동 재시도 (근본 원인 — Claude CLI cold start + 프롬프트 순응도 편차)
    let lastLine = '';
    let parsed = null;
    let result;
    let retryAttempts = 0;
    const maxAttempts = 2;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      retryAttempts = attempt;
      if (attempt > 1) {
        transcriptOut.write(`\n--- RETRY attempt ${attempt}/${maxAttempts} (prev: timeout=${result.timedOut}, parsed=${!!parsed}) ---\n`);
        console.log(`  🔄 재시도 ${attempt}/${maxAttempts} (탭 재포커스 + 2초 대기)`);
        focusChromeTab(TARGET_URL);
        await sleep(2000);
      }
      result = await runClaudeChromeStream(prompt, {
        timeoutMs: config.timeouts?.step_ms ?? 180000,
        onLine: (line) => {
          transcriptOut.write(line + '\n');
          const p = parseStepResult(line);
          if (p) parsed = p;
          lastLine = line;
        },
      });
      // 성공 조건: parsed 가 있으면 종료. 없으면 재시도 (timeout·자연어만 응답 모두 해당)
      if (parsed) break;
    }

    // 스크린샷 (조작 직후)
    await sleep(600);
    focusChromeTab(TARGET_URL);
    await sleep(300);
    const shotPath = join(SCREENSHOT_DIR, `${step.step_id}.png`);
    captureViewport(shotPath);

    const obs = {
      step_id: step.step_id,
      layer: step.layer,
      component: step.component,
      ts: new Date().toISOString(),
      ok: parsed?.ok === true && (parsed?.matches_expected !== false),
      action: parsed?.action ?? null,
      observed: parsed?.observed ?? null,
      matches_expected: parsed?.matches_expected ?? null,
      overcook_note: parsed?.overcook_note ?? null,
      intent_fit: parsed?.intent_fit ?? null,
      justification: parsed?.justification ?? null,
      issues: Array.isArray(parsed?.issues) ? parsed.issues : [],
      destructive: !!step.destructive,
      safe_mode_skipped: SAFE_MODE && !!step.destructive,
      screenshot: shotPath,
      claude_exit: result.code,
      claude_timed_out: result.timedOut,
      parsed_ok: !!parsed,
      retry_attempts: retryAttempts,
    };
    recordObservation(obs);
    completed.add(step.step_id);
    saveCheckpoint();

    if (parsed) {
      if (obs.ok) okCount++; else failCount++;
      const mark = obs.ok ? '✅' : (obs.safe_mode_skipped ? '🚧' : '⚠️');
      console.log(`  ${mark} ok=${obs.ok} intent=${obs.intent_fit ?? '-'}  ${(obs.action ?? '').slice(0, 70)}`);
      if (obs.overcook_note) console.log(`  🔁 overcook: ${obs.overcook_note}`);
      if (obs.issues?.length) console.log(`  📌 issues: ${obs.issues[0].slice(0, 80)}`);
    } else {
      failCount++;
      if (result.timedOut) timeoutCount++;
      console.log(`  ❌ STEP_RESULT 파싱 실패 (timeout=${result.timedOut}, exit=${result.code})`);
    }

    // 진행률 Discord 알림
    const pct = Math.floor(((i + 1) / steps.length) * 100);
    const markPct = Math.floor(pct / notifyEvery) * notifyEvery;
    if (markPct > 0 && markPct < 100 && !notifiedMarks.has(markPct)) {
      notifiedMarks.add(markPct);
      notifyDiscord(`🗺️ 감사 ${markPct}% (${i + 1}/${steps.length}) — ${sessionName}`).catch(() => {});
    }
  }

  transcriptOut.end();

  const elapsedMin = ((Date.now() - startMs) / 60000).toFixed(1);
  console.log('\n' + '━'.repeat(60));
  console.log(`✅ 완료 — ${sessionName}`);
  console.log(`   step: ${steps.length}건  /  정상 ${okCount}  /  이상 ${failCount} (타임아웃 ${timeoutCount})`);
  console.log(`   소요: ${elapsedMin}분`);
  console.log(`   세션: ${SESSION_DIR}`);
  console.log(`   리포트: node virtualoffice-audit-report.mjs --session ${sessionName}`);

  await notifyDiscord(
    `✅ **VirtualOffice 감사 완료** — ${okCount}✅ / ${failCount}⚠️ (${elapsedMin}분)\n세션: ${sessionName}`,
  );
}

main().catch(async (e) => {
  console.error('❌ 실행 오류:', e);
  await notifyDiscord(`❌ VirtualOffice 감사 실패 — ${e.message}`);
  process.exit(1);
});
