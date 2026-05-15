#!/usr/bin/env node
/**
 * skill-matcher.mjs — task description으로 trigger_keywords 매칭하여 적용 skill 본문 반환
 *
 * 입력:  --prompt "task 설명" [--max 3] [--format text|json]
 * 출력:  매칭 skill 본문 (text) 또는 메타 (json)
 *
 * 호출 시점: coder-functions.sh / retry-wrapper.sh가 task 실행 전 prompt 앞에 주입
 *
 * 빠름 + 비용 0 (LLM 안 씀, frontmatter + 키워드 grep만)
 */
import { readFileSync, readdirSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME   = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const SKILLS_DIR = join(BOT_HOME, 'wiki', 'skills');
const LEDGER     = join(BOT_HOME, 'state', 'skill-matcher-ledger.jsonl');

const args = process.argv.slice(2);
const flagMap = {};
for (let i = 0; i < args.length - 1; i++) {
  if (args[i].startsWith('--')) flagMap[args[i].slice(2)] = args[i + 1];
}
const PROMPT = flagMap.prompt || '';
const MAX    = parseInt(flagMap.max || '3', 10);
const FORMAT = flagMap.format || 'text';

if (!PROMPT) {
  console.error('Usage: skill-matcher.mjs --prompt "<task 설명>" [--max 3] [--format text|json]');
  process.exit(1);
}

// ── frontmatter 파싱 (단순 yaml — 외부 의존 없이) ─────────────────────────
function parseFrontmatter(content) {
  const m = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) return { meta: {}, body: content };
  const meta = {};
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^(\w+):\s*(.+)$/);
    if (!kv) continue;
    let val = kv[2].trim();
    // 배열: [a, b, c]
    if (val.startsWith('[') && val.endsWith(']')) {
      val = val.slice(1, -1).split(',')
        .map(s => s.trim().replace(/^["']|["']$/g, ''))
        .filter(Boolean);
    } else {
      val = val.replace(/^["']|["']$/g, '');
      if (val === 'null') val = null;
      else if (/^\d+$/.test(val)) val = parseInt(val, 10);
    }
    meta[kv[1]] = val;
  }
  return { meta, body: m[2] };
}

// ── skill 매칭 (trigger_keywords intersect with prompt 단어) ─────────────
function matchSkills(prompt) {
  let files;
  try {
    files = readdirSync(SKILLS_DIR).filter(f => f.endsWith('.md') && f !== 'SKILL-TEMPLATE.md');
  } catch { return []; }
  const promptLower = prompt.toLowerCase();
  const matches = [];
  for (const f of files) {
    const fp = join(SKILLS_DIR, f);
    let content;
    try { content = readFileSync(fp, 'utf-8'); } catch { continue; }
    const { meta, body } = parseFrontmatter(content);
    const triggers = Array.isArray(meta.trigger_keywords) ? meta.trigger_keywords : [];
    const tags     = Array.isArray(meta.tags) ? meta.tags : [];
    if (triggers.length === 0 && tags.length === 0) continue;

    let score = 0;
    const hits = [];
    for (const k of triggers) {
      if (!k) continue;
      if (promptLower.includes(k.toLowerCase())) {
        score += 3;
        hits.push(k);
      }
    }
    for (const t of tags) {
      if (!t) continue;
      if (promptLower.includes(t.toLowerCase())) {
        score += 1;
        hits.push(`#${t}`);
      }
    }
    // value_score 보너스 (1~10 → 0~2)
    if (typeof meta.value_score === 'number') score += meta.value_score / 5;

    if (score > 0) {
      matches.push({ file: f, id: meta.id || f.replace('.md', ''), title: meta.title || '', score, hits, body });
    }
  }
  return matches.sort((a, b) => b.score - a.score).slice(0, MAX);
}

const matched = matchSkills(PROMPT);

// metric ledger — 매칭 결과 기록 (skill 사용 빈도 추적용)
try {
  const ledgerLine = JSON.stringify({
    ts: new Date().toISOString(),
    prompt_excerpt: PROMPT.slice(0, 100),
    matched_count: matched.length,
    matches: matched.map(m => ({ id: m.id, score: m.score, hits: m.hits })),
  }) + '\n';
  appendFileSync(LEDGER, ledgerLine);
} catch (_e) {}

if (FORMAT === 'json') {
  console.log(JSON.stringify(matched.map(m => ({ id: m.id, title: m.title, score: m.score, hits: m.hits })), null, 2));
} else {
  if (matched.length === 0) {
    // 매칭 없으면 빈 출력 (prompt 주입 시 무해)
    process.exit(0);
  }
  console.log('## 🧠 적용 가능한 skill (자동 매칭)');
  console.log('');
  for (const m of matched) {
    console.log(`### ${m.title}`);
    console.log(`> 매칭 키워드: ${m.hits.join(', ')} (score=${m.score.toFixed(1)})`);
    console.log('');
    // body 중 "## 적용 조건" + "## 해결 패턴" 섹션만 추출 (요약)
    const sections = m.body.split(/^##\s+/m);
    for (const sec of sections) {
      if (/^적용 조건|^해결 패턴|^When to use|^Solution/i.test(sec)) {
        console.log('## ' + sec.trim().slice(0, 800));
        console.log('');
      }
    }
  }
  console.log('---');
  console.log('');
}
