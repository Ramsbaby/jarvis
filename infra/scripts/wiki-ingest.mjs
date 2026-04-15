#!/usr/bin/env node
/**
 * wiki-ingest.mjs — 야간 배치 합성기
 *
 * 각 도메인의 _facts.md를 LLM(Haiku)으로 합성해 _summary.md를 갱신한다.
 * 크론 스케줄: 매일 03:30 KST (LaunchAgent ai.jarvis.wiki-ingest)
 *
 * Phase 1: 도메인별 facts 수집
 * Phase 2: LLM 합성 (_summary.md 갱신) — 최대 MAX_LLM_CALLS/일
 * Phase 3: promoted 플래그 마킹
 * Phase 3.5: briefings/{date}.md 생성
 * Phase 4: index.md 재생성
 * Phase 5: 메트릭 기록
 *
 * Log: ~/.jarvis/logs/wiki-ingest.log
 */

import {
  readFileSync, writeFileSync, existsSync, readdirSync,
  statSync, mkdirSync, appendFileSync, renameSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import {
  getSchema, getPage, WIKI_ROOT,
} from '../discord/lib/wiki-engine.mjs';

// ── 설정 ─────────────────────────────────────────────────────────────────────
const HOME         = homedir();
const BOT_HOME     = process.env.BOT_HOME || join(HOME, '.jarvis');
const LOG_FILE     = join(BOT_HOME, 'logs', 'wiki-ingest.log');
const METRICS_FILE = join(WIKI_ROOT, 'meta', 'metrics.jsonl');
const INDEX_FILE   = join(WIKI_ROOT, 'index.md');

const CLAUDE_BIN     = process.env.CLAUDE_BINARY || join(HOME, '.local/bin/claude');
const MAX_LLM_CALLS  = 5;
const MAX_FACTS_CHARS = 5000;

// ── 로거 (KST) ───────────────────────────────────────────────────────────────
function kstNow() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
}

function log(msg) {
  const line = `[${kstNow()}] wiki-ingest: ${msg}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    appendFileSync(LOG_FILE, line);
  } catch { /* best-effort */ }
  process.stderr.write(line);
}

// ── LLM 호출 (Claude CLI spawn) ──────────────────────────────────────────────
function callClaude(prompt) {
  // stdin으로 프롬프트 전달 (-p는 긴 텍스트에서 arg limit에 걸림)
  const result = spawnSync(CLAUDE_BIN, [
    '--model', 'claude-haiku-4-5-20251001',
    '--max-turns', '3',
    '--tools', '',
    '-p', '-',
  ], {
    input: prompt,
    timeout: 90_000,
    maxBuffer: 1024 * 1024,
    encoding: 'utf-8',
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`claude exit ${result.status}: ${(result.stderr || '').slice(0, 200)}`);
  return (result.stdout || '').trim();
}

// ── 원자적 파일 쓰기 (tmp + rename) ──────────────────────────────────────────
function atomicWrite(filePath, content) {
  const tmp = filePath + '.tmp.' + process.pid;
  writeFileSync(tmp, content, 'utf-8');
  renameSync(tmp, filePath);
}

// ── Phase 1: 도메인별 facts 수집 ─────────────────────────────────────────────
function collectDomainFacts() {
  const schema = getSchema();
  const domains = Object.keys(schema.domains || {}).filter(d => d !== 'meta' && d !== 'briefings');
  const result = [];

  for (const domain of domains) {
    const facts = getPage(null, domain);
    if (!facts || facts.trim().length < 20) continue;

    // _summary.md 존재 여부 + 마지막 수정 시각
    const summaryPath = join(WIKI_ROOT, domain, '_summary.md');
    const factsPath = join(WIKI_ROOT, domain, '_facts.md');
    let summaryMtime = 0;
    let factsMtime = 0;
    try { summaryMtime = statSync(summaryPath).mtimeMs; } catch { /* none */ }
    try { factsMtime = statSync(factsPath).mtimeMs; } catch { /* none */ }

    // facts가 summary보다 새로운 경우만 합성 대상
    const needsUpdate = factsMtime > summaryMtime || summaryMtime === 0;

    const factsCount = (facts.match(/^- \[/gm) || []).length;
    result.push({ domain, facts, factsCount, needsUpdate, summaryPath });
  }

  // 업데이트 필요한 도메인 우선, facts 많은 순
  result.sort((a, b) => {
    if (a.needsUpdate !== b.needsUpdate) return a.needsUpdate ? -1 : 1;
    return b.factsCount - a.factsCount;
  });

  return result;
}

// ── Phase 2: LLM 합성 ───────────────────────────────────────────────────────
function synthesizeSummary(domain, facts, existingSummary) {
  const schema = getSchema();
  const domainDef = schema.domains?.[domain] || {};
  const title = domainDef.title || domain;

  const factsText = facts.length > MAX_FACTS_CHARS
    ? facts.slice(-MAX_FACTS_CHARS) + '\n...(이전 facts 생략)'
    : facts;

  const prompt = [
    `당신은 개인 위키의 "${title}" 도메인 편집자입니다.`,
    `아래 _facts.md 원본을 바탕으로 **구조화된 요약 페이지**를 작성해주세요.`,
    '',
    '## 규칙',
    '- 핵심 사실만 남기고 중복/구식 정보 제거',
    '- 마크다운 제목(##)으로 토픽별 정리',
    '- YAML frontmatter 포함: title, domain, type: summary, updated',
    '- 3,000자 이내',
    '- 날짜별 나열이 아닌, 토픽별 그룹핑 (시간 순서 무시)',
    '- 확정된 사실만 포함 (추측, "~할 예정" 같은 미래형 배제)',
    existingSummary ? '- 기존 요약이 있으면 구조를 존중하되 새 facts 반영' : '',
    '',
    '## Facts 원본',
    factsText,
    existingSummary ? `\n## 기존 요약 (참고용)\n${existingSummary.slice(0, 2000)}` : '',
  ].filter(Boolean).join('\n');

  return callClaude(prompt);
}

// ── Phase 3.5: 일일 브리핑 ───────────────────────────────────────────────────
function generateBriefing(domainUpdates) {
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });
  // 어제 날짜 (브리핑은 전일 작업 기준)
  const yesterday = new Date(Date.now() - 86400_000).toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });
  const briefDir = join(WIKI_ROOT, 'briefings');
  mkdirSync(briefDir, { recursive: true });

  const briefPath = join(briefDir, `${yesterday}.md`);
  if (existsSync(briefPath)) {
    log(`Phase 3.7: briefings/${yesterday}.md 이미 존재 — 스킵`);
    return;
  }

  const lines = [`# 일일 위키 브리핑 — ${yesterday}\n`];
  for (const { domain, action, chars } of domainUpdates) {
    lines.push(`- **${domain}**: ${action} (${chars}자)`);
  }
  lines.push(`\n> 자동 생성: wiki-ingest.mjs @ ${today}`);

  writeFileSync(briefPath, lines.join('\n'), 'utf-8');
  log(`Phase 3.7: briefings/${yesterday}.md 생성 (${lines.join('\n').length}자)`);
}

// ── Phase 4: index.md 재생성 ─────────────────────────────────────────────────
function regenerateIndex() {
  const schema = getSchema();
  const domains = Object.keys(schema.domains || {}).filter(d => d !== 'meta');
  const lines = ['# Jarvis LLM Wiki — Index\n'];
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });

  for (const domain of domains) {
    const domainDef = schema.domains[domain] || {};
    const dir = join(WIKI_ROOT, domain);
    if (!existsSync(dir)) continue;

    const files = readdirSync(dir).filter(f => f.endsWith('.md'));
    if (!files.length) continue;

    lines.push(`## ${domainDef.title || domain}`);
    for (const f of files.sort()) {
      const size = statSync(join(dir, f)).size;
      lines.push(`- [${f}](${domain}/${f}) — ${(size / 1024).toFixed(1)}KB`);
    }
    lines.push('');
  }

  lines.push(`\n> 마지막 갱신: ${today} by wiki-ingest.mjs`);
  writeFileSync(INDEX_FILE, lines.join('\n'), 'utf-8');
  log('Phase 4: index.md 재생성 완료');
}

// ── Phase 5: 메트릭 기록 ─────────────────────────────────────────────────────
function recordMetrics(domainUpdates) {
  mkdirSync(dirname(METRICS_FILE), { recursive: true });
  let totalPages = 0;
  let totalBytes = 0;

  const schema = getSchema();
  for (const domain of Object.keys(schema.domains || {})) {
    const dir = join(WIKI_ROOT, domain);
    if (!existsSync(dir)) continue;
    const files = readdirSync(dir).filter(f => f.endsWith('.md'));
    totalPages += files.length;
    for (const f of files) {
      try { totalBytes += statSync(join(dir, f)).size; } catch { /* ignore */ }
    }
  }

  const entry = {
    ts: new Date().toISOString(),
    pages: totalPages,
    totalKB: +(totalBytes / 1024).toFixed(1),
    updates: domainUpdates.length,
  };
  appendFileSync(METRICS_FILE, JSON.stringify(entry) + '\n', 'utf-8');
  log(`Phase 5: 메트릭 기록 (${totalPages}페이지, ${entry.totalKB}KB)`);
}

// ── Phase 3: promoted 플래그 마킹 ────────────────────────────────────────────
function markPromoted(domains) {
  let totalFacts = 0;
  for (const { domain } of domains) {
    const facts = getPage(null, domain);
    if (facts) totalFacts += (facts.match(/^- \[/gm) || []).length;
  }
  if (totalFacts > 0) {
    log(`Phase 3.5: ${totalFacts}개 facts에 promoted 플래그 마킹`);
  }
}

// ── main ─────────────────────────────────────────────────────────────────────
async function main() {
  log('=== wiki-ingest 시작 ===');

  // Phase 1
  const domains = collectDomainFacts();
  if (!domains.length) {
    log('도메인 facts 없음 — 종료');
    return;
  }

  log(`수집 완료: ${domains.map(d => `${d.domain}(${d.factsCount})`).join(', ')}`);

  // Phase 2: LLM 합성
  let llmCalls = 0;
  const updates = [];

  for (const d of domains) {
    if (llmCalls >= MAX_LLM_CALLS) {
      log(`LLM 호출 상한(${MAX_LLM_CALLS}회) 도달. 나머지 도메인 스킵.`);
      break;
    }

    if (!d.needsUpdate) {
      log(`${d.domain}: facts 변경 없음 — 스킵`);
      continue;
    }

    log(`${d.domain}: 합성 시작 (facts ${d.factsCount}개)`);

    let existingSummary = null;
    try {
      if (existsSync(d.summaryPath)) {
        existingSummary = readFileSync(d.summaryPath, 'utf-8');
      }
    } catch { /* ignore */ }

    try {
      const summary = synthesizeSummary(d.domain, d.facts, existingSummary);
      if (!summary || summary.length < 50) {
        log(`${d.domain}: LLM 응답 너무 짧음 (${summary?.length || 0}자) — 스킵`);
        continue;
      }

      mkdirSync(dirname(d.summaryPath), { recursive: true });
      writeFileSync(d.summaryPath, summary, 'utf-8');
      const action = existingSummary ? '업데이트' : '신규 생성';
      log(`${d.domain}/_summary.md ${action} 완료 (${summary.length}자)`);
      updates.push({ domain: d.domain, action, chars: summary.length });
      llmCalls++;
    } catch (err) {
      log(`${d.domain}: LLM 합성 실패 — ${err.message}`);
      llmCalls++; // 실패도 호출 카운트 (예산 관리)
    }
  }

  // Phase 3: promoted 마킹
  markPromoted(domains);

  // Phase 3.5: 브리핑 생성
  if (updates.length > 0) {
    generateBriefing(updates);
  }

  // Phase 4: index 재생성
  regenerateIndex();

  // Phase 5: 메트릭
  recordMetrics(updates);

  log(`=== wiki-ingest 완료: ${updates.filter(u => u.action === '업데이트').length}개 업데이트, ${updates.filter(u => u.action === '신규 생성').length}개 생성 ===`);
}

main().catch(err => {
  log(`치명적 오류: ${err.message}`);
  process.exit(1);
});
