#!/usr/bin/env node
// skill-loop-select.mjs — 스킬 자가 생성 루프 1~2단: 성공 세션 후보 선별
// 1단 휴리스틱(비LLM) → 2단 LLM 재사용 가치 스코어링 → 임계치+상한 컷
// Usage: node skill-loop-select.mjs [--hours 26] [--no-llm] [--cap 3] [--threshold 7] [--include-active]
// 설계: ~/jarvis/runtime/state/autoplan/2026-06-10-skill-evolution-loop.md (Step 2~3)

import { readFileSync, readdirSync, statSync, appendFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const PROJECTS_DIR = join(HOME, '.claude', 'projects');
const DISCORD_DIR = join(HOME, 'jarvis', 'runtime', 'context', 'discord-history');
const DRAFTS_DIR = join(HOME, 'jarvis', 'runtime', 'state', 'skill-drafts');
const LEDGER = join(HOME, 'jarvis', 'runtime', 'ledger', 'skill-loop.jsonl');
const MODEL_POLICY = join(HOME, 'jarvis', 'runtime', 'context', 'model-policy.json');
const ASK_CLAUDE = join(HOME, 'jarvis', 'infra', 'bin', 'ask-claude.sh');
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');

const args = process.argv.slice(2);
const flag = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  if (i === -1) return dflt;
  const v = args[i + 1];
  return v && !v.startsWith('--') ? v : true;
};
const HOURS = Number(flag('hours', 26));
const NO_LLM = args.includes('--no-llm');
const CAP = Number(flag('cap', 3));
const THRESHOLD = Number(flag('threshold', 7));
const INCLUDE_ACTIVE = args.includes('--include-active');
const MAX_SCORING = 5; // LLM 스코어링 호출 상한 (비용 가드)

const now = Date.now();
const cutoff = now - HOURS * 3600_000;
const activeCutoff = now - 30 * 60_000; // 30분 내 수정 = 진행 중 세션으로 간주

function ledger(event, data) {
  appendFileSync(LEDGER, JSON.stringify({ ts: new Date().toISOString(), event, ...data }) + '\n');
}

// ── 1단: 휴리스틱 ──────────────────────────────────────────────
const SUCCESS_RE = /✅|Skill is valid|syntax OK|passed|EXIT=0|successfully|완료하였습니다|통과/g;
const FAIL_RE = /Exit code [1-9]\d*|FAILED|Traceback \(most recent/g;

function scanTranscripts() {
  const out = [];
  if (!existsSync(PROJECTS_DIR)) return out;
  for (const proj of readdirSync(PROJECTS_DIR)) {
    const dir = join(PROJECTS_DIR, proj);
    let files;
    try { files = readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { continue; }
    for (const f of files) {
      const p = join(dir, f);
      const st = statSync(p);
      if (st.mtimeMs < cutoff) continue;
      if (!INCLUDE_ACTIVE && st.mtimeMs > activeCutoff) continue; // 진행 중 세션 제외
      if (st.size < 30_000) continue;
      const text = readFileSync(p, 'utf8');
      const toolUse = (text.match(/"type":"tool_use"/g) || []).length;
      const success = (text.match(SUCCESS_RE) || []).length;
      const fail = (text.match(FAIL_RE) || []).length;
      if (toolUse < 15 || success < 3 || fail > success * 2) continue;
      out.push({ type: 'cli', path: p, size: st.size, toolUse, success, fail, mtime: st.mtime.toISOString() });
    }
  }
  return out;
}

function scanDiscord() {
  const out = [];
  if (!existsSync(DISCORD_DIR)) return out;
  for (const f of readdirSync(DISCORD_DIR).filter(f => f.endsWith('.md'))) {
    const p = join(DISCORD_DIR, f);
    const st = statSync(p);
    if (st.mtimeMs < cutoff || st.size < 4_000) continue;
    const text = readFileSync(p, 'utf8');
    const fences = (text.match(/```/g) || []).length / 2;
    if (fences < 3) continue;
    out.push({ type: 'discord', path: p, size: st.size, toolUse: 0, success: 0, fail: 0, fences, mtime: st.mtime.toISOString() });
  }
  return out;
}

// ── 2단: LLM 스코어링 ──────────────────────────────────────────
function firstUserText(transcriptPath) {
  for (const line of readFileSync(transcriptPath, 'utf8').split('\n')) {
    try {
      const o = JSON.parse(line);
      const c = o?.message?.content;
      if (o?.type === 'user' && typeof c === 'string' && c.length > 20 && !c.startsWith('<')) {
        return c.slice(0, 400);
      }
    } catch { /* skip */ }
  }
  return '(첫 사용자 메시지 추출 실패)';
}

function llmScore(cand, model) {
  const intro = cand.type === 'cli'
    ? firstUserText(cand.path)
    : readFileSync(cand.path, 'utf8').slice(0, 400);
  const prompt = [
    '다음은 AI 비서 세션 하나의 통계와 시작 요청이다. 이 세션의 작업 절차가 "재사용 가능한 스킬"로 만들 가치가 있는지 평가하라.',
    '높은 점수 기준: 여러 도구를 조합한 다단계 절차, 검증 단계 존재, 향후 같은 유형 작업 재발 가능성.',
    '낮은 점수 기준: 단순 조회/1회성 질답/이미 스킬이 존재할 법한 통상 작업.',
    `통계: 도구호출=${cand.toolUse}, 성공신호=${cand.success}, 실패신호=${cand.fail}, 크기=${Math.round(cand.size / 1024)}KB, 유형=${cand.type}`,
    `시작 요청: """${intro}"""`,
    '응답은 JSON 한 개만: {"score": 0~10 정수, "topic": "주제 한 줄", "slug": "kebab-case-영문", "reason": "근거 한 줄"}',
  ].join('\n');
  try {
    execFileSync('bash', [ASK_CLAUDE, 'skill-loop-score', prompt, 'Read', '120', '', '3', model], {
      timeout: 150_000, stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (e) {
    return { score: -1, error: `ask-claude 실패: ${String(e.message).slice(0, 120)}` };
  }
  // 결과는 results/skill-loop-score/ 최신 파일에서 회수
  const resDir = join(BOT_HOME, 'results', 'skill-loop-score');
  try {
    const newest = readdirSync(resDir).sort().at(-1);
    const raw = readFileSync(join(resDir, newest), 'utf8');
    // 결과 파일은 프롬프트를 함께 보존 → '## Result' 이후만 파싱 (프롬프트 속 JSON 템플릿 오매칭 방지)
    const resultPart = raw.split(/^## Result$/m).at(-1) ?? raw;
    const m = resultPart.match(/\{\s*"score"\s*:\s*\d+[\s\S]*?\}/);
    if (m) return JSON.parse(m[0]);
    return { score: -1, error: 'JSON 미발견', raw: raw.slice(0, 150) };
  } catch (e) {
    return { score: -1, error: `결과 회수 실패: ${String(e.message).slice(0, 120)}` };
  }
}

// ── 메인 ──────────────────────────────────────────────────────
mkdirSync(DRAFTS_DIR, { recursive: true });
const candidates = [...scanTranscripts(), ...scanDiscord()]
  .sort((a, b) => (b.toolUse + b.success) - (a.toolUse + a.success));

console.log(`[1단 휴리스틱] 후보 ${candidates.length}건 (최근 ${HOURS}h)`);
for (const c of candidates) {
  console.log(`  - [${c.type}] ${c.path.split('/').pop()} tool=${c.toolUse} ok=${c.success} fail=${c.fail} ${Math.round(c.size / 1024)}KB`);
  ledger('candidate', { type: c.type, path: c.path, toolUse: c.toolUse, success: c.success, fail: c.fail });
}

let selected = [];
if (NO_LLM) {
  console.log('[2단] --no-llm: 스코어링 생략 (휴리스틱 상위만 표시)');
} else {
  const model = JSON.parse(readFileSync(MODEL_POLICY, 'utf8')).currentLatest.haiku; // E3: 중앙 참조
  for (const c of candidates.slice(0, MAX_SCORING)) {
    const s = llmScore(c, model);
    console.log(`  점수=${s.score} ${s.topic || ''} ${s.error || ''}`);
    ledger('scored', { path: c.path, ...s });
    if (s.score >= THRESHOLD) selected.push({ ...c, ...s });
  }
  selected = selected.sort((a, b) => b.score - a.score).slice(0, CAP);
  const outFile = join(DRAFTS_DIR, `selected-${new Date().toISOString().slice(0, 10)}.jsonl`);
  writeFileSync(outFile, selected.map(s => JSON.stringify(s)).join('\n') + (selected.length ? '\n' : ''));
  console.log(`[2단 선별] 임계치 ${THRESHOLD}+ → ${selected.length}건 (상한 ${CAP}) → ${outFile}`);
  for (const s of selected) ledger('selected', { path: s.path, score: s.score, slug: s.slug, topic: s.topic });
}
