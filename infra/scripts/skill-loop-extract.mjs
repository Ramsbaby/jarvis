#!/usr/bin/env node
// skill-loop-extract.mjs — 스킬 자가 생성 루프 3단: 선별 세션 → 스킬 초안 (4중 게이트)
// 게이트: ①증거≥1 ②PII·시크릿·사내명 스크럽 ③기존 스킬 중복 ④quick_validate.py
// Usage: node skill-loop-extract.mjs [--date YYYY-MM-DD] [--max 3]
// 설계: ~/jarvis/runtime/state/autoplan/2026-06-10-skill-evolution-loop.md (Step 4)

import { readFileSync, readdirSync, appendFileSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const DRAFTS = join(HOME, 'jarvis', 'runtime', 'state', 'skill-drafts');
const LEDGER = join(HOME, 'jarvis', 'runtime', 'ledger', 'skill-loop.jsonl');
const MODEL_POLICY = join(HOME, 'jarvis', 'runtime', 'context', 'model-policy.json');
const ASK_CLAUDE = join(HOME, 'jarvis', 'infra', 'bin', 'ask-claude.sh');
const VALIDATOR = join(HOME, '.claude', 'commands', 'skill-creator', 'scripts', 'quick_validate.py');
const MISTAKES = join(HOME, 'jarvis', 'runtime', 'wiki', 'meta', 'learned-mistakes.md');
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const SKILL_DIRS = [join(HOME, '.claude', 'commands'), join(HOME, '.claude', 'skills')];

const args = process.argv.slice(2);
const flag = (n, d) => { const i = args.indexOf(`--${n}`); return i !== -1 && args[i + 1] ? args[i + 1] : d; };
const DATE = flag('date', new Date().toISOString().slice(0, 10));
const MAX = Number(flag('max', 3));

const ledger = (event, data) =>
  appendFileSync(LEDGER, JSON.stringify({ ts: new Date().toISOString(), event, ...data }) + '\n');

// ── 게이트 ② 스크럽 패턴 (PII·시크릿·사내명) ─────────────────────
const SCRUB_RE = [
  /sk-ant-[a-zA-Z0-9_-]{8,}/, /ghp_[a-zA-Z0-9]{10,}/, /eyJ[A-Za-z0-9_-]{20,}\./, // 토큰
  /010-\d{4}-\d{4}/, /\d{6}-\d{7}/,                                              // 전화·주민
  /[a-zA-Z0-9._%+-]+@(naver|gmail|daum)\.[a-z]{2,}/,                              // 개인 이메일
  /평창문화로|청암빌라/,                                                            // 주소
  /메타에이전트|에피소리|핵토|메타스페이스|meta-bridge/i,                            // 사내명
];

// ── 증거 추출: transcript에서 (명령, 출력) 쌍 ────────────────────
function extractEvidence(path, type) {
  const pairs = [];
  if (type === 'discord') {
    const fences = readFileSync(path, 'utf8').match(/```[\s\S]*?```/g) || [];
    for (const f of fences.slice(0, 6)) pairs.push({ cmd: '(discord 대화 발췌)', out: f.replace(/```\w*\n?|```/g, '').slice(0, 280) });
    return pairs;
  }
  let pendingCmd = null;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (pairs.length >= 8) break;
    let o; try { o = JSON.parse(line); } catch { continue; }
    const content = o?.message?.content;
    if (!Array.isArray(content)) continue;
    for (const item of content) {
      if (item.type === 'tool_use' && item.name === 'Bash' && item.input?.command) {
        pendingCmd = item.input.command.slice(0, 220);
      } else if (item.type === 'tool_result' && pendingCmd) {
        const text = typeof item.content === 'string' ? item.content
          : (item.content || []).map(c => c.text || '').join('\n');
        if (text && !/error|Exit code [1-9]/i.test(text.slice(0, 100))) {
          pairs.push({ cmd: pendingCmd, out: text.slice(0, 280) });
        }
        pendingCmd = null;
      }
    }
  }
  return pairs;
}

// ── 게이트 ③ 중복 검사: 기존 스킬 카탈로그 ───────────────────────
function existingSkills() {
  const names = new Set();
  for (const dir of SKILL_DIRS) {
    if (!existsSync(dir)) continue;
    for (const e of readdirSync(dir)) {
      const n = e.replace(/\.md$/, '');
      if (statSync(join(dir, e)).isDirectory() || e.endsWith('.md')) names.add(n.toLowerCase());
    }
  }
  return [...names];
}
function duplicateOf(slug, catalog) {
  const tokens = slug.toLowerCase().split('-').filter(t => t.length >= 3);
  for (const name of catalog) {
    if (slug.toLowerCase() === name) return name;
    const nTokens = name.split('-').filter(t => t.length >= 3);
    const overlap = tokens.filter(t => nTokens.includes(t)).length;
    if (overlap >= 2 || (nTokens.length === 1 && tokens.includes(nTokens[0]))) return name;
  }
  return null;
}

// ── 오답노트 연계: 주제 키워드로 관련 실수 검색 ───────────────────
function relatedMistakes(topic, slug) {
  if (!existsSync(MISTAKES)) return [];
  const keywords = [...new Set([...topic.split(/\s+/), ...slug.split('-')])].filter(k => k.length >= 3).slice(0, 5);
  const lines = readFileSync(MISTAKES, 'utf8').split('\n');
  const hits = [];
  for (const kw of keywords) {
    for (const l of lines) {
      if (l.includes(kw) && /패턴|대응/.test(l) && hits.length < 3 && !hits.includes(l)) hits.push(l.trim().slice(0, 200));
    }
  }
  return hits;
}

// ── 초안 본문 생성 (LLM, 분석급 모델) ─────────────────────────────
function generateBody(sel, evidence, mistakes, model) {
  const prompt = [
    '너는 AI 비서의 재사용 스킬 문서 작성기다. 아래 실제 세션 증거를 바탕으로 스킬 본문(markdown)을 작성하라.',
    `주제: ${sel.topic} / 슬러그: ${sel.slug}`,
    '',
    '필수 섹션 (이 순서·이 제목 그대로):',
    '## 언제 쓰는가 / ## 절차 / ## 검증 증거 (실측) / ## 재발 방지 가드 (오답노트 연계) / ## 롤백',
    '',
    '규칙:',
    '- "검증 증거 (실측)" 섹션에는 아래 제공된 실제 명령·출력 발췌만 사용. 창작 금지.',
    '- 절차는 제공된 증거에서 역산. 증거에 없는 단계는 "(증거 외 — 확인 필요)" 표시.',
    '- 개인정보·토큰·회사 내부명 금지. 경로는 $HOME 기준 일반화.',
    '- 첫 줄은 "# <제목>" 한국어. frontmatter 쓰지 마라 (스크립트가 붙인다).',
    '- 출력은 markdown 원문만. 코드펜스로 감싸지 마라.',
    '',
    `[관련 과거 실수 — 재발 방지 가드 섹션에 반영]`,
    mistakes.length ? mistakes.map(m => `- ${m}`).join('\n') : '- (검색된 항목 없음 — "해당 없음" 표기)',
    '',
    '[실제 세션 증거]',
    ...evidence.map((e, i) => `증거${i + 1}:\n$ ${e.cmd}\n${e.out}\n`),
  ].join('\n');
  execFileSync('bash', [ASK_CLAUDE, 'skill-loop-extract', prompt, 'Read', '240', '', '3', model], {
    timeout: 280_000, stdio: ['ignore', 'pipe', 'pipe'],
  });
  const resDir = join(BOT_HOME, 'results', 'skill-loop-extract');
  const newest = readdirSync(resDir).sort().at(-1);
  const raw = readFileSync(join(resDir, newest), 'utf8');
  let body = (raw.split(/^## Result$/m).at(-1) ?? '').trim();
  body = body.replace(/^```(markdown)?\n?/, '').replace(/\n?```\s*$/, '').trim();
  const h1 = body.indexOf('# ');
  return h1 >= 0 ? body.slice(h1) : body;
}

// ── 메인 ────────────────────────────────────────────────────────
const selFile = join(DRAFTS, `selected-${DATE}.jsonl`);
if (!existsSync(selFile)) { console.error(`선별 파일 없음: ${selFile}`); process.exit(1); }
const selected = readFileSync(selFile, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)).slice(0, MAX);
const model = JSON.parse(readFileSync(MODEL_POLICY, 'utf8')).currentLatest.sonnet; // E3: 중앙 참조 (추출=분석급)
const catalog = existingSkills();
console.log(`[추출] 대상 ${selected.length}건, 기존 스킬 카탈로그 ${catalog.length}종, 모델 ${model}`);

// 게이트 ⓪: 세션 중복 — 같은 source-session으로 이미 초안이 있으면 스킵 (슬러그 변동에 의한 중복 초안 방지)
function sessionAlreadyDrafted(sessionPath) {
  for (const state of ['pending', 'approved', 'archive']) {
    const base = join(DRAFTS, state);
    if (!existsSync(base)) continue;
    for (const d of readdirSync(base)) {
      const f = join(base, d, 'SKILL.md');
      try { if (readFileSync(f, 'utf8').includes(`source-session: ${sessionPath}`)) return `${state}/${d}`; } catch { /* skip */ }
    }
  }
  return null;
}

for (const sel of selected) {
  const tag = sel.slug || 'unnamed';
  // 게이트 ⓪: 세션 중복
  const prior = sessionAlreadyDrafted(sel.path);
  if (prior) { console.log(`  ↺ ${tag}: 동일 세션 초안 존재 (${prior}) → 스킵`); ledger('gate-reject', { slug: tag, gate: 'session-dedup', prior }); continue; }
  // 게이트 ①: 증거
  const evidence = extractEvidence(sel.path, sel.type);
  if (evidence.length < 1) { console.log(`  ✗ ${tag}: 증거 0건 → 미생성`); ledger('gate-reject', { slug: tag, gate: 'evidence', path: sel.path }); continue; }
  // 게이트 ③: 중복 (LLM 호출 전 — 비용 절약)
  const dup = duplicateOf(tag, catalog);
  const mode = dup ? 'improve-suggestion' : 'new';
  // 생성
  let body;
  try { body = generateBody(sel, evidence, relatedMistakes(sel.topic || '', tag), model); }
  catch (e) { console.log(`  ✗ ${tag}: 생성 실패 ${String(e.message).slice(0, 100)}`); ledger('gate-reject', { slug: tag, gate: 'generation', error: String(e.message).slice(0, 150) }); continue; }
  // 조립 (frontmatter는 스크립트가 결정적으로 생성 — LLM 형식 오류 차단)
  const desc = (`${sel.topic || tag} 작업의 재사용 절차. ${sel.reason || ''}`).replace(/[<>"]/g, '').slice(0, 300);
  // 게이트 ②: 스크럽 — frontmatter(description 포함)+본문 전체 검사 (/verify 지적: desc 우회 차단)
  const hit = SCRUB_RE.find(re => re.test(`${desc}\n${body}`));
  if (hit) { console.log(`  ✗ ${tag}: 스크럽 게이트 (${hit})`); ledger('gate-reject', { slug: tag, gate: 'scrub', pattern: String(hit) }); continue; }
  const created = DATE;
  const expires = new Date(Date.parse(DATE) + 14 * 86400_000).toISOString().slice(0, 10);
  const fm = [
    '---', `name: ${tag}`, `description: ${desc}`,
    'metadata:', '  origin: auto-generated', '  target: cli', `  score: ${sel.score}`,
    `  source-session: ${sel.path}`, `  evidence-count: ${evidence.length}`,
    `  mode: ${mode}`, ...(dup ? [`  duplicate-of: ${dup}`] : []),
    `  created: ${created}`, `  expires: ${expires}`, '  status: pending', '---', '',
  ].join('\n');
  const dir = join(DRAFTS, 'pending', tag);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'SKILL.md'), fm + body + '\n');
  // 게이트 ④: 기계 검증
  try { execFileSync('python3', [VALIDATOR, dir], { stdio: 'pipe' }); }
  catch (e) {
    console.log(`  ✗ ${tag}: quick_validate 실패 → archive로 이동`);
    ledger('gate-reject', { slug: tag, gate: 'validate', error: String(e.stdout || e.message).slice(0, 150) });
    execFileSync('mv', [dir, join(DRAFTS, 'archive', `${tag}-invalid-${Date.now()}`)]);
    continue;
  }
  console.log(`  ✓ ${tag}: 초안 생성 (증거 ${evidence.length}건, mode=${mode}${dup ? `, 기존 ${dup} 개선 제안` : ''})`);
  ledger('draft-created', { slug: tag, score: sel.score, evidence: evidence.length, mode, duplicateOf: dup || undefined, expires });
}
