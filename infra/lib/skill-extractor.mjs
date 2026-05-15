#!/usr/bin/env node
/**
 * skill-extractor.mjs — Hermes 패턴 흡수: task done → skill 자동 생성
 *
 * 입력:  task transcript (또는 task id로 DB에서 조회)
 * 출력:  ~/jarvis/runtime/wiki/skills/skill-{slug}.md
 *
 * 사용:
 *   node ~/jarvis/infra/lib/skill-extractor.mjs --task-id <id> [--transcript <file>] [--dry-run]
 *
 * 호출 시점: dev-queue task done 시 background (jarvis-coder.sh 또는 coder-functions.sh hook)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { query } from '@anthropic-ai/claude-agent-sdk';
import { getTask } from './task-store.mjs';

delete process.env.CLAUDECODE;

const BOT_HOME    = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const SKILLS_DIR  = join(BOT_HOME, 'wiki', 'skills');
const MODELS_FILE = join(BOT_HOME, 'config', 'models.json');
const CLAUDE_BIN  = process.env.CLAUDE_BINARY || join(homedir(), '.local/bin/claude');
const LEDGER      = join(BOT_HOME, 'state', 'skill-extractor-ledger.jsonl');

const MODELS = existsSync(MODELS_FILE) ? JSON.parse(readFileSync(MODELS_FILE, 'utf-8')) : {};
const SONNET_MODEL = MODELS.sonnet || 'claude-sonnet-4-6';

mkdirSync(SKILLS_DIR, { recursive: true });

// ── CLI 인자 ─────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const flagMap = {};
for (let i = 0; i < args.length - 1; i++) {
  if (args[i].startsWith('--')) flagMap[args[i].slice(2)] = args[i + 1];
}
const TASK_ID = flagMap['task-id'];
const TRANSCRIPT_FILE = flagMap['transcript'];
const DRY_RUN = args.includes('--dry-run');

if (!TASK_ID) {
  console.error('Usage: skill-extractor.mjs --task-id <id> [--transcript <file>] [--dry-run]');
  process.exit(1);
}

function _log(msg) {
  const ts = new Date().toISOString();
  console.log(`[${ts}] [skill-extractor] ${msg}`);
}

function appendLedger(entry) {
  try {
    const line = JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n';
    require('node:fs').appendFileSync(LEDGER, line);
  } catch {}
}

// ── 기존 skill 중복 검사 (id 기반) ────────────────────────────────────────
function findExistingSkill(taskId) {
  if (!existsSync(SKILLS_DIR)) return null;
  for (const f of readdirSync(SKILLS_DIR)) {
    if (!f.endsWith('.md') || f === 'SKILL-TEMPLATE.md') continue;
    const content = readFileSync(join(SKILLS_DIR, f), 'utf-8');
    if (content.includes(`auto-extracted-from-task:${taskId}`)) {
      return join(SKILLS_DIR, f);
    }
  }
  return null;
}

// ── slug 생성 (한글 / 특수문자 제거) ──────────────────────────────────────
function toSlug(title) {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9가-힣\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-')
    .slice(0, 60);
}

// ── LLM 호출 (Sonnet 4.6 — 비용 효율 + 정형화 능력) ──────────────────────
async function extractSkillFromTranscript(taskMeta, transcript) {
  const prompt = `다음은 Jarvis dev-queue에서 완료된 task의 transcript입니다.

<task>
id: ${taskMeta.id}
name: ${taskMeta.name || taskMeta.id}
prompt: ${taskMeta.prompt || '(empty)'}
status: ${taskMeta.status}
</task>

<transcript>
${transcript.slice(0, 30000)}
</transcript>

위 task에서 **재사용 가능한 skill**(다른 비슷한 task에 적용할 수 있는 패턴)을 추출하세요.
재사용 가치가 없으면 (단발 작업, 너무 specific 등) "{}"만 반환하세요.

추출 시 다음 JSON 형식으로만 반환하세요. 추가 설명 없이 JSON만:

{
  "title": "한 줄 제목 (50자 이내)",
  "trigger_keywords": ["키워드1", "키워드2", ...],
  "tags": ["domain", "technology", ...],
  "when_to_use": "어떤 상황에서 적용? (3-5줄)",
  "solution": "해결 패턴 (단계별)",
  "code_snippet": "재사용 가능 코드 (있으면)",
  "caveats": "주의사항 / 함정",
  "value_score": 1~10
}

규칙:
- value_score 6 미만이면 빈 {} 반환 (너무 사소한 패턴은 skill로 만들지 않음)
- title은 명사구 (~"...로 ~~하기" 같은 동사형 X)
- trigger_keywords는 다음 비슷한 task가 들어왔을 때 매칭에 쓰일 수 있게 명확히`;

  const opts = {
    model: SONNET_MODEL,
    pathToClaudeCodeExecutable: CLAUDE_BIN,
    maxTurns: 1,
  };

  let result = '';
  for await (const msg of query({ prompt, options: opts })) {
    if (msg.type === 'assistant' && Array.isArray(msg.message?.content)) {
      for (const block of msg.message.content) {
        if (block.type === 'text') result += block.text;
      }
    }
  }
  const cleaned = result.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();
  if (cleaned === '{}' || cleaned === '') return null;
  try {
    return JSON.parse(cleaned);
  } catch {
    const match = cleaned.match(/\{[\s\S]+\}/);
    if (match) return JSON.parse(match[0]);
    throw new Error(`JSON 파싱 실패: ${cleaned.slice(0, 200)}`);
  }
}

// ── skill 문서 작성 ─────────────────────────────────────────────────────
function writeSkillDoc(extracted, taskId) {
  const slug = toSlug(extracted.title);
  const fp = join(SKILLS_DIR, `skill-${slug}.md`);
  const today = new Date().toISOString().slice(0, 10);
  const content = `---
id: skill-${slug}
title: "${extracted.title.replace(/"/g, '\\"')}"
created: ${today}
updated: ${today}
last_used: null
success_count: 0
fail_count: 0
source: "auto-extracted-from-task:${taskId}"
tags: [${(extracted.tags || []).map(t => `"${t}"`).join(', ')}]
related_skills: []
trigger_keywords: [${(extracted.trigger_keywords || []).map(k => `"${k}"`).join(', ')}]
value_score: ${extracted.value_score || 5}
---

# ${extracted.title}

## 적용 조건 (When to use)
${extracted.when_to_use || '(미작성)'}

## 해결 패턴 (Solution)
${extracted.solution || '(미작성)'}

## 코드 스니펫 (Code)
\`\`\`
${extracted.code_snippet || '(없음)'}
\`\`\`

## 주의사항 (Caveats)
${extracted.caveats || '(없음)'}

## 학습 출처
- Task: \`${taskId}\`
- 자동 추출: ${new Date().toISOString()}
`;
  writeFileSync(fp, content, 'utf-8');
  return fp;
}

// ── 메인 ────────────────────────────────────────────────────────────────
async function main() {
  _log(`task=${TASK_ID} dry-run=${DRY_RUN}`);

  // 1. 기존 skill 중복 체크
  const existing = findExistingSkill(TASK_ID);
  if (existing && !DRY_RUN) {
    _log(`이미 존재: ${existing} (skip)`);
    appendLedger({ task_id: TASK_ID, action: 'skip-existing', file: existing });
    process.exit(0);
  }

  // 2. task 메타 로드
  const taskMeta = getTask(TASK_ID);
  if (!taskMeta) {
    _log(`task not found: ${TASK_ID}`);
    process.exit(1);
  }

  // 3. transcript 로드
  let transcript = '';
  if (TRANSCRIPT_FILE && existsSync(TRANSCRIPT_FILE)) {
    transcript = readFileSync(TRANSCRIPT_FILE, 'utf-8');
  } else {
    transcript = JSON.stringify(taskMeta.meta || {}, null, 2);
  }

  // 4. LLM 호출
  let extracted;
  try {
    extracted = await extractSkillFromTranscript(taskMeta, transcript);
  } catch (err) {
    _log(`LLM 호출 실패: ${err.message}`);
    appendLedger({ task_id: TASK_ID, action: 'llm-fail', error: err.message });
    process.exit(1);
  }

  if (!extracted || (extracted.value_score && extracted.value_score < 6)) {
    _log(`재사용 가치 낮음 (score=${extracted?.value_score || 'null'}) — skill 생성 안 함`);
    appendLedger({ task_id: TASK_ID, action: 'skip-low-value', score: extracted?.value_score });
    process.exit(0);
  }

  // 5. dry-run vs 실제 쓰기
  if (DRY_RUN) {
    _log(`[dry-run] extracted: ${JSON.stringify(extracted, null, 2).slice(0, 500)}`);
    process.exit(0);
  }

  const fp = writeSkillDoc(extracted, TASK_ID);
  _log(`✅ skill 생성: ${fp}`);
  appendLedger({ task_id: TASK_ID, action: 'created', file: fp, score: extracted.value_score });
}

main().catch(err => {
  _log(`fatal: ${err.message}`);
  process.exit(1);
});
